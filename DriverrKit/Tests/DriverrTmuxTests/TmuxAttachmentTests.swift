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
            return CommandResult(standardOutput: "$0 @1 150x43\n", standardError: "", exitStatus: 0)
          }
          if lock.withLock({ listingHangs }) { try await Task.sleep(for: .seconds(3600)) }
          return CommandResult(
            standardOutput: lock.withLock { livingPanes }, standardError: "", exitStatus: 0)
        },
        open: { [self] command in
          lock.withLock { opened.append(command) }
          return stream
        },
        resizesWindow: { [self] in lock.withLock { resizes } })
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
    #expect(host.opened == ["'tmux' -u -C attach-session -t '$0' \\; refresh-client -C 150x43"])
    #expect(host.cliCommands.first?.contains("display-message -p -t '%3'") == true)
    await bridge.release()
  }

  @Test("a controller sizes its window before the paint, and the paint has history and the cursor")
  func controllerPaint() async throws {
    let host = Host()
    let bridge = try await host.attacher.open(terminalID: "tmux:%3", size: Self.phone)
    #expect(host.stream.lines.first == "refresh-client -C @1:60x20")
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
    #expect(host.stream.lines.last == "refresh-client -C @1:")
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

  @Test("a tmux that refuses window sizes, as one before 3.3 does, still opens and stops asking")
  func noWindowSizes() async throws {
    let host = Host()
    host.stream.refuseWindowSizes()
    let bridge = try await host.attacher.open(terminalID: "tmux:%3", size: Self.phone)
    var output = bridge.output.makeAsyncIterator()
    _ = try await read(&output, until: "H")
    try await bridge.resize(to: TerminalSize(columns: 40, rows: 30, pixelWidth: 0, pixelHeight: 0))
    await bridge.release()
    #expect(host.stream.lines.filter { $0.hasPrefix("refresh-client") } == ["refresh-client -C @1:60x20"])
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
    let sized = try #require(host.stream.lines.firstIndex(of: "refresh-client -C @1:60x20"))
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
    #expect(host.stream.lines.last == "refresh-client -C @1:", "the window was asked back")
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
    // The check is written; the next command's reply comes after its answer.
    while !host.stream.lines.contains(where: { $0.hasSuffix("'#{pane_id} #{window_id}'") }) {
      try await Task.sleep(for: .milliseconds(5))
    }
    // The move hands the old window back and sizes the new one, with nobody touching anything.
    let deadline = ContinuousClock.now + .seconds(5)
    while !host.stream.lines.contains("refresh-client -C @7:60x20"), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    let handedBack = try #require(host.stream.lines.firstIndex(of: "refresh-client -C @1:"))
    let sized = try #require(host.stream.lines.firstIndex(of: "refresh-client -C @7:60x20"))
    #expect(handedBack < sized)
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

  @Test("a place line reads the session, the window and the current window's size")
  func place() {
    #expect(
      TmuxAttacher.place(from: "$0 @1 150x43\n")
        == TmuxAttacher.Place(session: "$0", window: "@1", currentWindowSize: "150x43"))
    #expect(
      TmuxAttacher.place(from: "$2 @5 \n")
        == TmuxAttacher.Place(session: "$2", window: "@5", currentWindowSize: nil))
    #expect(TmuxAttacher.place(from: "nonsense") == nil)
  }
}
