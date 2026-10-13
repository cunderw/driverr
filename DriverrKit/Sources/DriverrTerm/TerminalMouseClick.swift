import DriverrCore
import SwiftTerm

/// A tap as a left click, for a program on a PTY that asked for mouse reports.
///
/// `allowMouseReporting` is off so selection and scrolling stay on the phone, which also
/// stops SwiftTerm's tap from reaching the program. This sends that click and nothing
/// else. A herdr pane's click goes through `TerminalFeed.click` instead.
enum TerminalMouseClick {
  /// Sends a press and a release at `cell` if the program asked for button events, and
  /// reports whether it did.
  ///
  /// The gate restates SwiftTerm's non-public `MouseMode.sendButtonPress()`: X10 mode
  /// (`?9h`) and no mode send nothing. `Terminal.sendEvent` uses the program's chosen
  /// encoding. The pixel position is read only in SGR pixel mode (`?1016h`).
  ///
  /// - Parameters:
  ///   - cell: counted from 0; `sendEvent` adds the 1 a mouse report counts from.
  ///   - pixelX: from the viewport's left edge, in device pixels.
  ///   - pixelY: from the viewport's top edge, in device pixels.
  @discardableResult
  static func send(at cell: TerminalCell, pixelX: Int, pixelY: Int, to terminal: Terminal) -> Bool {
    switch terminal.mouseMode {
    case .vt200, .buttonEventTracking, .anyEvent: break
    case .off, .x10: return false
    }
    // Every mode that passes the gate above also reports a release.
    for release in [false, true] {
      let flags = terminal.encodeButton(
        button: 0, release: release, shift: false, meta: false, control: false
      )
      terminal.sendEvent(
        buttonFlags: flags, x: cell.column, y: cell.row, pixelX: pixelX, pixelY: pixelY
      )
    }
    return true
  }
}
