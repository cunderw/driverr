import DriverrTerm
import SwiftTerm
import SwiftUI
import Testing
import UIKit

@testable import Driverr

/// The edit menu's Copy says that it happened.
///
/// SwiftTerm's `copy(_:)` clears the selection as it copies, so a Copy that worked and a
/// menu that was dismissed leave the same screen. `DriverrTerminalUIView.copy(_:)` tells a
/// `TerminalCopyNotice`, and `TerminalScreen` draws it over the terminals with
/// `copyNoticeOverlay`. The timing is `TerminalCopyNoticeTests` in `DriverrKit`; these
/// cases pin the wiring and the placement.
///
/// Hosted, because `copy(_:)` is a `UIResponder` action on a view in a real window and the
/// overlay's claim is about resolved frames. These cases write to the simulator's general
/// pasteboard without reading it first, because reading another app's content can raise the
/// paste permission prompt.
@MainActor
@Suite("Terminal copy notice")
struct TerminalCopyTests {
  /// A notice whose hide never fires, so a case reads the state a Copy left without racing
  /// the two-second timer.
  private static func heldNotice() -> TerminalCopyNotice {
    TerminalCopyNotice(schedule: { _, _ in })
  }

  private struct Hosted {
    let window: UIWindow
    let view: DriverrTerminalUIView
    let finish: () -> Void
  }

  private func hosted<Content: View>(
    notice: TerminalCopyNotice,
    size: CGSize = HostedProbe.phone,
    wrap: (DriverrTerminalView) -> Content
  ) throws -> Hosted {
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    let feed = TerminalFeed(output: stream, send: { _ in }, resize: { _ in }, close: {})
    let session = TerminalSession(feed: feed)
    let window = HostedProbe.window(
      wrap(DriverrTerminalView(session: session, wantsKeyboardFocus: false, copyNotice: notice)),
      size: size
    )
    let view = try #require(Self.terminal(in: window))
    return Hosted(window: window, view: view) { continuation.finish() }
  }

  private static func terminal(in view: UIView) -> DriverrTerminalUIView? {
    if let terminal = view as? DriverrTerminalUIView { return terminal }
    for subview in view.subviews {
      if let terminal = terminal(in: subview) { return terminal }
    }
    return nil
  }

  private static func pump() {
    for _ in 0..<5 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
  }

  @Test("Copy puts the selection on the pasteboard and shows the notice")
  func copyShowsNotice() throws {
    let notice = Self.heldNotice()
    let hosted = try hosted(notice: notice) { $0 }
    defer { hosted.finish() }
    hosted.view.feed(text: "first row\r\nsecond row\r\n")

    hosted.view.selection.selectAll()
    let selected = hosted.view.selection.getSelectedText()
    #expect(selected.contains("second row"))
    #expect(!notice.isShowing)

    hosted.view.copy(nil)

    #expect(UIPasteboard.general.string == selected)
    #expect(notice.isShowing)
    #expect(!hosted.view.selection.active, "SwiftTerm's copy still clears the selection")
    withExtendedLifetime(hosted.window) {}
  }

  /// A Copy over empty rows says nothing: "Copied to clipboard" over an empty paste is no use.
  @Test("Copy over blank rows shows no notice")
  func blankCopyShowsNothing() throws {
    let notice = Self.heldNotice()
    let hosted = try hosted(notice: notice) { $0 }
    defer { hosted.finish() }

    hosted.view.selection.selectAll()
    hosted.view.copy(nil)

    #expect(!notice.isShowing)
    withExtendedLifetime(hosted.window) {}
  }

  /// A copy the far side asked for (OSC 52) is not the reader's Copy, so it says nothing.
  @Test("an OSC 52 copy from the far side shows no notice")
  func remoteCopyShowsNothing() throws {
    let notice = Self.heldNotice()
    let hosted = try hosted(notice: notice) { $0 }
    defer { hosted.finish() }

    // "remote" in base64.
    hosted.view.feed(text: "\u{1b}]52;c;cmVtb3Rl\u{07}")
    Self.pump()

    #expect(UIPasteboard.general.string == "remote")
    #expect(!notice.isShowing)
    withExtendedLifetime(hosted.window) {}
  }

  /// The notice lies over the top of the terminal and resizes nothing, on both sizes. A band
  /// would shrink the grid and send the far side a SIGWINCH as it came and another as it went.
  @Test(
    "the notice overlays the top of the terminal without resizing it",
    arguments: [false, true]
  )
  func overlayKeepsTheGrid(pad: Bool) throws {
    let size = pad ? HostedProbe.pad : HostedProbe.phone
    let notice = Self.heldNotice()
    var barFrame: CGRect?
    let hosted = try hosted(notice: notice, size: size) { terminal in
      terminal.copyNoticeOverlay(
        notice,
        bar: TerminalCopyNoticeBar().measuredFrame { barFrame = $0 }
      )
    }
    defer { hosted.finish() }

    let frameBefore = hosted.view.convert(hosted.view.bounds, to: nil)
    let terminal = hosted.view.getTerminal()
    let gridBefore = (terminal.cols, terminal.rows)
    #expect(frameBefore.height > 0)
    #expect(barFrame == nil)

    notice.copied()
    Self.pump()

    let bar = try #require(barFrame, "the notice never appeared")
    #expect(hosted.view.convert(hosted.view.bounds, to: nil) == frameBefore)
    #expect(terminal.cols == gridBefore.0 && terminal.rows == gridBefore.1)
    #expect(bar.minY == frameBefore.minY)
    #expect(bar.width == frameBefore.width)
    #expect(bar.height > 0 && bar.height < frameBefore.height / 4)
    withExtendedLifetime(hosted.window) {}
  }
}
