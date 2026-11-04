import DriverrCore
import Foundation
import SwiftTerm
import SwiftUI
import Testing
import UIKit

@testable import DriverrTerm

/// Entering the alternate screen (`ESC[?1049h`, as `less` does) draws the program's first row
/// at the top of the view, whatever the view was showing of the normal buffer (issue #73).
///
/// The misdraw needs the grid to have **shrunk** since the alternate screen was last left,
/// as it does when the keyboard comes up, and a program that **scrolls** its screen into place
/// with line feeds, as `less` and `man` do. SwiftTerm's `Buffer.resize` raised the inactive
/// alternate buffer's line capacity when the grid grew and never lowered it when the grid
/// shrank, because the buffer is empty while inactive and the lowering sat behind
/// `lines.count > 0`. The program's line feeds then grew the alternate buffer back to the old
/// row count, `yDisp` followed, and the scroll view showed the screen clamped to its end: the
/// partial-row remainder moved from the bottom of the view to the top, and the screen drew
/// that far low. Measured on a simulator: 36 rows shrunk to 25, `yDisp` 11, offset 191 where
/// a grid starting at row 11 needs 198, row 0 drawn 7 pt low. Fixed in the SwiftTerm fork.
///
/// Scrolling back is not part of it. The scrolled-back starts stay because the issue reported
/// it from there, and leaving the alternate screen must return to that buffer.
@MainActor
@Suite("DriverrTerminalUIView alternate screen geometry", .serialized, .timeLimit(.minutes(1)))
struct TerminalAlternateScreenGeometryTests {
  enum Start: String, CaseIterable, CustomTestStringConvertible {
    /// Following the bottom of a long buffer.
    case atBottom
    /// `scrollUp(lines:)`, row-aligned, which turns SwiftTerm's manual scrolling on.
    case scrolledBackByRows
    /// Scrolled back by rows, then left at a part-row offset.
    case scrolledBackPartRow
    /// At the bottom, then the view shrank (a keyboard came up) before less started.
    case shrunk
    /// Scrolled back, then the view shrank before less started.
    case scrolledBackThenShrunk
    var testDescription: String { rawValue }
  }

  enum Host: String, CaseIterable, CustomTestStringConvertible {
    /// `HostedProbe.window`, with the root ignoring the safe area.
    case plain
    /// Inside a `NavigationStack` with a title, as the pane screen is pushed.
    case navigation
    var testDescription: String { rawValue }
  }

  private static func terminal(in view: UIView) -> DriverrTerminalUIView? {
    if let terminal = view as? DriverrTerminalUIView { return terminal }
    for subview in view.subviews {
      if let terminal = terminal(in: subview) { return terminal }
    }
    return nil
  }

  private static func bytes(_ text: String) -> ArraySlice<UInt8> { ArraySlice(text.utf8) }

  /// A full alternate screen whose row 0 is a red bar, written the way `less` writes one:
  /// clear, then lines separated by line feeds, more of them than the screen has rows, so
  /// the screen scrolls into place. A screen drawn with absolute cursor moves never scrolls
  /// and cannot show the bug.
  private static func scrollingScreen(rows: Int, cols: Int) -> String {
    var lines: [String] = (0..<20).map { "gone \($0)" }
    lines.append("\u{1b}[41m" + String(repeating: " ", count: cols) + "\u{1b}[0m")
    lines += (1..<rows).map { "row \($0)" }
    return "\u{1b}[H\u{1b}[2J" + lines.joined(separator: "\r\n")
  }

  /// The first y, in the view's visible bounds, where the red bar is painted, or `nil`.
  private static func firstRedY(_ view: DriverrTerminalUIView) -> Int? {
    view.setNeedsDisplay()
    view.layoutIfNeeded()
    let width = Int(view.bounds.width)
    let height = Int(view.bounds.height)
    guard width > 0, height > 0,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    // UIKit coordinates, top-left origin, the visible bounds only.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.translateBy(x: -view.bounds.minX, y: -view.bounds.minY)
    view.layer.render(in: context)
    guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    // Memory row 0 is the top of the image after the flip above.
    let x = min(width - 1, 20)
    for y in 0..<height {
      let i = y * width * 4 + x * 4
      let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
      if r > 100, r > 2 * g, r > 2 * b { return y }
    }
    return nil
  }

  private static func state(_ view: DriverrTerminalUIView) -> String {
    let t = view.getTerminal()
    return "alt \(t.isCurrentBufferAlternate) rows \(t.rows) yDisp \(t.buffer.yDisp) "
      + "cell \(view.getOptimalFrameSize().height / CGFloat(max(t.rows, 1))) "
      + "contentHeight \(view.contentSize.height) offsetY \(view.contentOffset.y) "
      + "bounds \(view.bounds.height) inset \(view.adjustedContentInset)"
  }

  @Test(
    "less opened from any scroll position draws its first row at the top",
    arguments: Host.allCases, Start.allCases)
  func alternateScreenStartsAtTheTop(host: Host, start: Start) throws {
    // A part-row remainder below the grid, and an exact multiple.
    for height in [874.0, 864.0] { try check(host: host, start: start, height: height) }
  }

  private func check(host: Host, start: Start, height: Double) throws {
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    defer { continuation.finish() }
    let session = TerminalSession(
      feed: TerminalFeed(output: stream, send: { _ in }, resize: { _ in }, close: {}))
    let terminalView = DriverrTerminalView(session: session, wantsKeyboardFocus: false)
    let window =
      host == .navigation
      ? HostedProbe.window(
        NavigationStack { terminalView.navigationTitle("pane") },
        size: CGSize(width: 402, height: height))
      : HostedProbe.window(terminalView, size: CGSize(width: 402, height: height))
    defer { withExtendedLifetime(window) {} }
    let view = try #require(Self.terminal(in: window))
    let terminal = view.getTerminal()
    let cell = view.getOptimalFrameSize().height / CGFloat(max(terminal.rows, 1))
    let fullRows = terminal.rows

    view.feedKeepingScrollGeometry(
      Self.bytes((0..<200).map { "fill \($0)\r\n" }.joined()))
    window.layoutIfNeeded()
    switch start {
    case .atBottom: break
    case .scrolledBackByRows: view.scrollUp(lines: 50)
    case .scrolledBackPartRow:
      view.scrollUp(lines: 50)
      view.contentOffset.y += cell * 0.4
    case .shrunk, .scrolledBackThenShrunk:
      if start == .scrolledBackThenShrunk { view.scrollUp(lines: 50) }
      // About what the keyboard takes from a phone's terminal.
      window.frame = CGRect(origin: .zero, size: CGSize(width: 402, height: height - 340))
      window.layoutIfNeeded()
      try #require(terminal.rows < fullRows, "the grid did not shrink: \(Self.state(view))")
    }
    window.layoutIfNeeded()

    view.feedKeepingScrollGeometry(Self.bytes("\u{1b}[?1049h"))
    view.feedKeepingScrollGeometry(
      Self.bytes(Self.scrollingScreen(rows: terminal.rows, cols: terminal.cols)))
    window.layoutIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    window.layoutIfNeeded()
    let red = Self.firstRedY(view)
    #expect(terminal.isCurrentBufferAlternate)
    // The alternate screen is exactly one grid: its first row is the buffer's first line, its
    // content is one grid tall, and its only right offset is 0.
    #expect(terminal.buffer.yDisp == 0, "\(Self.state(view))")
    #expect(
      abs(view.contentSize.height - CGFloat(terminal.rows) * cell) < 1, "\(Self.state(view))")
    #expect(abs(view.contentOffset.y) < 1, "\(Self.state(view))")
    #expect(red == 0, "row 0 painted at y \(String(describing: red)), \(Self.state(view))")

    // Leaving less: the view follows the normal buffer again.
    view.feedKeepingScrollGeometry(Self.bytes("\u{1b}[?1049l"))
    window.layoutIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    let yDisp = terminal.buffer.yDisp
    let contentHeight = Double(view.contentSize.height)
    let wantOffset = min(
      Double(CGFloat(yDisp) * cell),
      max(0, contentHeight - Double(view.bounds.height) + Double(view.adjustedContentInset.bottom)))
    #expect(!terminal.isCurrentBufferAlternate)
    #expect(abs(Double(view.contentOffset.y) - wantOffset) < 1, "\(Self.state(view))")
  }
}
