import Foundation

/// Everything the global tmux resize setting says. Here, as `PaneScreenCopy` is, so `swift test`
/// covers it.
public enum TmuxResizeCopy {
  /// The section header. tmux writes its own name in lower case.
  public static let header = "tmux"

  public static let title = "Resize tmux Windows"

  /// "Wraps" is what the setting off does: the pane's rows arrive at the computer's width and
  /// the phone's grid wraps each one. `TerminalSessionTests.aNarrowerGridDoesNotHoldTheProgramsRows`
  /// shows a wider row split across two.
  public static let footer =
    "While a tmux pane is open, Driverr resizes its tmux window to fit this screen, and puts "
    + "the old size back when you leave. Turn this off to keep the window at the computer's "
    + "size, so a wider pane wraps on this screen. Resizing needs tmux 3.3 or later."
}
