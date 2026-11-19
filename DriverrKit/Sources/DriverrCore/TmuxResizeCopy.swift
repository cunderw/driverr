import Foundation

/// Everything the global tmux resize setting says. Here, as `PaneScreenCopy` is, so `swift test`
/// covers it.
public enum TmuxResizeCopy {
  /// The section header. tmux writes its own name in lower case.
  public static let header = "tmux"

  public static let title = "Resize tmux Windows"

  /// The second sentence matters most: the desk gets its size back.
  public static let footer =
    "While a tmux pane is open, Driverr sizes its window to this screen. The window gets its "
    + "size back when you leave the pane. Turn this off to keep the desk's size; a wide pane "
    + "then does not fit."
}
