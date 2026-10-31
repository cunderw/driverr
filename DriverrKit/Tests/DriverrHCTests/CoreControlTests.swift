import DriverrCore
import DriverrHerdr
import Foundation
import Testing

@testable import DriverrHC

/// Hands out one scripted stream per `hc connect`, and counts them.
private final class CoreHost: @unchecked Sendable {
  private let lock = NSLock()
  private var streams: [FakeCoreStream]
  private var commands: [String] = []

  init(_ streams: FakeCoreStream...) {
    self.streams = streams
  }

  var opened: [String] { lock.withLock { commands } }

  func open(_ command: String) async throws -> any HerdrStream {
    try lock.withLock {
      commands.append(command)
      guard !streams.isEmpty else { throw AppError.channelFailed(reason: "no stream") }
      return streams.removeFirst()
    }
  }
}

@Suite("Core control", .timeLimit(.minutes(1)))
struct CoreControlTests {
  private func control(_ host: CoreHost, deadline: Duration = .seconds(30)) -> CoreControl {
    CoreControl(
      binaryPath: "/home/my user/.local/bin/herdr-core",
      callDeadline: deadline,
      open: { try await host.open($0) }
    )
  }

  private func listing(_ terminals: String) -> FakeCoreStream {
    let stream = FakeCoreStream()
    stream.replies["terminal.list"] = .result(#"{"terminals":[\#(terminals)]}"#)
    return stream
  }

  /// Two spaces, listed the wrong way round for `document`.
  private func spaces() -> FakeCoreStream {
    listing(
      #"""
      {"address":"t1","labels":{"herdr.space":"a","herdr.tab":"x"}},
      {"address":"t2","labels":{"herdr.space":"b","herdr.tab":"y"}}
      """#)
  }

  /// `b` before `a`, and named.
  private static let document = #"""
    {"value":{"spaces":[{"id":"b","name":"Bee","tabs":[]},{"id":"a","name":"Ay","tabs":[]}]},
    "version":7}
    """#

  private let terminal = #"{"address":"t1","cwd":"/srv","title":"a"}"#

  @Test("a snapshot opens the connection by quoted path and lists terminals")
  func snapshot() async throws {
    let stream = listing(terminal)
    let host = CoreHost(stream)
    let tree = try await control(host).snapshot()
    #expect(tree.allPanes.map(\.id) == ["core:t1"])
    #expect(host.opened == ["'/home/my user/.local/bin/herdr-core' connect"])
    #expect(Set(stream.methods) == ["terminal.list", "doc.get"])
  }

  @Test("the app's document orders and names the snapshot")
  func documentOrders() async throws {
    let stream = spaces()
    stream.replies["doc.get"] = .result(Self.document)
    let tree = try await control(CoreHost(stream)).snapshot()
    #expect(tree.workspaces.map(\.label) == ["Bee", "Ay"])
  }

  @Test("Driverr reads the app's document and never writes it")
  func neverWrites() async throws {
    let stream = spaces()
    stream.replies["doc.get"] = .result(Self.document)
    let control = control(CoreHost(stream))
    _ = try await control.snapshot()
    stream.replies["doc.get"] = .error("unavailable")
    _ = try await control.snapshot()
    #expect(Set(stream.methods) == ["terminal.list", "doc.get"])
    #expect(stream.methods.filter { $0 == "doc.get" }.count == 2)
  }

  @Test("no document leaves the terminals as listed")
  func noDocument() async throws {
    let tree = try await control(CoreHost(spaces())).snapshot()
    #expect(tree.workspaces.map(\.id) == ["core:a", "core:b"])
  }

  /// The app's format is private, and one poll's failure must not move rows under a thumb.
  @Test(
    "a read that fails keeps the last good order",
    arguments: [
      FakeCoreStream.Reply.error("unavailable"),
      .result(#"{"value":5,"version":8}"#),
      .result(#"{"value":{"spaces":"later"},"version":8}"#),
    ])
  func failedReadKeepsOrder(reply: FakeCoreStream.Reply) async throws {
    let stream = spaces()
    stream.replies["doc.get"] = .result(Self.document)
    let control = control(CoreHost(stream))
    #expect(try await control.snapshot().workspaces.map(\.id) == ["core:b", "core:a"])

    stream.replies["doc.get"] = reply
    #expect(try await control.snapshot().workspaces.map(\.id) == ["core:b", "core:a"])
  }

  @Test(
    "a first read that fails is no document, not a failed snapshot",
    arguments: [
      FakeCoreStream.Reply.error("no such method"),
      .result(#"{"value":"not a document"}"#),
    ])
  func unreadableDocument(reply: FakeCoreStream.Reply) async throws {
    let stream = spaces()
    stream.replies["doc.get"] = reply
    let tree = try await control(CoreHost(stream)).snapshot()
    #expect(tree.workspaces.map(\.id) == ["core:a", "core:b"])
  }

  @Test("a read that never answers costs the deadline, not the snapshot")
  func silentDocument() async throws {
    let stream = spaces()
    stream.replies["doc.get"] = .silent
    let control = control(CoreHost(stream), deadline: .milliseconds(500))
    #expect(try await control.snapshot().allPanes.count == 2)
  }

  @Test("a document that has gone clears the order")
  func documentCleared() async throws {
    let stream = spaces()
    stream.replies["doc.get"] = .result(Self.document)
    let control = control(CoreHost(stream))
    _ = try await control.snapshot()

    stream.replies["doc.get"] = .result(FakeCoreStream.noDocument)
    #expect(try await control.snapshot().workspaces.map(\.id) == ["core:a", "core:b"])
  }

  @Test("snapshots share one connection")
  func oneConnection() async throws {
    let host = CoreHost(listing(terminal))
    let control = control(host)
    _ = try await control.snapshot()
    _ = try await control.snapshot()
    #expect(host.opened.count == 1)
  }

  @Test("concurrent first calls share one opening")
  func oneOpening() async throws {
    let host = CoreHost(listing(terminal))
    let control = control(host)
    async let first = control.snapshot()
    async let second = control.snapshot()
    _ = try await (first, second)
    #expect(host.opened.count == 1)
  }

  @Test("after the stream dies, the next snapshot reopens")
  func reopen() async throws {
    let dying = listing(terminal)
    let replacement = listing(#"{"address":"t2","cwd":"/srv","title":"b"}"#)
    let host = CoreHost(dying, replacement)
    let control = control(host)
    _ = try await control.snapshot()

    dying.finish()
    // Letting the stream go is the last thing the reader does when it sees the end.
    try await waitUntil("the reader sees the end") { dying.closes == 1 }

    let tree = try await control.snapshot()
    #expect(tree.allPanes.map(\.id) == ["core:t2"])
    #expect(host.opened.count == 2)
  }

  @Test("availability reads the same connection the snapshot uses")
  func availability() async throws {
    let host = CoreHost(listing(terminal))
    let control = control(host)
    #expect(await control.availability() == .coreReady(version: "0.1.14"))
    _ = try await control.snapshot()
    #expect(host.opened.count == 1)
  }

  @Test("a refused core reports why, and is not asked again on every poll")
  func refusal() async {
    let stream = FakeCoreStream()
    stream.helloReply = FakeCoreStream.helloReply(generation: 2)
    let host = CoreHost(stream)
    let control = control(host)

    let expected = HerdrAvailability.coreIncompatible(
      version: "0.1.14", generation: 2, missingMethods: [])
    #expect(await control.availability() == expected)

    await #expect(throws: AppError.herdrCommandFailed(reason: expected.message)) {
      try await control.snapshot()
    }
    #expect(host.opened.count == 1)
  }

  @Test("no core and a dead core are both not installed")
  func notCore() async {
    let stream = FakeCoreStream()
    stream.helloReply = nil
    let host = CoreHost(stream)
    let control = control(host, deadline: .milliseconds(50))
    #expect(await control.availability() == .notInstalled)
    await #expect(throws: AppError.herdrCommandFailed(reason: "herdr-core is not answering.")) {
      try await control.snapshot()
    }
  }

  @Test("a failed exec is not a crash")
  func openFails() async {
    let host = CoreHost()
    #expect(await control(host).availability() == .notInstalled)
  }

  @Test("attaching names the terminal's address, quoted, machine prefix included")
  func attachCommand() {
    let pane = Pane(
      id: "core:box/t1", tabID: "x", workspaceID: "y", title: "z", terminalID: "box/t1")
    #expect(
      control(CoreHost()).attachCommand(for: pane)
        == "'/home/my user/.local/bin/herdr-core' attach box/t1"
    )
  }

  /// One connected core that answers `terminal.attach`.
  private func attachable(_ reply: FakeCoreStream.Reply? = nil) -> FakeCoreStream {
    let stream = FakeCoreStream()
    stream.replies = ["terminal.attach": reply ?? .result(FakeCoreStream.attached(channel: 3))]
    return stream
  }

  private func text(_ frame: CoreFrame) -> String {
    String(decoding: frame.payload, as: UTF8.self)
  }

  /// Everything after the close is the same in every case below, so it is checked once here:
  /// DATA frames on the viewer's channel, then its CLOSE, and nothing that claims the size.
  private func typed(on stream: FakeCoreStream) async throws -> [String] {
    try await waitUntil("the CLOSE") { stream.streamFrames.last?.kind == .close }
    let frames = stream.streamFrames
    #expect(frames.allSatisfy { $0.channel == 3 })
    #expect(frames.dropLast().allSatisfy { $0.kind == .data })
    return frames.dropLast().map(text)
  }

  /// `touch` drops an observer's input, so a held `observe` cannot type. 0x0 is what keeps a
  /// typing viewer off the size: `apply_size` returns before it resizes.
  @Test("typing goes through a short-lived 0x0 viewer, never terminal.send")
  func typingViewer() async throws {
    let stream = attachable()
    let control = control(CoreHost(stream))

    try await control.sendText(paneID: "core:box/t7", text: "hi")

    #expect(try await typed(on: stream) == ["hi"])
    #expect(stream.methods == ["terminal.attach"])
    let params = try #require(try stream.params(of: "terminal.attach").first)
    #expect(params["terminal"] as? String == "box/t7")
    #expect(params["cols"] as? Int == 0)
    #expect(params["rows"] as? Int == 0)
    #expect(params["resumed"] as? Bool == true)
    #expect(params["observe"] as? Bool == false)
    #expect(params["history"] as? Int == 0)
    #expect(params["display"] == nil)
  }

  @Test("a submit is the text, then CR on its own, as core's own send writes them")
  func submit() async throws {
    let stream = attachable(.result(FakeCoreStream.attached(channel: 3, pasteGap: 1)))
    let control = control(CoreHost(stream))

    try await control.submitText(paneID: "core:t7", text: "hi")

    #expect(try await typed(on: stream) == ["hi", "\r"])
  }

  @Test(
    "a template's submit key is pressed, and one a viewer cannot spell falls back to CR",
    arguments: [("tab", "\t"), ("ctrl+enter", "\r")]
  )
  func templateSubmit(key: String, written: String) async throws {
    let stream = attachable(
      .result(FakeCoreStream.attached(channel: 3, submit: key, pasteGap: 1)))
    let control = control(CoreHost(stream))

    try await control.submitText(paneID: "core:t7", text: "hi")

    #expect(try await typed(on: stream) == ["hi", written])
  }

  @Test("keys are written one at a time, spelled as a plain terminal sends them")
  func keys() async throws {
    let stream = attachable()
    let control = control(CoreHost(stream))

    try await control.sendKeys(
      paneID: "core:t7",
      keys: [.up, .down, .left, .right, .enter, .esc, .tab, .interrupt, .yes, .no, .digit3]
    )

    #expect(
      try await typed(on: stream) == [
        "\u{1B}[A", "\u{1B}[B", "\u{1B}[D", "\u{1B}[C", "\r", "\u{1B}", "\t", "\u{03}", "y", "n",
        "3",
      ])
  }

  @Test("an attach the core refuses reaches the composer in the core's words, and types nothing")
  func refusedTyping() async throws {
    let stream = attachable(.error("t7 is lost, waiting for its new shell"))
    let control = control(CoreHost(stream))

    await #expect(
      throws: AppError.herdrCommandFailed(reason: "t7 is lost, waiting for its new shell")
    ) {
      try await control.sendText(paneID: "core:t7", text: "hi")
    }
    #expect(stream.streamFrames.isEmpty)
  }

  @Test("opening a terminal is active, at the phone's size, with the emulator's history")
  func openParams() async throws {
    let stream = attachable()
    let control = control(CoreHost(stream))

    let attacher = try #require(control.paneAttacher(for: "core:t7"))
    _ = try await attacher.open(
      terminalID: "box/t7", size: TerminalSize(columns: 50, rows: 20))

    let params = try #require(try stream.params(of: "terminal.attach").first)
    #expect(params["terminal"] as? String == "box/t7")
    #expect(params["cols"] as? Int == 50)
    #expect(params["rows"] as? Int == 20)
    #expect(params["resumed"] as? Bool == false)
    #expect(params["observe"] as? Bool == false)
    #expect(params["history"] as? Int == 500)
    #expect(params["display"] == nil)
  }

  @Test("an observer is read-only, and takes no history")
  func observeParams() async throws {
    let stream = attachable()
    let control = control(CoreHost(stream))

    let attacher = try #require(control.paneAttacher(for: "core:t7"))
    _ = try await attacher.observe(terminalID: "t7", size: TerminalSize(columns: 50, rows: 20))

    let params = try #require(try stream.params(of: "terminal.attach").first)
    #expect(params["observe"] as? Bool == true)
    #expect(params["history"] as? Int == 0)
  }

  @Test("an attach with no core says so")
  func attachWithNoCore() async {
    let control = control(CoreHost())
    await #expect(throws: AppError.herdrCommandFailed(reason: "herdr-core is not answering.")) {
      _ = try await control.open(terminalID: "t7", size: TerminalSize(columns: 50, rows: 20))
    }
  }

  @Test("what is not built yet refuses instead of reporting success")
  func notBuiltYet() async {
    let control = control(CoreHost())
    let pane = Pane(id: "core:t1", tabID: "x", workspaceID: "y", title: "z", terminalID: "t1")
    let refused = AppError.herdrCommandFailed(
      reason: "Driverr can't do this on a herdr-core terminal yet.")

    await #expect(throws: refused) { _ = try await control.readScreen(of: pane, lines: 5) }
    await #expect(throws: refused) { try await control.perform(.close, on: pane.id) }
    await #expect(throws: refused) {
      try await control.rename(.tab(id: "core:tab"), to: "x")
    }
  }

  @Test("a read maps every pane to empty, as a pane that could not be read")
  func readPanes() async throws {
    let panes = try await control(CoreHost()).readPanes(ids: ["core:t1", "core:t2"], lines: 5)
    #expect(panes == ["core:t1": [], "core:t2": []])
  }

  @Test("a socket path changes nothing: a core is not a herdr session")
  func socketPath() {
    let control = control(CoreHost())
    #expect(control.bound(toSocketPath: "/run/x.sock").binaryPath == control.binaryPath)
  }
}
