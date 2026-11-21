import Foundation

/// What the key row's Tab key puts on the wire: Tab on a tap, back-tab on a hold.
///
/// Back-tab is `ESC [ Z` (CSI Z, cursor backward tabulation). Claude Code cycles its mode
/// with Shift-Tab and reads this sequence. The software keyboard's Shift does not reach the
/// row's Tab key, so a hold on Tab is the row's way to send it.
public enum TabKeyBytes {
  public static let tab: [UInt8] = [0x09]
  /// SwiftTerm's own `EscapeSequences.cmdBackTab`, which a hardware Shift-Tab sends.
  public static let backTab: [UInt8] = [0x1B, 0x5B, 0x5A]

  /// - Parameter shift: the key was held, or Shift was down, for this Tab.
  public static func bytes(shift: Bool) -> [UInt8] {
    shift ? backTab : tab
  }
}
