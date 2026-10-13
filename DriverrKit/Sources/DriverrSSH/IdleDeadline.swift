import Foundation

/// When a byte last moved on one stream, in either direction.
///
/// The work under `withIdleDeadline` marks it and the deadline's timer reads it, from
/// different tasks, so it is guarded by a lock. `ContinuousClock` counts time the app spent
/// suspended, so a command that was out when the app went to the background can be called
/// stalled on return.
final class StreamActivity: @unchecked Sendable {
  private let lock = NSLock()
  private var last = ContinuousClock.now

  /// Call when a send has returned or output has arrived.
  func moved() {
    lock.withLock { last = .now }
  }

  /// How long it has been since the last byte moved, or since the work started.
  var idleTime: Duration {
    lock.withLock { ContinuousClock.now - last }
  }
}

/// Runs `work` over `stream`, and gives up once no byte has moved for `deadline`.
///
/// For a command that reads its standard input. Nothing in SSH ends one on a host that has
/// stopped answering. If the start-up files of the host's shell take some of the input,
/// `head -c` waits for bytes that are not coming, and the caller waits for `head`.
///
/// The deadline counts idle time, not the whole call, so a large upload on a slow link is
/// not stopped while it still moves. `work` calls `StreamActivity.moved()` each time a send
/// returns or output arrives. The timer sleeps for the deadline, then sleeps again for the
/// part of it that a later byte bought back, as `ConnectionCoordinator.withHandshakeDeadline`
/// does for human time. Nothing polls.
///
/// **Not a task group.** A group waits for every child. A send parked on a dead link fails
/// only when the peer answers the close, so a group would wait out the stall it is there to
/// end. `work` runs as an unstructured task that may be abandoned, the shape of
/// `PaneComposerModel.bounded`. The first of three things settles the call, exactly once:
/// `work` ending, the deadline, or the caller's cancellation. The last two cancel `work` and
/// close the stream. The close ends a read of the output. It does not end a parked send,
/// which stays parked until the connection goes.
///
/// - Parameter stalled: what to throw on the deadline. Each caller has its own error type.
/// - Throws: what `work` threw, `stalled`, or `CancellationError`.
func withIdleDeadline<T: Sendable>(
  _ deadline: Duration,
  over stream: any ExecStream,
  stalled: any Error,
  _ work: @escaping @Sendable (StreamActivity) async throws -> T
) async throws -> T {
  switch await firstToSettle(deadline, work: work, discarding: { _ in }) {
  case .finished(let result):
    return try result.get()
  case .stalled:
    await stream.close()
    throw stalled
  case .cancelled:
    await stream.close()
    throw CancellationError()
  }
}

/// Opens a stream, and gives up once `deadline` has passed with no stream.
///
/// A link that died before the command was sent never answers the channel open, and an open
/// does not check cancellation. Without this the caller waits before `withIdleDeadline` has
/// a stream to watch.
///
/// **A stream that opens after the call has settled is closed here.** Nobody else holds it,
/// and on the host its command would wait for input.
///
/// - Throws: what `open` threw, `stalled`, or `CancellationError`.
func openingStream(
  within deadline: Duration,
  stalled: any Error,
  _ open: @escaping @Sendable () async throws -> any ExecStream
) async throws -> any ExecStream {
  switch await firstToSettle(deadline, work: { _ in try await open() }, discarding: { await $0.close() }) {
  case .finished(let result):
    return try result.get()
  case .stalled:
    throw stalled
  case .cancelled:
    throw CancellationError()
  }
}

/// The race both deadlines share. See `withIdleDeadline` for why it is not a task group.
///
/// - Parameter discard: given what `work` returned when the call had already settled
///   without it.
private func firstToSettle<T: Sendable>(
  _ deadline: Duration,
  work: @escaping @Sendable (StreamActivity) async throws -> T,
  discarding discard: @escaping @Sendable (T) async -> Void
) async -> IdleVerdict<T> {
  // Before `work` starts, so a caller that is already cancelled sends nothing.
  guard !Task.isCancelled else { return .cancelled }
  let activity = StreamActivity()
  let race = IdleRace<T>()
  let working = Task {
    do {
      let value = try await work(activity)
      if !race.settle(.finished(.success(value))) { await discard(value) }
    } catch {
      race.settle(.finished(.failure(error)))
    }
  }
  let timer = Task {
    var remaining = deadline
    while true {
      // `Task.sleep` throws on cancel. That is how a call that has settled stops this task,
      // so no sleep is left parked behind a command that finished.
      do { try await Task.sleep(for: remaining) } catch { return }
      let idle = activity.idleTime
      guard idle < deadline else { break }
      remaining = deadline - idle
    }
    race.settle(.stalled)
  }

  let verdict = await withTaskCancellationHandler {
    await withCheckedContinuation { race.arm($0) }
  } onCancel: {
    race.settle(.cancelled)
  }
  timer.cancel()
  if case .finished = verdict {} else { working.cancel() }
  return verdict
}

/// How a call under `firstToSettle` ended.
private enum IdleVerdict<T: Sendable>: Sendable {
  case finished(Result<T, any Error>)
  case stalled
  case cancelled
}

/// Whichever of the work, the deadline and a cancellation comes first, resolved exactly once.
///
/// A later `settle` finds a verdict already there and returns, which stops a double resume
/// (a crash). `settle` can also come before `arm`: the work can finish, or the caller can
/// already be cancelled, before the continuation exists. The verdict is kept and `arm`
/// resumes with it. The three callers are different tasks, so this is a lock, where
/// `PaneComposerModel.SendRace` is a `nil` check on the main actor.
private final class IdleRace<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var verdict: IdleVerdict<T>?
  private var continuation: CheckedContinuation<IdleVerdict<T>, Never>?

  func arm(_ continuation: CheckedContinuation<IdleVerdict<T>, Never>) {
    let settled = lock.withLock {
      if verdict == nil { self.continuation = continuation }
      return verdict
    }
    if let settled { continuation.resume(returning: settled) }
  }

  /// - Returns: whether this verdict is the one the call ends with.
  @discardableResult
  func settle(_ verdict: IdleVerdict<T>) -> Bool {
    let (won, waiting): (Bool, CheckedContinuation<IdleVerdict<T>, Never>?) = lock.withLock {
      guard self.verdict == nil else { return (false, nil) }
      self.verdict = verdict
      defer { continuation = nil }
      return (true, continuation)
    }
    waiting?.resume(returning: verdict)
    return won
  }
}
