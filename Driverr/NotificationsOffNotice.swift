import Foundation

/// The row Settings shows when the user has turned notifications off.
///
/// It explains why a feature is doing nothing, on a screen the user has to seek out, so it
/// is not a nag. `BlockedPaneNotifier` still asks only once. A plain rule, so `DriverrTests`
/// can assert it without a window.
enum NotificationsOffNotice {
  static let title = "Notifications are off"
  static let message = "Driverr cannot tell you when a pane needs you."

  /// Whether the row belongs on screen.
  ///
  /// - Parameters:
  ///   - status: what the system says, or `nil` before the first read. An unread status shows
  ///     nothing, so the row never appears a beat after the screen.
  ///   - isStoreTour: `-uiTestingDemoTranscript`, the App Store screenshot run. The ephemeral
  ///     notification centre reports `.denied`, and the row must not appear in store art.
  static func isVisible(status: NotificationAuthorization?, isStoreTour: Bool) -> Bool {
    status == .denied && !isStoreTour
  }
}
