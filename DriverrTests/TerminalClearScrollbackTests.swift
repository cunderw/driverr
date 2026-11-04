import DriverrCore
import Foundation
import SwiftTerm
import SwiftUI
import Testing
import UIKit

@testable import DriverrTerm

/// `clear` (`ESC[3J ESC[H ESC[2J`) leaves the view's scroll geometry matching the buffer.
///
/// `ESC[3J` drops the scrollback, so the buffer shrinks to one screen and `yDisp` falls to
/// 0. The view's `contentSize` and `contentOffset` are derived from the buffer, and if
/// nothing recomputes them the view keeps showing where the old bottom was: blank while new
/// output is short, and at a stale offset once output scrolls (issue #29).
///
/// Hosted, because the geometry lives on SwiftTerm's `UIScrollView`, which only lays out in
/// a real window. Bytes are fed straight into the view, so each read sees the state the
/// bytes left behind with no wait.
@MainActor
@Suite("DriverrTerminalUIView after clear", .serialized)
struct TerminalClearScrollbackTests {
  private static func terminal(in view: UIView) -> DriverrTerminalUIView? {
    if let terminal = view as? DriverrTerminalUIView { return terminal }
    for subview in view.subviews {
      if let terminal = terminal(in: subview) { return terminal }
    }
    return nil
  }

  /// What the view shows, against what the buffer says it should.
  private struct Geometry: CustomStringConvertible {
    let rows: Int
    let yDisp: Int
    let cellHeight: Double
    let contentHeight: Double
    let offsetY: Double
    let boundsHeight: Double
    let insetBottom: Double

    @MainActor init(_ view: DriverrTerminalUIView) {
      let terminal = view.getTerminal()
      rows = terminal.rows
      yDisp = terminal.buffer.yDisp
      cellHeight = Double(view.getOptimalFrameSize().height) / Double(max(terminal.rows, 1))
      contentHeight = Double(view.contentSize.height)
      offsetY = Double(view.contentOffset.y)
      boundsHeight = Double(view.bounds.height)
      insetBottom = Double(view.adjustedContentInset.bottom)
    }

    /// Following the bottom, the buffer is `yDisp + rows` lines.
    var expectedContentHeight: Double { Double(yDisp + rows) * cellHeight }
    /// SwiftTerm's `updateScroller`: the row offset, clamped to the reachable maximum.
    var expectedOffsetY: Double {
      min(Double(yDisp) * cellHeight, max(0, expectedContentHeight - boundsHeight + insetBottom))
    }

    var description: String {
      "rows \(rows) yDisp \(yDisp) cell \(cellHeight) contentHeight \(contentHeight) "
        + "(want \(expectedContentHeight)) offsetY \(offsetY) (want \(expectedOffsetY)) "
        + "bounds \(boundsHeight)"
    }
  }

  private static func lines(_ range: Range<Int>, prefix: String) -> String {
    range.map { "\(prefix) \($0)\r\n" }.joined()
  }

  /// How many distinct colours the view paints in its top `rows` rows, as on screen.
  ///
  /// A blank band is one colour, the background. Rendered from the layer, so it reads what
  /// `draw(_:)` produced for the visible bounds, not what the buffer holds.
  private static func coloursInTopRows(_ view: DriverrTerminalUIView, rows: Int, cellHeight: Double)
    -> Int
  {
    view.setNeedsDisplay()
    view.layoutIfNeeded()
    let size = view.bounds.size
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
      context.cgContext.translateBy(x: -view.bounds.minX, y: -view.bounds.minY)
      view.layer.render(in: context.cgContext)
    }
    guard let cg = image.cgImage, let data = cg.dataProvider?.data,
      let bytes = CFDataGetBytePtr(data)
    else { return 0 }
    let band = min(cg.height, Int(Double(rows) * cellHeight))
    var colours = Set<UInt32>()
    for y in 0..<band {
      for x in 0..<cg.width {
        let i = y * cg.bytesPerRow + x * 4
        colours.insert(
          UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8
            | UInt32(bytes[i + 3]))
      }
    }
    return colours.count
  }

  @Test("clear, then short output, then a screenful: the view follows the buffer")
  func clearKeepsGeometry() async throws {
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    defer { continuation.finish() }
    let feed = TerminalFeed(
      output: stream, send: { _ in }, resize: { _ in }, close: {}, scroll: nil, click: nil)
    let session = TerminalSession(feed: feed)
    let window = HostedProbe.window(
      DriverrTerminalView(session: session, wantsKeyboardFocus: false)
    )
    defer { withExtendedLifetime(window) {} }
    let view = try #require(Self.terminal(in: window))

    view.feed(text: Self.lines(0..<200, prefix: "before"))
    window.layoutIfNeeded()
    let before = Geometry(view)
    print("issue29 before clear: \(before)")
    #expect(before.yDisp > 0)
    #expect(abs(before.contentHeight - before.expectedContentHeight) < 1, "\(before)")
    #expect(abs(before.offsetY - before.expectedOffsetY) < 1, "\(before)")
    let beforeColours = Self.coloursInTopRows(view, rows: 3, cellHeight: before.cellHeight)
    print("issue29 before clear: colours in top rows \(beforeColours)")
    #expect(beforeColours > 1, "the probe sees drawn text before clear")

    // What `clear` sends, then a short command's output.
    view.feed(text: "\u{1b}[3J\u{1b}[H\u{1b}[2J")
    view.feed(text: "short\r\n")
    window.layoutIfNeeded()
    let afterShort = Geometry(view)
    print("issue29 after clear + short: \(afterShort)")
    #expect(afterShort.yDisp == 0)
    #expect(
      abs(afterShort.contentHeight - afterShort.expectedContentHeight) < 1, "\(afterShort)")
    #expect(abs(afterShort.offsetY - afterShort.expectedOffsetY) < 1, "\(afterShort)")
    let shortColours = Self.coloursInTopRows(view, rows: 3, cellHeight: afterShort.cellHeight)
    print("issue29 after clear + short: colours in top rows \(shortColours)")
    #expect(shortColours > 1, "the short output is drawn at the top of the view")

    // Output past the first screen scrolls the buffer.
    view.feed(text: Self.lines(0..<(afterShort.rows + 10), prefix: "after"))
    window.layoutIfNeeded()
    let afterLong = Geometry(view)
    print("issue29 after clear + long: \(afterLong)")
    #expect(afterLong.yDisp > 0)
    #expect(abs(afterLong.contentHeight - afterLong.expectedContentHeight) < 1, "\(afterLong)")
    #expect(abs(afterLong.offsetY - afterLong.expectedOffsetY) < 1, "\(afterLong)")
    let longColours = Self.coloursInTopRows(view, rows: 3, cellHeight: afterLong.cellHeight)
    print("issue29 after clear + long: colours in top rows \(longColours)")
    #expect(longColours > 1, "the long output is drawn")
  }
}
