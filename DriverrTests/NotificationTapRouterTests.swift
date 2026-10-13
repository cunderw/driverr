import DriverrCore
import Foundation
import Testing

@testable import Driverr

/// What a notification tap asks the presenter for.
///
/// Driven through `route(userInfo:)`, because `UNNotificationResponse` has no public
/// initialiser. The delegate only hands the dictionary over. `LaunchUITests` drives the same
/// `requestOpen` and `drainPendingOpen` route through `-uiTestingOpen`.
@MainActor
@Suite("NotificationTapRouter")
struct NotificationTapRouterTests {
  private let hostID = UUID()

  private func router(_ presenter: TerminalPresenter) -> NotificationTapRouter {
    NotificationTapRouter(presenter: presenter)
  }

  @Test("a tap asks the presenter for the pane the card names")
  func aTapRequestsThePane() {
    let presenter = TerminalPresenter()
    let router = router(presenter)

    router.route(userInfo: [
      NotificationTapRouter.hostIDKey: hostID.uuidString,
      NotificationTapRouter.paneIDKey: "w1:p2",
    ])

    #expect(presenter.pendingOpen == .init(hostID: hostID, paneID: "w1:p2"))
  }

  @Test("a card with no ids in it is a no-op")
  func anEmptyUserInfoDoesNothing() {
    let presenter = TerminalPresenter()

    router(presenter).route(userInfo: [:])

    #expect(presenter.pendingOpen == nil)
  }

  @Test("a card naming a host but no pane is a no-op")
  func aMissingPaneDoesNothing() {
    let presenter = TerminalPresenter()

    router(presenter).route(userInfo: [NotificationTapRouter.hostIDKey: hostID.uuidString])

    #expect(presenter.pendingOpen == nil)
  }

  @Test("a card whose host id is not a UUID is a no-op")
  func aMalformedHostIDDoesNothing() {
    let presenter = TerminalPresenter()

    router(presenter).route(userInfo: [
      NotificationTapRouter.hostIDKey: "workbox",
      NotificationTapRouter.paneIDKey: "w1:p2",
    ])

    #expect(presenter.pendingOpen == nil)
  }

  @Test("a card with an empty pane id opens nothing rather than the host's shell")
  func anEmptyPaneIDDoesNothing() {
    // `requestOpen(hostID:paneID: nil)` means the plain shell, which a card about a blocked
    // agent did not ask for.
    let presenter = TerminalPresenter()

    router(presenter).route(userInfo: [
      NotificationTapRouter.hostIDKey: hostID.uuidString,
      NotificationTapRouter.paneIDKey: "",
    ])

    #expect(presenter.pendingOpen == nil)
  }
}
