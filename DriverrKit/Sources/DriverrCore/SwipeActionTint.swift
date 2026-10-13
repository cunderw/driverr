import Foundation

/// The fills of the app's swipe pills.
///
/// Fixed colours, not the theme accent. UIKit draws a swipe label white whatever the fill,
/// so the accent rule has no foreground to switch. Untinted, a pill takes the theme accent,
/// and white reads 3.42:1 on the default light accent
/// (`ThemeTests.theDefaultAccentCannotCarryAWhiteLabel`); a destructive pill drew blue.
///
/// One value for both appearances. `.indigo` in dark is #6D7CFF, which white reads at 3.51:1.
/// `ThemeTests` checks both fills against 4.5:1.
public enum SwipeActionTint {
  /// An ordinary action: Edit on the host list, Rename in the session tree. #6155F5 is light
  /// `.indigo`, 5.09:1 under white.
  public static let neutral = TerminalColor(hex: 0x6155_F5)

  /// A destructive action: Delete on the host list. #D70015 is Apple's high-contrast system
  /// red; the plain red does not carry white at 4.5:1.
  public static let destructive = TerminalColor(hex: 0xD700_15)
}
