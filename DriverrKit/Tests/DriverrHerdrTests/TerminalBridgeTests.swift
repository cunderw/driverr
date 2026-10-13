import DriverrCore
import Foundation
import Testing

@testable import DriverrHerdr

/// A scripted `HerdrStream`, so the bridge can be driven with no host and no SSH.
private final class ScriptedStream: HerdrStream, @unchecked Sendable {
  let output: AsyncThrowingStream<Data, any Error>
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let lock = NSLock()
  private var written: [Data] = []
  private(set) var closed = false
  /// What this stream answers `HerdrStream.end` with. `nil` is the honest answer for a
  /// channel that went away.
  private var scriptedEnd: ProcessEnd?

  init() {
    (output, continuation) = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self
    )
  }

  var sentLines: [String] {
    lock.withLock { written }.map { String(decoding: $0, as: UTF8.self) }
  }

  /// Parsed rather than string-matched, because `JSONEncoder` does not promise key order.
  var sentCommands: [[String: Any]] {
    lock.withLock { written }.compactMap {
      try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    }
  }

  func send(_ data: Data) async throws {
    lock.withLock { written.append(data) }
  }

  func close() async {
    lock.withLock { closed = true }
    continuation.finish()
  }

  var end: ProcessEnd? {
    get async { lock.withLock { scriptedEnd } }
  }

  func emit(_ text: String) { continuation.yield(Data(text.utf8)) }
  func emit(_ data: Data) { continuation.yield(data) }
  func finish() { continuation.finish() }

  /// Ends the stream as a process that ran and refused: the status and stderr are set before
  /// the output finishes, the order `BridgeFramePump` reads them in.
  func exit(status: Int, standardError: String = "") {
    lock.withLock {
      scriptedEnd = ProcessEnd(exitStatus: status, standardErrorTail: standardError)
    }
    continuation.finish()
  }
}

private func frameLine(_ text: String, seq: Int = 1) -> String {
  let payload = Data(text.utf8).base64EncodedString()
  return """
    {"type":"terminal.frame","seq":\(seq),"full":true,"encoding":"ansi",\
    "width":80,"height":24,"bytes":"\(payload)"}
    """ + "\n"
}

@Suite("TerminalFrameDecoder")
struct TerminalFrameDecoderTests {
  @Test("a frame's base64 payload decodes to the bytes an emulator gets")
  func decodesAFrame() {
    var decoder = TerminalFrameDecoder()
    let records = decoder.consume(Data(frameLine("hello").utf8))
    #expect(records == [.frame(Data("hello".utf8))])
  }

  @Test("a record split across two reads is not lost")
  func handlesSplitRecords() {
    // A read is not a line. Splitting mid-base64 is the worst case, because both halves look
    // valid.
    let line = frameLine("hello")
    let cut = line.index(line.startIndex, offsetBy: line.count / 2)
    var decoder = TerminalFrameDecoder()

    let first = decoder.consume(Data(String(line[line.startIndex..<cut]).utf8))
    #expect(first.isEmpty, "half a record is not a record")

    let second = decoder.consume(Data(String(line[cut...]).utf8))
    #expect(second == [.frame(Data("hello".utf8))])
  }

  @Test("several records in one read all come out, in order")
  func handlesBatchedRecords() {
    var decoder = TerminalFrameDecoder()
    let batch = frameLine("one", seq: 1) + frameLine("two", seq: 2) + frameLine("three", seq: 3)
    let records = decoder.consume(Data(batch.utf8))
    #expect(records == [.frame(Data("one".utf8)), .frame(Data("two".utf8)), .frame(Data("three".utf8))])
  }

  @Test("a record type this build has never seen is skipped, not fatal")
  func skipsUnknownRecords() {
    // herdr adds records, and one must not take the pane down, as `HerdrWireTypes` does for
    // snapshot fields.
    var decoder = TerminalFrameDecoder()
    let stream = "{\"type\":\"terminal.something_new\",\"whatever\":true}\n" + frameLine("after")
    let records = decoder.consume(Data(stream.utf8))
    #expect(records == [.frame(Data("after".utf8))])
  }

  @Test("a line that is not JSON at all does not derail the stream")
  func survivesGarbage() {
    var decoder = TerminalFrameDecoder()
    let records = decoder.consume(Data(("not json\n" + frameLine("after")).utf8))
    #expect(records == [.frame(Data("after".utf8))])
  }

  @Test("terminal.closed with no reason decodes as an ordinary close")
  func reportsClosedWithNoReason() {
    var decoder = TerminalFrameDecoder()
    let records = decoder.consume(Data("{\"type\":\"terminal.closed\"}\n".utf8))
    #expect(records == [.closed(reason: .paneClosed)])
  }

  @Test("a refusal reason decodes to .refused")
  func decodesRefusedReason() {
    var decoder = TerminalFrameDecoder()
    let line =
      "{\"type\":\"terminal.closed\",\"reason\":\"terminal attach failed: terminal t1 "
      + "already has an attached client; retry with --takeover\"}\n"
    let records = decoder.consume(Data(line.utf8))
    #expect(records == [.closed(reason: .refused)])
  }

  @Test("a takeover reason decodes to .takenOver")
  func decodesTakenOverReason() {
    var decoder = TerminalFrameDecoder()
    let line = "{\"type\":\"terminal.closed\",\"reason\":\"terminal attach taken over\"}\n"
    let records = decoder.consume(Data(line.utf8))
    #expect(records == [.closed(reason: .takenOver)])
  }

  @Test("an ordinary process exit still decodes to .paneClosed, not .other")
  func decodesExitedReasonAsOrdinary() {
    // herdr sends "terminal <id> exited" for a plain process exit. It must map like no
    // reason at all, or `PaneBridge.output` throws and `TerminalSession` reports an ordinary
    // exit as unexpected.
    var decoder = TerminalFrameDecoder()
    let line = "{\"type\":\"terminal.closed\",\"reason\":\"terminal term_w1p2 exited\"}\n"
    let records = decoder.consume(Data(line.utf8))
    #expect(records == [.closed(reason: .paneClosed)])
  }

  /// herdr shutting down closes no pane, so it must not read as "This pane was closed."
  @Test("a herdr that says it is shutting down decodes to .serverShuttingDown")
  func decodesShutdownReason() {
    var decoder = TerminalFrameDecoder()
    let line = "{\"type\":\"terminal.closed\",\"reason\":\"server is shutting down\"}\n"
    let records = decoder.consume(Data(line.utf8))
    #expect(records == [.closed(reason: .serverShuttingDown)])
  }

  /// herdr does not document these reasons, so the match is by substring and
  /// case-insensitive. A miss falls to `.other`, which is harmless.
  @Test("herdr's wording is matched loosely, in either case and inside a longer sentence")
  func decodesTheseReasonsLoosely() {
    var decoder = TerminalFrameDecoder()
    let lines = [
      "{\"type\":\"terminal.closed\",\"reason\":\"detached\"}\n",
      "{\"type\":\"terminal.closed\",\"reason\":\"client detached\"}\n",
      "{\"type\":\"terminal.closed\",\"reason\":\"Detached\"}\n",
    ]
    for line in lines {
      #expect(decoder.consume(Data(line.utf8)) == [.closed(reason: .detached)], "\(line)")
    }
    let shutdown = "{\"type\":\"terminal.closed\",\"reason\":\"the server is shutting down now\"}\n"
    #expect(decoder.consume(Data(shutdown.utf8)) == [.closed(reason: .serverShuttingDown)])
  }

  @Test("a reason this build has never seen still decodes to .other, kept verbatim")
  func decodesUnknownReason() {
    // A reason from a newer herdr is safer over-reported as a close than reattached.
    var decoder = TerminalFrameDecoder()
    let line = "{\"type\":\"terminal.closed\",\"reason\":\"terminal session stopped\"}\n"
    let records = decoder.consume(Data(line.utf8))
    #expect(records == [.closed(reason: .other("terminal session stopped"))])
  }

  @Test("a plain herdr line on stderr reads as its sentence, with the prefix off")
  func readsAPlainStandardErrorLine() {
    // herdr writes `herdr: <what went wrong>`. The prefix costs seven characters of a bar that
    // holds about 120, and says nothing the reader does not know.
    #expect(
      TerminalFrameDecoder.herdrMessage(
        fromStandardError: "herdr: failed to request terminal attach: pane not found\n"
      ) == "failed to request terminal attach: pane not found"
    )
  }

  @Test("herdr's JSON error envelope reads as its message")
  func readsTheErrorEnvelope() {
    // herdr's docs say CLI server errors are JSON on stderr. Which shape a failed
    // `terminal session control` uses is unconfirmed, so both are handled.
    let envelope = "{\"id\":\"\",\"error\":{\"code\":\"pane_not_found\","
      + "\"message\":\"pane w1:p9 not found\"}}"
    #expect(
      TerminalFrameDecoder.herdrMessage(fromStandardError: envelope) == "pane w1:p9 not found"
    )
  }

  @Test("the last line is the one that explains a failure")
  func readsTheLastLine() {
    // The last thing a process said is the part that says why it stopped.
    let tail = """
      herdr: connecting to server
      herdr: lost connection to server: broken pipe

      """
    #expect(
      TerminalFrameDecoder.herdrMessage(fromStandardError: tail)
        == "lost connection to server: broken pipe"
    )
  }

  @Test("an envelope on the last line is read even when the tail does not start with one")
  func readsAnEnvelopeAfterProgressLines() {
    // The whole-tail attempt needs the tail to start with `{`, and real failures print first.
    let tail = """
      herdr: connecting to server
      {"id":"","error":{"code":"server_unavailable","message":"server is shutting down"}}

      """
    #expect(
      TerminalFrameDecoder.herdrMessage(fromStandardError: tail) == "server is shutting down"
    )
  }

  @Test("a shell that could not find herdr explains itself with no special case")
  func readsAMissingBinary() {
    // The remote shell answers 127 with the same prefix herdr uses, so no special case.
    #expect(
      TerminalFrameDecoder.herdrMessage(fromStandardError: "herdr: command not found\n")
        == "command not found"
    )
  }

  @Test("stderr with nothing in it is nothing to say, not an empty sentence")
  func readsNothingFromNothing() {
    // An empty message is worse than the fixed sentence, so the fallback must be reachable.
    #expect(TerminalFrameDecoder.herdrMessage(fromStandardError: "") == nil)
    #expect(TerminalFrameDecoder.herdrMessage(fromStandardError: "  \n \n") == nil)
    #expect(TerminalFrameDecoder.herdrMessage(fromStandardError: "herdr: ") == nil)
  }

  @Test("text that only looks like an envelope falls back to reading it as a line")
  func readsAMalformedEnvelopeAsText() {
    // `JSONSerialization`, so a non-envelope returns nil rather than throwing.
    #expect(
      TerminalFrameDecoder.herdrMessage(fromStandardError: "{not json at all")
        == "{not json at all"
    )
  }

  @Test("an encoding this build cannot render is skipped rather than fed to the emulator")
  func skipsUnknownEncoding() {
    // Non-ANSI bytes fed to the emulator look like a rendering bug.
    var decoder = TerminalFrameDecoder()
    let payload = Data("hello".utf8).base64EncodedString()
    let line = "{\"type\":\"terminal.frame\",\"encoding\":\"something-else\",\"bytes\":\"\(payload)\"}\n"
    #expect(decoder.consume(Data(line.utf8)).isEmpty)
  }

  @Test("a gap in the sequence is counted rather than thrown")
  func countsSequenceGaps() {
    // Rendering what arrived beats nothing, but the gap is recorded so the emulator is not
    // blamed for the hole.
    var decoder = TerminalFrameDecoder()
    _ = decoder.consume(Data(frameLine("one", seq: 1).utf8))
    #expect(decoder.sequenceGaps == 0)

    _ = decoder.consume(Data(frameLine("three", seq: 3).utf8))
    #expect(decoder.sequenceGaps == 1)

    _ = decoder.consume(Data(frameLine("four", seq: 4).utf8))
    #expect(decoder.sequenceGaps == 1, "a contiguous frame is not a new gap")
  }
}

@Suite("TerminalBridgeClient")
struct TerminalBridgeClientTests {
  private let size = TerminalSize(columns: 80, rows: 24, pixelWidth: 800, pixelHeight: 480)

  @Test("the control command names the terminal and this client's viewport")
  func buildsTheControlCommand() {
    let command = TerminalBridgeClient.controlCommand(
      binaryPath: "herdr",
      terminalID: "term_w1p2",
      size: TerminalSize(columns: 50, rows: 30, pixelWidth: 500, pixelHeight: 600)
    )
    #expect(command == "herdr terminal session control term_w1p2 --cols 50 --rows 30")
  }

  @Test("takeover is never passed, so attaching cannot evict the user at their desk")
  func neverTakesOver() {
    // Taking over needs its own decision, as for `attachCommand`.
    let command = TerminalBridgeClient.controlCommand(
      binaryPath: "herdr",
      terminalID: "t",
      size: TerminalSize(columns: 1, rows: 1, pixelWidth: 1, pixelHeight: 1)
    )
    #expect(!command.contains("--takeover"))
  }

  @Test("an awkward terminal id cannot break out of its argument")
  func quotesItsArguments() {
    let command = TerminalBridgeClient.controlCommand(
      binaryPath: "/opt/homebrew/bin/herdr",
      terminalID: "term; rm -rf /",
      size: TerminalSize(columns: 80, rows: 24, pixelWidth: 800, pixelHeight: 480)
    )
    #expect(
      command == #"/opt/homebrew/bin/herdr terminal session control 'term; rm -rf /' --cols 80 --rows 24"#
    )
  }

  @Test("takeover is passed only when the caller deliberately asks for it")
  func takeoverIsOptedIn() {
    // The one deliberate use: retrying a `.refused` open.
    let command = TerminalBridgeClient.controlCommand(
      binaryPath: "herdr",
      terminalID: "term_w1p2",
      size: TerminalSize(columns: 50, rows: 30, pixelWidth: 500, pixelHeight: 600),
      takeover: true
    )
    #expect(command == "herdr terminal session control term_w1p2 --cols 50 --rows 30 --takeover")
  }

  @Test("the observe command names the terminal and this client's viewport, and never takes over")
  func buildsTheObserveCommand() {
    let command = TerminalBridgeClient.observeCommand(
      binaryPath: "herdr",
      terminalID: "term_w1p2",
      size: TerminalSize(columns: 24, rows: 6, pixelWidth: 240, pixelHeight: 120)
    )
    #expect(command == "herdr terminal session observe term_w1p2 --cols 24 --rows 6")
  }

  /// Without `HERDR_SOCKET_PATH`, a host with a non-default socket opens pane streams on the
  /// default herdr, which answers "terminal target … not found".
  @Test("a socket path is exported ahead of both the control and the observe command")
  func exportsTheSocketPath() async throws {
    let commands = CommandLog()
    let client = TerminalBridgeClient(socketPath: "/run/herdr sock") { command in
      await commands.append(command)
      return ScriptedStream()
    }
    _ = try await client.open(terminalID: "term_w1p2", size: size)
    _ = try await client.observe(terminalID: "term_w1p2", size: size)

    #expect(
      await commands.all == [
        "export HERDR_SOCKET_PATH='/run/herdr sock'; "
          + "herdr terminal session control term_w1p2 --cols 80 --rows 24",
        "export HERDR_SOCKET_PATH='/run/herdr sock'; "
          + "herdr terminal session observe term_w1p2 --cols 80 --rows 24",
      ]
    )
  }

  @Test("with no socket path both commands run bare, on the host's default herdr")
  func leavesTheDefaultSocketAlone() async throws {
    let commands = CommandLog()
    let client = TerminalBridgeClient { command in
      await commands.append(command)
      return ScriptedStream()
    }
    _ = try await client.open(terminalID: "term_w1p2", size: size)
    _ = try await client.observe(terminalID: "term_w1p2", size: size)

    #expect(
      await commands.all == [
        "herdr terminal session control term_w1p2 --cols 80 --rows 24",
        "herdr terminal session observe term_w1p2 --cols 80 --rows 24",
      ]
    )
  }

  private actor CommandLog {
    private(set) var all: [String] = []
    func append(_ command: String) { all.append(command) }
  }

  private func openBridge() async throws -> (ScriptedStream, any PaneBridge) {
    let stream = ScriptedStream()
    let client = TerminalBridgeClient { _ in stream }
    let bridge = try await client.open(terminalID: "term_w1p2", size: size)
    return (stream, bridge)
  }

  @Test("frames arrive as bytes ready for the emulator")
  func deliversFrames() async throws {
    let (stream, bridge) = try await openBridge()
    stream.emit(frameLine("\u{1B}[2Jhello"))

    var iterator = bridge.output.makeAsyncIterator()
    let bytes = try await iterator.next()
    #expect(bytes == Data("\u{1B}[2Jhello".utf8))
  }

  @Test("scrolling sends herdr's own command, with a direction and a line count")
  func sendsScroll() async throws {
    // A pane's history is herdr's, so scrolling is a message rather than a scroll view gesture.
    let (stream, bridge) = try await openBridge()
    try await bridge.scroll(.up, lines: 5)

    let command = try #require(stream.sentCommands.first)
    #expect(command["type"] as? String == "terminal.scroll")
    #expect(command["direction"] as? String == "up")
    #expect(command["lines"] as? Int == 5)
  }

  @Test("a scroll of no lines is not sent at all")
  func ignoresEmptyScroll() async throws {
    // herdr rejects a non-positive count, so a drag that rounds to zero would earn an error.
    let (stream, bridge) = try await openBridge()
    try await bridge.scroll(.down, lines: 0)
    #expect(stream.sentLines.isEmpty)
  }

  @Test("a click sends a left press then a release at one 0-based cell")
  func sendsClick() async throws {
    // herdr encodes the report, and only when the pane's program asked for mouse events.
    let (stream, bridge) = try await openBridge()
    try await bridge.click(TerminalCell(column: 12, row: 5))

    let commands = stream.sentCommands
    #expect(commands.count == 2)
    #expect(commands.map { $0["type"] as? String } == ["terminal.mouse", "terminal.mouse"])
    #expect(commands.map { $0["kind"] as? String } == ["down", "up"])
    for command in commands {
      #expect(command["column"] as? Int == 12)
      #expect(command["row"] as? Int == 5)
      #expect(command["modifiers"] as? Int == 0)
    }
  }

  @Test("typed text is sent as text, and raw bytes as base64, never both")
  func sendsInput() async throws {
    let (stream, bridge) = try await openBridge()
    try await bridge.send(text: "ls\n")
    try await bridge.send(bytes: Data([0x1B]))

    let lines = stream.sentLines
    #expect(lines.count == 2)
    #expect(lines[0].contains("\"type\":\"terminal.input\""))
    #expect(lines[0].contains("\"text\":\"ls\\n\""))
    #expect(!lines[0].contains("\"bytes\""), "herdr drops a command carrying both")
    #expect(lines[1].contains("\"bytes\":\"Gw==\""))
    #expect(!lines[1].contains("\"text\""))
  }

  @Test("resizing carries the cell pixel size as well as the grid")
  func sendsResize() async throws {
    // Programs that draw images size themselves off the pixel pair.
    let (stream, bridge) = try await openBridge()
    try await bridge.resize(
      to: TerminalSize(columns: 40, rows: 20, pixelWidth: 400, pixelHeight: 400)
    )

    let line = try #require(stream.sentLines.first)
    #expect(line.contains("\"type\":\"terminal.resize\""))
    #expect(line.contains("\"cols\":40"))
    #expect(line.contains("\"rows\":20"))
    #expect(line.contains("\"cell_width_px\":10"))
    #expect(line.contains("\"cell_height_px\":20"))
  }

  @Test("releasing tells herdr, then closes the stream")
  func releasesTheController() async throws {
    // herdr allows one controller at a time, so the next attach would find the pane taken.
    let (stream, bridge) = try await openBridge()
    await bridge.release()

    #expect(stream.sentLines.first?.contains("\"type\":\"terminal.release\"") == true)
    #expect(stream.closed)
  }

  @Test("an ordinary close ends the output stream with no error")
  func closesOnTerminalClosed() async throws {
    let (stream, bridge) = try await openBridge()
    stream.emit(frameLine("before"))
    stream.emit("{\"type\":\"terminal.closed\"}\n")

    var received: [Data] = []
    for try await bytes in bridge.output { received.append(bytes) }
    #expect(received == [Data("before".utf8)])
  }

  @Test("a plain process exit ends the output stream with no error, same as no reason")
  func processExitDoesNotThrow() async throws {
    // herdr's ordinary close carries "terminal <id> exited". Mapped to `.other`, it would throw
    // on the most common close.
    let (stream, bridge) = try await openBridge()
    stream.emit(frameLine("before"))
    stream.emit("{\"type\":\"terminal.closed\",\"reason\":\"terminal term_w1p2 exited\"}\n")

    var received: [Data] = []
    for try await bytes in bridge.output { received.append(bytes) }
    #expect(received == [Data("before".utf8)])
  }

  @Test("a refusal is thrown, not swallowed, so a caller can offer Take over")
  func refusalSurfacesAsAThrownReason() async throws {
    let (stream, bridge) = try await openBridge()
    let line =
      "{\"type\":\"terminal.closed\",\"reason\":\"terminal attach failed: terminal "
      + "term_w1p2 already has an attached client; retry with --takeover\"}\n"
    stream.emit(line)

    await #expect(throws: TerminalCloseReason.refused) {
      for try await _ in bridge.output {}
    }
  }

  @Test("a takeover is thrown, not swallowed, so a caller can show Take back")
  func takeoverSurfacesAsAThrownReason() async throws {
    let (stream, bridge) = try await openBridge()
    stream.emit(frameLine("before"))
    stream.emit("{\"type\":\"terminal.closed\",\"reason\":\"terminal attach taken over\"}\n")

    var received: [Data] = []
    await #expect(throws: TerminalCloseReason.takenOver) {
      for try await bytes in bridge.output { received.append(bytes) }
    }
    #expect(received == [Data("before".utf8)])
  }

  @Test("a stream that stops with nothing from herdr on it is .streamEnded, not .paneClosed")
  func aBareStreamEndIsDistinguishable() async throws {
    // A dropped channel and herdr ending the session both simply stop, and only herdr writes
    // `terminal.closed`. The missing record decides whether Driverr still owes the attach
    // token back, so it must survive this layer.
    let (stream, bridge) = try await openBridge()
    stream.emit(frameLine("before"))
    stream.finish()

    var received: [Data] = []
    await #expect(throws: TerminalCloseReason.streamEnded) {
      for try await bytes in bridge.output { received.append(bytes) }
    }
    #expect(received == [Data("before".utf8)], "the frames that did arrive still arrived")
  }

  @Test("a bridge process that exits nonzero is .processFailed, carrying herdr's own words")
  func aFailedProcessCarriesItsReason() async throws {
    // A stream that stops may be a lost channel or a remote command that refused. The exit
    // status separates them, and herdr writes the reason to stderr.
    let (stream, bridge) = try await openBridge()
    stream.exit(
      status: 1,
      standardError: "herdr: failed to request terminal attach: pane not found\n"
    )

    await #expect(
      throws: TerminalCloseReason.processFailed(
        status: 1,
        message: "failed to request terminal attach: pane not found"
      )
    ) {
      for try await _ in bridge.output {}
    }
  }

  @Test("herdr's JSON error envelope reads as its message, not as a line of JSON")
  func aFailedProcessReadsTheEnvelope() async throws {
    // Which shape a failed `terminal session control` writes is unconfirmed, so both are
    // handled.
    let (stream, bridge) = try await openBridge()
    stream.exit(
      status: 1,
      standardError: "{\"id\":\"\",\"error\":{\"code\":\"server_unavailable\","
        + "\"message\":\"server is unavailable\"}}\n"
    )

    await #expect(
      throws: TerminalCloseReason.processFailed(status: 1, message: "server is unavailable")
    ) {
      for try await _ in bridge.output {}
    }
  }

  @Test("a bridge process that exits nonzero saying nothing still says it failed")
  func aSilentFailureStillReportsItsStatus() async throws {
    // The status alone separates "the command refused" from "the channel vanished".
    // `TerminalEndDisposition` supplies the sentence.
    let (stream, bridge) = try await openBridge()
    stream.exit(status: 127, standardError: "   \n")

    await #expect(throws: TerminalCloseReason.processFailed(status: 127, message: nil)) {
      for try await _ in bridge.output {}
    }
  }

  @Test("a bridge process that exits zero with no record on it is still just a stream that stopped")
  func aCleanExitIsNotAFailure() async throws {
    // A clean exit with no `terminal.closed` says nothing about the terminal behind it.
    let (stream, bridge) = try await openBridge()
    stream.exit(status: 0, standardError: "herdr: some warning nobody asked about\n")

    await #expect(throws: TerminalCloseReason.streamEnded) {
      for try await _ in bridge.output {}
    }
  }

  @Test("herdr's own close outranks the exit status underneath it")
  func aStatedCloseBeatsTheExitStatus() async throws {
    // The pump returns at the record and never reads the status.
    let (stream, bridge) = try await openBridge()
    stream.emit("{\"type\":\"terminal.closed\",\"reason\":\"terminal attach taken over\"}\n")
    stream.exit(status: 1, standardError: "herdr: something else entirely\n")

    await #expect(throws: TerminalCloseReason.takenOver) {
      for try await _ in bridge.output {}
    }
  }

  @Test("a release ends the stream cleanly rather than as a link that went")
  func aReleaseIsNotAStreamThatWentAway() async throws {
    // Driverr asked for the hand-back. `BridgeFramePump.cancel()` finishes before the task can
    // reach `.streamEnded`, and the task checks its own cancellation too.
    let (_, bridge) = try await openBridge()
    await bridge.release()

    var received: [Data] = []
    for try await bytes in bridge.output { received.append(bytes) }
    #expect(received.isEmpty)
  }
}

@Suite("TerminalBridgeClient.observe")
struct TerminalBridgeObserverTests {
  private let size = TerminalSize(columns: 24, rows: 6, pixelWidth: 240, pixelHeight: 120)

  private func openObserver() async throws -> (ScriptedStream, any PaneObserver) {
    let stream = ScriptedStream()
    let client = TerminalBridgeClient { _ in stream }
    let observer = try await client.observe(terminalID: "term_w1p2", size: size)
    return (stream, observer)
  }

  @Test("frames decode the same way as a controller's")
  func deliversFrames() async throws {
    let (stream, observer) = try await openObserver()
    stream.emit(frameLine("\u{1B}[2Jhello"))

    var iterator = observer.output.makeAsyncIterator()
    let bytes = try await iterator.next()
    #expect(bytes == Data("\u{1B}[2Jhello".utf8))
  }

  @Test("releasing closes the stream without sending a wire command")
  func releaseSendsNothing() async throws {
    // An observer never held the token; `HerdrPaneBridge.release()` writes `terminal.release`.
    let (stream, observer) = try await openObserver()
    await observer.release()

    #expect(stream.sentLines.isEmpty)
    #expect(stream.closed)
  }

  @Test("an ordinary close ends the output stream with no error")
  func closesOnTerminalClosed() async throws {
    let (stream, observer) = try await openObserver()
    stream.emit(frameLine("before"))
    stream.emit("{\"type\":\"terminal.closed\"}\n")

    var received: [Data] = []
    for try await bytes in observer.output { received.append(bytes) }
    #expect(received == [Data("before".utf8)])
  }

  @Test("a non-ordinary close reason is still thrown from an observer's stream")
  func surfacesCloseReason() async throws {
    // Same decoding path as a controller's.
    let (stream, observer) = try await openObserver()
    stream.emit("{\"type\":\"terminal.closed\",\"reason\":\"terminal session stopped\"}\n")

    await #expect(throws: TerminalCloseReason.other("terminal session stopped")) {
      for try await _ in observer.output {}
    }
  }

  @Test("an observer's stream stopping with nothing on it is .streamEnded too")
  func aBareStreamEndIsDistinguishable() async throws {
    // One pump serves both; nothing above an observer acts on this.
    let (stream, observer) = try await openObserver()
    stream.finish()

    await #expect(throws: TerminalCloseReason.streamEnded) {
      for try await _ in observer.output {}
    }
  }
}
