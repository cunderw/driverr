import DriverrCore
import SwiftTerm

/// Where a vertical drag goes on a feed whose history is not remote: a core terminal or a pty.
///
/// The scroll view can only move through the emulator's own scrollback, and a full-screen
/// program's alternate screen has none, so its history is the program's to move. This is the
/// order herdr's `wheel_routing` uses for a pane: a program that asked for the mouse gets the
/// wheel on either screen, and one that did not gets cursor keys on the alternate screen.
enum TerminalDragRoute: Equatable {
  /// The scroll view moves through the emulator's own scrollback.
  case localScrollback
  /// The program asked for mouse reports, so the drag is wheel events.
  case wheel
  /// A full-screen program with no mouse, so the drag is cursor keys.
  case arrowKeys

  /// X10 counts as no mouse: it reports presses of real buttons, and a wheel is not one.
  static func route(for terminal: Terminal) -> TerminalDragRoute {
    switch terminal.mouseMode {
    case .vt200, .buttonEventTracking, .anyEvent: .wheel
    case .off, .x10: terminal.isCurrentBufferAlternate ? .arrowKeys : .localScrollback
    }
  }

  /// Sends `lines` of a drag to the program, one report or key per line.
  ///
  /// A wheel has no release. The arrows are by hand because `less` ignores `CSI B` and moves on
  /// `SS3 B`, and SwiftTerm has nothing public that spells them for the current mode.
  ///
  /// - Parameters:
  ///   - direction: `.up` is older output, which is the wheel going up.
  ///   - cell: counted from 0; `sendEvent` adds the 1 a mouse report counts from.
  ///   - pixelX: from the viewport's left edge, in device pixels.
  ///   - pixelY: from the viewport's top edge, in device pixels.
  static func send(
    _ direction: ScrollDirection,
    lines: Int,
    at cell: TerminalCell,
    pixelX: Int,
    pixelY: Int,
    to terminal: Terminal
  ) {
    switch route(for: terminal) {
    case .localScrollback:
      break
    case .wheel:
      let flags = terminal.encodeButton(
        button: direction == .up ? 4 : 5, release: false, shift: false, meta: false, control: false
      )
      for _ in 0..<lines {
        terminal.sendEvent(
          buttonFlags: flags, x: cell.column, y: cell.row, pixelX: pixelX, pixelY: pixelY
        )
      }
    case .arrowKeys:
      let introducer = terminal.applicationCursor ? "\u{1b}O" : "\u{1b}["
      let key = introducer + (direction == .up ? "A" : "B")
      for _ in 0..<lines { terminal.sendResponse(text: key) }
    }
  }
}
