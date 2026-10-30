import DriverrCore
import DriverrHerdr
import Foundation

/// A message from the core with no id: `event`, `heartbeat` or `missed`.
struct CoreNotification: Equatable, Sendable {
  let method: String
  /// The whole JSON-RPC message.
  let message: Data
}

/// What a stream channel's handler hears.
enum CoreChannelEvent: Equatable, Sendable {
  case frame(CoreFrame)
  /// The connection ended with this channel open. No CLOSE is coming.
  case connectionEnded
}

/// One `hc connect`: the plain opening, then JSON-RPC on channel 0 of the framed stream.
///
/// **One reader for the connection's whole life.** `HerdrStream.output` can be iterated once,
/// and the opening and the frames share it. Something must also keep draining it, or the SSH
/// window fills and the core stalls behind it. The reader holds this actor until the stream
/// ends, which the link's own teardown guarantees.
///
/// **`close` is never awaited.** It can suspend forever on a link that has been torn down.
actor CoreConnection {
  typealias ChannelHandler = @Sendable (CoreChannelEvent) -> Void

  private struct PendingCall {
    let continuation: CheckedContinuation<Data, any Error>
    let deadline: Task<Void, Never>
    /// `openChannel`'s handler, which takes the channel the reply names.
    let handler: ChannelHandler?
  }

  private let stream: any HerdrStream
  private let callDeadline: Duration
  private let notifications: @Sendable (CoreNotification) -> Void

  private var scanner: CoreHelloScanner? = CoreHelloScanner()
  private var opening: CheckedContinuation<CoreHandshake, Never>?
  private var openingDeadline: Task<Void, Never>?
  private var decoder = CoreFrameDecoder()
  private var pending: [Int: PendingCall] = [:]
  private var nextID = CoreHello.requestID + 1
  /// Stream channels, by number. `openChannel` installs them. A frame for a channel with no
  /// handler and no open outstanding is dropped.
  private var channels: [UInt32: ChannelHandler] = [:]
  /// Frames for a channel nobody holds yet, kept while an open is outstanding.
  ///
  /// The core queues a stream's first paint before it queues the reply naming the channel,
  /// so the paint can arrive first. Bounded by the stream's starting credit.
  private var earlyFrames: [UInt32: [CoreFrame]] = [:]
  /// `openChannel` calls whose deadline passed. Their reply can still arrive, and it names a
  /// viewer the core is holding. See `adoptChannel`.
  private var abandonedOpens: Set<Int> = []

  /// Whether the stream is still up. Once `false` it stays `false`, and a new connection is
  /// the only way on. See `CoreLink`.
  private(set) var isOpen = true

  init(
    stream: any HerdrStream,
    callDeadline: Duration,
    notifications: @escaping @Sendable (CoreNotification) -> Void = { _ in }
  ) {
    self.stream = stream
    self.callDeadline = callDeadline
    self.notifications = notifications
  }

  /// Starts the reader, says `hello`, and waits up to one call's deadline for the reply.
  ///
  /// A deadline, an end of stream and a failed send all land on `.notCore`, because each
  /// means no core answered. This connection is closed unless the answer is `.ready`.
  func handshake() async -> CoreHandshake {
    let output = stream.output
    Task {
      do {
        for try await chunk in output { self.receive(chunk) }
      } catch {
        // A failed stream and a finished one both leave nothing to read.
      }
      self.end(failure: Self.endedFailure)
    }

    let outcome = await withCheckedContinuation { continuation in
      opening = continuation
      openingDeadline = Task { [callDeadline] in
        try? await Task.sleep(for: callDeadline)
        guard !Task.isCancelled else { return }
        self.settleOpening(.notCore)
      }
      send(CoreHello.request) { connection, _ in connection.settleOpening(.notCore) }
    }

    if case .ready = outcome {} else { end(failure: Self.endedFailure) }
    return outcome
  }

  /// Calls a method on channel 0 and decodes its `result`.
  ///
  /// Calls run side by side, and each fails on its own deadline. A reply that arrives after
  /// that finds no pending call and is dropped. A deadline does not end the connection,
  /// because one slow method says nothing about the next.
  func call<Params: Encodable & Sendable, Answer: Decodable & Sendable>(
    _ method: String,
    params: Params,
    as answer: Answer.Type = Answer.self
  ) async throws -> Answer {
    try Self.answer(in: await exchange(method, params: params, handler: nil), as: answer)
  }

  /// Calls a method that answers with a stream channel, and hands the stream to `handler`.
  ///
  /// **`handler` is installed inside reply routing, not after this returns.** The stream's
  /// first frames can arrive before the reply or right behind it, and a caller resumed later
  /// would miss them. A stream that fails to decode is closed, because nobody will hold it.
  func openChannel<Params: Encodable & Sendable, Answer: Decodable & Sendable>(
    _ method: String,
    params: Params,
    as answer: Answer.Type = Answer.self,
    handler: @escaping ChannelHandler
  ) async throws -> (channel: UInt32, answer: Answer) {
    let message = try await exchange(method, params: params, handler: handler)
    let channel = Self.channel(in: message)
    do {
      let answer = try Self.answer(in: message, as: answer)
      guard let channel else { throw AppError.herdrResponseUnreadable }
      return (channel, answer)
    } catch {
      if let channel { closeChannel(channel) }
      throw error
    }
  }

  /// Writes one frame on a stream channel, and returns once it has gone.
  ///
  /// **Awaited, unlike every other write here**, because `send` is a task per write, which
  /// would let keystrokes overtake each other. The caller's own queue keeps the order.
  func write(_ kind: CoreFrame.Kind, _ payload: Data, toChannel channel: UInt32) async throws {
    guard isOpen else { throw Self.endedFailure }
    try await stream.send(CoreFrame(channel: channel, kind: kind, payload: payload).encoded)
  }

  /// Tells the core this many bytes of a stream have been consumed.
  ///
  /// Never awaited, so the path that consumes output cannot wait on the path that returns its
  /// credit. Order does not matter, because credit only adds up.
  func credit(_ bytes: Int, toChannel channel: UInt32) {
    guard isOpen else { return }
    var payload = Data()
    withUnsafeBytes(of: UInt32(clamping: bytes).littleEndian) { payload.append(contentsOf: $0) }
    send(CoreFrame(channel: channel, kind: .credit, payload: payload).encoded) { _, _ in }
  }

  /// Leaves a stream channel. Its handler hears nothing more. The core's empty CLOSE, and
  /// anything still on the wire, find no handler.
  func closeChannel(_ channel: UInt32) {
    channels[channel] = nil
    guard isOpen else { return }
    send(CoreFrame(channel: channel, kind: .close, payload: Data()).encoded) { _, _ in }
  }

  /// Ends this connection from Driverr's side. Pending calls fail, and stream handlers hear.
  func close() {
    end(failure: Self.endedFailure)
  }

  private func exchange<Params: Encodable & Sendable>(
    _ method: String,
    params: Params,
    handler: ChannelHandler?
  ) async throws -> Data {
    guard isOpen else { throw Self.endedFailure }

    let id = nextID
    nextID += 1
    let request = CoreRequest(id: id, method: method, params: params)
    let frame = CoreFrame(channel: 0, kind: .data, payload: try JSONEncoder().encode(request))

    return try await withCheckedThrowingContinuation { continuation in
      let deadline = Task { [callDeadline] in
        try? await Task.sleep(for: callDeadline)
        guard !Task.isCancelled else { return }
        self.expire(id, method: method)
      }
      pending[id] = PendingCall(continuation: continuation, deadline: deadline, handler: handler)
      send(frame.encoded) { connection, error in
        connection.settle(id, with: .failure(Self.sendFailure(error)))
      }
    }
  }

  // MARK: - Receiving

  private func receive(_ chunk: Data) {
    guard isOpen else { return }

    guard var unfinished = scanner else {
      deliver(chunk)
      return
    }
    switch unfinished.append(chunk) {
    case .needsMore:
      scanner = unfinished
    case .notCore:
      scanner = nil
      settleOpening(.notCore)
    case .reply(let handshake, let remainder):
      scanner = nil
      settleOpening(handshake)
      if !remainder.isEmpty { deliver(remainder) }
    }
  }

  private func deliver(_ chunk: Data) {
    do {
      for frame in try decoder.append(chunk) { route(frame) }
    } catch {
      end(failure: AppError.herdrResponseUnreadable)
    }
  }

  private func route(_ frame: CoreFrame) {
    guard frame.channel == 0 else {
      routeStream(frame)
      return
    }
    guard frame.kind == .data,
      let envelope = try? JSONDecoder().decode(CoreEnvelope.self, from: frame.payload)
    else { return }

    if let id = envelope.id {
      adoptChannel(inReply: frame.payload, to: id)
      settle(id, with: .success(frame.payload))
    } else if let method = envelope.method {
      notifications(CoreNotification(method: method, message: frame.payload))
    }
  }

  private func routeStream(_ frame: CoreFrame) {
    if let handler = channels[frame.channel] {
      if frame.kind == .close { channels[frame.channel] = nil }
      handler(.frame(frame))
    } else if hasOpenOutstanding {
      earlyFrames[frame.channel, default: []].append(frame)
    }
  }

  /// Gives the channel a reply names to whoever opened it, ahead of resuming them.
  ///
  /// A reply to an open that timed out gets a CLOSE instead. The viewer exists on the core
  /// whether or not anyone is still waiting, and a leaked typing viewer would hold the size.
  private func adoptChannel(inReply message: Data, to id: Int) {
    let wasAbandoned = abandonedOpens.remove(id) != nil
    let handler = pending[id]?.handler
    guard wasAbandoned || handler != nil, let channel = Self.channel(in: message) else { return }

    let early = earlyFrames.removeValue(forKey: channel) ?? []
    guard let handler else {
      closeChannel(channel)
      return
    }
    channels[channel] = handler
    for frame in early { routeStream(frame) }
  }

  private var hasOpenOutstanding: Bool {
    !abandonedOpens.isEmpty || pending.values.contains { $0.handler != nil }
  }

  // MARK: - Settling

  /// In a task of its own, so a hung `send` cannot hold a caller past its deadline.
  private func send(
    _ data: Data,
    onFailure: @escaping @Sendable (isolated CoreConnection, any Error) -> Void
  ) {
    let stream = stream
    Task {
      do {
        try await stream.send(data)
      } catch {
        onFailure(self, error)
      }
    }
  }

  private func settle(_ id: Int, with outcome: Result<Data, any Error>) {
    defer { if !hasOpenOutstanding { earlyFrames = [:] } }
    guard let call = pending.removeValue(forKey: id) else { return }
    call.deadline.cancel()
    call.continuation.resume(with: outcome)
  }

  private func expire(_ id: Int, method: String) {
    if pending[id]?.handler != nil { abandonedOpens.insert(id) }
    settle(id, with: .failure(Self.timedOutFailure(method)))
  }

  private func settleOpening(_ handshake: CoreHandshake) {
    openingDeadline?.cancel()
    openingDeadline = nil
    opening?.resume(returning: handshake)
    opening = nil
  }

  /// Fails everything waiting and lets the stream go. Runs at most once.
  private func end(failure: AppError) {
    guard isOpen else { return }
    isOpen = false
    settleOpening(.notCore)
    abandonedOpens = []
    for id in Array(pending.keys) { settle(id, with: .failure(failure)) }
    earlyFrames = [:]
    let handlers = channels.values
    channels = [:]
    for handler in handlers { handler(.connectionEnded) }
    let stream = stream
    Task { await stream.close() }
  }

  // MARK: - Words

  private static let endedFailure = AppError.channelFailed(
    reason: "The connection to herdr-core ended.")

  private static func timedOutFailure(_ method: String) -> AppError {
    .herdrCommandFailed(reason: "herdr-core did not answer \(method).")
  }

  private static func sendFailure(_ error: any Error) -> AppError {
    (error as? AppError) ?? endedFailure
  }

  private static func channel(in message: Data) -> UInt32? {
    (try? JSONDecoder().decode(CoreResponse<CoreChannelResult>.self, from: message))?
      .result?.channel
  }

  private static func answer<Answer: Decodable & Sendable>(
    in message: Data,
    as type: Answer.Type
  ) throws -> Answer {
    guard let response = try? JSONDecoder().decode(CoreResponse<Answer>.self, from: message)
    else { throw AppError.herdrResponseUnreadable }
    if let result = response.result { return result }
    throw AppError.herdrCommandFailed(
      reason: response.error?.message ?? "herdr-core refused the request.")
  }
}
