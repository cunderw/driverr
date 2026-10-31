import DriverrCore
import SwiftTerm

/// Where a vertical drag goes on a feed whose history is not remote.
///
/// **A stub of today's behaviour, for the regression test on this branch.** Every drag is left
/// to the scroll view, which has nothing to scroll on the alternate screen.
enum TerminalDragRoute: Equatable {
  /// The scroll view moves through the emulator's own scrollback.
  case localScrollback
  /// The program asked for mouse reports, so the drag is wheel events.
  case wheel
  /// A full-screen program with no mouse, so the drag is cursor keys.
  case arrowKeys

  static func route(for terminal: Terminal) -> TerminalDragRoute { .localScrollback }

  /// Sends `lines` of a drag to the program, one report or key per line.
  static func send(
    _ direction: ScrollDirection,
    lines: Int,
    at cell: TerminalCell,
    pixelX: Int,
    pixelY: Int,
    to terminal: Terminal
  ) {}
}
