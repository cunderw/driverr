import DriverrCore
import Foundation

/// Which kind of device the notice would be shown on.
///
/// Not `UIUserInterfaceIdiom`, so this file stays free of UIKit. Any other idiom maps to
/// `.phone`, which shows the notice rather than hiding it.
public enum KeyboardNoticeIdiom: Equatable, Sendable {
  case phone
  case pad
}

/// Why the software keyboard is or is not on screen, as a pure function of three facts.
///
/// A `swift test` can drive it. In a UI-test launch `GCKeyboard.coalesced` is nil, so a UI
/// test only ever sees the hardware keyboard disconnected.
public enum KeyboardNoticeState: Equatable, Sendable {
  /// The software keyboard is on screen, or nothing has asked for it yet.
  case normal
  /// First responder was resigned on purpose, for example with the hide-keyboard key.
  case dismissed
  /// First responder, a hardware keyboard is attached, and the frame that arrived is the
  /// accessory row's own height rather than a software keyboard's: iOS is suppressing it.
  case suppressedByHardwareKeyboard

  /// With a hardware keyboard attached, a frame at or under the key row's height counts as
  /// suppressed. A software keyboard is well over 100 pt tall (362 pt measured).
  ///
  /// In production the row is hidden while a hardware keyboard is attached, so the
  /// comparison matters only under the `-uiTesting` override that keeps the row. Whether a
  /// phone adds the home-indicator inset to that frame is not measured.
  static let accessoryRowHeight: Double = PaneKey.AccessoryRowMetrics.rowHeight

  /// - Parameters:
  ///   - isFirstResponder: whether the terminal currently holds the keyboard.
  ///   - hardwareKeyboardConnected: `HardwareKeyboardMonitor.isConnected`.
  ///   - keyboardFrameHeight: the end frame height from the terminal's own
  ///     `keyboardDidShowNotification`, in points. Zero before the first one arrives.
  ///   - idiom: the device this would be shown on. `.pad` never reports
  ///     `suppressedByHardwareKeyboard`. See below.
  public static func decide(
    isFirstResponder: Bool,
    hardwareKeyboardConnected: Bool,
    keyboardFrameHeight: Double,
    idiom: KeyboardNoticeIdiom = .phone
  ) -> KeyboardNoticeState {
    guard isFirstResponder else { return .dismissed }
    guard hardwareKeyboardConnected, keyboardFrameHeight <= accessoryRowHeight else {
      return .normal
    }
    // No banner on iPad. On a phone the hardware keyboard is often iPhone Mirroring's,
    // which is not in the room, so a missing keyboard looks like a dead terminal. On an iPad
    // the user is typing on the hardware keyboard.
    guard idiom != .pad else { return .normal }
    return .suppressedByHardwareKeyboard
  }

  /// The notice's one line, for the device it is being shown on.
  ///
  /// Only the phone's text mentions iPhone Mirroring, which cannot happen on an iPad.
  public static func copy(for idiom: KeyboardNoticeIdiom) -> String {
    switch idiom {
    case .phone:
      return "Software keyboard hidden — a hardware keyboard is connected, including over "
        + "iPhone Mirroring. Press Globe or Eject to show it."
    case .pad:
      return "Software keyboard hidden — a hardware keyboard is connected. Press Globe or "
        + "Eject to show it."
    }
  }
}
