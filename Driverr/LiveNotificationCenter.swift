import Foundation
import UserNotifications

/// `UNUserNotificationCenter`, behind `NotificationScheduling`.
///
/// The only place in the app that posts to the system's notification centre, so the silent
/// conformance below is a complete guarantee.
struct LiveNotificationCenter: NotificationScheduling {
  private var center: UNUserNotificationCenter { .current() }

  func authorizationStatus() async -> NotificationAuthorization {
    switch await center.notificationSettings().authorizationStatus {
    case .authorized, .provisional, .ephemeral: .authorized
    case .denied: .denied
    case .notDetermined: .notDetermined
    // An unknown status means do not post. A missed card is recoverable; an unwanted one is not.
    @unknown default: .denied
    }
  }

  @discardableResult
  func requestAuthorization() async -> Bool {
    // No badge: an icon count would mean nothing across several hosts.
    (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
  }

  func post(id: String, title: String, body: String, userInfo: [String: String]) async {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    content.userInfo = userInfo
    // `trigger: nil` posts at once. The poll has already seen the transition.
    let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
    try? await center.add(request)
  }

  func withdraw(ids: [String]) async {
    // Delivered is a card on screen; pending is one added but not shown yet.
    center.removeDeliveredNotifications(withIdentifiers: ids)
    center.removePendingNotificationRequests(withIdentifiers: ids)
  }
}

#if DEBUG
/// A notifier that reaches nothing, for every launch that is not the real app.
///
/// If a `-uiTesting` launch reached `LiveNotificationCenter`, the first blocked pane would
/// raise a system permission alert over the app, and UI tests would fail on elements behind
/// it. It reports `.denied`, so `BlockedPaneNotifier` never reaches the permission path.
struct SilentNotificationCenter: NotificationScheduling {
  func authorizationStatus() async -> NotificationAuthorization { .denied }
  @discardableResult func requestAuthorization() async -> Bool { false }
  func post(id: String, title: String, body: String, userInfo: [String: String]) async {}
  func withdraw(ids: [String]) async {}
}
#endif
