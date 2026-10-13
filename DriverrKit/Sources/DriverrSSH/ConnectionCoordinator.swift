import DriverrCore
import Foundation

/// Where a connection attempt has got to.
///
/// `failed` carries the `AppError`, because a wrong password, a changed host key and an
/// unreachable host each need a different screen.
public enum ConnectionPhase: Sendable, Hashable {
  case idle
  case connecting
  case authenticating
  case connected
  case failed(AppError)
  /// The connection was up and is not any more. Reachable only from `connected`.
  ///
  /// Kept apart from `failed`: a failed attempt has something for the user to correct,
  /// and a loss only needs a retry. Reconnect logic must not fire for a connection that
  /// never came up.
  case lost(AppError)
}

/// Runs the connect sequence and remembers where it got to.
///
/// It lives here, not in a SwiftUI store, so it can be tested against the fake and a
/// real SSH server without a simulator. The app's store observes `phase`.
public actor ConnectionCoordinator {
  private let transport: any SSHTransport
  public private(set) var phase: ConnectionPhase = .idle
  /// The task watching the transport's closure signal. It is stopped before a disconnect
  /// Driverr asked for, so that disconnect is not reported as a loss.
  private var closureMonitor: Task<Void, Never>?
  /// The connected host, so a loss that `probe()` reports can name it.
  private var connectedHost: DriverrCore.Host?
  /// The loss signal for the connection currently up. See `losses`.
  private var lossStream: AsyncStream<AppError>?
  private var lossSignal: AsyncStream<AppError>.Continuation?

  /// How long a handshake may run. See `withHandshakeDeadline`.
  private let handshakeDeadline: Duration

  /// The default handshake budget.
  ///
  /// A TCP connection that is accepted and then goes quiet has no other timeout, because
  /// SSH does not time out a handshake. Without this, a wrong port on a filtered host
  /// shows "Connecting…" forever.
  public static let defaultHandshakeDeadline = Duration.seconds(20)

  /// How long a command with standard input may go with no byte moving. See
  /// `run(_:standardInput:)`.
  private let inputIdleDeadline: Duration

  /// The default idle budget for a command with standard input.
  ///
  /// The hook install runs its read and its write this way, with Cancel and Not Now disabled
  /// while the write is out. The budget is `PaneComposerCopy.sendDeadline`, because the wait
  /// is the same one: a person looking at a spinner with no way to leave.
  public static let defaultInputIdleDeadline = PaneComposerCopy.sendDeadline

  /// The default idle budget for an image upload. See `ImageUploader`.
  ///
  /// Longer than `defaultInputIdleDeadline`. A send returns when the bytes are in this
  /// device's socket buffer, so on a slow link the last of them are still on their way to the
  /// host while nothing moves here. The value is an estimate, not a measurement.
  public static let defaultUploadIdleDeadline = Duration.seconds(30)

  /// What a command with standard input fails with when the host stops answering.
  ///
  /// It does not say that nothing was written. The command may have run to any point.
  static let stalledCommand = AppError.channelFailed(
    reason: "The host stopped answering before the command finished.")

  /// - Parameter handshakeDeadline: overridable so a test can assert the timeout in
  ///   milliseconds.
  /// - Parameter inputIdleDeadline: overridable for the same reason.
  public init(
    transport: any SSHTransport,
    handshakeDeadline: Duration = ConnectionCoordinator.defaultHandshakeDeadline,
    inputIdleDeadline: Duration = ConnectionCoordinator.defaultInputIdleDeadline
  ) {
    self.transport = transport
    self.handshakeDeadline = handshakeDeadline
    self.inputIdleDeadline = inputIdleDeadline
  }

  public func connect(
    to host: DriverrCore.Host,
    validator: any HostKeyValidator,
    credential: SSHAuthMethod
  ) async throws {
    stopWatchingForClosure()
    phase = .connecting
    askedTime = .zero
    askingSince = nil
    do {
      let transport = self.transport
      // Wrapped so the deadline does not count time a person spends on the trust prompt.
      // See `humanTime`.
      let timed = TimedHostKeyValidator(wrapped: validator, coordinator: self)
      try await withHandshakeDeadline(host: host) { [self] in
        // Host key first: the trust decision happens during key exchange, so a
        // mismatched host never sees a password.
        try await transport.connect(to: host, hostKeyValidator: timed)
        await setPhase(.authenticating)
        try await transport.authenticate(credential)
      }
      connectedHost = host
      phase = .connected
      // `.lost` becomes possible only from here. Everything above is an attempt.
      armLossSignal()
      await watchForClosure()
    } catch let error as AppError {
      phase = .failed(error)
      throw error
    } catch {
      let wrapped = AppError.connectionFailed(
        host: host.hostname,
        reason: "The connection could not be established."
      )
      phase = .failed(wrapped)
      throw wrapped
    }
  }

  /// Yields when a connection that was up goes away, at the moment `phase` becomes
  /// `.lost`.
  ///
  /// `ConnectionModel` reads `phase` only at the end of a connect, so it needs this to
  /// hear about a later loss. Like `SSHTransport.disconnections`, the stream belongs to
  /// one connection: the next `connect` finishes it. A disconnect Driverr asked for
  /// finishes it without a yield, so it does not start a reconnect.
  public var losses: AsyncStream<AppError> {
    // With nothing connected, return a finished stream so no caller waits forever.
    lossStream ?? AsyncStream { $0.finish() }
  }

  /// Asks the connection whether it is still there, and records `.lost` if it is not.
  ///
  /// A link that died while the phone was suspended may never signal `disconnections`.
  /// This runs one trivial command on its own channel. A failure to run it is the answer.
  public func probe() async -> ConnectionPhase {
    guard phase == .connected, let connectedHost else { return phase }
    do {
      _ = try await transport.execChannel(command: Self.probeCommand)
    } catch {
      reportLoss(.disconnected(reason: "\(connectedHost.hostname) is no longer reachable."))
    }
    return phase
  }

  /// A POSIX shell builtin. Only whether the channel throws matters, not the exit status.
  private static let probeCommand = "true"

  // MARK: - The handshake deadline

  /// Time this attempt has spent on finished trust prompts.
  private var askedTime: Duration = .zero
  /// When the trust prompt now on screen went up, if one is.
  private var askingSince: ContinuousClock.Instant?

  fileprivate func startedAsking() {
    askingSince = .now
  }

  fileprivate func stoppedAsking() {
    guard let askingSince else { return }
    askedTime += ContinuousClock.now - askingSince
    self.askingSince = nil
  }

  /// All time this attempt has spent waiting on a person, including a prompt still up.
  ///
  /// The deadline does not count this time. On first contact the handshake waits inside
  /// the validator while the user compares a fingerprint, and the timeout must not kill
  /// that.
  private func humanTime() -> Duration {
    askedTime + (askingSince.map { ContinuousClock.now - $0 } ?? .zero)
  }

  private func setPhase(_ newPhase: ConnectionPhase) {
    phase = newPhase
  }

  /// Runs the handshake with a budget, and adds back any time a person spent deciding.
  ///
  /// The timer sleeps for the budget, then sleeps again for any human time added since.
  /// Nothing polls, and each extra round is paid for by time that has already passed.
  private func withHandshakeDeadline<T: Sendable>(
    host: DriverrCore.Host,
    _ body: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let budget = handshakeDeadline
    let transport = self.transport
    return try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await body() }
      group.addTask { [self] in
        var remaining = budget
        var credited = Duration.zero
        while true {
          try await Task.sleep(for: remaining)
          let human = await humanTime()
          guard human > credited else { break }
          remaining = human - credited
          credited = human
        }
        throw AppError.connectionFailed(
          host: host.hostname,
          reason: "It accepted the connection but never finished the handshake."
        )
      }
      // The first task to finish decides: the handshake, or the timer throwing.
      do {
        let result = try await group.next()!
        group.cancelAll()
        return result
      } catch {
        // **`cancelAll` alone cannot end the handshake.** `NIOSSHTransport.connect` waits
        // on `EventLoopFuture.get()`, which ignores cancellation, and the group waits for
        // its children. Without the disconnect the deadline never fires on a real
        // transport. Closing the transport fails those futures, as the user's Cancel
        // does. Call the transport's `disconnect`, not this actor's, which would set the
        // phase to `.idle`. The caller's `catch` sets the phase.
        group.cancelAll()
        await transport.disconnect()
        throw error
      }
    }
  }

  public func run(_ command: String) async throws -> CommandResult {
    guard phase == .connected else {
      throw AppError.notConnected(host: connectedHost?.hostname ?? "the host")
    }
    return try await transport.execChannel(command: command)
  }

  /// Runs one command to completion with `standardInput` written to its stdin, and collects
  /// its output. For bytes that must not be in the command, where `ps` on the host shows
  /// them. See `InputCommandRunner`.
  ///
  /// It gives up when no byte has moved in either direction for the idle deadline, and closes
  /// the stream. See `withIdleDeadline`. With no input it is `run(_:)` with that deadline.
  /// Opening the channel has the same budget of its own, because a link that is already
  /// dead never answers the open. See `openingStream`.
  ///
  /// - Throws: `notConnected`, the error from opening the channel, `channelFailed` when the
  ///   channel ended without an exit status or the host stopped answering, or
  ///   `CancellationError`. A command that exits before it has read its input is not an
  ///   error: its status is returned.
  public func run(_ command: String, standardInput: Data) async throws -> CommandResult {
    let stream = try await openingStream(within: inputIdleDeadline, stalled: Self.stalledCommand) {
      try await self.openStream(command: command)
    }
    do {
      let result = try await Self.exchange(standardInput, over: stream, idleDeadline: inputIdleDeadline)
      await stream.close()
      return result
    } catch {
      await stream.close()
      throw error
    }
  }

  /// Writes `input` to the command's stdin, then reads its output to the end and its status,
  /// under `idleDeadline`.
  ///
  /// - Throws: `stalledCommand` when no byte moved for `idleDeadline`. The stream is closed
  ///   by then.
  static func exchange(
    _ input: Data,
    over stream: any ExecStream,
    idleDeadline: Duration = ConnectionCoordinator.defaultInputIdleDeadline
  ) async throws -> CommandResult {
    try await withIdleDeadline(idleDeadline, over: stream, stalled: stalledCommand) { activity in
      try await transfer(input, over: stream, marking: activity)
    }
  }

  /// The exchange itself. It may be abandoned part way: see `withIdleDeadline`.
  ///
  /// A command can exit without reading its input, as the hook write does when it refuses a
  /// file. The channel then closes and a `send` fails. That is the command's answer, not a
  /// failure here, so sending stops and the output and the status are read as usual.
  ///
  /// **This relies on `ExecStream.send` failing only once the channel has closed.** If a
  /// send failed with the channel still open, the command would wait for input that is not
  /// coming, and the read of `output` below would wait for the command until the deadline.
  /// The caller closes the stream on every path, as `ImageUploader.upload()` does.
  private static func transfer(
    _ input: Data,
    over stream: any ExecStream,
    marking activity: StreamActivity
  ) async throws -> CommandResult {
    // Drained from the start, because the stderr buffer is small and the command may write
    // to it before it reads.
    async let standardError = collect(stream.standardError, marking: activity)

    var index = input.startIndex
    while index < input.endIndex {
      try Task.checkCancellation()
      let end =
        input.index(index, offsetBy: ImageUploader.chunkSize, limitedBy: input.endIndex)
        ?? input.endIndex
      do {
        try await stream.send(input[index..<end])
      } catch {
        break
      }
      activity.moved()
      index = end
    }

    // Read stdout to its end before asking for the status. See
    // `ImageUploader.transfer(over:marking:)`. A channel that failed throws here, and the
    // missing status below reports it.
    var printed = Data()
    do {
      for try await chunk in stream.output {
        activity.moved()
        printed.append(chunk)
      }
    } catch {}

    guard let status = await stream.exitStatus else {
      throw AppError.channelFailed(reason: "The command ended without an exit status.")
    }
    return CommandResult(
      standardOutput: String(decoding: printed, as: UTF8.self),
      standardError: String(decoding: (try? await standardError) ?? Data(), as: UTF8.self),
      exitStatus: status
    )
  }

  private static func collect(
    _ stream: AsyncThrowingStream<Data, any Error>,
    marking activity: StreamActivity
  ) async throws -> Data {
    var data = Data()
    for try await chunk in stream {
      activity.moved()
      data.append(chunk)
    }
    return data
  }

  /// Opens an interactive shell on its own channel. Throws "not connected" before
  /// authentication, as `run` does.
  public func openPTY(size: TerminalSize) async throws -> any PTYChannel {
    guard phase == .connected else {
      throw AppError.notConnected(host: connectedHost?.hostname ?? "the host")
    }
    return try await transport.ptyChannel(size: size)
  }

  /// Starts a long-lived command with both directions open. See `ExecStream`.
  ///
  /// Callers go through the coordinator, which owns the connection's lifetime, so no
  /// channel outlives a disconnect.
  public func openStream(command: String) async throws -> any ExecStream {
    guard phase == .connected else {
      throw AppError.notConnected(host: connectedHost?.hostname ?? "the host")
    }
    return try await transport.execStream(command: command)
  }

  public func disconnect() async {
    // Stop the watcher first, or it reports this disconnect as a loss.
    stopWatchingForClosure()
    await transport.disconnect()
    connectedHost = nil
    phase = .idle
  }

  /// Turns the transport's closure signal into a phase. One event ends the watch.
  private func watchForClosure() async {
    let disconnections = await transport.disconnections
    closureMonitor = Task { [weak self] in
      for await error in disconnections {
        await self?.reportLoss(error)
        break
      }
    }
  }

  private func reportLoss(_ error: AppError) {
    // Any other phase means this watcher's connection is already over or replaced.
    guard phase == .connected else { return }
    phase = .lost(error)
    lossSignal?.yield(error)
    // Finished after one event, so a reconnect loop's iterator does not stay alive on a
    // connection that is over.
    lossSignal?.finish()
    lossSignal = nil
  }

  private func armLossSignal() {
    lossSignal?.finish()
    let (stream, continuation) = AsyncStream<AppError>.makeStream(of: AppError.self)
    lossStream = stream
    lossSignal = continuation
  }

  private func stopWatchingForClosure() {
    closureMonitor?.cancel()
    closureMonitor = nil
    // Finished, never yielded to: a disconnect or a new connect is not a loss.
    lossSignal?.finish()
    lossSignal = nil
  }

  /// Test seam. Waits until the closure watcher has handled the loss it saw.
  ///
  /// Returns at once when nothing is watched. With a healthy connection it waits, like
  /// the watcher.
  func waitForClosureHandling() async {
    await closureMonitor?.value
  }
}

/// The caller's validator, reporting to the coordinator while a person is being asked.
///
/// The app cannot see when key exchange reaches the validator, so the wrapper does it.
/// The whole `validate` call counts as human time, because the store lookup inside it
/// takes microseconds. See `ConnectionCoordinator.humanTime`.
private struct TimedHostKeyValidator: HostKeyValidator {
  let wrapped: any HostKeyValidator
  let coordinator: ConnectionCoordinator

  func validate(_ key: SSHHostKey, for host: DriverrCore.Host) async -> HostKeyDecision {
    await coordinator.startedAsking()
    let decision = await wrapped.validate(key, for: host)
    await coordinator.stoppedAsking()
    return decision
  }
}
