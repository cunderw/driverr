import XCTest

/// Selecting a pane in the sidebar has to open *that pane's* terminal, not a shell that
/// happens to be on the same host.
///
/// The fake bridge writes a frame naming the terminal it opened, which tells an attach to
/// `w1:p2` apart from a plain shell.
///
/// Relaunches per test: connecting records a trust decision and leaves a terminal open.
@MainActor
final class PaneAttachUITests: XCTestCase {
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
    timeout: TimeInterval = 10
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if (terminal.value as? String)?.contains(text) == true { return true }
      usleep(200_000)
    }
    return (terminal.value as? String)?.contains(text) == true
  }

  private func connectedHost() -> XCUIApplication {
    XCUIDevice.shared.orientation = .portrait
    // Seeded, because this class is not about connecting.
    let app = connectedHostApp()
    require(app, "session.workspace", "Expected the session tree")
    return app
  }

  /// An agent pane opens on its chat, so a test that wants the terminal asks for it. Every
  /// caller is on an agent pane, so a missing segment fails.
  private func showTerminal(_ app: XCUIApplication) {
    require(app, "pane.surface.terminal", "Expected the Terminal segment on an agent pane").tap()
  }

  /// Opens the pane sheet, the one place that marks the current pane.
  private func openPaneSheet(
    _ app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    require(app, "terminal.panes", "Expected the panes button", file: file, line: line).tap()
    require(app, "terminal.sheet.pane", "Expected the sheet to draw a tile per pane")
  }

  /// The tile whose label starts with `title`. Tiles share an identifier, and a label reads
  /// "<title>, <state>", so the prefix does not depend on the state's wording.
  private func paneTile(_ app: XCUIApplication, titled title: String) -> XCUIElement {
    app.buttons.matching(identifier: "terminal.sheet.pane")
      .matching(NSPredicate(format: "label BEGINSWITH %@", title))
      .firstMatch
  }

  func testSelectingAPaneAttachesThatPane() {
    let app = connectedHost()

    // The tree row, because the Needs-you row opens the chat with the keyboard up.
    treePaneRow(app, titled: "needs a decision").tap()
    showTerminal(app)

    let terminal = require(app, "terminal.view", "Expected the terminal to open")
    // `w1:p2`'s terminal is `term_w1p2`. The bridge frame naming it proves the right pane
    // opened; a plain shell would show only the prompt.
    XCTAssertTrue(
      waitForTerminalText(terminal, containing: "herdr pane term_w1p2"),
      "Expected the bridge to open this pane. Terminal showed: "
        + String(describing: terminal.value)
    )

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "pane-attached"
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// A pane with no agent attaches too. Most panes on a real session have none, and
  /// attaching through the agent would fail with `agent_not_found`.
  func testSelectingAShellPaneAttachesItToo() {
    let app = connectedHost()

    // `swift test` is the seed's pane with no agent. It has a terminal id like the others.
    treePaneRow(app, titled: "swift test").tap()

    let terminal = require(app, "terminal.view", "Expected the terminal to open")
    XCTAssertTrue(
      waitForTerminalText(terminal, containing: "herdr pane term_w1p3"),
      "Expected a shell pane to open through the bridge too. Terminal showed: "
        + String(describing: terminal.value)
    )

    // The switcher marks it current, with no agent to name.
    openPaneSheet(app)
    let tile = paneTile(app, titled: "swift test")
    XCTAssertTrue(
      tile.waitForExistence(timeout: 10),
      "Expected a tile for the attached pane.\nTree was:\n\(app.debugDescription)"
    )
    XCTAssertEqual(
      tile.value as? String,
      "Current pane",
      "Expected the attached pane's tile to be the current one"
    )
  }

  /// The switcher says which pane this is and what it is doing, in words rather than colour,
  /// because terminals look alike.
  func testTheSwitcherSaysWhichPaneThisIs() {
    let app = connectedHost()

    treePaneRow(app, titled: "needs a decision").tap()
    showTerminal(app)
    require(app, "terminal.view", "Expected the terminal")

    openPaneSheet(app)
    let tile = paneTile(app, titled: "needs a decision")
    XCTAssertTrue(
      tile.waitForExistence(timeout: 10),
      "Expected a tile for the attached pane.\nTree was:\n\(app.debugDescription)"
    )
    XCTAssertEqual(
      tile.value as? String,
      "Current pane",
      "Expected the attached pane's tile to be the current one"
    )
    XCTAssertTrue(
      tile.label.contains("Waiting for you"),
      "Expected the tile to say what the pane is doing, got: \(tile.label)"
    )
  }

  // Switching by leaving and tapping another row is not driven here; it stalled until
  // XCTest killed the test. The presenter's request identity, which makes it work, is
  // `TerminalPresenterTests`.

  /// The plain shell is still reachable and is not an attach.
  func testOpenTerminalStillOpensAShell() {
    let app = connectedHost()

    require(app, "connect.terminal", "Expected the plain terminal button").tap()
    let terminal = require(app, "terminal.view", "Expected a terminal")
    XCTAssertTrue(waitForTerminalText(terminal, containing: "carson@workbox"), "no prompt")

    XCTAssertFalse(
      (terminal.value as? String)?.contains("agent attach") == true,
      "A plain shell must not attach to a pane"
    )
    // A plain shell is not a pane, so the current place is the Shell tile, labelled only
    // "Shell". The sheet still lists the host's panes.
    openPaneSheet(app)
    let current = app.buttons.matching(identifier: "terminal.sheet.pane")
      .matching(NSPredicate(format: "value == %@", "Current pane"))
    XCTAssertEqual(
      current.count,
      1,
      "Expected exactly one place to be marked as the current one.\nTree was:\n"
        + app.debugDescription
    )
    XCTAssertEqual(
      current.firstMatch.label,
      "Shell",
      "A plain shell has no pane, so the Shell tile is the one that may be current."
        + "\nTree was:\n\(app.debugDescription)"
    )
  }
}
