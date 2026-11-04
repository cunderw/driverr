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
/// Red on 9b42a8a in one cell only: `alwaysAdjust` x `scrollAnimating`. A `UIScrollView`
/// animation still in flight survives SwiftTerm's `contentOffset` write in `bufferActivated`
/// and settles at UIKit's own clamp, `-adjustedContentInset.top`, so the screen draws that far
/// low. With no top inset the clamp is 0, which is why `plain` and `navigation` pass.
///
/// **This probe passes on 9b42a8a.** It reproduces five starting states the hosted tier
/// can reach (at the bottom, scrolled back by rows, at a part-row offset, an animated scroll in
/// flight, scrolled back then shrunk) at a 10 pt remainder and at an exact multiple, and SwiftTerm
/// lands every one at offset 0 with row 0 painted at y 0. The device misdraw needs a state this
/// tier cannot make (a real drag's tracking or deceleration, or the device's insets).
@MainActor
@Suite("DriverrTerminalUIView alternate screen geometry", .serialized, .timeLimit(.minutes(1)))
struct TerminalAlternateScreenGeometryTests {
  enum Start: String, CaseIterable, CustomTestStringConvertible {
    /// Following the bottom of a long buffer.
    case atBottom
    /// `scrollUp(lines:)`, row-aligned, which turns SwiftTerm's manual scrolling on.
    case scrolledBackByRows
    /// Scrolled back by rows, then left at a part-row offset. A real drag also sets SwiftTerm's
    /// within-row remainder, which needs `isTracking` and cannot be made in-process.
    case scrolledBackPartRow
    /// Scrolled back by rows, with an animated scroll still moving the offset when the bytes
    /// arrive, as a fling's deceleration can be.
    case scrollAnimating
    /// Scrolled back, then the view shrank (a keyboard came up) before less started.
    case scrolledBackThenShrunk
    var testDescription: String { rawValue }
  }

  enum Host: String, CaseIterable, CustomTestStringConvertible {
    /// `HostedProbe.window`, with the root ignoring the safe area.
    case plain
    /// Inside a `NavigationStack` with a title, as the pane screen is pushed.
    case navigation
    /// Plain, with the scroll view told to adjust for the safe area on every axis.
    case alwaysAdjust
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

  /// A full alternate screen whose row 0 is a red bar and whose other rows are plain text.
  private static func screen(rows: Int, cols: Int) -> String {
    var text = "\u{1b}[H\u{1b}[2J\u{1b}[41m" + String(repeating: " ", count: cols) + "\u{1b}[0m"
    for row in 1..<rows { text += "\u{1b}[\(row + 1);1Hrow \(row)" }
    return text
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
      + "bounds \(view.bounds.height) inset \(view.adjustedContentInset) "
      + "safeArea \(view.safeAreaInsets) behaviour \(view.contentInsetAdjustmentBehavior.rawValue) "
      + "scrollEnabled \(view.isScrollEnabled)"
  }

  @Test(
    "less opened from any scroll position draws its first row at the top",
    arguments: Host.allCases, Start.allCases)
  func alternateScreenStartsAtTheTop(host: Host, start: Start) throws {
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
    if host == .alwaysAdjust { view.contentInsetAdjustmentBehavior = .always }
    let terminal = view.getTerminal()
    let cell = view.getOptimalFrameSize().height / CGFloat(max(terminal.rows, 1))

    view.feedKeepingScrollGeometry(
      Self.bytes((0..<200).map { "fill \($0)\r\n" }.joined()))
    window.layoutIfNeeded()
    switch start {
    case .atBottom: break
    case .scrolledBackByRows: view.scrollUp(lines: 50)
    case .scrolledBackPartRow:
      view.scrollUp(lines: 50)
      view.contentOffset.y += cell * 0.4
    case .scrollAnimating:
      view.scrollUp(lines: 50)
      let from = view.contentOffset.y
      view.setContentOffset(CGPoint(x: 0, y: from - cell * 10), animated: true)
      // Until the animation has moved the offset, so the bytes land mid-animation.
      for _ in 0..<50 where abs(view.contentOffset.y - from) < 1 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
      }
    case .scrolledBackThenShrunk:
      view.scrollUp(lines: 50)
      window.frame = CGRect(origin: .zero, size: CGSize(width: 402, height: height - 340))
      window.layoutIfNeeded()
    }
    if start != .scrollAnimating { window.layoutIfNeeded() }
    print("issue73 \(host) \(start) \(height) before: \(Self.state(view))")

    view.feedKeepingScrollGeometry(Self.bytes("\u{1b}[?1049h"))
    print("issue73 \(host) \(start) \(height) after 1049h: \(Self.state(view))")
    view.feedKeepingScrollGeometry(Self.bytes(Self.screen(rows: terminal.rows, cols: terminal.cols)))
    window.layoutIfNeeded()
    print("issue73 \(host) \(start) \(height) after screen: \(Self.state(view))")
    RunLoop.current.run(until: Date().addingTimeInterval(start == .scrollAnimating ? 1 : 0.05))
    window.layoutIfNeeded()
    let red = Self.firstRedY(view)
    print("issue73 \(host) \(start) \(height) after tick: \(Self.state(view)) firstRedY \(String(describing: red))")
    #expect(terminal.isCurrentBufferAlternate)
    // The alternate screen is exactly one grid, so its only right offset is 0.
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
    print("issue73 \(host) \(start) \(height) after 1049l: \(Self.state(view)) wantOffset \(wantOffset)")
    #expect(!terminal.isCurrentBufferAlternate)
    #expect(abs(Double(view.contentOffset.y) - wantOffset) < 1, "\(Self.state(view))")
  }
}
