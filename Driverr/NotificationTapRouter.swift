import DriverrCore
import Foundation
import UserNotifications

/// Routes a notification tap to the pane it names.
///
/// `UNNotificationResponse` cannot be built in a test, so the rule is in `route(userInfo:)`,
/// which `DriverrTests` drives, and the delegate only hands off. `TerminalPresenter.requestOpen`
/// only records the request, because a delegate must return promptly. `ContentView` drains
/// it, on the same route `-uiTestingOpen` drives in `LaunchUITests`.
final class NotificationTapRouter: NSObject, UNUserNotificationCenterDelegate {
  /// The `userInfo` keys a posted card carries. Named here because this side must still read
  /// a card posted by an older build.
  static let hostIDKey = "hostID"
  static let paneIDKey = "paneID"
  /// `Pane.sessionWitness` when the card was scheduled. Only the reset alert carries it, and
  /// its Continue sends only to a pane that still has it.
  static let paneWitnessKey = "paneWitness"

  private let presenter: TerminalPresenter

  init(presenter: TerminalPresenter) {
    self.presenter = presenter
    super.init()
  }

  /// Opens the pane a card names, and ignores a card that names none this build understands.
  /// An unknown host id is a no-op in `TerminalPresenter.open`, which is ordinary because a
  /// notification can outlive its host.
  @MainActor
  func route(userInfo: [String: String]) {
    Self.route(userInfo: userInfo, to: presenter)
  }

  /// The rule, `static` so the delegate need not send `self`, which is not `Sendable`, to the
  /// main actor.
  @MainActor
  static func route(userInfo: [String: String], to presenter: TerminalPresenter) {
    route(action: UNNotificationDefaultActionIdentifier, userInfo: userInfo, to: presenter)
  }

  /// The same, for a card's action. The reset alert's Continue opens the pane and asks for
  /// `LimitResetReminder.continueText` to be sent once the connection is up, to the pane only
  /// if it still has the card's witness. herdr reuses positional pane ids, so the id alone
  /// can name another conversation. A card with no witness only opens the pane, as every
  /// other action and a plain tap do.
  @MainActor
  static func route(action: String, userInfo: [String: String], to presenter: TerminalPresenter) {
    guard let hostID = userInfo[hostIDKey].flatMap(UUID.init(uuidString:)),
      let paneID = userInfo[paneIDKey], !paneID.isEmpty
    else { return }
    if action == LimitResetReminder.continueActionID,
      let witness = userInfo[paneWitnessKey], !witness.isEmpty
    {
      presenter.requestOpen(
        hostID: hostID,
        intent: .paneSending(paneID, witness: witness, text: LimitResetReminder.continueText))
    } else {
      presenter.requestOpen(hostID: hostID, paneID: paneID)
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    let userInfo = Self.strings(in: response.notification.request.content.userInfo)
    let action = response.actionIdentifier
    let presenter = presenter
    await MainActor.run { Self.route(action: action, userInfo: userInfo, to: presenter) }
  }

  /// Nothing is shown while the app is in front.
  ///
  /// A second guard beside `BlockedPaneAlerts`, which announces nothing while the app is
  /// active, so no card drops over a terminal being typed into.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    []
  }

  /// The `String`-to-`String` part of a `userInfo`, which is all Driverr puts there and all
  /// that can cross an actor boundary.
  static func strings(in userInfo: [AnyHashable: Any]) -> [String: String] {
    userInfo.reduce(into: [:]) { result, pair in
      guard let key = pair.key as? String, let value = pair.value as? String else { return }
      result[key] = value
    }
  }
}
