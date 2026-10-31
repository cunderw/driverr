import DriverrCore
import Foundation
import Observation
import SwiftTerm
import Testing

@testable import DriverrTerm

/// A `TerminalFeed` whose far side is this test. Not `FakeSSHTransport`, because
/// `DriverrTerm` must not depend on `DriverrSSH`.
private final class TestFeed {
  /// What the closures capture, held in a `let` so they are `@Sendable` without an escape
  /// hatch.
  final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [Data] = []
    private var _sizes: [TerminalSize] = []
    private var _scrolls: [(ScrollDirection, Int)] = []
    private var _clicks: [TerminalCell] = []
    private var _closed = false
    private var _focuses: [Bool] = []
    private var _consumed: [Int] = []
    private var _leftAlternateScreen = 0

    var focuses: [Bool] { lock.withLock { _focuses } }
    var consumed: [Int] { lock.withLock { _consumed } }
    var leftAlternateScreen: Int { lock.withLock { _leftAlternateScreen } }
    var sent: [Data] { lock.withLock { _sent } }
    var sizes: [TerminalSize] { lock.withLock { _sizes } }
    var scrolls: [(ScrollDirection, Int)] { lock.withLock { _scrolls } }
    var clicks: [TerminalCell] { lock.withLock { _clicks } }
    var closed: Bool { lock.withLock { _closed } }

    // Each of these wakes a `waitUntil`. Recording happens on the session's threads, so the
    // signal hops to the main actor.
    func record(sent data: Data) {
      lock.withLock { _sent.append(data) }
      Waker.signalFromAnywhere()
    }
    func record(size: TerminalSize) {
      lock.withLock { _sizes.append(size) }
      Waker.signalFromAnywhere()
    }
    func record(scroll: ScrollDirection, lines: Int) {
      lock.withLock { _scrolls.append((scroll, lines)) }
      Waker.signalFromAnywhere()
    }
    func record(click: TerminalCell) {
      lock.withLock { _clicks.append(click) }
      Waker.signalFromAnywhere()
    }
    func recordClose() {
      lock.withLock { _closed = true }
      Waker.signalFromAnywhere()
    }
    func record(focus: Bool) {
      lock.withLock { _focuses.append(focus) }
      Waker.signalFromAnywhere()
    }
    func record(consumed: Int) {
      lock.withLock { _consumed.append(consumed) }
      Waker.signalFromAnywhere()
    }
    func recordLeftAlternateScreen() {
      lock.withLock { _leftAlternateScreen += 1 }
      Waker.signalFromAnywhere()
    }
  }

  let feed: TerminalFeed
  let recorder = Recorder()
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

  var sent: [Data] { recorder.sent }
  var sizes: [TerminalSize] { recorder.sizes }
  var scrolls: [(ScrollDirection, Int)] { recorder.scrolls }
  var clicks: [TerminalCell] { recorder.clicks }
  var closed: Bool { recorder.closed }
  var focuses: [Bool] { recorder.focuses }
  var consumed: [Int] { recorder.consumed }
  var leftAlternateScreen: Int { recorder.leftAlternateScreen }
  var sentText: String { String(decoding: sent.reduce(Data(), +), as: UTF8.self) }

  /// - Parameter scrollable: stand in for a herdr pane. A pty has no `scroll` or `click`
  ///   closure, which is what `scrollsRemotely` reads.
  /// - Parameter raw: stand in for a herdr-core terminal, which also takes focus and consumed
  ///   bytes.
  init(scrollable: Bool = false, raw: Bool = false) {
    let (stream, continuation) = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self
    )
    self.continuation = continuation
    let recorder = recorder
    feed = TerminalFeed(
      output: stream,
      send: { recorder.record(sent: $0) },
      resize: { recorder.record(size: $0) },
      close: { recorder.recordClose() },
      scroll: scrollable
        ? { @Sendable in recorder.record(scroll: $0, lines: $1) }
        : nil,
      // `async`, as herdr's bridge is. A synchronous closure converted to async runs without a
      // hop, which hid a reorder between clicks.
      click: scrollable ? { @Sendable cell async in recorder.record(click: cell) } : nil,
      focus: raw ? { @Sendable gained async in recorder.record(focus: gained) } : nil,
      consumed: raw ? { @Sendable in recorder.record(consumed: $0) } : nil,
      leftAlternateScreen: raw ? { @Sendable in recorder.recordLeftAlternateScreen() } : nil,
      awaitsFirstSize: raw
    )
  }

  func emit(_ text: String) { continuation.yield(Data(text.utf8)) }
  func finish() { continuation.finish() }
  func fail(_ error: any Error) { continuation.finish(throwing: error) }
}

/// The emulator, headless.
private final class HeadlessRenderer {
  let terminal: Terminal
  /// `Terminal` holds its delegate weakly, so the renderer keeps it alive.
  private let delegate = NullDelegate()

  init(columns: Int = 80, rows: Int = 24) {
    terminal = Terminal(
      delegate: delegate,
      options: TerminalOptions(cols: columns, rows: rows)
    )
  }

  func feed(_ bytes: ArraySlice<UInt8>) {
    terminal.feed(buffer: bytes)
    // No observation covers SwiftTerm's grid, so this wakes every `renderer.screen` wait.
    Waker.signalFromAnywhere()
  }

  var screen: String {
    (0..<terminal.rows)
      .compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  final class NullDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
  }
}

/// Wakes a waiter when something it watches has moved, in place of a clock.
///
/// A generation counter, so a signal between reading the generation and parking is not
/// lost. It is shared by the whole file: parallel tests only add spurious wake-ups, which
/// cost a cheap re-check, and a missed wake-up is the failure that matters.
@MainActor
private final class Waker {
  static let shared = Waker()

  private(set) var generation = 0
  private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var nextID = 0

  nonisolated static func signalFromAnywhere() {
    Task { @MainActor in Waker.shared.signal() }
  }

  func signal() {
    generation += 1
    let resuming = waiters
    waiters.removeAll()
    for waiter in resuming { waiter.continuation.resume() }
  }

  func next(after seen: Int) async {
    guard generation == seen else { return }
    let id = nextID
    nextID += 1
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        // Cancelled before parking: resume now, or nothing ever will.
        if Task.isCancelled {
          continuation.resume()
        } else {
          waiters.append((id, continuation))
        }
      }
    } onCancel: {
      Task { @MainActor in Waker.shared.cancel(id) }
    }
  }

  private func cancel(_ id: Int) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    waiters.remove(at: index).continuation.resume()
  }
}

/// Waits for the session to have done something, woken by the thing that does it. A
/// wall-clock poll that expired silently let tests assert against a half-finished session
/// on a loaded machine.
///
/// Three sources cover every condition here:
///
/// - `TestFeed.Recorder`, for anything the far side was told.
/// - `HeadlessRenderer.feed`, for the emulator's grid.
/// - `withObservationTracking` around the predicate, for `TerminalSession`'s own
///   observable properties.
///
/// A condition that never becomes true fails at the suite's `.timeLimit`. The limit cancels
/// the task, `Waker.next` then returns at once, and the `Task.isCancelled` check is what ends
/// the loop; without it the wait spins on the main actor and the run hangs with no tally. For
/// a claim that something must not happen, use `allowTimeFor`.
@MainActor
private func waitUntil(
  sourceLocation: SourceLocation = #_sourceLocation,
  _ condition: @MainActor () -> Bool
) async {
  while true {
    let seen = Waker.shared.generation
    var satisfied = false
    withObservationTracking {
      satisfied = condition()
    } onChange: {
      Waker.signalFromAnywhere()
    }
    if satisfied { return }
    await Waker.shared.next(after: seen)
    if Task.isCancelled {
      Issue.record(
        "waitUntil was cancelled before its condition held",
        sourceLocation: sourceLocation
      )
      return
    }
  }
}

/// Gives something that must not happen its chance to, and expires on purpose. Here a wall
/// clock is right: expiry is the pass, so a slow machine holds rather than fails.
///
/// `laterResizesKeepTheShortWindow` is the exception: it asserts a resize did arrive within
/// 100 ms of a 300 ms settling window. That window is the assertion, and no event means
/// "no later one arrived in time", so it stays a timing claim.
@MainActor
private func allowTimeFor(
  _ condition: @MainActor () -> Bool,
  upTo window: Duration
) async {
  let deadline = ContinuousClock.now + window
  while ContinuousClock.now < deadline {
    if condition() { return }
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(1))
  }
}

@MainActor
@Suite("TerminalSession scroll pacing", .timeLimit(.minutes(1)))
struct TerminalSessionScrollTests {
  /// A pane feed whose scrolls never get a frame back, so the pacing gate stays shut.
  private func paneSession(
    timeout: Duration = .seconds(30)
  ) -> (TestFeed, TerminalSession) {
    let feed = TestFeed(scrollable: true)
    let session = TerminalSession(feed: feed.feed, scrollPacingTimeout: timeout)
    session.start()
    return (feed, session)
  }

  @Test("a drag's rows ride in one command instead of one command per row")
  func coalescesRowsWhileAFrameIsOutstanding() async {
    // herdr answers a scroll with a full-screen repaint of about 2.6 KB however many rows moved.
    // Sixty one-row commands cost about ten times six ten-row ones, parsed on the main thread.
    let (feed, session) = paneSession()
    let renderer = HeadlessRenderer()
    session.attach { renderer.feed($0) }

    for _ in 0..<10 { session.scroll(.up, lines: 1) }
    await waitUntil { !feed.scrolls.isEmpty }

    #expect(feed.scrolls.count == 1, "only the first row should have gone out on its own")
    #expect(feed.scrolls.first?.1 == 1)

    // The first command's frame lands; the nine banked rows go as one.
    feed.emit("frame")
    await waitUntil { feed.scrolls.count == 2 }
    #expect(feed.scrolls.count == 2)
    #expect(feed.scrolls.last?.0 == .up)
    #expect(feed.scrolls.last?.1 == 9)
  }

  @Test("the whole drag still arrives — coalescing moves rows, it does not drop them")
  func preservesTotalTravel() async {
    let (feed, session) = paneSession()
    session.attach { _ in }

    for _ in 0..<25 { session.scroll(.up, lines: 1) }
    await waitUntil { !feed.scrolls.isEmpty }
    feed.emit("frame")
    await waitUntil { feed.scrolls.count == 2 }

    let travelled = feed.scrolls.reduce(0) { $0 + ($1.0 == .up ? $1.1 : -$1.1) }
    #expect(travelled == 25)
  }

  @Test("reversing mid-drag cancels rather than sending both directions")
  func nettsOpposingDirections() async {
    let (feed, session) = paneSession()
    session.attach { _ in }

    session.scroll(.up, lines: 1)  // goes out immediately, opening the gate
    await waitUntil { !feed.scrolls.isEmpty }

    session.scroll(.up, lines: 8)
    session.scroll(.down, lines: 3)
    feed.emit("frame")
    await waitUntil { feed.scrolls.count == 2 }

    #expect(feed.scrolls.last?.0 == .up)
    #expect(feed.scrolls.last?.1 == 5, "8 up then 3 down is 5 up, not two commands")
  }

  @Test("a drag that ends where it began sends nothing more")
  func sendsNothingForNetZero() async {
    let (feed, session) = paneSession()
    session.attach { _ in }

    session.scroll(.up, lines: 1)
    await waitUntil { !feed.scrolls.isEmpty }

    session.scroll(.up, lines: 6)
    session.scroll(.down, lines: 6)
    feed.emit("frame")
    // Give a second command every chance to appear.
    try? await Task.sleep(for: .milliseconds(50))
    #expect(feed.scrolls.count == 1)
  }

  @Test("a scroll nobody answers does not wedge scrolling forever")
  func recoversWhenNoFrameComesBack() async {
    // At either end of the scrollback herdr sends no frame. Pacing on frames alone would shut
    // the gate for good.
    let (feed, session) = paneSession(timeout: .milliseconds(20))
    session.attach { _ in }

    session.scroll(.up, lines: 1)
    await waitUntil { !feed.scrolls.isEmpty }

    session.scroll(.up, lines: 4)
    await waitUntil { feed.scrolls.count == 2 }
    #expect(feed.scrolls.count == 2, "the timeout should have reopened the gate")
    #expect(feed.scrolls.last?.1 == 4)
  }

  @Test("a pty ignores scrolling entirely — its history is already on this side")
  func ptyDoesNotScrollRemotely() async {
    let feed = TestFeed()
    let session = TerminalSession(feed: feed.feed)
    session.start()
    session.attach { _ in }

    #expect(!session.scrollsRemotely)
    session.scroll(.up, lines: 5)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(feed.scrolls.isEmpty)
  }

  @Test("a closed session stops scrolling")
  func doesNotScrollAfterClose() async {
    let (feed, session) = paneSession()
    session.attach { _ in }
    session.close()

    session.scroll(.up, lines: 3)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(feed.scrolls.isEmpty)
  }
}

@MainActor
@Suite("TerminalSession", .timeLimit(.minutes(1)))
struct TerminalSessionTests {
  @Test("renders bytes from the feed into the emulator")
  func rendersFeedOutput() async {
    let feed = TestFeed()
    let renderer = HeadlessRenderer()
    let session = TerminalSession(feed: feed.feed)
    session.attach { renderer.feed($0) }
    session.start()

    feed.emit("hello from the far side")
    await waitUntil { renderer.screen == "hello from the far side" }

    #expect(renderer.screen == "hello from the far side")
    #expect(session.state == .running)
  }

  @Test("output that arrives before a renderer attaches is not lost")
  func buffersOutputUntilAttached() async {
    let feed = TestFeed()
    let session = TerminalSession(feed: feed.feed)
    session.start()
    feed.emit("prompt$ ")
    await waitUntil { session.bufferedByteCount > 0 }
    #expect(session.bufferedByteCount == 8)

    let renderer = HeadlessRenderer()
    session.attach { renderer.feed($0) }

    #expect(renderer.screen == "prompt$")
    #expect(session.bufferedByteCount == 0)
  }

  @Test("typed input reaches the far side")
  func sendsInput() async {
    let feed = TestFeed()
    let session = TerminalSession(feed: feed.feed)
    session.start()

    session.send(text: "ls -la\r")
    await waitUntil { !feed.sentText.isEmpty }

    #expect(feed.sentText == "ls -la\r")
  }

  @Test("input sent before the pump starts still reaches the far side")
  func sendsBeforeStart() async {
    // The channel is open from construction and `start()` only governs output, so an attach
    // command written before the view exists must not be lost.
    let feed = TestFeed()
    let session = TerminalSession(feed: feed.feed)

    session.send(text: "herdr agent attach w1:p2\n")
    await waitUntil { !feed.sentText.isEmpty }

    #expect(feed.sentText == "herdr agent attach w1:p2\n")
  }

  @Test("input is dropped once the session is no longer running")
  func doesNotSendAfterClose() async {
    let feed = TestFeed()
    let session = TerminalSession(feed: feed.feed)
    session.start()
    session.close()
    await waitUntil { feed.closed }

    session.send(text: "too late")
    // Nothing to wait for, so allow time for the thing that must not happen.
    await allowTimeFor({ !feed.sentText.isEmpty }, upTo: .milliseconds(100))

    #expect(feed.sentText.isEmpty)
    #expect(session.state == .closed)
    #expect(feed.closed)
  }

  @Test("a resize reaches the far side")
  func resizeIsForwarded() async {
    let feed = TestFeed()
    let session = TerminalSession(
      feed: feed.feed,
      resizeCoalescingWindow: .milliseconds(5),
      openSettlingWindow: .milliseconds(5)
    )
    session.start()

    session.resize(to: TerminalSize(columns: 100, rows: 30))
    await waitUntil { !feed.sizes.isEmpty }

    #expect(feed.sizes == [TerminalSize(columns: 100, rows: 30)])
  }

  @Test("a repeat of the size already sent costs nothing")
  func repeatedSizeIsDropped() async {
    let feed = TestFeed()
    let session = TerminalSession(
      feed: feed.feed,
      resizeCoalescingWindow: .milliseconds(5),
      openSettlingWindow: .milliseconds(5)
    )
    session.start()

    session.resize(to: TerminalSize(columns: 100, rows: 30))
    await waitUntil { !feed.sizes.isEmpty }
    session.resize(to: TerminalSize(columns: 100, rows: 30))
    await allowTimeFor({ feed.sizes.count > 1 }, upTo: .milliseconds(100))

    #expect(feed.sizes.count == 1)
  }

  @Test("a burst of sizes collapses to the last one — one SIGWINCH, not thirty")
  func resizeBurstCoalesces() async {
    // A Split View drag is a stream of widths; forwarding each redraws a full-screen program
    // every frame.
    let feed = TestFeed()
    let session = TerminalSession(
      feed: feed.feed,
      resizeCoalescingWindow: .milliseconds(30),
      openSettlingWindow: .milliseconds(30)
    )
    session.start()

    for columns in 60...90 {
      session.resize(to: TerminalSize(columns: columns, rows: 30))
    }
    await waitUntil { !feed.sizes.isEmpty }
    await allowTimeFor({ feed.sizes.count > 1 }, upTo: .milliseconds(100))

    #expect(feed.sizes == [TerminalSize(columns: 90, rows: 30)])
  }

  @Test("the newest reported size is readable before it has been sent")
  func reportsTheLatestSizeImmediately() async {
    let feed = TestFeed()
    let session = TerminalSession(
      feed: feed.feed,
      resizeCoalescingWindow: .seconds(30),
      openSettlingWindow: .seconds(30)
    )
    session.start()

    session.resize(to: TerminalSize(columns: 111, rows: 22))

    // Nothing has gone out yet, but a re-attaching view must learn the size.
    #expect(feed.sizes.isEmpty)
    #expect(session.reportedSize == TerminalSize(columns: 111, rows: 22))
  }

  @Test("pixel dimensions survive the trip to the far side")
  func forwardsPixelDimensions() async {
    let feed = TestFeed()
    let session = TerminalSession(
      feed: feed.feed,
      resizeCoalescingWindow: .milliseconds(5),
      openSettlingWindow: .milliseconds(5)
    )
    session.start()

    session.resize(
      to: TerminalSize(columns: 80, rows: 24, pixelWidth: 1170, pixelHeight: 2532)
    )
    await waitUntil { !feed.sizes.isEmpty }

    #expect(feed.sizes.first?.pixelWidth == 1170)
    #expect(feed.sizes.first?.pixelHeight == 2532)
  }

  @Test("an open's two layout passes reach the far side once, not twice")
  func openSettlesBeforeTheFirstSIGWINCH() async {
    // Opening lays the grid out, then the keyboard rises with the accessory row: two passes
    // with an animation between. On a phone that was `50x18` then `50x22`, two SIGWINCHs and,
    // on a herdr pane, two reflows of the desk.
    let feed = TestFeed()
    let session = TerminalSession(
      feed: feed.feed,
      resizeCoalescingWindow: .milliseconds(5),
      openSettlingWindow: .milliseconds(200)
    )
    session.start()

    session.resize(to: TerminalSize(columns: 50, rows: 18))
    // Longer than the coalescing window, shorter than the settling one.
    try? await Task.sleep(for: .milliseconds(60))
    #expect(feed.sizes.isEmpty)
    session.resize(to: TerminalSize(columns: 50, rows: 22))

    await waitUntil { !feed.sizes.isEmpty }
    await allowTimeFor({ feed.sizes.count > 1 }, upTo: .milliseconds(120))

    #expect(feed.sizes == [TerminalSize(columns: 50, rows: 22)])
  }

  @Test("once the far side knows a size, a change is on the short window again")
  func laterResizesKeepTheShortWindow() async {
    // The settling window is for an open. A rotation is a change the user just made and must
    // land quickly.
    let feed = TestFeed()
    let session = TerminalSession(
      feed: feed.feed,
      resizeCoalescingWindow: .milliseconds(5),
      openSettlingWindow: .milliseconds(300)
    )
    session.start()
    session.resize(to: TerminalSize(columns: 50, rows: 22))
    await waitUntil { !feed.sizes.isEmpty }

    session.resize(to: TerminalSize(columns: 93, rows: 7))
    // A third of the settling window, and long enough not to race a loaded machine.
    await allowTimeFor({ feed.sizes.count > 1 }, upTo: .milliseconds(100))

    #expect(feed.sizes.last == TerminalSize(columns: 93, rows: 7))
  }

  @Test("a resize pending when the session closes is not sent afterwards")
  func closeCancelsAPendingResize() async {
    let feed = TestFeed()
    let session = TerminalSession(
      feed: feed.feed,
      resizeCoalescingWindow: .milliseconds(20),
      openSettlingWindow: .milliseconds(20)
    )
    session.start()

    session.resize(to: TerminalSize(columns: 100, rows: 30))
    session.close()
    await allowTimeFor({ !feed.sizes.isEmpty }, upTo: .milliseconds(150))

    #expect(feed.sizes.isEmpty)
  }

  @Test("a clean end of stream is closed, not failed")
  func cleanEndIsClosed() async {
    let feed = TestFeed()
    let session = TerminalSession(feed: feed.feed)
    session.start()

    feed.finish()
    await waitUntil { session.state != .running }

    #expect(session.state == .closed)
  }

  @Test("an AppError from the feed survives as itself")
  func failureKeepsTheAppError() async {
    let feed = TestFeed()
    let session = TerminalSession(feed: feed.feed)
    session.start()

    feed.fail(AppError.channelFailed(reason: "The channel closed unexpectedly."))
    await waitUntil { session.state != .running }

    #expect(session.state == .failed(.channelFailed(reason: "The channel closed unexpectedly.")))
  }

  @Test("an unrecognised error still ends the session as a channel failure")
  func unknownFailureIsMapped() async {
    struct Mystery: Error {}
    let feed = TestFeed()
    let session = TerminalSession(feed: feed.feed)
    session.start()

    feed.fail(Mystery())
    await waitUntil { session.state != .running }

    guard case .failed(let error) = session.state else {
      Issue.record("expected a failure, got \(session.state)")
      return
    }
    #expect(error.errorDescription?.isEmpty == false)
  }

  @Test("start is idempotent — a second call does not open a second pump")
  func startIsIdempotent() async {
    let feed = TestFeed()
    let renderer = HeadlessRenderer()
    let session = TerminalSession(feed: feed.feed)
    session.attach { renderer.feed($0) }
    session.start()
    session.start()

    feed.emit("once")
    await waitUntil { renderer.screen == "once" }

    #expect(renderer.screen == "once")
  }

  @Test("detaching buffers output for the next renderer instead of dropping it")
  func detachBuffers() async {
    let feed = TestFeed()
    let first = HeadlessRenderer()
    let session = TerminalSession(feed: feed.feed)
    session.attach { first.feed($0) }
    session.start()
    feed.emit("before")
    await waitUntil { first.screen == "before" }

    session.detach()
    feed.emit(" after")
    await waitUntil { session.bufferedByteCount > 0 }

    let second = HeadlessRenderer()
    session.attach { second.feed($0) }

    #expect(first.screen == "before")
    #expect(second.screen == "after")
  }

  @Test("a title set by the remote side is recorded")
  func recordsTitle() {
    let session = TerminalSession(feed: TestFeed().feed)
    #expect(session.title == nil)
    session.setTitle("workbox: ~")
    #expect(session.title == "workbox: ~")
  }

  @Test("two sessions run independently — no shared emulator state")
  func sessionsAreIndependent() async {
    let leftFeed = TestFeed()
    let rightFeed = TestFeed()
    let left = HeadlessRenderer()
    let right = HeadlessRenderer()
    let leftSession = TerminalSession(feed: leftFeed.feed)
    let rightSession = TerminalSession(feed: rightFeed.feed)
    leftSession.attach { left.feed($0) }
    rightSession.attach { right.feed($0) }
    leftSession.start()
    rightSession.start()

    leftFeed.emit("left pane")
    rightFeed.emit("right pane")
    await waitUntil { left.screen == "left pane" && right.screen == "right pane" }

    #expect(left.screen == "left pane")
    #expect(right.screen == "right pane")
  }

  @Test("a full-screen redraw renders at the position the escape sequence asks for")
  func handlesCursorAddressing() async {
    let feed = TestFeed()
    let renderer = HeadlessRenderer(columns: 20, rows: 4)
    let session = TerminalSession(feed: feed.feed)
    session.attach { renderer.feed($0) }
    session.start()

    // Clear, home, then row 3 column 5, as a curses redraw does.
    feed.emit("\u{1B}[2J\u{1B}[H\u{1B}[3;5Hvim")
    await waitUntil { renderer.screen.contains("vim") }

    let rows = (0..<renderer.terminal.rows)
      .map { renderer.terminal.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
    #expect(rows.firstIndex { $0.contains("vim") } == 2, "\(rows)")
    // Four cells of padding then the word, so the cursor really moved to column 5.
    #expect(rows[2].hasSuffix("vim"), "\(rows)")
    #expect(rows[2].count == 7, "\(rows)")
  }

  // MARK: - What the renderer has on screen

  @Test("the last rows on screen can be read back, for a thumbnail of a pane")
  func visibleLinesAreTheLastRowsOnScreen() async {
    // A warm pane's emulator gives the sheet a free thumbnail. The emulator belongs to the
    // view, so the view hands over a closure to read it.
    let feed = TestFeed()
    let renderer = HeadlessRenderer(columns: 20, rows: 10)
    let session = TerminalSession(feed: feed.feed)
    session.attach({ renderer.feed($0) }, visibleText: { renderer.screen })
    session.start()

    feed.emit("one\r\ntwo\r\nthree\r\nfour\r\n")
    await waitUntil { renderer.screen.contains("four") }

    #expect(session.visibleLines(last: 3) == ["two", "three", "four"])
    #expect(session.visibleLines(last: 99) == ["one", "two", "three", "four"], "no padding")
  }

  @Test("a session nothing is rendering has no rows to report, which is not no rows")
  func visibleLinesAreNilWithoutARenderer() async {
    // `nil`, not `[]`: a cold pane's thumbnail comes from a batched `pane read`, and an empty
    // array would mean a blank pane.
    let feed = TestFeed()
    let renderer = HeadlessRenderer()
    let session = TerminalSession(feed: feed.feed)

    #expect(session.visibleLines(last: 6) == nil)

    session.attach({ renderer.feed($0) }, visibleText: { renderer.screen })
    #expect(session.visibleLines(last: 6) != nil)

    // A `detach` is a dismantled view; reading its grid would report stale content forever.
    session.detach()
    #expect(session.visibleLines(last: 6) == nil)
  }

  /// A tap on a PTY is a press and then a release, and the far side must hear them in order.
  /// Many clicks, so a race shows as a count.
  @Test("a PTY click's press reaches the far side before its release, every time")
  func clickPressAndReleaseStayInOrder() async {
    let feed = TestFeed()
    let session = TerminalSession(feed: feed.feed)
    session.start()
    // The view's delegate without the view: SwiftTerm's `sendEvent` lands in `session.send`.
    final class Forwarder: TerminalDelegate {
      let session: TerminalSession
      init(session: TerminalSession) { self.session = session }
      func send(source: Terminal, data: ArraySlice<UInt8>) {
        let session = session
        MainActor.assumeIsolated { session.send(data) }
      }
    }
    let forwarder = Forwarder(session: session)
    let terminal = Terminal(delegate: forwarder, options: TerminalOptions(cols: 80, rows: 24))
    terminal.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
    let before = feed.sentText.count

    let clicks = 500
    let press = "\u{1b}[<0;7;5M"
    let release = "\u{1b}[<0;7;5m"
    for _ in 0..<clicks {
      TerminalMouseClick.send(at: TerminalCell(column: 6, row: 4), pixelX: 0, pixelY: 0, to: terminal)
    }
    // Counts bytes, so a fix that sends a click as one write passes too.
    await waitUntil { feed.sentText.count - before >= clicks * (press + release).count }

    let reports = feed.sentText.dropFirst(before).split(separator: "\u{1b}").map { "\u{1b}" + $0 }
    let outOfOrder = stride(from: 0, to: reports.count - 1, by: 2)
      .filter { reports[$0] != press || reports[$0 + 1] != release }
      .count
    #expect(outOfOrder == 0, "\(outOfOrder) of \(clicks) clicks reached the far side out of order")
    withExtendedLifetime(forwarder) {}
  }

  /// herdr's bridge sends one click from one task, but each click is its own task here, so
  /// successive taps must stay in order.
  @Test("a pane's clicks reach the far side in the order they were made")
  func paneClicksStayInOrder() async {
    let feed = TestFeed(scrollable: true)
    let session = TerminalSession(feed: feed.feed)
    session.start()

    let clicks = 500
    for column in 0..<clicks { session.click(column: column, row: 0) }
    await waitUntil { feed.clicks.count >= clicks }

    let columns = feed.clicks.map(\.column)
    let outOfOrder = zip(columns, columns.dropFirst()).filter { $0 > $1 }.count
    #expect(outOfOrder == 0, "\(outOfOrder) of \(clicks) clicks reached the far side out of order")
  }

  /// `close` goes through the input queue last, so earlier input still goes out.
  @Test("input sent before close reaches the far side before the close")
  func inputSentBeforeCloseStillGoesOut() async {
    // Many short sessions, so an overtaking close shows as a count.
    let sessions = 200
    let writes = 20
    var overtaken = 0
    for _ in 0..<sessions {
      let feed = TestFeed()
      let recorder = feed.recorder
      // `async`, as the SSH channel's and herdr's closures are; synchronous ones could never
      // overtake.
      let session = TerminalSession(feed: TerminalFeed(
        output: feed.feed.output,
        send: { @Sendable data async in recorder.record(sent: data) },
        resize: { _ in },
        // The close leaves a mark, so its place among the writes shows.
        close: { @Sendable () async in
          recorder.record(sent: Data("|".utf8))
          recorder.recordClose()
        }
      ))
      session.start()
      for _ in 0..<writes { session.send(text: "x") }
      session.close()
      await waitUntil { feed.closed }
      if feed.sentText != String(repeating: "x", count: writes) + "|" { overtaken += 1 }
    }
    #expect(overtaken == 0, "\(overtaken) of \(sessions) closes overtook input sent before them")
  }

  /// A scroll-down that overtook the queued scroll-up would leave the pane scrolled up on the
  /// user's own screen.
  @Test("scrollToBottom lands after a restore that was queued before it")
  func scrollToBottomWaitsForQueuedScrolls() async {
    let feed = TestFeed(scrollable: true)
    let recorder = feed.recorder
    let session = TerminalSession(feed: TerminalFeed(
      output: feed.feed.output,
      send: { _ in },
      resize: { _ in },
      close: {},
      // A slow scroll-up, so a scroll that skips the queue overtakes it.
      scroll: { @Sendable direction, lines async in
        if direction == .up { try? await Task.sleep(for: .milliseconds(50)) }
        recorder.record(scroll: direction, lines: lines)
      }
    ))
    session.start()

    session.restoreScroll(rows: 5)
    await session.scrollToBottom()

    #expect(feed.scrolls.map(\.0) == [.up, .down], "the desk was left scrolled up")
  }

  /// The scene waits on this before `terminal.release`.
  @Test("pendingWritesSent returns once slow queued writes have gone out")
  func pendingWritesSentWaitsForTheQueue() async {
    let feed = TestFeed()
    let recorder = feed.recorder
    let session = TerminalSession(feed: TerminalFeed(
      output: feed.feed.output,
      send: { @Sendable data async in
        try? await Task.sleep(for: .milliseconds(20))
        recorder.record(sent: data)
      },
      resize: { _ in },
      close: {}
    ))
    session.start()

    for _ in 0..<5 { session.send(text: "x") }
    session.close()
    let drained = await session.pendingWritesSent(within: .seconds(30))

    #expect(drained)
    #expect(feed.sentText == "xxxxx")
  }

  /// A write that never finishes must not hold the hand-back past the limit.
  @Test("pendingWritesSent gives up on a stuck write at its limit")
  func pendingWritesSentIsBounded() async {
    let feed = TestFeed()
    let session = TerminalSession(feed: TerminalFeed(
      output: feed.feed.output,
      send: { @Sendable _ async in try? await Task.sleep(for: .seconds(3600)) },
      resize: { _ in },
      close: {}
    ))
    session.start()

    session.send(text: "x")
    session.close()
    let began = ContinuousClock.now
    let drained = await session.pendingWritesSent(within: .milliseconds(100))

    #expect(!drained)
    #expect(ContinuousClock.now - began < .seconds(5))
  }

  @Test("the write queue does not keep a session alive")
  func writeQueueDoesNotRetainTheSession() async {
    let feed = TestFeed()
    var session: TerminalSession? = TerminalSession(feed: feed.feed)
    weak let released = session
    session?.send(text: "x")
    await waitUntil { feed.sentText == "x" }

    session = nil
    #expect(released == nil)
  }
}

/// A pacing scheduler the test drives. The live one sleeps, and a sleep short enough to keep
/// the suite fast loses to a loaded machine. This banks the timeouts so the test fires them.
@MainActor
private final class ManualScrollPacingScheduler {
  private var pending: [() -> Void] = []

  lazy var schedule: TerminalSession.ScrollPacingScheduler = { [weak self] _, work in
    self?.pending.append(work)
  }

  /// Fires every timeout scheduled so far.
  func fireAll() {
    let work = pending
    pending.removeAll()
    work.forEach { $0() }
  }
}

@MainActor
@Suite("TerminalSession scroll memory", .timeLimit(.minutes(1)))
struct TerminalSessionScrollMemoryTests {
  private func paneSession(
    timeout: Duration = .seconds(30),
    scheduler: @escaping TerminalSession.ScrollPacingScheduler = TerminalSession
      .liveScrollPacingScheduler
  ) -> (TestFeed, TerminalSession) {
    let feed = TestFeed(scrollable: true)
    let session = TerminalSession(
      feed: feed.feed,
      scrollPacingTimeout: timeout,
      scrollPacingScheduler: scheduler
    )
    session.start()
    session.attach { _ in }
    return (feed, session)
  }

  @Test("scrolledRows only grows once herdr answers with a frame")
  func countsOnlyAnsweredScrolls() async {
    let (feed, session) = paneSession()

    session.scroll(.up, lines: 5)
    await waitUntil { !feed.scrolls.isEmpty }
    #expect(session.scrolledRows == 0, "not answered yet")

    feed.emit("frame")
    await waitUntil { session.scrolledRows == 5 }
    #expect(session.scrolledRows == 5)
  }

  @Test("a scroll nobody answers is not counted")
  func unansweredScrollDoesNotCount() async {
    let scheduler = ManualScrollPacingScheduler()
    let (feed, session) = paneSession(scheduler: scheduler.schedule)

    session.scroll(.up, lines: 5)
    await waitUntil { !feed.scrolls.isEmpty }
    feed.emit("frame")
    await waitUntil { session.scrolledRows == 5 }

    // At the top of scrollback herdr sends no frame; the timeout reopens the gate and must not
    // count. The timeout is fired directly rather than waited out.
    session.scroll(.up, lines: 4)
    await waitUntil { feed.scrolls.count == 2 }
    scheduler.fireAll()
    #expect(session.scrolledRows == 5, "the unanswered scroll must not be counted")
  }

  @Test("scrolledRows never goes negative")
  func clampsAtZero() async {
    let (feed, session) = paneSession()

    session.scroll(.up, lines: 3)
    await waitUntil { !feed.scrolls.isEmpty }
    feed.emit("frame")
    await waitUntil { session.scrolledRows == 3 }

    session.scroll(.down, lines: 10)
    await waitUntil { feed.scrolls.count == 2 }
    feed.emit("frame")
    await waitUntil { feed.scrolls.count == 2 && session.scrolledRows == 0 }

    #expect(session.scrolledRows == 0)
  }

  @Test("scrollToBottom sends one scroll down of exactly the banked size, then forgets it")
  func scrollToBottomSendsOneCommand() async {
    let (feed, session) = paneSession()

    session.scroll(.up, lines: 7)
    await waitUntil { !feed.scrolls.isEmpty }
    feed.emit("frame")
    await waitUntil { session.scrolledRows == 7 }

    await session.scrollToBottom()
    await waitUntil { feed.scrolls.count == 2 }

    #expect(feed.scrolls.last?.0 == .down)
    #expect(feed.scrolls.last?.1 == 7)
    #expect(session.scrolledRows == 0)
  }

  @Test("scrollToBottom does nothing at zero")
  func scrollToBottomNoOpAtZero() async {
    let (feed, session) = paneSession()

    await session.scrollToBottom()
    try? await Task.sleep(for: .milliseconds(30))

    #expect(feed.scrolls.isEmpty)
  }

  @Test("restoreScroll sends one scroll up of the given size")
  func restoreScrollSendsOneCommand() async {
    let (feed, session) = paneSession()

    session.restoreScroll(rows: 9)
    await waitUntil { !feed.scrolls.isEmpty }

    #expect(feed.scrolls.count == 1)
    #expect(feed.scrolls.first?.0 == .up)
    #expect(feed.scrolls.first?.1 == 9)
    #expect(session.scrolledRows == 9)
  }

  @Test("restoreScroll does nothing at zero")
  func restoreScrollNoOpAtZero() async {
    let (feed, session) = paneSession()

    session.restoreScroll(rows: 0)
    try? await Task.sleep(for: .milliseconds(30))

    #expect(feed.scrolls.isEmpty)
    #expect(session.scrolledRows == 0)
  }

  @Test("a pty never sends a scroll, since its history is already on this side")
  func ptyNeverScrolls() async {
    let feed = TestFeed()
    let session = TerminalSession(feed: feed.feed)
    session.start()
    session.attach { _ in }

    session.restoreScroll(rows: 4)
    await session.scrollToBottom()
    try? await Task.sleep(for: .milliseconds(30))

    #expect(feed.scrolls.isEmpty)
  }

  @Test("a pane's click reaches the far side as the cell it was given")
  func paneClickReachesFeed() async {
    let (feed, session) = paneSession()
    #expect(session.clicksRemotely)

    session.click(column: 7, row: 3)
    await waitUntil { !feed.clicks.isEmpty }

    #expect(feed.clicks == [TerminalCell(column: 7, row: 3)])
  }

  @Test("a pty sends no click through the session, since the view encodes its own")
  func ptyClickIsNoOp() async {
    let feed = TestFeed()
    let session = TerminalSession(feed: feed.feed)
    session.start()
    session.attach { _ in }
    #expect(!session.clicksRemotely)

    session.click(column: 1, row: 1)
    try? await Task.sleep(for: .milliseconds(30))

    #expect(feed.clicks.isEmpty)
    #expect(feed.sent.isEmpty)
  }

  @Test("a closed pane sends no click")
  func closedPaneSendsNoClick() async {
    let (feed, session) = paneSession()
    session.close()

    session.click(column: 1, row: 1)
    try? await Task.sleep(for: .milliseconds(30))

    #expect(feed.clicks.isEmpty)
  }
}

@MainActor
@Suite("TerminalFeed read-only", .timeLimit(.minutes(1)))
struct TerminalFeedReadOnlyTests {
  @Test("a session on a read-only feed drops send, never scrolls remotely, and still renders")
  func readOnlyFeedIsInertExceptForOutput() async {
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
    let closedFlag = TestFeed.Recorder()
    let feed = TerminalFeed.readOnly(output: stream) { closedFlag.recordClose() }
    let session = TerminalSession(feed: feed)
    let renderer = HeadlessRenderer()
    session.attach { renderer.feed($0) }
    session.start()

    #expect(!session.scrollsRemotely)
    #expect(!session.clicksRemotely)

    // There is nothing to observe beyond not crashing and not stalling the session.
    session.send(text: "ignored")

    continuation.yield(Data("observed output".utf8))
    await waitUntil { renderer.screen == "observed output" }
    #expect(renderer.screen == "observed output")

    session.close()
    await waitUntil { closedFlag.closed }
    #expect(closedFlag.closed)
  }
}

/// A session over a herdr-core attach stream: what it owes the far side beyond its bytes.
@MainActor
@Suite("TerminalSession over a raw stream", .timeLimit(.minutes(1)))
struct TerminalSessionRawStreamTests {
  /// `terminal.attach`'s first paint at 40x20, captured from a scratch core 0.1.14. The program
  /// had printed 1 to 40 and turned on focus reports, SGR mouse and bracketed paste, so this
  /// holds a reset, history pushed off the top, `?1004h` and the win32 report.
  private static let firstPaint = Data(
    base64Encoded:
      "G1shcBtbPzIwMjZsG1s/OWwbWz8xMDAwbBtbPzEwMDFsG1s/MTAwMmwbWz8xMDAzbBtbPzEwMDRsG1s/MTAwNWwb"
      + "Wz8xMDA2bBtbPzEwMTVsG1s/MTAxNmwbWz8yMDA0bBtbPzFsG1s/NjZsG1s/MjAzMWwbWz8yMDQ4bBtbPTA7MXUb"
      + "Wz8xMDQ5bBtbPzEwNDdsG1s/NDdsG1tIG1sySjENCjINCjMNCjQNCjUNCjYNCjcNCjgNCjkNCjEwDQoxMQ0KMTIN"
      + "CjEzDQoxNA0KMTUNCjE2DQoxNw0KMTgNCjE5DQoyMA0KMjEbWzBtDQoKCgoKCgoKCgoKCgoKCgoKCgoKChtbSBtb"
      + "MkobWz8xMDAwaBtbPzEwMDRoG1s/MTAwNmgbWz8yMDA0aBtbM2cbWzlHG0gbWzE3RxtIG1syNUcbSBtbMzNHG0gb"
      + "W0gyMg0KMjMNCjI0DQoyNQ0KMjYNCjI3DQoyOA0KMjkNCjMwDQozMQ0KMzINCjMzDQozNA0KMzUNCjM2DQozNw0K"
      + "MzgNCjM5DQo0MA0KcmVhZHk+IBtbMjA7OEgbWzBtG10yO2ZpeHR1cmUbXBtbPzkwMDFs"
  )!

  /// The view's delegate without the view: what the emulator replies lands in `session.send`.
  private final class Forwarder: TerminalDelegate {
    let session: TerminalSession
    init(session: TerminalSession) { self.session = session }
    func send(source: Terminal, data: ArraySlice<UInt8>) {
      let session = session
      MainActor.assumeIsolated { session.send(data) }
    }
  }

  /// Whatever the emulator says back while it draws `paint`, ending at a sentinel so the
  /// session's queue is known to have drained.
  private func replies(toPaintOn feed: TestFeed) async -> String {
    let session = TerminalSession(feed: feed.feed)
    session.start()
    let forwarder = Forwarder(session: session)
    let terminal = Terminal(delegate: forwarder, options: TerminalOptions(cols: 40, rows: 20))
    terminal.feed(buffer: ArraySlice([UInt8](Self.firstPaint)))
    session.send(text: "sentinel")
    await waitUntil { feed.sentText.hasSuffix("sentinel") }
    withExtendedLifetime(forwarder) {}
    return String(feed.sentText.dropLast("sentinel".count))
  }

  /// Anything here would be typed into the program. `CSI I` is the one SwiftTerm has:
  /// `?1004h` reports the focus at once.
  @Test("a core's first paint draws no reply from the emulator")
  func firstPaintDrawsNoReply() async {
    #expect(await replies(toPaintOn: TestFeed(raw: true)) == "")
  }

  /// The other half of the filter: without `focus`, nothing else tells the far side.
  @Test("a feed without focus keeps SwiftTerm's own report")
  func ptyKeepsTheFocusReport() async {
    #expect(await replies(toPaintOn: TestFeed()) == "\u{1b}[I")
  }

  @Test("only a whole focus report is dropped")
  func onlyAWholeReportIsDropped() async {
    let feed = TestFeed(raw: true)
    let session = TerminalSession(feed: feed.feed)
    session.start()
    session.send(text: "\u{1b}[O")
    session.send(text: "\u{1b}[A")
    session.send(text: "\u{1b}[Ix")
    await waitUntil { feed.sentText.hasSuffix("x") }
    #expect(feed.sentText == "\u{1b}[A\u{1b}[Ix")
  }

  /// The history arrives as lines pushed off the top, and the screen after a `2J`, so what the
  /// emulator does with `2J` decides whether a drag finds it.
  @Test("the paint's history lands in the local scrollback, in order, with the screen after")
  func historyReachesScrollback() throws {
    let delegate = NullDelegate()
    let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 40, rows: 20))
    terminal.feed(buffer: ArraySlice([UInt8](Self.firstPaint)))

    let text = String(decoding: terminal.getBufferAsData(), as: UTF8.self)
    let numbers = text.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    #expect(numbers == Array(1...40), "\(text)")
    withExtendedLifetime(delegate) {}
  }

  private final class NullDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
  }

  @Test("bytes count as consumed once rendered, not when they arrive")
  func creditFollowsTheRenderer() async {
    let feed = TestFeed(raw: true)
    let session = TerminalSession(feed: feed.feed)
    session.start()

    feed.emit("before")
    await waitUntil { session.bufferedByteCount == 6 }
    #expect(feed.consumed.isEmpty)

    var rendered = 0
    session.attach { rendered += $0.count }
    #expect(rendered == 6)
    #expect(feed.consumed == [6])

    feed.emit("after!!")
    await waitUntil { rendered == 13 }
    #expect(feed.consumed == [6, 7])
  }

  /// Why `CoreAttachment` rewrites a paint. A core's paint opens with a soft reset and `?1049l`,
  /// which in SwiftTerm restores a cursor nothing saved, and with it autowrap off.
  @Test(
    "a paint that leaves the alternate screen by 1047 keeps autowrap, and by 1049 does not",
    arguments: [("\u{1b}[?1047l", 2), ("\u{1b}[?1049l", 1)]
  )
  func autowrapAfterAPaint(leaving: String, rows: Int) {
    let delegate = Forwarding()
    let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 40, rows: 20))

    terminal.feed(text: "\u{1b}[!p" + leaving + "\u{1b}[H\u{1b}[2J")
    terminal.feed(text: String(repeating: "x", count: 50))

    let used = (0..<3).filter { terminal.getLine(row: $0)?.translateToString(trimRight: true) != "" }
    #expect(used.count == rows)
    withExtendedLifetime(delegate) {}
  }

  private final class Forwarding: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
  }

  /// A paint on the alternate screen goes through the normal one on its way, so what counts is
  /// where the whole chunk ends.
  @Test("leaving the alternate screen is judged per chunk", arguments: [(false, 1), (true, 0)])
  func leavingIsJudgedPerChunk(backAgain: Bool, reports: Int) async {
    let feed = TestFeed(raw: true)
    let session = TerminalSession(feed: feed.feed)
    session.start()
    session.attach { _ in
      session.alternateScreenChanged(false)
      if backAgain { session.alternateScreenChanged(true) }
    }
    session.alternateScreenChanged(true)

    feed.emit("x")
    feed.emit("sentinel")
    await waitUntil { feed.consumed.count == 2 }

    #expect(feed.leftAlternateScreen == reports)
  }

  /// SwiftTerm says nothing about a grid that lands on its own default, and a core attach
  /// holding for a size would wait out its deadline.
  @Test("a feed that is waiting for a size hears the first grid, as a resize")
  func firstGridReachesAWaitingFeed() async {
    let feed = TestFeed(raw: true)
    let session = TerminalSession(feed: feed.feed, openSettlingWindow: .zero)
    session.start()

    session.firstGridMeasured(TerminalSize(columns: 80, rows: 25))

    await waitUntil { !feed.sizes.isEmpty }
    #expect(feed.sizes == [TerminalSize(columns: 80, rows: 25)])
  }

  @Test("a first grid says nothing once a size has been reported")
  func firstGridAfterAReport() async {
    let feed = TestFeed(raw: true)
    let session = TerminalSession(feed: feed.feed, openSettlingWindow: .zero)
    session.start()

    session.resize(to: TerminalSize(columns: 52, rows: 48))
    session.firstGridMeasured(TerminalSize(columns: 80, rows: 25))

    await waitUntil { !feed.sizes.isEmpty }
    #expect(feed.sizes == [TerminalSize(columns: 52, rows: 48)])
  }

  /// A pty and a herdr pane stay as they were: no report at SwiftTerm's default grid.
  @Test("a feed that is not waiting ignores the first grid")
  func firstGridIgnored() {
    let session = TerminalSession(feed: TestFeed().feed)
    session.start()

    session.firstGridMeasured(TerminalSize(columns: 80, rows: 25))

    #expect(session.reportedSize == nil)
  }

  @Test("a focus change is sent once, in order with what was typed")
  func focusIsSentOnce() async {
    let feed = TestFeed(raw: true)
    let session = TerminalSession(feed: feed.feed)
    session.start()

    session.focus(true)
    session.focus(true)
    session.send(text: "x")
    session.focus(false)
    await waitUntil { feed.focuses.count >= 2 }
    #expect(feed.focuses == [true, false])
    #expect(feed.sentText == "x")
  }

  @Test("a closed session reports no focus, and a feed that does not ask is not told")
  func focusNeedsALiveSessionAndAFeedThatAsks() async {
    let raw = TestFeed(raw: true)
    let session = TerminalSession(feed: raw.feed)
    session.start()
    session.close()
    session.focus(true)
    await waitUntil { raw.closed }
    #expect(raw.focuses.isEmpty)

    let pty = TerminalSession(feed: TestFeed().feed)
    pty.start()
    pty.focus(true)
    #expect(!pty.scrollsRemotely)
    #expect(!pty.clicksRemotely)
  }
}
