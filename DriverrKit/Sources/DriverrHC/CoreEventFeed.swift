import DriverrCore
import Foundation

/// How soon a change should reach the screen.
///
/// `title` carries Claude Code's spinner, so it changes several times a second while nothing
/// that matters does.
enum CoreChangeUrgency: Sendable {
  case none
  /// At most every `CoreSignalPacer.pacedGap`.
  case paced
  /// Within `CoreSignalPacer.promptGap`.
  case prompt
}

/// When to tell the app that something changed. A value, so the rate is a test with no clock.
///
/// The first change after a quiet spell goes at once. What follows inside the gap waits for
/// its end and goes as one.
struct CoreSignalPacer {
  static let promptGap: Duration = .milliseconds(300)
  static let pacedGap: Duration = .seconds(3)

  private var lastFired: ContinuousClock.Instant?
  private var due: ContinuousClock.Instant?

  /// Records a change, and answers when the signal covering it should fire. `nil` for no change.
  mutating func noted(
    _ urgency: CoreChangeUrgency,
    at now: ContinuousClock.Instant
  ) -> ContinuousClock.Instant? {
    let gap: Duration
    switch urgency {
    case .none: return nil
    case .paced: gap = Self.pacedGap
    case .prompt: gap = Self.promptGap
    }
    let earliest = lastFired.map { max(now, $0 + gap) } ?? now
    let soonest = min(due ?? earliest, earliest)
    due = soonest
    return soonest
  }

  mutating func fired(at now: ContinuousClock.Instant) {
    lastFired = now
    due = nil
  }
}

/// The one listener's stream of "something changed".
///
/// **A stream per listen.** An `AsyncStream` ends for good when the task reading it is
/// cancelled, and the session cancels its listener on every pause. The newest listener wins.
/// A lock, because `HerdrControl.changes` is not async.
final class CoreChangeSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var listener: AsyncStream<Void>.Continuation?

  func listen() -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: Void.self, bufferingPolicy: .bufferingNewest(1))
    lock.withLock {
      listener?.finish()
      listener = continuation
    }
    return stream
  }

  func fire() {
    lock.withLock { _ = listener?.yield() }
  }
}

/// Puts a subscription's DATA back into lines.
///
/// The core cuts DATA at 16 KiB wherever that falls, so a line can span frames and a frame can
/// hold many. The cap is a frame's own: `missed` can be that long and no more could be a reply.
struct CoreLineAssembler {
  struct TooLong: Error {}

  private var partial = Data()

  mutating func append(_ bytes: Data) throws -> [Data] {
    var lines: [Data] = []
    var rest = bytes[...]
    while let newline = rest.firstIndex(of: 0x0A) {
      partial.append(rest[..<newline])
      lines.append(partial)
      partial = Data()
      rest = rest[rest.index(after: newline)...]
    }
    partial.append(rest)
    guard partial.count <= CoreFrame.maximumPayload else { throw TooLong() }
    return lines
  }
}

/// A core's terminals, kept current by its own events.
///
/// **`CoreControl.snapshot()` is a read of this.** The first read subscribes, and every later
/// one is answered from what the events have said, so nothing runs on the host per read. Once
/// the connection goes the next read subscribes on a new one. `seq` restarts with each core
/// process and nothing said meanwhile is replayed, so a subscription starts from its own reply.
///
/// **The subscription lasts as long as the connection.** Leaving the screen stops the signal
/// being heard, not the events, so coming back has nothing to catch up on.
///
/// Events arrive on the reply's channel and not as channel 0 notifications, so credit is theirs
/// to return: one consumer, crediting each frame once it has been applied. An unread frame then
/// holds the core back, and a consumer that falls far enough behind is sent `missed`.
actor CoreEventFeed {
  /// Three heartbeats at 15 s each, in ticks and not a time. **Ticks stop while the app is
  /// suspended**, so a phone back in the hand does not call a healthy line dead.
  static let silentTicksAllowed = 9

  private struct Subscription {
    let id: Int
    let connection: CoreConnection
    let watchdog: Task<Void, Never>
    var state: CoreEventState
    var silentTicks = 0
  }

  private let link: CoreLink
  private let sessionFiles: CoreSessionFiles
  private let heartbeatTick: Duration
  private let signal = CoreChangeSignal()

  private var subscription: Subscription?
  private var subscribing: Task<Void, any Error>?
  private var nextSubscriptionID = 0
  /// Kept across a reconnect and a failed read, so neither can reorder the rows under a thumb.
  private var document: CoreAppDocument?
  private var sessions: [String: String] = [:]
  private var documentIsStale = false
  private var staleSessions: Set<String> = []
  private var reading: Task<Void, Never>?
  private var pacer = CoreSignalPacer()
  private var firing: Task<Void, Never>?
  private var firingAt: ContinuousClock.Instant?

  init(link: CoreLink, sessionFiles: CoreSessionFiles, heartbeatTick: Duration) {
    self.link = link
    self.sessionFiles = sessionFiles
    self.heartbeatTick = heartbeatTick
  }

  nonisolated func changes() -> AsyncStream<Void> { signal.listen() }

  /// The tree as the events left it, subscribing first if nothing is subscribed.
  func tree() async throws -> SessionTree {
    let terminals = try await subscribedTerminals()
    return CoreSnapshotMapper.tree(
      from: CoreListResult(terminals: terminals), document: document, sessions: sessions)
  }

  /// Concurrent callers share one subscribing. A loop, because `isOpen` is another actor's
  /// state and this one's can change across the hop.
  private func subscribedTerminals() async throws -> [CoreTerminal] {
    while true {
      if let subscribing { try await subscribing.value }
      guard let held = subscription else { break }
      if await held.connection.isOpen, let current = subscription?.state.terminals {
        return current
      }
      ended(held.id)
    }

    let opening = Task { try await subscribe() }
    subscribing = opening
    try await opening.value
    guard let state = subscription?.state else {
      throw AppError.channelFailed(reason: "The connection to herdr-core ended.")
    }
    return state.terminals
  }

  /// "Subscribe before reading": what changes during the reads below arrives as an event.
  ///
  /// The first tree waits for them, so it needs no reordering and no chat opens on a guess.
  private func subscribe() async throws {
    defer { subscribing = nil }
    let (connection, handshake) = await link.established()
    guard let connection else { throw CoreControl.failure(for: handshake) }

    let (frames, delivery) = AsyncStream.makeStream(of: CoreChannelEvent.self)
    let opened: (channel: UInt32, answer: CoreEventSnapshot)
    do {
      opened = try await connection.openChannel(
        "events.subscribe",
        params: CoreNoParams(),
        as: CoreEventSnapshot.self,
        handler: { delivery.yield($0) }
      )
    } catch {
      delivery.finish()
      throw error
    }

    let id = nextSubscriptionID
    nextSubscriptionID += 1
    let channel = opened.channel
    Task { await consume(frames, of: id, channel: channel, over: connection) }
    subscription = Subscription(
      id: id,
      connection: connection,
      watchdog: Task { await watch(id, over: connection) },
      state: CoreEventState(opened.answer)
    )
    documentIsStale = true
    staleSessions.formUnion(opened.answer.terminals.map(\.address))
    await startReading().value
  }

  private func consume(
    _ frames: AsyncStream<CoreChannelEvent>,
    of id: Int,
    channel: UInt32,
    over connection: CoreConnection
  ) async {
    var assembler = CoreLineAssembler()
    frames: for await event in frames {
      switch event {
      case .frame(let frame) where frame.kind == .data:
        do {
          for line in try assembler.append(frame.payload) where !line.isEmpty {
            try apply(line, to: id)
          }
        } catch {
          // Nothing later can be trusted once a line is lost, and the way back is a new reply.
          await connection.close()
          break frames
        }
        await connection.credit(frame.payload.count, toChannel: channel)
      case .frame(let frame) where frame.kind == .close:
        break frames
      case .frame:
        break
      case .connectionEnded:
        break frames
      }
    }
    ended(id)
  }

  private func apply(_ line: Data, to id: Int) throws {
    guard subscription?.id == id else { return }
    subscription?.silentTicks = 0
    let decoded = try JSONDecoder().decode(CoreEventLine.self, from: line)
    guard let effect = subscription?.state.apply(decoded) else { return }
    documentIsStale = documentIsStale || effect.readsDocument
    staleSessions.formUnion(effect.sessionReads)
    if documentIsStale || !staleSessions.isEmpty { _ = startReading() }
    changed(effect.signal)
  }

  /// A subscription has gone, by whatever road.
  ///
  /// Signalled, because nothing polls a core. The refresh that follows is what subscribes
  /// again, and when it fails the session's timer takes over until one works.
  private func ended(_ id: Int) {
    guard let held = subscription, held.id == id else { return }
    held.watchdog.cancel()
    subscription = nil
    changed(.prompt)
  }

  /// Closes a connection that has gone quiet, as a missing heartbeat means.
  ///
  /// The whole connection, because a line that has stopped carrying heartbeats has stopped
  /// carrying everything, and every viewer on it needs to hear so.
  private func watch(_ id: Int, over connection: CoreConnection) async {
    while !Task.isCancelled {
      try? await Task.sleep(for: heartbeatTick)
      guard !Task.isCancelled, subscription?.id == id else { return }
      subscription?.silentTicks += 1
      guard let silent = subscription?.silentTicks, silent >= Self.silentTicksAllowed else {
        continue
      }
      await connection.close()
      return
    }
  }

  // MARK: - What an event cannot carry

  private func startReading() -> Task<Void, Never> {
    if let reading { return reading }
    let task = Task { await readWhatIsStale() }
    reading = task
    return task
  }

  /// Off the consumer, so a silent read holds up no event, and one at a time, so an older
  /// answer cannot land on a newer one.
  private func readWhatIsStale() async {
    while documentIsStale || !staleSessions.isEmpty, let held = subscription {
      let readsDocument = documentIsStale
      let addresses = staleSessions
      documentIsStale = false
      staleSessions = []

      async let read: CoreDocGetResult<CoreAppDocument>? =
        readsDocument
        ? try? held.connection.call(
          "doc.get",
          params: CoreDocGetParams(name: CoreAppDocument.name),
          as: CoreDocGetResult<CoreAppDocument>.self)
        : nil
      await readSessions(of: addresses, over: held.connection)
      if let read = await read {
        document = read.value
        changed(.prompt)
      }
    }
    reading = nil
  }

  private func readSessions(of addresses: Set<String>, over connection: CoreConnection) async {
    guard !addresses.isEmpty, let terminals = subscription?.state.terminals else { return }
    let read = await sessionFiles.identifiers(for: terminals, reading: addresses, over: connection)
    guard read != sessions else { return }
    sessions = read
    changed(.prompt)
  }

  // MARK: - Saying so

  private func changed(_ urgency: CoreChangeUrgency) {
    let now = ContinuousClock.now
    guard let due = pacer.noted(urgency, at: now) else { return }
    guard due > now else {
      fire(at: now)
      return
    }
    guard firingAt != due else { return }
    firing?.cancel()
    firingAt = due
    firing = Task {
      try? await Task.sleep(until: due, clock: .continuous)
      guard !Task.isCancelled else { return }
      fire(at: .now)
    }
  }

  private func fire(at now: ContinuousClock.Instant) {
    firing?.cancel()
    firing = nil
    firingAt = nil
    pacer.fired(at: now)
    signal.fire()
  }
}
