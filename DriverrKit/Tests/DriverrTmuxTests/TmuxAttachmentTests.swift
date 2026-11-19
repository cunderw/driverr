import DriverrCore
import DriverrHerdr
import Foundation
import Testing

@testable import DriverrTmux

/// A tmux pane's live terminal, against a scripted control client.
@Suite("TmuxAttachment", .timeLimit(.minutes(1)))
struct TmuxAttachmentTests {
  private static let phone = TerminalSize(columns: 60, rows: 20, pixelWidth: 600, pixelHeight: 400)

  /// A host with one session, `$0`, whose current window is 150x43, holding `%3` in `@1`.
  private final class Host: @unchecked Sendable {
    let lock = NSLock()
    var opened: [String] = []
    var cliCommands: [String] = []
    var livingPanes = "%3\n"
    var resizes = true
    /// The listing after a stream ends never answers, as on a link that went quiet.
    var listingHangs = false
    /// What locating a pane answers, by pane. Unlisted panes are `%3`'s place.
    var places: [String: String] = [:]
    /// The control streams of sessions other than `$0`, by session.
    var sessions: [String: FakeTmuxControlStream] = [:]
    let stream: FakeTmuxControlStream

    init(_ panes: [String: FakeTmuxControlStream.Pane] = ["%3": Host.shell()]) {
      stream = FakeTmuxControlStream(panes: panes)
    }

    static func shell(window: String = "@1") -> FakeTmuxControlStream.Pane {
      var state = TmuxPaneState()
      state.height = 2
      state.cursorColumn = 2
      state.cursorRow = 1
      state.scrollBottom = 1
      return FakeTmuxControlStream.Pane(
        window: window, state: state, history: ["old one", "old two"], screen: ["$ ls", "$ "])
    }

    var attacher: TmuxAttacher {
      TmuxAttacher(
        binary: "'tmux' -u",
        run: { [self] command in
          lock.withLock { cliCommands.append(command) }
          if command.contains("display-message") {
            let pane = Self.quoted(after: "-t", in: command)
            let place = lock.withLock { places[pane] } ?? "$0 @1 150x43"
            return CommandResult(standardOutput: place + "\n", standardError: "", exitStatus: 0)
          }
          if lock.withLock({ listingHangs }) { try await Task.sleep(for: .seconds(3600)) }
          return CommandResult(
            standardOutput: lock.withLock { livingPanes }, standardError: "", exitStatus: 0)
        },
        open: { [self] command in
          let session = Self.quoted(after: "attach-session -t", in: command)
          return lock.withLock {
            opened.append(command)
            return sessions[session] ?? stream
          }
        },
        resizesWindow: { [self] in lock.withLock { resizes } })
    }

    /// The single-quoted word after `prefix` in `command`.
    static func quoted(after prefix: String, in command: String) -> String {
      guard let start = command.range(of: prefix + " '") else { return "" }
      return String(command[start.upperBound...].prefix { $0 != "'" })
    }
  }

  /// The first sizing line for `window`, which reads the size it had first.
  private static func firstSizing(_ window: String, _ size: String) -> String {
    "display-message -p -t \(window) '#{window_width}x#{window_height}' ; refresh-client -C \(window):\(size)"
  }

  /// The line that gives `window` back at `size`.
  private static func handBack(_ window: String, _ size: String = FakeTmuxControlStream.windowSize)
    -> String
  {
    "refresh-client -C \(window):\(size) ; refresh-client -C \(window):"
  }

  /// How tmux before 3.3 sizes `window`, which takes no `@W:` size.
  private static func resize(_ window: String, _ columns: Int, _ rows: Int) -> String {
    "resize-window -x \(columns) -y \(rows) -t \(window)"
  }

  /// The line that gives `window` back at `150x43` on tmux before 3.3, and leaves its size to
  /// tmux again.
  private static func handBackBefore33(_ window: String) -> String {
    "resize-window -x 150 -y 43 -t \(window) ; set-option -w -u -t \(window) window-size"
  }

  /// Polls `condition` for up to `seconds`, for state with no signal of its own. Callers assert
  /// after, so a wait that runs out fails there.
  private func poll(_ seconds: Double = 5, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  /// Output until it holds `text`, or the stream ends.
  private func read(
    _ iterator: inout AsyncThrowingStream<Data, any Error>.AsyncIterator, until text: String
  ) async throws -> String {
    var seen = Data()
    while !String(decoding: seen, as: UTF8.self).contains(text) {
      guard let chunk = try await iterator.next() else { break }
      seen.append(chunk)
    }
    return String(decoding: seen, as: UTF8.self)
  }

  /// Whether `body` returns within `limit`. A race, not a task group, because a group waits for
  /// the child that hung, and a suspended task fails no test.
  private func finishes(
    within limit: Duration, _ body: @escaping @Sendable () async -> Void
  ) async -> Bool {
    final class Once: @unchecked Sendable {
      let lock = NSLock()
      var waiting: CheckedContinuation<Bool, Never>?
      func resume(_ value: Bool) {
        lock.withLock {
          defer { waiting = nil }
          return waiting
        }?.resume(returning: value)
      }
    }
    let once = Once()
    return await withCheckedContinuation { continuation in
      once.lock.withLock { once.waiting = continuation }
      Task {
        await body()
        once.resume(true)
      }
      Task {
        try? await Task.sleep(for: limit)
        once.resume(false)
      }
    }
  }

  @Test("the client attaches to the session, sized to its current window, never to the pane")
  func attachLine() async throws {
    let host = Host()
    let bridge = try await host.attacher.open(terminalID: "tmux:%3", size: Self.phone)
    // `@1:` first, which tmux before 3.3 refuses, so it skips the client size after it.
    #expect(
      host.opened == [
        "'tmux' -u -C attach-session -t '$0' \\; refresh-client -C @1: \\; refresh-client -C 150x43"
      ])
    #expect(host.cliCommands.first?.contains("display-message -p -t '%3'") == true)
    await bridge.release()
  }

  @Test("a controller sizes its window before the paint, and the paint has history and the cursor")
  func controllerPaint() async throws {
    let host = Host()
    let bridge = try await host.attacher.open(terminalID: "tmux:%3", size: Self.phone)
    #expect(host.stream.lines.first == Self.firstSizing("@1", "60x20"))
    #expect(host.stream.lines.dropFirst().first?.hasPrefix("display-message -p -t %3 ") == true)
    #expect(host.stream.lines.dropFirst().first?.contains("capture-pane -p -e -S -500 -t %3") == true)

    var output = bridge.output.makeAsyncIterator()
    let paint = try await read(&output, until: "H")
    #expect(paint.hasPrefix("old one\r\nold two\r\n$ ls\r\n$ "))
    #expect(paint.hasSuffix("\u{1B}[0m\u{1B}[2;3H"), "cursor at row 2, column 3")
    await bridge.release()
  }

  @Test("output tmux had queued before the paint is in the capture and is dropped; later output is not")
  func ordering() async throws {
    let host = Host()
    host.stream.around(paintOf: "%3", stale: "STALE", fresh: "FRESH")
    let bridge = try await host.attacher.open(terminalID: "tmux:%3", size: Self.phone)
    var output = bridge.output.makeAsyncIterator()
    let seen = try await read(&output, until: "FRESH")
    #expect(!seen.contains("STALE"))
    #expect(seen.hasPrefix("old one"))
    #expect(seen.hasSuffix("FRESH"))
    await bridge.release()
  }

  /// Found by `LiveTmuxProbeTests.ordering`: a counting pane's numbers came twice, because the
  /// output written while the window was being sized reached the viewer ahead of the paint.
  @Test("output while the window is sized, before the first paint, is in the paint and is dropped")
  func outputWhileSizing() async throws {
    let host = Host()
    host.stream.after(sizing: "%3", writes: "REFLOWED")
    host.stream.around(paintOf: "%3", stale: "", fresh: "FRESH")
    let bridge = try await host.attacher.open(terminalID: "tmux:%3", size: Self.phone)
    var output = bridge.output.makeAsyncIterator()
    let seen = try await read(&output, until: "FRESH")
    #expect(!seen.contains("REFLOWED"))
    #expect(seen.hasPrefix("old one"))
    await bridge.release()
  }

  @Test("on the alternate screen the normal one is painted first, then ?1049h, then the program")
  func alternateScreen() async throws {
    var pane = Host.shell()
    pane.state.alternateScreen = true
    pane.normal = ["$ claude", ""]
    pane.screen = ["CLAUDE", "> "]
    let host = Host(["%3": pane])
    let bridge = try await host.attacher.open(terminalID: "tmux:%3", size: Self.phone)
    var output = bridge.output.makeAsyncIterator()
    let paint = try await read(&output, until: "H")
    let expected =
      "old one\r\nold two\r\n$ claude\r\n\u{1B}[0m\u{1B}[?1049h\u{1B}[H\u{1B}[2JCLAUDE\r\n> "
    #expect(paint.hasPrefix(expected))
    await bridge.release()
  }

  @Test("modes a program set come back after the paint")
  func modes() {
    var state = TmuxPaneState()
    state.height = 24
    state.scrollBottom = 23
    state.applicationCursorKeys = true
    state.bracketedPaste = true
    state.mouseSGR = true
    state.cursorVisible = false
    state.cursorRow = 4
    let modes = TmuxPaint.modes(of: state)
    #expect(modes == "\u{1B}[0m\u{1B}[?1h\u{1B}[?1006h\u{1B}[?2004h\u{1B}[5;1H\u{1B}[?25l")
    // A state line from a tmux that does not know a variable leaves the field empty.
    let line = FakeTmuxControlStream.stateLine(state).replacingOccurrences(of: "1.24.", with: ".24.")
    #expect(TmuxPaneState(Data(line.utf8))?.bracketedPaste == false)
  }

  @Test("typing goes as hex keys, in chunks, emoji and control bytes included")
  func typing() async throws {
    let host = Host()
    let bridge = try await host.attacher.open(terminalID: "tmux:%3", size: Self.phone)
    try await bridge.send(text: "é😀\u{3}")
    let paste = Data(repeating: 0x61, count: TmuxSessionClient.keyChunk + 10)
    try await bridge.send(bytes: paste)
    // A command the fake answers after the keys proves they have all been read.
    try await bridge.resize(to: TerminalSize(columns: 61, rows: 20, pixelWidth: 0, pixelHeight: 0))
    #expect(host.stream.keys(for: "%3") == Data("é😀\u{3}".utf8) + paste)
    let keyLines = host.stream.lines.filter { $0.hasPrefix("send-keys") }
    #expect(keyLines.count == 3)
    #expect(keyLines.first == "send-keys -t %3 -H c3 a9 f0 9f 98 80 03")
    await bridge.release()
  }

  @Test("a resize sizes the window again, and release hands the window back and closes")
  func resizeAndRelease() async throws {
    let host = Host()
    let bridge = try await host.attacher.open(terminalID: "tmux:%3", size: Self.phone)
    try await bridge.resize(to: TerminalSize(columns: 40, rows: 30, pixelWidth: 0, pixelHeight: 0))
    #expect(host.stream.lines.contains("refresh-client -C @1:40x30"))
    await bridge.release()
    // The client leaving hands its windows back only after it has gone, so the window is asked
    // for first, and is back when the release returns.
    #expect(host.stream.lines.last == Self.handBack("@1"))
    #expect(host.stream.size(of: "@1") == "150x43")
    #expect(host.stream.closeCount == 1, "the last pane to leave closes the client")
  }

  @Test("with resizing off nothing sizes a window, at open, on resize or on release")
  func resizingOff() async throws {
    let host = Host()
    host.resizes = false
    let bridge = try await host.attacher.open(terminalID: "tmux:%3", size: Self.phone)
    try await bridge.resize(to: TerminalSize(columns: 40, rows: 30, pixelWidth: 0, pixelHeight: 0))
    try await bridge.send(text: "x")
    await bridge.release()
    #expect(!host.stream.lines.contains { $0.hasPrefix("refresh-client") })
  }

  // MARK: Window sizes before tmux 3.3 (#115)

  /// tmux 3.2a answers `refresh-client -C @W:CxR` with `bad size argument`. `resize-window` sizes
  /// one window there, current or not, and leaves it at `window-size manual` until it is unset.
  @Test("before 3.3 a window is sized with resize-window before the paint, and handed back unset")
  func sizesBefore33() async throws {
    let host = Host()
    host.stream.refuseWindowSizes()
    let bridge = try await host.attacher.open(terminalID: "tmux:%3", size: Self.phone)
    let opened = host.stream.lines
    #expect(opened.first == Self.firstSizing("@1", "60x20"), "the 3.3 line, refused")
    #expect(opened.dropFirst().first == Self.resize("@1", 60, 20), "sized before the paint")
    #expect(opened.dropFirst(2).first?.hasPrefix("display-message -p -t %3 ") == true)
    #expect(host.stream.size(of: "@1") == "60x20")
    #expect(host.stream.isSizedByHand("@1"))

    try await bridge.resize(to: TerminalSize(columns: 40, rows: 30, pixelWidth: 0, pixelHeight: 0))
    #expect(host.stream.lines.last == Self.resize("@1", 40, 30))
    #expect(host.stream.size(of: "@1") == "40x30")

    await bridge.release()
    #expect(host.stream.lines.last == Self.handBackBefore33("@1"))
    #expect(host.stream.size(of: "@1") == "150x43")
    #expect(!host.stream.isSizedByHand("@1"), "tmux sizes the window again")
    #expect(host.stream.lines.filter { $0.contains("refresh-client -C @") }.count == 1)
    #expect(host.stream.closeCount == 1)
  }

  @Test("before 3.3, two controllers on one window: the newest size holds, and both gone unsets it")
  func twoControllersBefore33() async throws {
    let host = Host(["%3": Host.shell(), "%4": Host.shell()])
    host.stream.refuseWindowSizes()
    let attacher = host.attacher
    let first = try await attacher.open(terminalID: "tmux:%3", size: Self.phone)
    let second = try await attacher.open(
      terminalID: "tmux:%4", size: TerminalSize(columns: 40, rows: 30, pixelWidth: 0, pixelHeight: 0))
    #expect(host.stream.lines.contains(Self.resize("@1", 40, 30)))
    #expect(host.stream.size(of: "@1") == "40x30")
    await second.release()
    #expect(host.stream.lines.last == Self.resize("@1", 60, 20), "the size still held goes back on")
    #expect(host.stream.size(of: "@1") == "60x20")
    #expect(host.stream.isSizedByHand("@1"))
    await first.release()
    #expect(host.stream.lines.last == Self.handBackBefore33("@1"))
    #expect(host.stream.size(of: "@1") == "150x43")
    #expect(!host.stream.isSizedByHand("@1"))
    #expect(host.stream.lines.filter { $0.contains("refresh-client -C @") }.count == 1)
  }

  /// Once tmux has refused one `@W:` size, every later window's first line reads its own size
  /// ahead of `resize-window`.
  @Test("before 3.3, a window sized after the first refusal is never asked with refresh-client")
  func anotherWindowBefore33() async throws {
    let host = Host(["%3": Host.shell(), "%4": Host.shell(window: "@2")])
    host.stream.refuseWindowSizes()
    let attacher = host.attacher
    let first = try await attacher.open(terminalID: "tmux:%3", size: Self.phone)
    let second = try await attacher.open(terminalID: "tmux:%4", size: Self.phone)
    #expect(
      host.stream.lines.contains(
        "display-message -p -t @2 '#{window_width}x#{window_height}' ; " + Self.resize("@2", 60, 20)))
    #expect(!host.stream.lines.contains { $0.contains("refresh-client -C @2") })
    #expect(host.stream.size(of: "@2") == "60x20")
    await second.release()
    #expect(host.stream.lines.last == Self.handBackBefore33("@2"))
    #expect(host.stream.size(of: "@2") == "150x43")
    #expect(!host.stream.isSizedByHand("@2"))
    await first.release()
    #expect(host.stream.size(of: "@1") == "150x43")
    #expect(!host.stream.isSizedByHand("@1"))
  }

  /// Both lines go out as 3.3's, and tmux refuses both. The window's own size comes from the
  /// first, and the newest size is the one that holds.
  @Test("before 3.3, two first sizes refused in flight still size the window and give it back")
  func twoSizingsInFlightBefore33() async throws {
    let host = Host(["%3": Host.shell(), "%4": Host.shell()])
    host.stream.refuseWindowSizes()
    let attacher = host.attacher
    host.stream.hold(linesContaining: "refresh-client -C @1:")
    async let first = attacher.open(terminalID: "tmux:%3", size: Self.phone)
    async let second = attacher.open(
      terminalID: "tmux:%4", size: TerminalSize(columns: 40, rows: 30, pixelWidth: 0, pixelHeight: 0))
    try await poll { host.stream.lines.filter { $0.contains("refresh-client -C @1:") }.count == 2 }
    let inFlight = host.stream.lines.filter { $0.contains("refresh-client -C @1:") }.count
    host.stream.resumeHeld()
    #expect(inFlight == 2, "both sizes were written before tmux answered either")
    let bridges = try await [first, second]
    // The two opens race, so the newest size is whichever line went second.
    let newest = host.stream.lines.last { $0.contains("refresh-client -C @1:") }?
      .components(separatedBy: "@1:").last
    #expect(newest == "60x20" || newest == "40x30")
    #expect(host.stream.size(of: "@1") == newest)
    for bridge in bridges { await bridge.release() }
    #expect(host.stream.size(of: "@1") == "150x43")
    #expect(!host.stream.isSizedByHand("@1"))
  }

  /// Only tmux before 3.3 answers `bad size argument`; any other refusal is about one size.
  @Test("a refusal other than bad size argument leaves sizing on")
  func otherRefusal() async throws {
    let host = Host()
    host.stream.refuseWindowSizes(with: "size too small or too big", times: 1)
    let bridge = try await host.attacher.open(terminalID: "tmux:%3", size: Self.phone)
    try await bridge.resize(to: TerminalSize(columns: 40, rows: 30, pixelWidth: 0, pixelHeight: 0))
    #expect(host.stream.lines.contains { $0.hasSuffix("refresh-client -C @1:40x30") })
    #expect(host.stream.size(of: "@1") == "40x30")
    await bridge.release()
  }

  @Test("an observer sizes nothing and paints no history; promoted, its first key sizes and repaints")
  func observerPromotion() async throws {
    let host = Host()
    let observer = try #require(
      try await host.attacher.observe(terminalID: "tmux:%3", size: Self.phone) as? any PromotableObserver)
    var output = observer.output.makeAsyncIterator()
    let first = try await read(&output, until: "H")
    #expect(first.hasPrefix("$ ls\r\n$ "))
    #expect(!host.stream.lines.contains { $0.hasPrefix("refresh-client") })

    let bridge = try await observer.promote()
    #expect(!host.stream.lines.contains { $0.hasPrefix("refresh-client") }, "not until touched")
    try await bridge.send(text: "y")
    let repaint = try await read(&output, until: "H")
    #expect(repaint.hasPrefix("\u{1B}[?1047l\u{1B}[H\u{1B}[2J\u{1B}[3Jold one"))
    // A command the fake answers after the key proves the key line has been read.
    try await bridge.resize(to: TerminalSize(columns: 61, rows: 20, pixelWidth: 0, pixelHeight: 0))
    let sized = try #require(host.stream.lines.firstIndex(of: Self.firstSizing("@1", "60x20")))
    let typed = try #require(host.stream.lines.firstIndex { $0.hasPrefix("send-keys") })
    #expect(sized < typed)
    await bridge.release()
  }

  /// The observer's paint left the emulator on the alternate screen. A repaint that cleared there
  /// would put the history and the normal screen into the alternate buffer, where they are lost
  /// when the program leaves it.
  @Test("a promoted observer on the alternate screen leaves it before it repaints")
  func promotionOnTheAlternateScreen() async throws {
    var pane = Host.shell()
    pane.state.alternateScreen = true
    pane.normal = ["$ claude", ""]
    pane.screen = ["CLAUDE", "> "]
    let host = Host(["%3": pane])
    let observer = try #require(
      try await host.attacher.observe(terminalID: "tmux:%3", size: Self.phone) as? any PromotableObserver)
    var output = observer.output.makeAsyncIterator()
    let first = try await read(&output, until: "CLAUDE")
    #expect(first.contains("\u{1B}[?1049h"), "the observer's paint is on the alternate screen")

    let bridge = try await observer.promote()
    try await bridge.send(text: "y")
    let repaint = try await read(&output, until: "CLAUDE")
    #expect(repaint.hasPrefix("\u{1B}[?1047l\u{1B}[H\u{1B}[2J\u{1B}[3Jold one"))
    let entering = try #require(repaint.range(of: "\u{1B}[?1049h"))
    #expect(repaint[..<entering.lowerBound].contains("$ claude"), "the normal screen comes first")
    await bridge.release()
  }

  /// A release that waits for tmux's answer holds the scene, which awaits it, for good.
  @Test("release gives up on a tmux that does not answer, and closes the channel")
  func releaseOnASilentLink() async throws {
    let host = Host(["%3": Host.shell(), "%4": Host.shell()])
    let attacher = host.attacher
    let bridge = try await attacher.open(terminalID: "tmux:%3", size: Self.phone)
    let other = try await attacher.observe(terminalID: "tmux:%4", size: Self.phone)
    host.stream.goSilent()

    #expect(await finishes(within: .seconds(5)) { await bridge.release() })
    #expect(host.stream.lines.last == Self.handBack("@1"), "the window was asked back")
    #expect(await finishes(within: .seconds(5)) { await other.release() })
    #expect(host.stream.closeCount == 1, "the channel closes even though tmux never answered")
  }

  /// The listing after the stream ends goes over a fresh exec channel, which can hang as well.
  @Test("a stream end whose listing never answers is .streamEnded, in time")
  func streamEndWithASilentListing() async throws {
    let host = Host()
    host.listingHangs = true
    let bridge = try await host.attacher.open(terminalID: "tmux:%3", size: Self.phone)
    let output = bridge.output
    host.stream.emit("%exit\n")
    host.stream.finish()
    final class Ending: @unchecked Sendable {
      let lock = NSLock()
      var error: (any Error)?
    }
    let ending = Ending()
    let ended = await finishes(within: .seconds(10)) {
      do {
        for try await _ in output {}
      } catch {
        ending.lock.withLock { ending.error = error }
      }
    }
    #expect(ended)
    #expect(ending.lock.withLock { ending.error } as? TerminalCloseReason == .streamEnded)
  }

  @Test("two panes in one session share one client, which closes with the last")
  func sharedClient() async throws {
    let host = Host(["%3": Host.shell(), "%4": Host.shell()])
    let attacher = host.attacher
    let first = try await attacher.open(terminalID: "tmux:%3", size: Self.phone)
    let second = try await attacher.observe(terminalID: "tmux:%4", size: Self.phone)
    #expect(host.opened.count == 1)
    #expect(attacher.clientCount == 1)
    await first.release()
    #expect(host.stream.closeCount == 0)
    await second.release()
    #expect(host.stream.closeCount == 1)
    #expect(attacher.clientCount == 0)
  }

  @Test("a pane that leaves its layout and is gone finishes cleanly")
  func paneClosed() async throws {
    let host = Host()
    let bridge = try await host.attacher.open(terminalID: "tmux:%3", size: Self.phone)
    var output = bridge.output.makeAsyncIterator()
    _ = try await read(&output, until: "H")
    host.stream.setPane("%3", nil)
    host.stream.emit("%layout-change @1 b25d,60x20,0,0,4 b25d,60x20,0,0,4 *\n")
    while try await output.next() != nil {}
    await bridge.release()
  }

  @Test("a pane that moved to another window is followed, not closed")
  func paneMoved() async throws {
    let host = Host()
    let bridge = try await host.attacher.open(terminalID: "tmux:%3", size: Self.phone)
    host.stream.setPane("%3", Host.shell(window: "@7"))
    host.stream.emit("%window-close @1\n")
    // The move hands the old window back and sizes the new one, with nobody touching anything.
    try await poll { host.stream.lines.contains(Self.firstSizing("@7", "60x20")) }
    let handedBack = try #require(host.stream.lines.firstIndex(of: Self.handBack("@1")))
    let sized = try #require(host.stream.lines.firstIndex(of: Self.firstSizing("@7", "60x20")))
    #expect(handedBack < sized)
    #expect(host.stream.size(of: "@1") == "150x43")
    try await bridge.resize(to: TerminalSize(columns: 41, rows: 30, pixelWidth: 0, pixelHeight: 0))
    #expect(host.stream.lines.contains("refresh-client -C @7:41x30"))
    host.stream.emit(FakeTmuxControlStream.output("%3", "STILL HERE"))
    var output = bridge.output.makeAsyncIterator()
    _ = try await read(&output, until: "STILL HERE")
    await bridge.release()
  }

  @Test("the stream ending with the pane still listed is .streamEnded, which the scene reattaches")
  func streamEnded() async throws {
    let host = Host()
    let bridge = try await host.attacher.open(terminalID: "tmux:%3", size: Self.phone)
    var output = bridge.output.makeAsyncIterator()
    _ = try await read(&output, until: "H")
    host.stream.emit("%exit\n")
    host.stream.finish()
    await #expect(throws: TerminalCloseReason.streamEnded) {
      while try await output.next() != nil {}
    }
    #expect(host.cliCommands.last == "'tmux' -u list-panes -a -F '#{pane_id}'")
  }

  @Test("the stream ending with the pane gone from the server is a clean close")
  func sessionGone() async throws {
    let host = Host()
    let bridge = try await host.attacher.open(terminalID: "tmux:%3", size: Self.phone)
    var output = bridge.output.makeAsyncIterator()
    _ = try await read(&output, until: "H")
    host.lock.withLock { host.livingPanes = "%9\n" }
    host.stream.emit("%exit\n")
    host.stream.finish()
    while try await output.next() != nil {}
  }

  @Test("a pane that is gone at open is an error a person can read")
  func goneAtOpen() async throws {
    let host = Host([:])
    await #expect(throws: AppError.self) {
      _ = try await host.attacher.open(terminalID: "tmux:%3", size: Self.phone)
    }
    await #expect(throws: AppError.self) {
      _ = try await host.attacher.open(terminalID: "w1:p1", size: Self.phone)
    }
  }

  // MARK: Window sizes (#116)

  /// With a desk attached, `@W:` alone leaves a window it is not viewing at the phone's size
  /// (measured on 3.7c), and the fake keeps it there too.
  @Test("release gives the window back at the size it had before the phone sized it")
  func earlierSizeComesBack() async throws {
    let host = Host()
    let bridge = try await host.attacher.open(terminalID: "tmux:%3", size: Self.phone)
    #expect(host.stream.size(of: "@1") == "60x20")
    await bridge.release()
    #expect(host.stream.size(of: "@1") == "150x43")
  }

  @Test("two controllers on one window: the newest size holds, and both gone leaves the first size")
  func twoControllers() async throws {
    let host = Host(["%3": Host.shell(), "%4": Host.shell()])
    let attacher = host.attacher
    let first = try await attacher.open(terminalID: "tmux:%3", size: Self.phone)
    let second = try await attacher.open(
      terminalID: "tmux:%4", size: TerminalSize(columns: 40, rows: 30, pixelWidth: 0, pixelHeight: 0))
    #expect(host.stream.size(of: "@1") == "40x30")
    await second.release()
    #expect(host.stream.size(of: "@1") == "60x20", "the size still on screen goes back on")
    await first.release()
    #expect(host.stream.size(of: "@1") == "150x43")
  }

  /// The last holder's hand-back and a new viewer's first size, decided one after the other.
  /// Written in the other order, the new viewer would read the phone's size as the window's own,
  /// and the hand-back's trailing `@W:` would drop the new size.
  @Test("a new first size decided after the last hand-back is written after it")
  func handBackThenFirstSize() async throws {
    let host = Host(["%3": Host.shell(), "%4": Host.shell()])
    let attacher = host.attacher
    let leaving = try #require(
      try await attacher.open(terminalID: "tmux:%3", size: Self.phone) as? TmuxAttachment)
    let arriving = try #require(
      try await attacher.observe(terminalID: "tmux:%4", size: Self.phone) as? TmuxAttachment)
    let client = leaving.client
    let size = TerminalSize(columns: 40, rows: 30, pixelWidth: 0, pixelHeight: 0)
    final class Once: @unchecked Sendable {
      let lock = NSLock()
      var fired = false
    }
    let once = Once()
    client.afterSizingDecision = {
      guard once.lock.withLock({ defer { once.fired = true }; return !once.fired }) else { return }
      client.startSizing("@1", to: size, for: arriving) {}
    }
    await leaving.release()
    try await poll { host.stream.lines.contains { $0.hasSuffix("refresh-client -C @1:40x30") } }
    // A command after both proves the fake has run them.
    try await arriving.resize(to: Self.phone)
    let first = try #require(host.stream.lines.firstIndex(of: Self.firstSizing("@1", "40x30")))
    let handBack = try #require(host.stream.lines.firstIndex(of: Self.handBack("@1")))
    #expect(handBack < first)
    #expect(host.stream.size(of: "@1") == "40x30")
    client.afterSizingDecision = nil
    await arriving.release()
    #expect(host.stream.size(of: "@1") == "150x43")
  }

  /// A refusal that is not `bad size argument` still ran the line's `display-message`, so the
  /// window's own size is known, and another viewer holding it gives it back at that size.
  @Test("a first size refused while another viewer holds the window keeps the window's own size")
  func refusedFirstSizeKeepsTheOwnSize() async throws {
    let host = Host(["%3": Host.shell(), "%4": Host.shell()])
    let attacher = host.attacher
    host.stream.hold(linesContaining: "refresh-client -C @1:")
    host.stream.refuseWindowSizes(with: "size too small or too big", times: 1)
    async let refused = attacher.open(terminalID: "tmux:%3", size: Self.phone)
    try await poll { host.stream.lines.contains(Self.firstSizing("@1", "60x20")) }
    async let holding = attacher.open(
      terminalID: "tmux:%4", size: TerminalSize(columns: 40, rows: 30, pixelWidth: 0, pixelHeight: 0))
    try await poll { host.stream.lines.contains("refresh-client -C @1:40x30") }
    let inFlight = host.stream.lines.contains("refresh-client -C @1:40x30")
    host.stream.resumeHeld()
    #expect(inFlight, "the second size was written before tmux answered the first")
    let (first, second) = try await (refused, holding)
    #expect(host.stream.size(of: "@1") == "40x30")
    await second.release()
    #expect(host.stream.lines.last == Self.handBack("@1"))
    #expect(host.stream.size(of: "@1") == "150x43")
    await first.release()
  }

  /// The size a window had is read once, ahead of every size, even when two controllers size it
  /// before tmux has answered either.
  @Test("two first sizings in flight at once still give the window back at its own size")
  func twoSizingsInFlight() async throws {
    let host = Host(["%3": Host.shell(), "%4": Host.shell()])
    let attacher = host.attacher
    host.stream.hold(linesContaining: "refresh-client -C @1:")
    async let first = attacher.open(terminalID: "tmux:%3", size: Self.phone)
    async let second = attacher.open(
      terminalID: "tmux:%4", size: TerminalSize(columns: 40, rows: 30, pixelWidth: 0, pixelHeight: 0))
    try await poll { host.stream.lines.filter { $0.contains("refresh-client -C @1:") }.count == 2 }
    let inFlight = host.stream.lines.filter { $0.contains("refresh-client -C @1:") }.count
    host.stream.resumeHeld()
    #expect(inFlight == 2, "both sizes were written before tmux answered either")
    let bridges = try await [first, second]
    for bridge in bridges { await bridge.release() }
    #expect(host.stream.size(of: "@1") == "150x43")
  }

  /// The race in a move: the new window's size is on its way when the viewer is released. An
  /// observer keeps the client open, so the answer still arrives.
  @Test("a release while the new window's size is on its way still hands that window back")
  func releaseBeforeTheSizeAnswers() async throws {
    let host = Host(["%3": Host.shell(), "%4": Host.shell()])
    let attacher = host.attacher
    let bridge = try await attacher.open(terminalID: "tmux:%3", size: Self.phone)
    let observer = try await attacher.observe(terminalID: "tmux:%4", size: Self.phone)
    host.stream.hold(linesContaining: "refresh-client -C @7:")
    host.stream.setPane("%3", Host.shell(window: "@7"))
    host.stream.emit("%layout-change @1 b25d,60x20,0,0,4 b25d,60x20,0,0,4 *\n")
    try await poll { host.stream.lines.contains { $0.contains("refresh-client -C @7:") } }
    await bridge.release()
    host.stream.resumeHeld()
    try await poll { host.stream.lines.contains(Self.handBack("@7")) }
    #expect(host.stream.lines.contains { $0.hasSuffix("refresh-client -C @7:60x20") })
    #expect(host.stream.size(of: "@7") == "150x43")
    await observer.release()
  }

  // MARK: Sessions (#117)

  /// Measured on 3.2a and 3.7c: after `move-pane`, `join-pane` or `break-pane -t B:`, the old
  /// session's client hears `%layout-change` and then nothing from the pane. Moving a session's
  /// last pane also ends that client with `%exit`, right behind the change.
  @Test("a pane moved to another session is followed there, and keeps its output")
  func movedToAnotherSession() async throws {
    var moved = Host.shell(window: "@7")
    moved.session = "$1"
    moved.screen = ["$ moved", "$ "]
    let host = Host()
    let other = FakeTmuxControlStream(panes: ["%3": moved], session: "$1")
    host.sessions["$1"] = other
    // Held, as `TmuxControl` holds it: a client finds the other session's client through it.
    let attacher = host.attacher
    let bridge = try await attacher.open(terminalID: "tmux:%3", size: Self.phone)
    var output = bridge.output.makeAsyncIterator()
    _ = try await read(&output, until: "H")

    host.places["%3"] = "$1 @7 100x30"
    host.stream.setPane("%3", moved)
    host.stream.emit("%layout-change @1 b25d,60x20,0,0,9 b25d,60x20,0,0,9 *\n")
    // The answer is out once the old window is asked back. Then the old session's client ends.
    try await poll { host.stream.lines.contains { $0.hasPrefix("refresh-client -C @1:") } }
    host.stream.emit("%exit\n")
    host.stream.finish()

    try await poll { other.lines.contains { $0.contains("capture-pane") } }
    other.emit(FakeTmuxControlStream.output("%3", "STILL HERE"))
    final class Seen: @unchecked Sendable {
      let lock = NSLock()
      var text = ""
      var error: (any Error)?
    }
    let seen = Seen()
    let output2 = bridge.output
    let arrived = await finishes(within: .seconds(5)) {
      do {
        for try await chunk in output2 {
          let done = seen.lock.withLock {
            seen.text += String(decoding: chunk, as: UTF8.self)
            return seen.text.contains("STILL HERE")
          }
          if done { return }
        }
      } catch {
        seen.lock.withLock { seen.error = error }
      }
    }
    #expect(arrived)
    #expect(seen.lock.withLock { seen.error } == nil)
    let text = seen.lock.withLock { seen.text }
    #expect(text.contains("\u{1B}[2J\u{1B}[3J"), "the screen is painted again, cleared first")
    #expect(text.contains("$ moved"))
    #expect(host.opened.last?.contains("attach-session -t '$1'") == true)
    #expect(other.lines.contains(Self.firstSizing("@7", "60x20")))
    #expect(host.stream.size(of: "@1") == "150x43")
    await bridge.release()
    #expect(other.lines.last == Self.handBack("@7"))
    #expect(other.closeCount == 1)
  }

  // MARK: FirstAnswer (#117)

  @Test("an early answer cancels the deadline's sleeper")
  func sleeperCancelled() async {
    let (ended, ending) = AsyncStream.makeStream(of: Void.self)
    let value = await FirstAnswer.within(
      .seconds(3600), otherwise: false,
      sleep: { limit in
        do {
          try await Task.sleep(for: limit)
        } catch {
          ending.yield()
          throw error
        }
      }
    ) { $0.resume(true) }
    #expect(value)
    #expect(await finishes(within: .seconds(5)) { for await _ in ended { return } })
  }

  @Test("a place line reads the session, the window and the current window's size")
  func place() {
    #expect(
      TmuxAttacher.place(from: "$0 @1 150x43\n")
        == TmuxAttacher.Place(session: "$0", window: "@1", currentWindowSize: "150x43"))
    #expect(
      TmuxAttacher.place(from: "$2 @5 \n")
        == TmuxAttacher.Place(session: "$2", window: "@5", currentWindowSize: nil))
    #expect(TmuxAttacher.place(from: "nonsense") == nil)
    #expect(TmuxAttacher.place(from: "$2 @5 5xx5\n")?.currentWindowSize == nil)
    #expect(TmuxAttacher.place(from: "$2 @5 x5\n")?.currentWindowSize == nil)
  }
}
