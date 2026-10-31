import DriverrCore
import Foundation
import SwiftTerm
import Testing

@testable import DriverrTerm

/// A drag on a feed with no `scroll`, a core terminal or a PTY, against a headless `Terminal`.
///
/// The mode strings are what a core painted for each program, in order.
@Suite("TerminalDragRoute")
struct TerminalDragRouteTests {
  /// Claude Code with `"tui": "fullscreen"`.
  private static let fullscreenClaude =
    "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1004h\u{1b}[?1006h\u{1b}[?2004h"
  /// `less`, which also turns on application cursor keys.
  private static let less = "\u{1b}[?1049h\u{1b}[?1h"

  private final class Recorder: TerminalDelegate {
    var sent: [UInt8] = []
    func send(source: Terminal, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
    var text: String { String(decoding: sent, as: UTF8.self) }
  }

  /// A phone-sized terminal after `output`. Returns the delegate so it outlives the terminal's
  /// weak reference.
  private func terminal(after output: String) -> (Terminal, Recorder) {
    let recorder = Recorder()
    let terminal = Terminal(delegate: recorder, options: TerminalOptions(cols: 47, rows: 22))
    terminal.feed(text: output)
    recorder.sent.removeAll()
    return (terminal, recorder)
  }

  private func dragged(
    _ direction: ScrollDirection,
    lines: Int,
    after output: String
  ) -> String {
    let (terminal, recorder) = terminal(after: output)
    TerminalDragRoute.send(
      direction,
      lines: lines,
      at: TerminalCell(column: 9, row: 4),
      pixelX: 0,
      pixelY: 0,
      to: terminal
    )
    return recorder.text
  }

  private var shellOutput: String {
    (1...2000).map(String.init).joined(separator: "\r\n") + "\r\n"
  }

  /// Why a drag does nothing today: the screen it would scroll has no lines above it.
  @Test("the alternate screen has no scrollback for a scroll view to move through")
  func alternateScreenHasNoScrollback() {
    let (terminal, _) = terminal(after: shellOutput + Self.fullscreenClaude)
    #expect(terminal.isCurrentBufferAlternate)
    #expect(terminal.buffer.yDisp == 0)
    #expect(terminal.mouseMode == .anyEvent)
  }

  @Test("fullscreen Claude takes a drag as the wheel")
  func fullscreenClaudeTakesTheWheel() {
    let (terminal, _) = terminal(after: Self.fullscreenClaude)
    #expect(TerminalDragRoute.route(for: terminal) == .wheel)
  }

  /// Dragging down reveals older output, which is the wheel going up. Measured against a real
  /// Claude Code: one SGR 64 is one line back, one SGR 65 is one line forward, no release.
  @Test("a drag down is one SGR 64 per line, and a drag up one SGR 65", arguments: [
    (ScrollDirection.up, "\u{1b}[<64;10;5M\u{1b}[<64;10;5M\u{1b}[<64;10;5M"),
    (ScrollDirection.down, "\u{1b}[<65;10;5M\u{1b}[<65;10;5M\u{1b}[<65;10;5M"),
  ])
  func wheelBytes(direction: ScrollDirection, expected: String) {
    #expect(dragged(direction, lines: 3, after: Self.fullscreenClaude) == expected)
  }

  @Test("a shell's output stays in the scroll view")
  func shellKeepsLocalScrollback() {
    let (terminal, _) = terminal(after: shellOutput)
    #expect(terminal.buffer.yDisp > 0)
    #expect(TerminalDragRoute.route(for: terminal) == .localScrollback)
  }

  @Test("a shell's drag sends nothing to the shell")
  func shellSendsNothing() {
    #expect(dragged(.up, lines: 3, after: shellOutput).isEmpty)
  }

  @Test("less takes a drag as cursor keys")
  func lessTakesArrowKeys() {
    let (terminal, _) = terminal(after: Self.less)
    #expect(TerminalDragRoute.route(for: terminal) == .arrowKeys)
  }

  /// `less` ignored `CSI B` and moved on `SS3 B`.
  @Test("cursor keys follow application cursor mode", arguments: [
    (Self.less, "\u{1b}OA\u{1b}OA"),
    ("\u{1b}[?1049h", "\u{1b}[A\u{1b}[A"),
  ])
  func arrowBytes(output: String, expected: String) {
    #expect(dragged(.up, lines: 2, after: output) == expected)
  }

  /// herdr's order: reporting comes before the screen, so a program in the normal screen that
  /// asked for the mouse, such as Claude Code without fullscreen, gets the wheel too.
  @Test("a mouse mode on the normal screen takes a drag as the wheel")
  func normalScreenMouseModeTakesTheWheel() {
    let (terminal, _) = terminal(after: shellOutput + "\u{1b}[?1000h\u{1b}[?1006h")
    #expect(TerminalDragRoute.route(for: terminal) == .wheel)
  }

  /// X10 reports presses of real buttons. Ghostty's encoder drops a wheel there, so herdr sends
  /// nothing, and the scrollback stays reachable here.
  @Test("X10 mode on the normal screen stays local")
  func x10StaysLocal() {
    let (terminal, _) = terminal(after: "\u{1b}[?9h")
    #expect(TerminalDragRoute.route(for: terminal) == .localScrollback)
  }
}
