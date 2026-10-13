import Foundation
import Observation

/// What the terminal's chrome should tell the user about the keyboard, if anything.
///
/// Collects the three facts `KeyboardNoticeState.decide` needs, which UIKit reports
/// separately: first-responder status, the keyboard's end frame height, and whether a
/// hardware keyboard is attached. It owns the only `HardwareKeyboardMonitor` in the chrome.
@MainActor
@Observable
public final class KeyboardNoticeModel {
  public private(set) var state: KeyboardNoticeState = .dismissed

  /// Where the terminal's accessory row starts, in the app window's coordinates, or `nil`
  /// when the keyboard is not on screen.
  ///
  /// Reported by the terminal, because the row lives in UIKit's input window, drawn over
  /// the app, where SwiftUI cannot see it.
  public private(set) var accessoryRowTop: Double?

  private let hardwareKeyboard: HardwareKeyboardMonitor
  private let idiom: KeyboardNoticeIdiom
  /// Keeps the key row on screen with a hardware keyboard attached. The `-uiTesting`
  /// override sets it, so UI tests find the row whatever keyboard the simulator reports.
  private let keepsAccessoryRowWithHardwareKeyboard: Bool
  private var isFirstResponder = false
  private var keyboardFrameHeight: Double = 0
  /// Set once the reader closes the notice, and never cleared. The model lives as long as
  /// the scene, so the notice stays closed while the terminal is open.
  private var isDismissedByReader = false

  public init(
    hardwareKeyboardConnected: Bool = HardwareKeyboardMonitor.isCurrentlyConnected,
    hardwareKeyboardSubscription: @escaping HardwareKeyboardMonitor.Subscription =
      HardwareKeyboardMonitor.liveSubscription,
    idiom: KeyboardNoticeIdiom = .phone,
    keepsAccessoryRowWithHardwareKeyboard: Bool = false
  ) {
    self.idiom = idiom
    self.keepsAccessoryRowWithHardwareKeyboard = keepsAccessoryRowWithHardwareKeyboard
    hardwareKeyboard = HardwareKeyboardMonitor(
      isConnected: hardwareKeyboardConnected,
      subscribe: hardwareKeyboardSubscription
    )
    recompute()
    hardwareKeyboard.onChange = { [weak self] in self?.recompute() }
  }

  /// The notice's own words, for the device it is on.
  public var noticeText: String { KeyboardNoticeState.copy(for: idiom) }

  /// Whether the chrome should draw the hardware-keyboard notice right now.
  public var showsHardwareKeyboardNotice: Bool {
    state == .suppressedByHardwareKeyboard && !isDismissedByReader
  }

  /// Whether the terminal should carry its key row. A hardware keyboard has every key on
  /// the row, and the row costs the grid rows.
  ///
  /// It reads the hardware keyboard directly, not `state`, so the row does not come and
  /// go with first-responder changes.
  public var showsAccessoryRow: Bool {
    keepsAccessoryRowWithHardwareKeyboard || !hardwareKeyboard.isConnected
  }

  /// The reader closed the notice, for the life of this scene. See `isDismissedByReader`.
  public func dismissNotice() {
    isDismissedByReader = true
  }

  /// The terminal reports its first-responder changes here, in both directions.
  public func firstResponderChanged(_ isFirstResponder: Bool) {
    self.isFirstResponder = isFirstResponder
    recompute()
  }

  /// The keyboard's end frame height. It stops the hardware-keyboard flag alone from
  /// showing the notice while a software keyboard is on screen.
  public func keyboardFrameChanged(height: Double) {
    keyboardFrameHeight = height
    recompute()
  }

  /// The terminal reports where its accessory row is, or that there is none on screen.
  ///
  /// Kept apart from `keyboardFrameChanged(height:)`, which feeds the notice. This is a
  /// layout measurement.
  public func accessoryRowTopChanged(_ top: Double?) {
    // Written only on a change. Every warm terminal shares this model and reports the
    // keyboard hiding, and each write relays out the grid.
    guard top != accessoryRowTop else { return }
    accessoryRowTop = top
  }

  /// How much of a terminal ending at `bottom` the accessory row covers. The grid drops
  /// that height, so the size sent over SIGWINCH is what the user can read.
  ///
  /// **A subtraction, not a constant.** The keyboard's safe area sometimes includes the row
  /// and sometimes does not: in portrait the same screen owed 0 pt on first show and 44 pt
  /// after a rotation. `bottom` must come from layout, not from the keyboard notification.
  public func obstruction(forRegionEndingAt bottom: Double) -> Double {
    guard let accessoryRowTop else { return 0 }
    return max(0, bottom - accessoryRowTop)
  }

  private func recompute() {
    state = KeyboardNoticeState.decide(
      isFirstResponder: isFirstResponder,
      hardwareKeyboardConnected: hardwareKeyboard.isConnected,
      keyboardFrameHeight: keyboardFrameHeight,
      idiom: idiom
    )
  }
}
