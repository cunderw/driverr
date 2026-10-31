import DriverrCore
import Foundation
import SwiftTerm
import SwiftUI
import Testing
import UIKit
import UIKit.UIGestureRecognizerSubclass

@testable import DriverrTerm

/// Selection and drags stay on the phone whatever mouse mode the far side asks for.
///
/// Driverr sets SwiftTerm's `allowMouseReporting` to `false`, so a tap selects, a selection
/// survives output, and a drag scrolls. The flag alone is not enough: SwiftTerm's
/// `mouseModeChanged` adds a mouse pan whenever the remote enables a mouse mode and never
/// reads the flag, and with the flag off its selection pan sends cursor keys for a drag it
/// catches after the selection has ended. These cases pin both.
///
/// Hosted, because gesture recognisers are only installed and consulted on a view in a real
/// window. Bytes are fed straight into the view rather than through the
/// session's stream, so each case reads the state the bytes left behind with no wait.
@MainActor
@Suite("DriverrTerminalUIView mouse reporting", .serialized)
struct TerminalMouseReportingTests {
  /// What the far side was sent: bytes, and a pane's clicks.
  private final class FarSide: @unchecked Sendable {
    private let lock = NSLock()
    private var _bytes = Data()
    private var _clicks: [TerminalCell] = []
    var text: String { lock.withLock { String(decoding: _bytes, as: UTF8.self) } }
    var clicks: [TerminalCell] { lock.withLock { _clicks } }
    func record(_ data: Data) {
      lock.withLock { _bytes.append(data) }
      Waker.signalShared()
    }
    func record(_ click: TerminalCell) { lock.withLock { _clicks.append(click) } }
  }

  /// A terminal built by `DriverrTerminalView` in a key window, and the pans it starts with.
  ///
  /// The baseline is asserted, not assumed: the scroll view's own pan and the drag pan. A
  /// SwiftTerm update that installs another pan at rest fails here first, before a case
  /// compares a count against it.
  @MainActor
  private struct Hosted {
    let window: UIWindow
    let view: DriverrTerminalUIView
    let baseline: [UIGestureRecognizer]
    let farSide: FarSide
    let finish: () -> Void

    var pans: [UIGestureRecognizer] {
      (view.gestureRecognizers ?? []).filter { $0 is UIPanGestureRecognizer }
    }

    /// The pans that are not in the baseline: SwiftTerm's selection and mouse pans.
    var addedPans: [UIGestureRecognizer] {
      pans.filter { pan in !baseline.contains { $0 === pan } }
    }
  }

  private func hosted(pane: Bool) throws -> Hosted {
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    let farSide = FarSide()
    let feed = TerminalFeed(
      output: stream,
      send: { farSide.record($0) },
      resize: { _ in },
      close: {},
      scroll: pane ? { @Sendable _, _ in } : nil,
      // `async`, as herdr's bridge is. A synchronous closure runs on the caller's actor
      // without a hop, so it could never show a reorder.
      click: pane ? { @Sendable cell async in farSide.record(cell) } : nil
    )
    let session = TerminalSession(feed: feed)
    let window = HostedProbe.window(
      DriverrTerminalView(session: session, wantsKeyboardFocus: false)
    )
    let view = try #require(Self.terminal(in: window))
    let baseline = (view.gestureRecognizers ?? []).filter { $0 is UIPanGestureRecognizer }
    #expect(baseline.count == 2)
    return Hosted(window: window, view: view, baseline: baseline, farSide: farSide) {
      continuation.finish()
    }
  }

  private static func terminal(in view: UIView) -> DriverrTerminalUIView? {
    if let terminal = view as? DriverrTerminalUIView { return terminal }
    for subview in view.subviews {
      if let terminal = terminal(in: subview) { return terminal }
    }
    return nil
  }

  /// SwiftTerm's edit menu, through the view's own probe, which reads it without a
  /// deprecation warning.
  private static var editMenu: any EditMenuProbe.Type { EditMenu.self }

  /// Returns once every block already on the main queue has run.
  ///
  /// SwiftTerm removes its selection pan one `DispatchQueue.main.async` hop after the
  /// selection ends, and pumping the run loop from inside a test does not reach it: the test
  /// is itself a main-queue job, and the main queue does not run a second job inside one.
  /// Suspending lets the queue drain, and the queue is FIFO, so a block enqueued now runs
  /// after SwiftTerm's.
  private static func drainMainQueue() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  /// The remote asking for mouse events must not add SwiftTerm's pan, which would take the
  /// drag and send it as motion reports.
  @Test("a mouse mode from the far side adds no pan", arguments: [false, true])
  func mouseModeAddsNoPan(pane: Bool) async throws {
    let hosted = try hosted(pane: pane)
    defer { hosted.finish() }

    hosted.view.feed(text: "\u{1b}[?1000h")
    await Self.drainMainQueue()

    #expect(hosted.view.getTerminal().mouseMode != .off)
    #expect(hosted.pans.count == hosted.baseline.count)
    withExtendedLifetime(hosted.window) {}
  }

  /// Output arriving under a selection leaves it selected, with a mouse mode on.
  @Test("a selection survives streaming output", arguments: [false, true])
  func selectionSurvivesOutput(pane: Bool) async throws {
    let hosted = try hosted(pane: pane)
    defer { hosted.finish() }
    hosted.view.feed(text: "\u{1b}[?1000hfirst row\r\n")

    hosted.view.setSelectionRange(
      start: Position(col: 0, row: 0),
      end: Position(col: 4, row: 0)
    )
    #expect(hosted.view.selection.active)

    for line in 0..<5 {
      hosted.view.feed(text: "line \(line)\r\n")
    }
    await Self.drainMainQueue()

    #expect(hosted.view.selection.active)
    withExtendedLifetime(hosted.window) {}
  }

  /// Once a selection ends, SwiftTerm's selection pan must not begin, because a drag it
  /// catches with no selection is sent to the far side as cursor keys. SwiftTerm removes the
  /// pan itself, but one main-queue hop later, so the refusal has to hold before that hop.
  @Test("an ended selection's pan cannot begin", arguments: [false, true])
  func endedSelectionPanCannotBegin(pane: Bool) async throws {
    let hosted = try hosted(pane: pane)
    defer { hosted.finish() }

    hosted.view.selectAll(nil)
    let selectionPan = try #require(hosted.addedPans.first)
    #expect(hosted.addedPans.count == 1)
    #expect(hosted.view.gestureRecognizerShouldBegin(selectionPan))

    hosted.view.clearSelection()
    #expect(!hosted.view.selection.active)
    #expect(!hosted.view.gestureRecognizerShouldBegin(selectionPan))

    await Self.drainMainQueue()
    #expect(hosted.pans.count == hosted.baseline.count)
    withExtendedLifetime(hosted.window) {}
  }

  /// As above, with the selection ended by the far side instead of by the user: a region
  /// scroll (DECSTBM) that the selection crosses drops it, and output does arrive mid-drag.
  @Test("a selection ended by a region scroll leaves a pan that cannot begin", arguments: [false, true])
  func regionScrollEndsSelectionPan(pane: Bool) async throws {
    let hosted = try hosted(pane: pane)
    defer { hosted.finish() }
    hosted.view.feed(text: "one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix\r\n")

    hosted.view.selectAll(nil)
    let selectionPan = try #require(hosted.addedPans.first)
    #expect(hosted.view.selection.active)

    // Rows 2 to 5 become the scroll region, the cursor goes to its last row, and a line feed
    // there shifts the region in place. The selection spans the whole buffer, so it crosses
    // the region's edge and SwiftTerm drops it.
    hosted.view.feed(text: "\u{1b}[2;5r\u{1b}[5;1H\n")
    #expect(!hosted.view.selection.active)
    #expect(!hosted.view.gestureRecognizerShouldBegin(selectionPan))

    await Self.drainMainQueue()
    #expect(hosted.pans.count == hosted.baseline.count)
    withExtendedLifetime(hosted.window) {}
  }

  /// A pane's drag is its only way to scroll, so the refusal above must not catch the pane's
  /// own remote-scroll pan while nothing is selected.
  @Test("a pane's remote-scroll pan still begins with nothing selected")
  func remoteScrollPanBegins() throws {
    let hosted = try hosted(pane: true)
    defer { hosted.finish() }

    let remoteScroll = try #require(
      hosted.baseline.first { $0 !== hosted.view.panGestureRecognizer }
    )
    #expect(!hosted.view.selection.active)
    #expect(hosted.view.gestureRecognizerShouldBegin(remoteScroll))
    withExtendedLifetime(hosted.window) {}
  }

  /// A pane's remote-scroll pan accepts a trackpad and a mouse wheel, not only a touch.
  ///
  /// The pane turns the scroll view's own pan off, so this pan is the only thing on a pane
  /// that can take indirect scroll. A `UIPanGestureRecognizer` takes none by default.
  ///
  /// This asserts the mask and not the scroll itself, because no in-process API creates a
  /// scroll `UIEvent`. The wheel and the trackpad are checked on a device.
  @Test("a pane's remote-scroll pan accepts pointer scroll")
  func remoteScrollPanAcceptsPointerScroll() throws {
    let hosted = try hosted(pane: true)
    defer { hosted.finish() }

    let remoteScroll = try #require(
      hosted.baseline.first { $0 !== hosted.view.panGestureRecognizer } as? UIPanGestureRecognizer
    )
    #expect(remoteScroll.allowedScrollTypesMask == .all)
    withExtendedLifetime(hosted.window) {}
  }

  /// What Claude Code paints with `"tui": "fullscreen"`, as a core relayed it.
  private nonisolated static let fullscreenProgram =
    "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1004h\u{1b}[?1006h"

  /// The alternate screen has no scrollback, so the scroll view has nothing to move, and a
  /// drag does nothing unless the pan has it. The way back is pinned too, because a shell left
  /// with the scroll view off could never reach its history again.
  @Test(
    "a full-screen program takes the drag from the scroll view, and leaving gives it back",
    arguments: [Self.fullscreenProgram, "\u{1b}[?1049h", "\u{1b}[?1000h"]
  )
  func programTakesTheDrag(output: String) throws {
    let hosted = try hosted(pane: false)
    defer { hosted.finish() }
    let dragPan = try #require(hosted.view.dragPan)
    #expect(hosted.view.isScrollEnabled)
    #expect(!dragPan.isEnabled)

    hosted.view.feed(text: output)
    #expect(!hosted.view.isScrollEnabled)
    #expect(dragPan.isEnabled)

    hosted.view.feed(text: "\u{1b}[?1049l\u{1b}[?1003l\u{1b}[?1002l\u{1b}[?1000l")
    #expect(hosted.view.isScrollEnabled)
    #expect(!dragPan.isEnabled)
    withExtendedLifetime(hosted.window) {}
  }

  /// herdr's `wheel_routing` already does this for a pane, on its side of `terminal.scroll`.
  @Test("a pane's drag stays herdr's, whatever the program does")
  func paneIgnoresTheRoute() throws {
    let hosted = try hosted(pane: true)
    defer { hosted.finish() }
    let dragPan = try #require(hosted.view.dragPan)

    let leaving = "\u{1b}[?1049l\u{1b}[?1003l\u{1b}[?1002l\u{1b}[?1000l"
    for output in [Self.fullscreenProgram, leaving] {
      hosted.view.feed(text: output)
      #expect(!hosted.view.isScrollEnabled)
      #expect(dragPan.isEnabled)
    }
    withExtendedLifetime(hosted.window) {}
  }

  /// From where `handleDrag` hands over, with the location a touch would give. A pan reports
  /// no translation without real touches, and `RemoteScrollAccumulatorTests` covers the rows.
  @Test(
    "a drag reaches the program as wheel events under the finger, one per row",
    .timeLimit(.minutes(1)),
    arguments: [(3, "\u{1b}[<64;10;5M"), (-3, "\u{1b}[<65;10;5M")]
  )
  func dragReachesTheProgram(lines: Int, report: String) async throws {
    let hosted = try hosted(pane: false)
    defer { hosted.finish() }
    let view = hosted.view
    // Not `fullscreenProgram`: on this feed its `?1004h` draws SwiftTerm's own focus report.
    view.feed(text: "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h")
    let dragPan = try #require(view.dragPan)
    let coordinator = try #require(view.terminalDelegate as? DriverrTerminalView.Coordinator)

    let grid = view.getOptimalFrameSize()
    let cellWidth = grid.width / CGFloat(view.getTerminal().cols)
    let cellHeight = grid.height / CGFloat(view.getTerminal().rows)
    view.tapLocation = { _, _ in CGPoint(x: cellWidth * 9.5, y: cellHeight * 4.5) }

    coordinator.deliverDrag(lines: lines, from: dragPan, in: view)

    await waitUntilSignalled("the wheel") { hosted.farSide.text.count >= report.count * 3 }
    #expect(hosted.farSide.text == String(repeating: report, count: 3))
    withExtendedLifetime(hosted.window) {}
  }

  /// A selection drag already under way when the selection ends is cancelled at once, rather
  /// than left to deliver `.changed`, which SwiftTerm turns into cursor keys with no selection.
  @Test("a selection drag in flight is cancelled when the selection ends", arguments: [false, true])
  func inFlightSelectionDragIsCancelled(pane: Bool) throws {
    let hosted = try hosted(pane: pane)
    defer { hosted.finish() }

    hosted.view.selectAll(nil)
    let selectionPan = try #require(hosted.addedPans.first)
    selectionPan.state = .began
    #expect(selectionPan.state == .began)

    hosted.view.clearSelection()
    #expect(selectionPan.state != .began && selectionPan.state != .changed)
    withExtendedLifetime(hosted.window) {}
  }

  // MARK: - Tap to click

  /// The tap is SwiftTerm's own recogniser, with a target added, so there must be exactly
  /// one single tap on the view. A second one would mean a SwiftTerm update added another
  /// and `singleTapRecognizer` could be picking the wrong one.
  @Test("the view has exactly one single-tap recogniser", arguments: [false, true])
  func exactlyOneSingleTap(pane: Bool) throws {
    let hosted = try hosted(pane: pane)
    defer { hosted.finish() }

    let singleTaps = (hosted.view.gestureRecognizers ?? []).compactMap {
      $0 as? UITapGestureRecognizer
    }.filter { $0.numberOfTapsRequired == 1 && $0.numberOfTouchesRequired == 1 }
    #expect(singleTaps.count == 1)
    #expect(singleTaps.first === hosted.view.singleTapRecognizer)
    withExtendedLifetime(hosted.window) {}
  }

  /// Taps `point`, in the view's own (content) coordinates, through SwiftTerm's single-tap
  /// recogniser.
  ///
  /// No in-process API makes a touch, so the location comes through the view's seam, and
  /// `gestureRecognizerShouldBegin` is called by hand because setting `state` skips it.
  ///
  /// Focused first by default, because a tap on a terminal without the keyboard only takes
  /// it. The fixture's terminal is built with `wantsKeyboardFocus: false`, which stops it
  /// asking for focus on its own but not being given it.
  private func tap(_ hosted: Hosted, at point: CGPoint, focused: Bool = true) throws {
    let view = hosted.view
    if focused, !view.isFirstResponder {
      try #require(view.becomeFirstResponder())
    }
    // The edit menu is one per process, and a menu still up from an earlier tap turns this
    // tap's click off. That would let a test that expects nothing pass for the wrong reason.
    Self.editMenu.hide()
    // Read outside `#expect`, whose expansion cannot call a static member through an
    // existential metatype.
    let menuVisible = Self.editMenu.isVisible
    #expect(!menuVisible)
    view.tapLocation = { _, _ in point }
    let tap = try #require(view.singleTapRecognizer)
    _ = view.gestureRecognizerShouldBegin(tap)
    tap.state = .ended
  }

  /// Taps the middle of `cell` of the live screen, where SwiftTerm draws it: buffer line `n`
  /// sits `n` cell heights down the content, and the live screen is the last `rows` lines.
  private func tap(_ hosted: Hosted, at cell: TerminalCell, focused: Bool = true) throws {
    let view = hosted.view
    let grid = view.getOptimalFrameSize()
    let terminal = view.getTerminal()
    let cellWidth = grid.width / CGFloat(terminal.cols)
    let cellHeight = grid.height / CGFloat(terminal.rows)
    let lines = (view.contentSize.height / cellHeight).rounded()
    let liveScreenTop = (lines - CGFloat(terminal.rows)) * cellHeight
    try tap(
      hosted,
      at: CGPoint(
        x: (CGFloat(cell.column) + 0.5) * cellWidth,
        y: liveScreenTop + (CGFloat(cell.row) + 0.5) * cellHeight
      ),
      focused: focused
    )
  }

  /// Waits for the far side to hear something, a bounded number of main-queue turns.
  private static func waitFor(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  @Test("a tap on a pane reaches the far side as the cell it landed on")
  func paneTapReachesFarSideAsItsCell() async throws {
    let hosted = try hosted(pane: true)
    defer { hosted.finish() }

    try tap(hosted, at: TerminalCell(column: 6, row: 4))
    await Self.waitFor { !hosted.farSide.clicks.isEmpty }

    #expect(hosted.farSide.clicks == [TerminalCell(column: 6, row: 4)])
    // A pane's click is a command for herdr, never bytes typed into the pane.
    #expect(hosted.farSide.text.isEmpty)
    withExtendedLifetime(hosted.window) {}
  }

  @Test("a tap on a PTY that asked for SGR mouse reports sends a click on its row")
  func ptyTapSendsSGRClick() async throws {
    let hosted = try hosted(pane: false)
    defer { hosted.finish() }
    hosted.view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")

    try tap(hosted, at: TerminalCell(column: 6, row: 4))
    await Self.waitFor { hosted.farSide.text.contains("m") }

    #expect(hosted.farSide.text == "\u{1b}[<0;7;5M\u{1b}[<0;7;5m")
    withExtendedLifetime(hosted.window) {}
  }

  /// Claude Code keeps its main screen with mouse reports on, so a PTY can have scrollback
  /// under a program that takes clicks. A tap on a scrolled-back row is not on the program's
  /// screen, and clicking the live row at the same height would pick something unseen.
  @Test("a tap on scrollback sends no click")
  func tapOnScrollbackSendsNothing() async throws {
    let hosted = try hosted(pane: false)
    defer { hosted.finish() }
    hosted.view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
    for line in 0..<200 { hosted.view.feed(text: "line \(line)\r\n") }
    hosted.view.scroll(toPosition: 0)
    #expect(hosted.view.getTerminal().getTopVisibleRow() == 0)

    // The third row on screen, which is buffer line 2, long scrolled off the live screen.
    let cellHeight =
      hosted.view.getOptimalFrameSize().height / CGFloat(hosted.view.getTerminal().rows)
    try tap(hosted, at: CGPoint(x: 10, y: hosted.view.bounds.minY + 2.5 * cellHeight))
    try? await Task.sleep(for: .milliseconds(300))

    #expect(hosted.farSide.text.isEmpty)
    withExtendedLifetime(hosted.window) {}
  }

  @Test("with scrollback above it, a tap on the live screen clicks its own row")
  func tapOnLiveScreenOverScrollback() async throws {
    let hosted = try hosted(pane: false)
    defer { hosted.finish() }
    hosted.view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
    for line in 0..<200 { hosted.view.feed(text: "line \(line)\r\n") }
    #expect(hosted.view.getTerminal().getTopVisibleRow() > 0)

    try tap(hosted, at: TerminalCell(column: 6, row: 4))
    await Self.waitFor { hosted.farSide.text.contains("m") }

    #expect(hosted.farSide.text == "\u{1b}[<0;7;5M\u{1b}[<0;7;5m")
    withExtendedLifetime(hosted.window) {}
  }

  /// By design, the first tap on a terminal without the keyboard only takes the keyboard, as
  /// SwiftTerm's own mouse path does. The next tap clicks.
  @Test(
    "a tap on an unfocused terminal only focuses it, and the next tap clicks",
    arguments: [false, true]
  )
  func unfocusedTapOnlyFocuses(pane: Bool) async throws {
    let hosted = try hosted(pane: pane)
    defer { hosted.finish() }
    hosted.view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
    #expect(!hosted.view.isFirstResponder)

    try tap(hosted, at: TerminalCell(column: 6, row: 4), focused: false)
    try? await Task.sleep(for: .milliseconds(300))
    #expect(hosted.farSide.clicks.isEmpty)
    #expect(hosted.farSide.text.isEmpty)

    try tap(hosted, at: TerminalCell(column: 6, row: 4))
    await Self.waitFor { !hosted.farSide.clicks.isEmpty || hosted.farSide.text.contains("m") }
    if pane {
      #expect(hosted.farSide.clicks == [TerminalCell(column: 6, row: 4)])
    } else {
      #expect(hosted.farSide.text == "\u{1b}[<0;7;5M\u{1b}[<0;7;5m")
    }
    withExtendedLifetime(hosted.window) {}
  }

  /// `updateUIView` turns `wantsKeyboardFocus` off inside SwiftUI's render, and a resign there
  /// dismisses the keyboard mid-render and hangs the app on a notice pane, so the resign is
  /// deferred. The hang is
  /// `PaneChatUITests.testSwitchingBackToANoticeWithTheKeyboardUpKeepsTheAppAnswering`.
  @Test("turning keyboard focus off resigns one run-loop turn later")
  func focusOffResignsOneTurnLater() async throws {
    let hosted = try hosted(pane: true)
    defer { hosted.finish() }
    try #require(hosted.view.becomeFirstResponder())

    hosted.view.wantsKeyboardFocus = false
    #expect(hosted.view.isFirstResponder, "The resign must not run inside the update")

    await Self.drainMainQueue()
    #expect(!hosted.view.isFirstResponder, "The resign must still happen")
    withExtendedLifetime(hosted.window) {}
  }

  /// The deferred resign above leaves the terminal first responder for one turn. A tap in
  /// that turn is a tap on a terminal giving the keyboard back, so it does not click.
  @Test("a tap while a resign is pending does not click", arguments: [false, true])
  func tapWhileResignPendingDoesNotClick(pane: Bool) async throws {
    let hosted = try hosted(pane: pane)
    defer { hosted.finish() }
    hosted.view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
    try #require(hosted.view.becomeFirstResponder())

    hosted.view.wantsKeyboardFocus = false
    // `focused: false`, so the helper does not focus the view itself. A resign that ran at
    // once would leave nothing focused, and this would pass for that too.
    try tap(hosted, at: TerminalCell(column: 6, row: 4), focused: false)
    try? await Task.sleep(for: .milliseconds(300))

    #expect(hosted.farSide.clicks.isEmpty)
    #expect(hosted.farSide.text.isEmpty)
    withExtendedLifetime(hosted.window) {}
  }

  /// A responder that keeps first responder until told to let go, so a terminal's first ask
  /// for the keyboard is refused and its retry schedule starts.
  private final class FocusHolder: UIView {
    var letsGo = false
    override var canBecomeFirstResponder: Bool { true }
    override var canResignFirstResponder: Bool { letsGo }
  }

  /// A focus retry queued before `wantsKeyboardFocus` turned off must not take the keyboard
  /// afterwards, or Chat tapped mid-retry puts the terminal's keyboard up over the chat.
  @Test("a focus retry does not take the keyboard after focus is turned off")
  func focusRetryStopsWhenFocusTurnsOff() async throws {
    let hosted = try hosted(pane: true)
    defer { hosted.finish() }
    let holder = FocusHolder()
    hosted.window.addSubview(holder)
    try #require(holder.becomeFirstResponder())

    hosted.view.wantsKeyboardFocus = true
    hosted.view.takeKeyboardFocus()
    #expect(!hosted.view.isFirstResponder, "The first ask must be refused for a retry to queue")

    hosted.view.wantsKeyboardFocus = false
    holder.letsGo = true
    // Past the first two retries, at 100 and 350 ms.
    try? await Task.sleep(for: .milliseconds(600))

    #expect(!hosted.view.isFirstResponder)
    holder.removeFromSuperview()
    withExtendedLifetime(hosted.window) {}
  }

  @Test("a tap on a PTY that asked for no mouse reports sends nothing")
  func ptyTapWithoutMouseModeSendsNothing() async throws {
    let hosted = try hosted(pane: false)
    defer { hosted.finish() }

    try tap(hosted, at: TerminalCell(column: 6, row: 4))
    try? await Task.sleep(for: .milliseconds(300))

    #expect(hosted.farSide.text.isEmpty)
    withExtendedLifetime(hosted.window) {}
  }

  @Test("a tap that ends a selection does not also click", arguments: [false, true])
  func tapEndingSelectionDoesNotClick(pane: Bool) async throws {
    let hosted = try hosted(pane: pane)
    defer { hosted.finish() }
    hosted.view.feed(text: "\u{1b}[?1000h\u{1b}[?1006hfirst row\r\n")
    hosted.view.setSelectionRange(start: Position(col: 0, row: 0), end: Position(col: 4, row: 0))
    #expect(hosted.view.selection.active)

    try tap(hosted, at: TerminalCell(column: 2, row: 0))
    try? await Task.sleep(for: .milliseconds(300))

    #expect(hosted.farSide.clicks.isEmpty)
    #expect(hosted.farSide.text.isEmpty)
    withExtendedLifetime(hosted.window) {}
  }
}
