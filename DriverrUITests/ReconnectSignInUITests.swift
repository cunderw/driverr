import XCTest

/// A pane scene's reconnect that meets a sign-in on the web, as Tailscale SSH's check mode
/// asks for one (#175).
///
/// The logic is `DriverrTests` (`TerminalSceneModelTests`, "A reconnect that meets a
/// sign-in"). This covers the wiring: the scene's banner draws the URL, and its Cancel reaches
/// `stopReconnecting`. A hosted test cannot tap a button.
///
/// Seeded with `-uiTestingConnected`, because the connect path is not the subject;
/// `TerminalReconnectUITests` drives that by hand. Relaunches per test: it leaves a terminal
/// open and the launch's one drop spent.
@MainActor
final class ReconnectSignInUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  /// Waits for absence. XCUITest sees a hierarchy mid-transition, so a single
  /// `XCTAssertFalse(exists)` passes or fails on timing.
  private func requireGone(
    _ app: XCUIApplication,
    _ identifier: String,
    _ message: String,
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let match = element(app, identifier)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline && match.exists {
      _ = match.waitForExistence(timeout: 0.2)
    }
    XCTAssertFalse(
      match.exists,
      "\(message)\n'\(identifier)' was still there. Tree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
  }

  func testTheReconnectShowsTheSignInAndCancelStopsIt() {
    XCUIDevice.shared.orientation = .portrait
    // The link drops once the pane's bridge has opened, and every connection after the drop
    // holds for a sign-in.
    let app = connectedHostApp(["-uiTestingDropOnPaneOpen", "-uiTestingSignInOnReconnect"])
    waitFor(app, "session.workspace", "Expected the session tree")
    // The tree row, because the Needs-you row opens the chat with the keyboard up.
    treePaneRow(app, titled: "needs a decision").tap()

    // The drop waits for the pane to lay out, up to six seconds, then two more.
    let url = waitFor(
      app,
      "terminal.signIn.url",
      "Expected the reconnect banner to show the sign-in URL",
      timeout: 30
    )
    XCTAssertEqual(url.label, "https://login.tailscale.com/a/1a2b3c4d5e6f")
    waitFor(app, "terminal.signIn.host", "Expected the sign-in host on its own line")
    waitFor(app, "terminal.signIn.open", "Expected Open beside the sign-in URL")
    waitFor(app, "terminal.reconnecting", "Expected the banner to still say Reconnecting")

    waitFor(app, "terminal.signIn.cancel", "Expected a Cancel for the held reconnect").tap()

    waitFor(
      app,
      "terminal.disconnected",
      "Expected Cancel to stop the reconnect and offer Reconnect"
    )
    requireGone(app, "terminal.signIn.url", "The sign-in URL outlived the Cancel")
    requireGone(app, "terminal.reconnecting", "The banner still says Reconnecting")
  }
}
