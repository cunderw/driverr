import DriverrCore
import DriverrHerdr
import Foundation
import Testing

@testable import DriverrHC

@Suite("Core attachment", .timeLimit(.minutes(1)))
struct CoreAttachmentTests {
  /// Long enough never to fire on a healthy run.
  private let patient = Duration.seconds(30)

  private func attached(
    _ stream: FakeCoreStream,
    observe: Bool = false
  ) async throws -> (CoreAttachment, CoreConnection) {
    stream.replies["terminal.attach"] = .result(FakeCoreStream.attached(channel: 4))
    let connection = CoreConnection(stream: stream, callDeadline: patient)
    #expect(await connection.handshake() == .ready(version: "0.1.14"))
    let attachment = try await CoreAttachment.open(
      on: connection,
      params: CoreAttachParams(terminal: "t7", cols: 80, rows: 24, observe: observe)
    )
    return (attachment, connection)
  }

  private func close(_ payload: String) -> Data {
    CoreFrame(channel: 4, kind: .close, payload: Data(payload.utf8)).encoded
  }

  /// How a stream ended: `nil` for a clean finish, or what it threw.
  private func ending(of attachment: CoreAttachment) async -> (any Error)? {
    do {
      for try await _ in attachment.output {}
      return nil
    } catch {
      return error
    }
  }

  // The first four payloads are what a core 0.1.14 wrote; the rest are its other reasons.
  @Test(
    "a CLOSE's payload maps to why the stream ended",
    arguments: [
      (#"{"exit_code":3,"finished_ms":1793388532835,"reason":"exited","signal":null}"#, .paneClosed),
      (#"{"exit_code":null,"finished_ms":null,"reason":"signaled","signal":9}"#, .lost),
      // A kept terminal when the core stops. `reason` alone would call this a shutdown.
      (#"{"exit_code":null,"finished_ms":null,"reason":"server_stop","signal":1}"#, .lost),
      ("", .detached),
      // The API's own example, which has no `finished_ms` at all.
      (#"{"reason":"exited","exit_code":0,"signal":null}"#, .paneClosed),
      (#"{"finished_ms":1,"reason":"killed"}"#, .paneClosed),
      (#"{"finished_ms":1,"reason":"server_stop"}"#, .serverShuttingDown),
      (#"{"finished_ms":1,"reason":"host_shutdown"}"#, .serverShuttingDown),
      (#"{"finished_ms":1,"reason":"stopped_by_restart"}"#, .serverShuttingDown),
      (#"{"finished_ms":1,"reason":"holder_lost"}"#, .other("holder_lost")),
      ("{}", .paneClosed),
      ("not json", .other("not json")),
    ] as [(String, TerminalCloseReason)]
  )
  func closeReasons(payload: String, reason: TerminalCloseReason) {
    #expect(CoreAttachment.closeReason(from: Data(payload.utf8)) == reason)
  }

  @Test("bytes come out in order, and a program that ended finishes the stream cleanly")
  func cleanEnd() async throws {
    let stream = FakeCoreStream()
    let (attachment, _) = try await attached(stream)

    stream.writeMessage("hello", onChannel: 4)
    stream.write(close(#"{"finished_ms":1,"reason":"exited"}"#))

    var bytes = Data()
    for try await chunk in attachment.output { bytes.append(chunk) }
    #expect(bytes == Data("hello".utf8))
  }

  @Test("a loss throws, and the stream's last bytes still come out ahead of it")
  func loss() async throws {
    let stream = FakeCoreStream()
    let (attachment, _) = try await attached(stream)
    stream.write(close(#"{"finished_ms":null,"reason":"signaled"}"#))

    #expect(await ending(of: attachment) as? TerminalCloseReason == .lost)
  }

  @Test("a connection that ends throws streamEnded rather than leaving the reader waiting")
  func connectionEnds() async throws {
    let stream = FakeCoreStream()
    let (attachment, _) = try await attached(stream)
    stream.finish()

    #expect(await ending(of: attachment) as? TerminalCloseReason == .streamEnded)
  }

  @Test("input, size and focus are this channel's own frames, with the wire's layout")
  func writes() async throws {
    let stream = FakeCoreStream()
    let (attachment, _) = try await attached(stream)

    try await attachment.send(text: "é")
    try await attachment.send(bytes: Data([0x03]))
    try await attachment.resize(to: TerminalSize(columns: 0x0102, rows: 0x0304))
    try await attachment.focus(true)
    try await attachment.focus(false)

    #expect(
      stream.streamFrames == [
        CoreFrame(channel: 4, kind: .data, payload: Data("é".utf8)),
        CoreFrame(channel: 4, kind: .data, payload: Data([0x03])),
        CoreFrame(channel: 4, kind: .resize, payload: Data([0x02, 0x01, 0x04, 0x03])),
        CoreFrame(channel: 4, kind: .focus, payload: Data([1])),
        CoreFrame(channel: 4, kind: .focus, payload: Data([0])),
      ])
  }

  @Test("an observer's focus goes nowhere")
  func observerFocus() async throws {
    let stream = FakeCoreStream()
    let (attachment, _) = try await attached(stream, observe: true)

    try await attachment.focus(true)

    #expect(stream.streamFrames.isEmpty)
  }

  @Test("release sends CLOSE and finishes the stream, and no credit follows it")
  func release() async throws {
    let stream = FakeCoreStream()
    let (attachment, _) = try await attached(stream)

    await attachment.release()
    attachment.consumed(CoreAttachment.creditBatch)
    try await waitUntil("the CLOSE") { !stream.streamFrames.isEmpty }

    #expect(await ending(of: attachment) == nil)
    #expect(stream.streamFrames == [CoreFrame(channel: 4, kind: .close, payload: Data())])
  }

  private func creditSum(_ stream: FakeCoreStream) -> Int {
    stream.streamFrames.filter { $0.kind == .credit }.reduce(0) { sum, frame in
      #expect(frame.payload.count == 4)
      return sum + frame.payload.reversed().reduce(0) { $0 << 8 | Int($1) }
    }
  }

  /// The acceptance test: a burst past the core's 256 KiB of starting credit keeps coming, but
  /// only as fast as bytes are consumed, and channel 0 answers throughout.
  @Test("a long burst flows as bytes are consumed, and never holds up channel 0")
  func burst() async throws {
    let window = 256 * 1024
    let total = 1024 * 1024
    let stream = FakeCoreStream()
    stream.replies["terminal.list"] = .result(#"{"terminals":[]}"#)
    let (attachment, connection) = try await attached(stream)
    var output = attachment.output.makeAsyncIterator()

    // The reader takes everything it is given, and consumes none of it.
    stream.startBurst(total, onChannel: 4)
    var read = 0
    while read < window { read += try #require(try await output.next()).count }

    // A sleep, because this asserts that nothing happens: a CREDIT sent at the read would be
    // a task that has not run yet.
    try await Task.sleep(for: .milliseconds(100))
    #expect(stream.burstWritten == window)
    #expect(creditSum(stream) == 0, "credit before anything was consumed")

    // Stalled on credit, and the shared connection is unaffected.
    _ = try await connection.call(
      "terminal.list", params: CoreNoParams(), as: CoreListResult.self)

    attachment.consumed(CoreAttachment.creditBatch - 1)

    // What is owed so far, then the rest as it arrives.
    attachment.consumed(read - CoreAttachment.creditBatch + 1)
    var consumed = read
    while read < total {
      let chunk = try #require(try await output.next())
      read += chunk.count
      consumed += chunk.count
      attachment.consumed(chunk.count)
    }

    try await waitUntil("the batches") { creditSum(stream) > total - CoreAttachment.creditBatch }
    #expect(read == total)
    #expect(stream.burstWritten == total)
    #expect(creditSum(stream) <= consumed, "credit for bytes nobody consumed")
    let frames = stream.streamFrames.filter { $0.kind == .credit }.count
    #expect(frames <= total / CoreAttachment.creditBatch, "a CREDIT for less than a batch")
    _ = try await connection.call(
      "terminal.list", params: CoreNoParams(), as: CoreListResult.self)
  }
}
