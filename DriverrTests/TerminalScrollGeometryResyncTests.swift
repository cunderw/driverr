import DriverrCore
import Foundation
import SwiftTerm
import SwiftUI
import Testing
import UIKit

@testable import DriverrTerm

/// `DriverrTerminalUIView.feedKeepingScrollGeometry(_:)` beyond the plain `clear` that
/// `TerminalClearScrollbackTests` drives: the session's sink and a clear inside a chunk that
/// also scrolled (issue #29).
///
/// Hosted, for the same reason as `TerminalClearScrollbackTests`: the geometry lives on
/// SwiftTerm's `UIScrollView`, which only lays out in a real window.
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

  /// Bytes the session has handed its sink, counted on the main actor.
  @MainActor
  final class Consumed {
    var bytes = 0
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
  }
}
