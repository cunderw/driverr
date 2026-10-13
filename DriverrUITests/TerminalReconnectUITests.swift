import XCTest

/// A link that dies while a terminal is on screen, and comes back on its own.
///
/// The reconnect's logic is `DriverrTests` against `FakeSSHTransport.drop()`. This covers
/// the presentation: an inline banner, the terminal back on the same pane, and no alert.
///
/// Hand-driven on purpose, through the password field and the trust prompt, so it fails if
/// the connect path breaks. Relaunches per test: it records a trust decision and leaves a
/// terminal open.
@MainActor
final class TerminalReconnectUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  @discardableResult
  private func require(
    _ app: XCUIApplication,
    _ identifier: String,
    _ message: String,
    timeout: TimeInterval = 10,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> XCUIElement {
    let match = element(app, identifier)
    XCTAssertTrue(
      match.waitForExistence(timeout: timeout),
      "\(message)\nLooked for '\(identifier)'. Tree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
    return match
  }

  private func waitForTerminalText(
    _ terminal: XCUIElement,
    containing text: String,
    timeout: TimeInterval = 15
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if (terminal.value as? String)?.contains(text) == true { return true }
      usleep(200_000)
    }
    return (terminal.value as? String)?.contains(text) == true
  }

  /// Turns a `Toggle` on by tapping its switch, not its row, and checks it moved. It is a
  /// copy of `setSwitch` without the settle.
  private func turnOn(
    _ app: XCUIApplication,
    _ identifier: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let toggle = app.switches[identifier]
    XCTAssertTrue(
      toggle.waitForExistence(timeout: 10),
      "No switch called '\(identifier)'.\nTree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
    if (toggle.value as? String) != "1" {
      toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline && (toggle.value as? String) != "1" {
      usleep(100_000)
    }
    XCTAssertEqual(
      toggle.value as? String,
      "1",
      "'\(identifier)' never moved, so the host was saved with the opposite setting.",
      file: file,
      line: line
    )
  }

  /// An agent pane opens on its chat, so a test that wants the terminal asks for it.
  private func showTerminal(_ app: XCUIApplication) {
    require(app, "pane.surface.terminal", "Expected the Terminal segment on an agent pane").tap()
  }

  func testTheTerminalSaysTheLinkWentAndBringsThePaneBack() {
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    // The fake drops the link once the pane's bridge has opened, a moment the test and the
    // fake agree on; a timer would race. One drop per launch, so the reconnect survives.
    app.launchArguments += ["-uiTesting", "-uiTestingSeedHost", "-uiTestingDropOnPaneOpen"]
    app.launch()

    require(app, "hosts.row", "Expected the seeded host").tap()
    require(app, "connect.password", "Expected a password field").tap()
    app.typeText("hunter2")
    // Remembered, because a held credential is what reconnects without asking. A password
    // nobody remembered is asked for inline, in `DriverrTests`.
    turnOn(app, "connect.remember")
    require(app, "connect.connect", "Expected a connect button").tap()
    tapTrustPrompt(app, "Expected the trust prompt on first contact")
    require(app, "connect.connected", "Expected to reach a connected state")
    require(app, "session.workspace", "Expected the session tree")

    // The tree row, because the Needs-you row opens the chat with the keyboard up.
    treePaneRow(app, titled: "needs a decision").tap()
    // No wait for the terminal to paint. The link drops as the pane opens, and what the
    // pane held before the drop is not the subject.
    showTerminal(app)

    // Read the banner before the terminal. Each `terminal.value` read snapshots the whole
    // grid, and a loop of them can outlast the banner. The banner is inline, never an alert.
    require(
      app,
      "terminal.reconnecting",
      "Expected an inline banner saying the connection was being got back",
      timeout: 20
    )
    XCTAssertEqual(
      app.alerts.count,
      0,
      "A reconnect must never present an alert from inside the cover."
        + "\nTree was:\n\(app.debugDescription)"
    )

    XCTAssertTrue(
      element(app, "terminal.reconnecting").waitForNonExistence(timeout: 30),
      "The banner outlived the reconnect.\nTree was:\n\(app.debugDescription)"
    )

    // The same pane comes back, its bridge frame drawn again.
    let restored = require(
      app,
      "terminal.view",
      "Expected the terminal to still be the thing on screen",
      timeout: 20
    )
    XCTAssertTrue(
      waitForTerminalText(restored, containing: "herdr pane term_w1p2", timeout: 20),
      "Expected the pane Driverr was on to be re-opened. Terminal showed: "
        + String(describing: restored.value)
    )
    XCTAssertEqual(app.alerts.count, 0, "An alert appeared after the reconnect.")

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "terminal-after-reconnect"
    shot.lifetime = .keepAlways
    add(shot)
  }
}
