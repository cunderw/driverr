import Foundation

/// Everything the global Live Activities setting says. Here, as `PaneScreenCopy` is, so
/// `swift test` covers it.
public enum LiveActivityCopy {
  /// Worded as iOS words its own per-app row: the switch governs whether the app may draw
  /// one at all. Naming the Lock Screen or the Dynamic Island alone would be wrong.
  public static let title = "Allow Live Activities"

  /// The second sentence matters most: a card already on the Lock Screen goes when this is
  /// turned off.
  public static let footer =
    "A card appears on the Lock Screen and in the Dynamic Island while a host is connected. "
    + "Turning this off ends any card that is showing."

  /// The host screen's `Background` section header, which also holds Continue in
  /// Background.
  public static let hostSectionHeader = "Background"

  /// The Start/Stop title for one host. A `Button` that retitles itself rather than a
  /// `Toggle` (see `LiveActivityMenuItem`), so the word is the state.
  public static func hostButtonTitle(isStarted: Bool) -> String {
    isStarted ? "Stop Live Activity" : "Start Live Activity"
  }

  /// The section footer says what the current state means, not what the button will do.
  public static func hostFooter(isStarted: Bool) -> String {
    isStarted
      ? "This host appears on the Lock Screen card while it is connected."
      : "This host is left off the Lock Screen card."
  }
}
