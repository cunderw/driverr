import Foundation
@testable import SwiftTerm
import Testing

/// The SwiftTerm fork's guard for issue #73, on the kit tier so hosted CI runs it.
///
/// The alternate buffer is empty while inactive. Upstream's `Buffer.resize` lowers a buffer's
/// line capacity only when it holds lines, so after the keyboard shrank the grid the next
/// alternate screen grew back to the old row count as `less` scrolled its first screen in,
/// `yDisp` followed, and the screen drew low. A pin that loses the fork's fix fails here.
/// `TerminalAlternateScreenGeometryTests` in the hosted tier checks the drawn geometry.
@Suite("SwiftTerm alternate screen after a shrink")
struct AlternateScreenShrinkTests {
  /// `Terminal` holds its delegate weakly, so the test keeps it alive.
  private final class Sink: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
  }

  @Test("less scrolling its first screen in after the grid shrank stays one grid tall")
  func alternateScreenStaysOneGridTallAfterAShrink() {
    let sink = Sink()
    let terminal = Terminal(delegate: sink, options: TerminalOptions(cols: 80, rows: 36))
    terminal.resize(cols: 80, rows: 25)

    terminal.feed(text: "\u{1b}[?1049h\u{1b}[H\u{1b}[2J")
    terminal.feed(text: (0..<40).map { "line \($0)\r\n" }.joined())

    #expect(terminal.isCurrentBufferAlternate)
    #expect(terminal.buffer.yDisp == 0)
    #expect(terminal.buffer.yBase == 0)
    withExtendedLifetime(sink) {}
  }
}
