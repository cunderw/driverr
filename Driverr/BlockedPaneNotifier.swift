import DriverrCore
import Foundation

/// Whether the user has been asked about notifications yet, and what they said.
///
/// Plain cases so only one file needs `UserNotifications`. `.provisional` and `.ephemeral`
/// map to `.authorized`, because the only question here is whether a card may be posted.
enum NotificationAuthorization: Equatable, Sendable {
  case notDetermined
  case authorized
  case denied
}

/// Posting and withdrawing local notifications, as plain values.
///
/// `DriverrTests` substitutes a fake. The real `UNUserNotificationCenter` would raise a system
/// permission alert over the app in a test. `AppEnvironment.ephemeral` wires a notifier that
/// does nothing.
protocol NotificationScheduling: Sendable {
  func authorizationStatus() async -> NotificationAuthorization
  /// Asks the system to show the permission alert, and reports the answer.
  ///
  /// The notifier ignores the return value and re-reads the status, because a request made
  /// in the background may be answered long after this returns. If the answer has not arrived,
  /// the status is still `.notDetermined` and the next newly blocked pane asks again.
  @discardableResult func requestAuthorization() async -> Bool
  func post(id: String, title: String, body: String, userInfo: [String: String]) async
  func withdraw(ids: [String]) async
}

/// Turns one host's polls into notifications about panes that have gone blocked.
///
/// The rule is `DriverrCore.BlockedPaneAlerts`. This part handles permission, the card's
/// strings and the identifiers used to withdraw it. One per host, held by `ConnectionModel`.
@MainActor
final class BlockedPaneNotifier {
  private let host: DriverrCore.Host
  private let center: any NotificationScheduling
  private let store: any AnnouncedPaneStore
  private var alerts = BlockedPaneAlerts()
  /// Whether a permission request is in flight, so polls do not stack up one request per
  /// tick behind an unanswered alert.
  private var isRequestingAuthorization = false

  init(host: DriverrCore.Host, center: any NotificationScheduling, store: any AnnouncedPaneStore) {
    self.host = host
    self.center = center
    self.store = store
  }

  // MARK: - Carrying the announced set across processes

  /// Whether `alerts` has been given the set the last process left behind.
  private var hasRestored = false

  /// The one read of the store, shared by however many polls arrive during it.
  private var restore: Task<Set<String>, Never>?

  /// Loads the announced set, once, before the first tree is folded in.
  ///
  /// Without this, a background refresh, which launches the app cold, would treat every
  /// blocked pane as newly blocked and alert again on every run. A cold foreground launch has
  /// the same problem.
  ///
  /// Polls that arrive during the load await one task, and only the first applies it, so a
  /// later one cannot write a stale set over a fold that already happened.
  private func restoreAnnouncedIfNeeded() async {
    guard !hasRestored else { return }
    let task = restore ?? Task { [store, host] in await store.announcedPanes(forHost: host.id) }
    restore = task
    let stored = await task.value
    guard !hasRestored else { return }
    hasRestored = true
    alerts = BlockedPaneAlerts(announced: stored)
  }

  /// Folds one poll's tree in and does whatever it asks for.
  ///
  /// Permission is asked at the first newly blocked pane, never at launch. A request made in
  /// the background may not show its alert until the app is next in front. The status then
  /// stays `.notDetermined` and the next blocked pane asks again, with no second code path.
  ///
  /// `.denied` is final and silent. The app already shows a Needs-you count on every screen.
  func sessionChanged(to tree: SessionTree, isAppActive: Bool) async {
    await restoreAnnouncedIfNeeded()
    let outcome = alerts.update(to: tree, isAppActive: isAppActive)
    // Written before the cards go out. Dying after the write costs one missed notification.
    // Dying after posting but before the write would re-alert every blocked pane on every
    // refresh.
    await store.setAnnouncedPanes(alerts.announced, forHost: host.id)

    // Withdrawals first and unconditionally. A question answered elsewhere removes the card
    // even if permission was never granted, and withdrawing an unposted id is a no-op.
    if !outcome.clear.isEmpty {
      await center.withdraw(ids: outcome.clear.map(notificationID))
    }

    guard !outcome.newlyBlocked.isEmpty else { return }

    switch await center.authorizationStatus() {
    case .denied:
      return
    case .notDetermined:
      guard !isRequestingAuthorization else { return }
      isRequestingAuthorization = true
      await center.requestAuthorization()
      isRequestingAuthorization = false
      // Re-read, and post for this event if the answer was yes, so the first blocked pane
      // after install is not lost. An alert that could not present leaves `.notDetermined`,
      // so this returns and the next blocked pane asks again.
      guard await center.authorizationStatus() == .authorized else { return }
    case .authorized:
      break
    }

    // Only panes the rule still holds as blocked. A poll during any `await` above runs
    // `update` again, and a pane answered in the meantime would otherwise get a card that
    // nothing withdraws.
    for pane in outcome.announce where alerts.announced.contains(pane.id) {
      await center.post(
        id: notificationID(for: pane.id),
        title: pane.title,
        // The title says which conversation and the host says which machine.
        body: "\(host.name) needs you",
        userInfo: [
          NotificationTapRouter.hostIDKey: host.id.uuidString,
          NotificationTapRouter.paneIDKey: pane.id,
        ]
      )
    }
  }

  private func notificationID(for paneID: String) -> String {
    BlockedPaneAlerts.notificationID(hostID: host.id, paneID: paneID)
  }
}
