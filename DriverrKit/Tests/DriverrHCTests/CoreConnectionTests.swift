import DriverrCore
import DriverrHerdr
import Foundation
import Testing

@testable import DriverrHC

/// Every wait here ends in a failure of its own: a deadline nobody observes reads as a pass.
@Suite("Core connection", .timeLimit(.minutes(1)))
struct CoreConnectionTests {
  private struct Echo: Decodable, Equatable, Sendable {
    let value: Int
  }

  /// Long enough never to fire on a healthy run.
  private let patient = Duration.seconds(30)
  private let brief = Duration.milliseconds(50)

  private func connected(
    _ stream: FakeCoreStream,
    deadline: Duration? = nil,
    notifications: @escaping @Sendable (CoreNotification) -> Void = { _ in }
  ) async -> CoreConnection {
    let connection = CoreConnection(
      stream: stream,
      callDeadline: deadline ?? patient,
      notifications: notifications
    )
    #expect(await connection.handshake() == .ready(version: "0.1.14"))
    return connection
  }

  /// What a call threw, as a value, so a test can compare it.
  private func failure(
    of call: () async throws -> Echo
  ) async -> AppError? {
    do {
      _ = try await call()
      return nil
    } catch {
      return error as? AppError
    }
  }

  @Test("a call round-trips over channel 0")
  func roundTrip() async throws {
    let stream = FakeCoreStream()
    stream.replies = ["echo": .result(#"{"value":7}"#)]
    let connection = await connected(stream)
    let answer = try await connection.call("echo", params: CoreNoParams(), as: Echo.self)
    #expect(answer == Echo(value: 7))
    #expect(stream.methods == ["echo"])
  }

  @Test("the opening and the reply survive one byte per chunk, with a banner ahead")
  func splitEverything() async throws {
    let stream = FakeCoreStream()
    stream.banner = Data("Welcome\n".utf8)
    stream.chunkSize = 1
    stream.replies = ["echo": .result(#"{"value":7}"#)]
    let connection = await connected(stream)
    let answer = try await connection.call("echo", params: CoreNoParams(), as: Echo.self)
    #expect(answer == Echo(value: 7))
  }

  @Test("a frame that arrives in the same chunk as the reply is not lost")
  func frameBehindTheReply() async {
    let (notes, continuation) = AsyncStream<CoreNotification>.makeStream()
    let stream = FakeCoreStream()
    let note = #"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":1}}"#
    stream.afterHello = CoreFrame(channel: 0, kind: .data, payload: Data(note.utf8)).encoded
    _ = await connected(stream) { continuation.yield($0) }
    var iterator = notes.makeAsyncIterator()
    #expect(await iterator.next()?.method == "heartbeat")
  }

  @Test("calls run side by side and each gets its own answer, in whatever order")
  func outOfOrder() async throws {
    let stream = FakeCoreStream()
    stream.replies = [
      "slow": .late(#"{"value":1}"#, delay: .milliseconds(100)),
      "fast": .result(#"{"value":2}"#),
    ]
    let connection = await connected(stream)
    async let slow = connection.call("slow", params: CoreNoParams(), as: Echo.self)
    async let fast = connection.call("fast", params: CoreNoParams(), as: Echo.self)
    #expect(try await fast == Echo(value: 2))
    #expect(try await slow == Echo(value: 1))
  }

  @Test("two answers coalesced into one chunk both land")
  func coalescedAnswers() async throws {
    let stream = FakeCoreStream()
    stream.holdsReplies = true
    stream.replies = ["a": .result(#"{"value":1}"#), "b": .result(#"{"value":2}"#)]
    let connection = await connected(stream)
    async let first = connection.call("a", params: CoreNoParams(), as: Echo.self)
    async let second = connection.call("b", params: CoreNoParams(), as: Echo.self)
    while stream.methods.count < 2 { await Task.yield() }
    stream.flushHeld()
    #expect(try await first == Echo(value: 1))
    #expect(try await second == Echo(value: 2))
  }

  @Test("a message with no id goes to the notification sink, not to a call")
  func notifications() async {
    let (notes, continuation) = AsyncStream<CoreNotification>.makeStream()
    let stream = FakeCoreStream()
    _ = await connected(stream) { continuation.yield($0) }
    let json = #"{"jsonrpc":"2.0","method":"event","params":{"seq":42}}"#
    stream.writeMessage(json)
    var iterator = notes.makeAsyncIterator()
    #expect(
      await iterator.next() == CoreNotification(method: "event", message: Data(json.utf8)))
  }

  @Test("another channel's frame reaches its handler, and with none it is dropped")
  func otherChannels() async throws {
    let (frames, continuation) = AsyncStream<CoreFrame>.makeStream()
    let stream = FakeCoreStream()
    stream.replies = ["echo": .result(#"{"value":7}"#)]
    let connection = await connected(stream)

    stream.writeMessage("nobody is listening", onChannel: 9)
    await connection.setHandler({ continuation.yield($0) }, forChannel: 4)
    stream.writeMessage("bytes", onChannel: 4)

    var iterator = frames.makeAsyncIterator()
    #expect(await iterator.next()?.payload == Data("bytes".utf8))
    // Channel 0 is still working after a frame nobody took.
    let answer = try await connection.call("echo", params: CoreNoParams(), as: Echo.self)
    #expect(answer == Echo(value: 7))
  }

  @Test("a core's error reaches the caller in the core's words")
  func errorReply() async {
    let stream = FakeCoreStream()
    stream.replies = ["echo": .error("no terminal t9")]
    let connection = await connected(stream)
    let failure = await failure {
      try await connection.call("echo", params: CoreNoParams(), as: Echo.self)
    }
    #expect(failure == .herdrCommandFailed(reason: "no terminal t9"))
  }

  @Test("a result of the wrong shape is unreadable, not a crash")
  func unreadableReply() async {
    let stream = FakeCoreStream()
    stream.replies = ["echo": .result(#"{"unexpected":true}"#)]
    let connection = await connected(stream)
    let failure = await failure {
      try await connection.call("echo", params: CoreNoParams(), as: Echo.self)
    }
    #expect(failure == .herdrResponseUnreadable)
  }

  @Test("a call past its deadline fails, and the connection stays up")
  func callDeadline() async throws {
    let stream = FakeCoreStream()
    stream.replies = ["never": .silent, "echo": .result(#"{"value":7}"#)]
    let connection = await connected(stream, deadline: brief)
    let failure = await failure {
      try await connection.call("never", params: CoreNoParams(), as: Echo.self)
    }
    #expect(failure == .herdrCommandFailed(reason: "herdr-core did not answer never."))
    #expect(await connection.isOpen)
    let answer = try await connection.call("echo", params: CoreNoParams(), as: Echo.self)
    #expect(answer == Echo(value: 7))
  }

  @Test("a reply to a call that has already timed out is dropped")
  func lateReply() async throws {
    let stream = FakeCoreStream()
    stream.replies = [
      "late": .late(#"{"value":1}"#, delay: .milliseconds(150)),
      "echo": .result(#"{"value":2}"#),
    ]
    let connection = await connected(stream, deadline: brief)
    let failure = await failure {
      try await connection.call("late", params: CoreNoParams(), as: Echo.self)
    }
    #expect(failure == .herdrCommandFailed(reason: "herdr-core did not answer late."))
    try await Task.sleep(for: .milliseconds(200))
    // Id 2 was the late call. This is id 3, and it must get its own answer.
    let answer = try await connection.call("echo", params: CoreNoParams(), as: Echo.self)
    #expect(answer == Echo(value: 2))
  }

  @Test("a pending call fails when the stream ends, and the stream is let go")
  func streamEnd() async {
    let stream = FakeCoreStream()
    stream.replies = ["never": .silent]
    let connection = await connected(stream)
    async let pending = failure {
      try await connection.call("never", params: CoreNoParams(), as: Echo.self)
    }
    while stream.methods.isEmpty { await Task.yield() }
    stream.finish()
    #expect(await pending == .channelFailed(reason: "The connection to herdr-core ended."))
    #expect(await !connection.isOpen)
  }

  @Test("a call after the end fails at once")
  func callAfterEnd() async {
    let stream = FakeCoreStream()
    let connection = await connected(stream)
    await connection.close()
    let failure = await failure {
      try await connection.call("echo", params: CoreNoParams(), as: Echo.self)
    }
    #expect(failure == .channelFailed(reason: "The connection to herdr-core ended."))
  }

  @Test("close does not wait for the stream to close")
  func closeIsNotAwaited() async {
    let stream = HangingCloseStream()
    let connection = CoreConnection(stream: stream, callDeadline: patient)
    await connection.close()
    #expect(await !connection.isOpen)
  }

  @Test("a stream that ends without a reply is not a core")
  func endOfStream() async {
    let stream = FakeCoreStream()
    stream.helloReply = nil
    stream.banner = Data("usage: hc [options]\n".utf8)
    let connection = CoreConnection(stream: stream, callDeadline: patient)
    async let handshake = connection.handshake()
    while !stream.didAnswerHello { await Task.yield() }
    stream.finish()
    #expect(await handshake == .notCore)
  }

  @Test("a program that never answers is not a core, after the deadline, and is closed")
  func silentProgram() async {
    let stream = FakeCoreStream()
    stream.helloReply = nil
    let connection = CoreConnection(stream: stream, callDeadline: brief)
    #expect(await connection.handshake() == .notCore)
    #expect(await !connection.isOpen)
  }

  @Test("a refused core is closed")
  func refusedIsClosed() async {
    let stream = FakeCoreStream()
    stream.helloReply = FakeCoreStream.helloReply(generation: 2)
    let connection = CoreConnection(stream: stream, callDeadline: patient)
    #expect(
      await connection.handshake()
        == .refused(version: "0.1.14", generation: 2, missingMethods: []))
    #expect(await !connection.isOpen)
  }

  @Test("a frame over the bound ends the connection and fails what was pending")
  func oversizedFrame() async {
    let stream = FakeCoreStream()
    stream.replies = ["never": .silent]
    let connection = await connected(stream)
    async let pending = failure {
      try await connection.call("never", params: CoreNoParams(), as: Echo.self)
    }
    while stream.methods.isEmpty { await Task.yield() }

    var header = CoreFrame(channel: 0, kind: .data, payload: Data()).encoded
    let length = UInt32(CoreFrame.maximumPayload + 1)
    header.replaceSubrange(5..<9, with: withUnsafeBytes(of: length.littleEndian) { Data($0) })
    stream.write(header)

    #expect(await pending == .herdrResponseUnreadable)
    #expect(await !connection.isOpen)
  }
}

/// A stream whose `close` never returns, like NIO's after the event loop has shut down.
private struct HangingCloseStream: HerdrStream {
  let output = AsyncThrowingStream<Data, any Error> { _ in }
  var end: ProcessEnd? { get async { nil } }
  func send(_ data: Data) async throws {}
  func close() async {
    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
  }
}
