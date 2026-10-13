import XCTest

/// A host with no herdr is an ordinary SSH target. The screen offers a shell prominently
/// and still shows the herdr diagnosis.
///
/// Relaunches per test: connecting records a trust decision.
@MainActor
final class ShellWithoutHerdrUITests: XCTestCase {
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

  /// Waits for absence, because the screen is still settling when the connection lands.
  private func requireGone(
    _ app: XCUIApplication,
    _ identifier: String,
    _ message: String,
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let predicate = NSPredicate(format: "exists == false")
    let waiter = XCTNSPredicateExpectation(predicate: predicate, object: element(app, identifier))
    guard XCTWaiter().wait(for: [waiter], timeout: timeout) == .completed else {
      XCTFail(
        "\(message)\n'\(identifier)' was still there after \(timeout)s.\nTree was:\n\(app.debugDescription)",
        file: file,
        line: line
      )
      return
    }
  }

  /// - Parameter herdr: whether the fake host has a usable herdr on it.
  /// - Parameter extraArguments: other launch flags, such as one that drops the link.
  private func connectedHost(
    herdr: Bool,
    extraArguments: [String] = []
  ) -> XCUIApplication {
    XCUIDevice.shared.orientation = .portrait
    // Seeded, because this class is not about connecting.
    return connectedHostApp((herdr ? [] : ["-uiTestingNoHerdr"]) + extraArguments)
  }

  func testOffersAShellWhenHerdrIsMissing() {
    let app = connectedHost(herdr: false)
    let shell = require(
      app,
      "connect.shell",
      "Expected a prominent way to open a shell on a host with no herdr"
    )
    // Labelled, not a bare glyph.
    XCTAssertEqual(shell.label, "Open Shell")
  }

  func testKeepsTheHerdrDiagnosisVisible() {
    // The three kinds of "no herdr" have different answers, so the diagnosis stays beside
    // the shell action.
    let app = connectedHost(herdr: false)
    require(
      app,
      "herdr.unavailable",
      "Expected the herdr diagnosis to survive alongside the shell action"
    )
    requireGone(app, "herdr.ready", "A host with no herdr must not report one")
  }

  func testTheShellActuallyOpens() {
    let app = connectedHost(herdr: false)
    require(app, "connect.shell", "Expected the shell action").tap()
    require(app, "terminal.view", "Expected tapping the shell to open a terminal")

    // No pane switcher, because with no herdr session its sheet would hold only this
    // terminal. The rule is `PaneStripModel.showsSwitcher`; this checks `TerminalScreen`
    // reads it.
    requireGone(
      app,
      "terminal.panes",
      "A host with no herdr session has no panes to switch between"
    )
  }

  func testDoesNotOpenAShellOnItsOwn() {
    // Connecting is not asking for a terminal. One opened on connect would take the screen
    // from someone who came for something else, on every reconnect.
    let app = connectedHost(herdr: false)
    requireGone(
      app,
      "terminal.view",
      "Connecting must not open a terminal by itself"
    )
    require(app, "connect.shell", "Expected the shell to be offered rather than opened")
  }

  func testAHostWithHerdrIsUnaffected() {
    // With a session, the tree is the subject and the shell prompt stays away.
    let app = connectedHost(herdr: true)
    require(app, "session.workspace", "Expected the session tree on a herdr host")
    requireGone(
      app,
      "connect.shell",
      "The shell prompt belongs only on a host with no herdr"
    )
    // Still reachable, just not the subject.
    require(app, "connect.terminal", "Expected the toolbar shell action to remain")
  }

  /// The panes button stays away while the link is down.
  ///
  /// Gating the button on `showsSwitcher || isLinkDown` would bring it back on a herdr-less
  /// host whenever the link drops, over a sheet with nothing to switch to. The other tests
  /// never drop the link, so only this one catches that.
  ///
  /// The absence is read while the reconnect banner is up, because `requireGone` returns on
  /// the first absent read and would pass a button that came and went.
  func testKeepsThePanesButtonAwayWhileTheLinkIsDown() {
    // `-uiTestingDropOnShellOpen`, because the pane flag waits on an exec stream that a
    // herdr-less host never opens. The shell flag waits on the PTY, and `ReconnectSchedule`
    // keeps the banner up for the whole read below.
    let app = connectedHost(herdr: false, extraArguments: ["-uiTestingDropOnShellOpen"])
    require(app, "connect.shell", "Expected the shell action").tap()
    require(app, "terminal.view", "Expected tapping the shell to open a terminal")

    require(
      app,
      "terminal.reconnecting",
      "Expected the inline banner once the link dropped",
      timeout: 30
    )
    requireGone(
      app,
      "terminal.panes",
      "A herdr-less host has no panes to switch between, link down or not"
    )
  }
}
