import DriverrCore
import Foundation
import SwiftTerm
import SwiftUI
import Testing
import UIKit

@testable import DriverrTerm

/// `clear` (`ESC[3J ESC[H ESC[2J`) leaves the view's scroll geometry matching the buffer, and
/// `DriverrTerminalUIView.feedKeepingScrollGeometry(_:)` repairs it only then (issue #29).
///
/// `ESC[3J` drops the scrollback, so the buffer shrinks to one screen and `yDisp` falls to
/// 0. The view's `contentSize` and `contentOffset` are derived from the buffer, and if
/// nothing recomputes them the view keeps showing where the old bottom was: blank while new
/// output is short, and at a stale offset once output scrolls.
///
/// Hosted, because the geometry lives on SwiftTerm's `UIScrollView`, which only lays out in
/// a real window. Most tests feed bytes straight into the view, so each read sees the state
/// the bytes left behind with no wait.
@MainActor
@Suite("DriverrTerminalUIView scroll geometry after a feed", .serialized, .timeLimit(.minutes(1)))
struct TerminalScrollGeometryResyncTests {
  private static let clear = "\u{1b}[3J\u{1b}[H\u{1b}[2J"

  private static func terminal(in view: UIView) -> DriverrTerminalUIView? {
    if let terminal = view as? DriverrTerminalUIView { return terminal }
    for subview in view.subviews {
      if let terminal = terminal(in: subview) { return terminal }
    }
    return nil
  }

  private static func lines(_ range: Range<Int>, prefix: String) -> String {
    range.map { "\(prefix) \($0)\r\n" }.joined()
  }

  private static func bytes(_ text: String) -> ArraySlice<UInt8> { ArraySlice(text.utf8) }

  /// The scroll view against the buffer, for a view following the bottom.
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
    var followsBuffer: Bool {
      abs(contentHeight - expectedContentHeight) < 1 && abs(offsetY - expectedOffsetY) < 1
    }

    var description: String {
      "rows \(rows) yDisp \(yDisp) cell \(cellHeight) contentHeight \(contentHeight) "
        + "(want \(expectedContentHeight)) offsetY \(offsetY) (want \(expectedOffsetY)) "
        + "bounds \(boundsHeight)"
    }
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

  /// Whether the last row the scroll view's content height claims is in the buffer.
  private static func lastClaimedRowExists(_ view: DriverrTerminalUIView) -> Bool {
    let terminal = view.getTerminal()
    let cellHeight = view.getOptimalFrameSize().height / CGFloat(max(terminal.rows, 1))
    let claimed = Int((view.contentSize.height / cellHeight).rounded())
    return terminal.getScrollInvariantLine(row: terminal.buffer.totalLinesTrimmed + claimed - 1)
      != nil
  }

  /// Bytes the session has handed its sink, counted on the main actor.
  @MainActor
  final class Consumed {
    var bytes = 0
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

    view.feedKeepingScrollGeometry(ArraySlice(Self.lines(0..<200, prefix: "before").utf8))
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
    view.feedKeepingScrollGeometry(ArraySlice("\u{1b}[3J\u{1b}[H\u{1b}[2J".utf8))
    view.feedKeepingScrollGeometry(ArraySlice("short\r\n".utf8))
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
    view.feedKeepingScrollGeometry(
      ArraySlice(Self.lines(0..<(afterShort.rows + 10), prefix: "after").utf8))
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
  @Test("a clear inside a chunk that also scrolled leaves the view on the buffer")
  func clearInsideAScrollingChunk() throws {
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    defer { continuation.finish() }
    let session = TerminalSession(
      feed: TerminalFeed(output: stream, send: { _ in }, resize: { _ in }, close: {}))
    let window = HostedProbe.window(
      DriverrTerminalView(session: session, wantsKeyboardFocus: false))
    defer { withExtendedLifetime(window) {} }
    let view = try #require(Self.terminal(in: window))
    let rows = view.getTerminal().rows

    // A fresh view starts the chunk at `yDisp` 0, scrolls past a screen, and ends at 0
    // again, so comparing `yDisp` across the chunk sees nothing happen.
    view.feedKeepingScrollGeometry(
      Self.bytes(Self.lines(0..<(rows + 20), prefix: "before") + Self.clear + "short\r\n"))
    window.layoutIfNeeded()
    let after = Geometry(view)
    print("issue29 one chunk: \(after)")
    #expect(after.yDisp == 0)
    #expect(after.followsBuffer, "\(after)")
    #expect(view.scrollGeometryResyncs == 1)
  }

  @Test("bytes from the session reach the view through the entry point")
  func sessionSinkUsesTheEntryPoint() async throws {
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    defer { continuation.finish() }
    let consumed = Consumed()
    let waker = Waker()
    let feed = TerminalFeed(
      output: stream, send: { _ in }, resize: { _ in }, close: {},
      consumed: { count in
        Task { @MainActor in
          consumed.bytes += count
          waker.signal()
        }
      })
    let session = TerminalSession(feed: feed)
    let window = HostedProbe.window(
      DriverrTerminalView(session: session, wantsKeyboardFocus: false))
    defer { withExtendedLifetime(window) {} }
    let view = try #require(Self.terminal(in: window))

    var sent = 0
    func send(_ text: String) {
      sent += text.utf8.count
      continuation.yield(Data(text.utf8))
    }
    /// Waits on the session's own count of bytes handed to the sink.
    func drained() async throws {
      while consumed.bytes < sent {
        let seen = waker.generation
        guard consumed.bytes < sent else { break }
        await waker.next(after: seen)
        try #require(
          !Task.isCancelled, "the sink took \(consumed.bytes) of \(sent) bytes before the limit")
      }
    }

    send(Self.lines(0..<200, prefix: "before"))
    try await drained()
    window.layoutIfNeeded()
    let before = Geometry(view)
    #expect(before.yDisp > 0)
    #expect(before.followsBuffer, "\(before)")

    send(Self.clear)
    send("short\r\n")
    try await drained()
    window.layoutIfNeeded()
    let after = Geometry(view)
    print("issue29 through the session: \(after)")
    #expect(after.yDisp == 0)
    #expect(after.followsBuffer, "\(after)")
    #expect(view.scrollGeometryResyncs == 1)
  }

  /// Hosts a terminal with no session traffic, for tests that feed the view directly.
  private static func hostedView() throws -> (
    UIWindow, DriverrTerminalUIView, AsyncThrowingStream<Data, any Error>.Continuation
  ) {
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    let session = TerminalSession(
      feed: TerminalFeed(output: stream, send: { _ in }, resize: { _ in }, close: {}))
    let window = HostedProbe.window(
      DriverrTerminalView(session: session, wantsKeyboardFocus: false))
    return (window, try #require(Self.terminal(in: window)), continuation)
  }

  @Test("a reader scrolled back at the scrollback cap stays where they are as output arrives")
  func readerAtTheCapStays() throws {
    let (window, view, continuation) = try Self.hostedView()
    defer {
      continuation.finish()
      withExtendedLifetime(window) {}
    }
    let terminal = view.getTerminal()
    let cap = terminal.options.scrollback
    view.feedKeepingScrollGeometry(
      Self.bytes(Self.lines(0..<(cap + terminal.rows + 50), prefix: "fill")))
    window.layoutIfNeeded()
    // Past the cap, every new line trims one off the top.
    let bottom = terminal.buffer.yDisp
    try #require(terminal.buffer.totalLinesTrimmed > 0, "the fill reached the scrollback cap")

    view.scrollUp(lines: 100)
    let reading = terminal.buffer.yDisp
    try #require(reading == bottom - 100)
    let trimmedBefore = terminal.buffer.totalLinesTrimmed

    // One chunk, so the entry point judges ten trims at once.
    view.feedKeepingScrollGeometry(Self.bytes(Self.lines(0..<10, prefix: "more")))
    window.layoutIfNeeded()
    print(
      "issue29 cap: bottom \(bottom) reading \(reading) now \(terminal.buffer.yDisp) "
        + "trimmed \(trimmedBefore) -> \(terminal.buffer.totalLinesTrimmed)")
    #expect(terminal.buffer.totalLinesTrimmed == trimmedBefore + 10)
    // SwiftTerm keeps the reader's text still: the lines they read moved up ten rows.
    #expect(terminal.buffer.yDisp == reading - 10, "the reader was not moved to the bottom")
    #expect(view.scrollGeometryResyncs == 0)
  }

  @Test("a resize or a font change between chunks does not count as a clear")
  func resizeIsNotAClear() throws {
    let (window, view, continuation) = try Self.hostedView()
    defer {
      continuation.finish()
      withExtendedLifetime(window) {}
    }
    let terminal = view.getTerminal()
    view.feedKeepingScrollGeometry(Self.bytes(Self.lines(0..<200, prefix: "a")))
    window.layoutIfNeeded()
    let rowsBefore = terminal.rows

    // Shorter, then a rotation, each followed by output.
    window.frame = CGRect(origin: .zero, size: CGSize(width: 402, height: 600))
    window.layoutIfNeeded()
    view.feedKeepingScrollGeometry(Self.bytes(Self.lines(0..<20, prefix: "b")))
    window.frame = CGRect(origin: .zero, size: CGSize(width: 874, height: 402))
    window.layoutIfNeeded()
    view.feedKeepingScrollGeometry(Self.bytes(Self.lines(0..<20, prefix: "c")))
    try #require(terminal.rows != rowsBefore, "the resize reached the grid")

    // A smaller font regrids at once and corrects the scroll view one main-queue hop later,
    // so until then the scroll view claims rows past the buffer. Bytes that do not scroll,
    // such as an echoed keystroke, land inside that hop and leave the claim as it was.
    view.font = UIFont.monospacedSystemFont(ofSize: 9, weight: .regular)
    try #require(
      !Self.lastClaimedRowExists(view),
      "the font change left the scroll view claiming rows past the buffer")
    view.feedKeepingScrollGeometry(Self.bytes("x"))
    #expect(view.scrollGeometryResyncs == 0)
  }
}
