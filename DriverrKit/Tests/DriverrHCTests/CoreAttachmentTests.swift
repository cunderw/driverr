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
    observe: Bool = false,
    history: Int = 0
  ) async throws -> (CoreAttachment, CoreConnection) {
    stream.replies["terminal.attach"] = .result(FakeCoreStream.attached(channel: 4))
    let connection = CoreConnection(stream: stream, callDeadline: patient)
    #expect(await connection.handshake() == .ready(version: "0.1.14"))
    let attachment = try await CoreAttachment.open(
      on: connection,
      params: CoreAttachParams(
        terminal: "t7", cols: 80, rows: 24, observe: observe, history: history)
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

  // MARK: - What a first paint needs

  /// The reset every paint opens with, as a core 0.1.15 wrote it.
  private static let paintHead =
    "\u{1b}[!p\u{1b}[?2026l\u{1b}[?9l\u{1b}[?1000l\u{1b}[?1001l\u{1b}[?1002l\u{1b}[?1003l"
    + "\u{1b}[?1004l\u{1b}[?1005l\u{1b}[?1006l\u{1b}[?1015l\u{1b}[?1016l\u{1b}[?2004l"
    + "\u{1b}[?1l\u{1b}[?66l\u{1b}[?2031l\u{1b}[?2048l\u{1b}[=0;1u"

  private func text(of attachment: CoreAttachment) async throws -> String {
    var iterator = attachment.output.makeAsyncIterator()
    return String(decoding: try #require(try await iterator.next()), as: UTF8.self)
  }

  /// In SwiftTerm `?1049l` restores a cursor nothing saved, and the soft reset leaves the saved
  /// autowrap off, so everything after a paint clips at the last column.
  /// `TerminalSessionRawStreamTests` holds the emulator's half.
  @Test("a paint leaves the alternate screen without restoring a cursor, at the same length")
  func paintKeepsAutowrap() async throws {
    let stream = FakeCoreStream()
    let (attachment, _) = try await attached(stream)
    let tail = "\u{1b}[?1047l\u{1b}[?47l\u{1b}[H\u{1b}[2J$ "

    stream.writeMessage(Self.paintHead + "\u{1b}[?1049l" + tail, onChannel: 4)

    #expect(try await text(of: attachment) == Self.paintHead + "\u{1b}[?1047l" + tail)
  }

  /// A program can print a reset, but only the core starts a frame with one.
  @Test("a reset that does not start the frame is not a paint")
  func aResetInsideAFrameIsNotAPaint() async throws {
    let stream = FakeCoreStream()
    let (attachment, _) = try await attached(stream)
    let frame = "output" + paint(alternate: true)

    stream.writeMessage(frame, onChannel: 4)

    #expect(try await text(of: attachment) == frame)
    attachment.leftAlternateScreen()
    await attachment.repaintSettled()
    #expect(attachCount(stream) == 1)
  }

  @Test("a program's own ?1049l in live output is left alone")
  func liveOutputIsNotAPaint() async throws {
    let stream = FakeCoreStream()
    let (attachment, _) = try await attached(stream)

    stream.writeMessage("bye\u{1b}[?1049l", onChannel: 4)

    #expect(try await text(of: attachment) == "bye\u{1b}[?1049l")
  }

  private func paint(alternate: Bool) -> String {
    Self.paintHead + "\u{1b}[?1049l\u{1b}[?1047l\u{1b}[?47l\u{1b}[H\u{1b}[2J"
      + (alternate ? "\u{1b}[?1049h" : "") + "screen"
  }

  private func attachCount(_ stream: FakeCoreStream) -> Int {
    stream.methods.filter { $0 == "terminal.attach" }.count
  }

  /// A paint on the alternate screen carries nothing of the normal one, so a shell behind `top`
  /// comes back blank until a new attach paints it.
  @Test("leaving a screen the stream painted on attaches again, with the history and the size")
  func repaintAfterLeaving() async throws {
    let stream = FakeCoreStream()
    let (attachment, _) = try await attached(stream, history: 500)
    var iterator = attachment.output.makeAsyncIterator()
    try await attachment.resize(to: TerminalSize(columns: 50, rows: 21))
    stream.writeMessage(paint(alternate: true), onChannel: 4)
    _ = try #require(try await iterator.next())

    stream.replies["terminal.attach"] = .after(
      CoreFrame(channel: 5, kind: .data, payload: Data(paint(alternate: false).utf8)).encoded,
      then: FakeCoreStream.attached(channel: 5)
    )
    attachment.leftAlternateScreen()

    let repainted = try #require(try await iterator.next())
    #expect(String(decoding: repainted, as: UTF8.self).hasSuffix("screen"))
    let params = try #require(try stream.params(of: "terminal.attach").last)
    #expect(params["cols"] as? Int == 50)
    #expect(params["rows"] as? Int == 21)
    #expect(params["history"] as? Int == 500)
    // Not active: the phone typed nothing, and a desk may be holding the size.
    #expect(params["resumed"] as? Bool == true)

    // The new viewer is the stream now, and the old one is gone.
    try await waitUntil("the old CLOSE") {
      stream.streamFrames.contains { $0.channel == 4 && $0.kind == .close }
    }
    stream.writeMessage("late", onChannel: 4)
    stream.writeMessage("next", onChannel: 5)
    #expect(try await iterator.next() == Data("next".utf8))
    try await attachment.send(text: "k")
    #expect(stream.streamFrames.last == CoreFrame(channel: 5, kind: .data, payload: Data("k".utf8)))
  }

  /// The shell's history is already in the emulator, and a new attach would paint over a
  /// screen that has nothing wrong with it.
  @Test("leaving a screen the stream saw entered attaches nothing")
  func noRepaintAfterALiveProgram() async throws {
    let stream = FakeCoreStream()
    let (attachment, _) = try await attached(stream)
    var iterator = attachment.output.makeAsyncIterator()
    stream.writeMessage(paint(alternate: false), onChannel: 4)
    _ = try #require(try await iterator.next())

    attachment.leftAlternateScreen()

    await attachment.repaintSettled()
    #expect(attachCount(stream) == 1)
  }

  @Test("an observer repaints nothing, because nobody is looking at it")
  func observerDoesNotRepaint() async throws {
    let stream = FakeCoreStream()
    let (attachment, _) = try await attached(stream, observe: true)
    var iterator = attachment.output.makeAsyncIterator()
    stream.writeMessage(paint(alternate: true), onChannel: 4)
    _ = try #require(try await iterator.next())

    attachment.leftAlternateScreen()

    await attachment.repaintSettled()
    #expect(attachCount(stream) == 1)
  }

  /// One paint is one repaint: a later return to the normal screen has a screen to return to.
  @Test("a second exit from the alternate screen attaches nothing more")
  func oneRepaintPerPaint() async throws {
    let stream = FakeCoreStream()
    let (attachment, _) = try await attached(stream)
    var iterator = attachment.output.makeAsyncIterator()
    stream.writeMessage(paint(alternate: true), onChannel: 4)
    _ = try #require(try await iterator.next())
    stream.replies["terminal.attach"] = .after(
      CoreFrame(channel: 5, kind: .data, payload: Data(paint(alternate: false).utf8)).encoded,
      then: FakeCoreStream.attached(channel: 5)
    )

    attachment.leftAlternateScreen()
    _ = try #require(try await iterator.next())
    await attachment.repaintSettled()
    attachment.leftAlternateScreen()

    await attachment.repaintSettled()
    #expect(attachCount(stream) == 2)
  }

  private func alternatePainted(
    _ stream: FakeCoreStream
  ) async throws -> (CoreAttachment, AsyncThrowingStream<Data, any Error>.Iterator) {
    let (attachment, _) = try await attached(stream, history: 500)
    var iterator = attachment.output.makeAsyncIterator()
    stream.writeMessage(paint(alternate: true), onChannel: 4)
    _ = try #require(try await iterator.next())
    return (attachment, iterator)
  }

  private func closed(_ channel: UInt32, on stream: FakeCoreStream) -> Bool {
    stream.streamFrames.contains { $0.channel == channel && $0.kind == .close }
  }

  @Test("a viewer already released does not attach again")
  func releasedBeforeTheRepaint() async throws {
    let stream = FakeCoreStream()
    let (attachment, _) = try await alternatePainted(stream)

    await attachment.release()
    attachment.leftAlternateScreen()

    await attachment.repaintSettled()
    #expect(attachCount(stream) == 1)
  }

  /// The flag is what stops this. The repaint's own paint clears nothing until it lands.
  @Test("a second exit before the repaint has painted attaches nothing more")
  func secondExitDuringTheRepaint() async throws {
    let stream = FakeCoreStream()
    let (attachment, _) = try await alternatePainted(stream)
    stream.replies["terminal.attach"] = .result(FakeCoreStream.attached(channel: 5))
    stream.holdsReplies = true

    attachment.leftAlternateScreen()
    try await waitUntil("the second attach") { attachCount(stream) == 2 }
    attachment.leftAlternateScreen()
    stream.flushHeld()

    await attachment.repaintSettled()
    #expect(attachCount(stream) == 2)
  }

  /// The new viewer exists on the core by then, and one left open would hold the terminal.
  @Test("released while the repaint is on its way, the new viewer is closed too")
  func releasedDuringTheRepaint() async throws {
    let stream = FakeCoreStream()
    let (attachment, _) = try await alternatePainted(stream)
    stream.replies["terminal.attach"] = .result(FakeCoreStream.attached(channel: 5))
    stream.holdsReplies = true

    attachment.leftAlternateScreen()
    try await waitUntil("the second attach") { attachCount(stream) == 2 }
    await attachment.release()
    stream.flushHeld()

    await attachment.repaintSettled()
    try await waitUntil("both CLOSEs") { closed(4, on: stream) && closed(5, on: stream) }
  }

  /// Between the new viewer's first frame and the swap both channels are open, so the old one's
  /// bytes could land on top of the paint that replaced them.
  @Test("once the new viewer has painted, the old one's bytes are dropped")
  func oldChannelAfterTheNewPaint() async throws {
    let stream = FakeCoreStream()
    var (attachment, iterator) = try await alternatePainted(stream)
    let newPaint = CoreFrame(channel: 5, kind: .data, payload: Data(paint(alternate: false).utf8))
    let late = CoreFrame(channel: 4, kind: .data, payload: Data("late".utf8))
    let next = CoreFrame(channel: 5, kind: .data, payload: Data("next".utf8))
    stream.replies["terminal.attach"] = .followedBy(
      FakeCoreStream.attached(channel: 5),
      newPaint.encoded + late.encoded + next.encoded
    )

    attachment.leftAlternateScreen()

    let repainted = try #require(try await iterator.next())
    #expect(String(decoding: repainted, as: UTF8.self).hasSuffix("screen"))
    #expect(try await iterator.next() == Data("next".utf8))
  }

  /// A fall-behind repaint can land on a stream that already has the shell's history. Another
  /// history would print it twice.
  @Test("a stream that already holds the history repaints the screen and no more")
  func fallBehindDoesNotRepeatHistory() async throws {
    let stream = FakeCoreStream()
    let (attachment, _) = try await attached(stream, history: 500)
    var iterator = attachment.output.makeAsyncIterator()
    stream.writeMessage(paint(alternate: false), onChannel: 4)
    _ = try #require(try await iterator.next())
    stream.writeMessage(paint(alternate: true), onChannel: 4)
    _ = try #require(try await iterator.next())
    stream.replies["terminal.attach"] = .result(FakeCoreStream.attached(channel: 5))

    attachment.leftAlternateScreen()

    await attachment.repaintSettled()
    let params = try #require(try stream.params(of: "terminal.attach").last)
    #expect(attachCount(stream) == 2)
    #expect(params["history"] as? Int == 0)
  }

  /// A CREDIT sent to the old channel while the new one is painting is lost to the new one.
  @Test("credit gathered during a repaint goes to the new viewer")
  func creditDuringTheRepaint() async throws {
    let stream = FakeCoreStream()
    let (attachment, _) = try await alternatePainted(stream)
    stream.replies["terminal.attach"] = .result(FakeCoreStream.attached(channel: 5))
    stream.holdsReplies = true

    attachment.leftAlternateScreen()
    try await waitUntil("the second attach") { attachCount(stream) == 2 }
    attachment.consumed(CoreAttachment.creditBatch)
    stream.flushHeld()

    await attachment.repaintSettled()
    try await waitUntil("the credit") {
      stream.streamFrames.contains { $0.kind == .credit }
    }
    #expect(stream.streamFrames.filter { $0.kind == .credit }.map(\.channel) == [5])
  }
}
