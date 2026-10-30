import DriverrCore
import DriverrHerdr
import Foundation

/// A message from the core with no id: `event`, `heartbeat` or `missed`.
struct CoreNotification: Equatable, Sendable {
  let method: String
  /// The whole JSON-RPC message.
  let message: Data
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
  typealias ChannelHandler = @Sendable (CoreFrame) -> Void

  private struct PendingCall {
    let continuation: CheckedContinuation<Data, any Error>
    let deadline: Task<Void, Never>
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
  /// Stream channels, by number. Nothing opens one yet: `terminal.attach` and
  /// `events.subscribe` are what will. A frame for a channel with no handler is dropped.
  private var channels: [UInt32: ChannelHandler] = [:]

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
    guard isOpen else { throw Self.endedFailure }

    let id = nextID
    nextID += 1
    let request = CoreRequest(id: id, method: method, params: params)
    let frame = CoreFrame(channel: 0, kind: .data, payload: try JSONEncoder().encode(request))

    let message: Data = try await withCheckedThrowingContinuation { continuation in
      let deadline = Task { [callDeadline] in
        try? await Task.sleep(for: callDeadline)
        guard !Task.isCancelled else { return }
        self.settle(id, with: .failure(Self.timedOutFailure(method)))
      }
      pending[id] = PendingCall(continuation: continuation, deadline: deadline)
      send(frame.encoded) { connection, error in
        connection.settle(id, with: .failure(Self.sendFailure(error)))
      }
    }
    return try Self.answer(in: message, as: answer)
  }

  /// Ends this connection from Driverr's side. Pending calls fail.
  func close() {
    end(failure: Self.endedFailure)
  }

  func setHandler(_ handler: ChannelHandler?, forChannel channel: UInt32) {
    channels[channel] = handler
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
      channels[frame.channel]?(frame)
      return
    }
    guard frame.kind == .data,
      let envelope = try? JSONDecoder().decode(CoreEnvelope.self, from: frame.payload)
    else { return }

    if let id = envelope.id {
      settle(id, with: .success(frame.payload))
    } else if let method = envelope.method {
      notifications(CoreNotification(method: method, message: frame.payload))
    }
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
    guard let call = pending.removeValue(forKey: id) else { return }
    call.deadline.cancel()
    call.continuation.resume(with: outcome)
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
    for id in Array(pending.keys) { settle(id, with: .failure(failure)) }
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
