import XCTest

/// What a launch lands on: the empty list on a cold first run, the host it was left on
/// after a relaunch, and the pane or host a launch request names.
///
/// Relaunches per test, because every test is about what a launch does, and one
/// terminates and relaunches mid-test.
@MainActor
final class LaunchUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  /// No `-uiTesting`, so this runs the live environment and needs a simulator with no saved host.
  func testLaunchesToAnEmptyHostList() {
    let app = XCUIApplication()
    app.launch()

    // ContentUnavailableView copies its identifier onto each leaf, so both static texts
    // carry "hosts.empty". The icon image is the one element with a single match.
    XCTAssertTrue(
      app.images["hosts.empty"].waitForExistence(timeout: 10),
      "Expected the empty host list state on a cold launch"
    )
  }

  /// Relaunching lands on the host the user was on.
  ///
  /// `terminate()` is a force-quit, on which iOS discards `@SceneStorage`, so the selection
  /// lives in `UserDefaults`. See `ContentView.selectedHostID`.
  ///
  /// The first launch omits `-uiTestingRestoreSelection`. Restoring is off under
  /// `-uiTesting` unless asked for, but writing is not, so an earlier test may have stored
  /// a host. Without the flag the first launch starts on the list whatever is stored.
  ///
  /// Asserted on the host screen's pill, because on iPad the list stays beside it.
  func testRelaunchingRestoresTheSelectedHost() {
    let app = XCUIApplication()
    app.launchArguments += ["-uiTesting", "-uiTestingSeedHost"]
    app.launch()

    waitFor(app, "hosts.row", "Expected a launch without the flag to start on the host list")
      .tap()
    waitFor(app, "connect.disconnected", "Expected the seeded host's screen before relaunching")

    app.terminate()
    app.launchArguments += ["-uiTestingRestoreSelection"]
    app.launch()

    waitFor(
      app,
      "connect.disconnected",
      "Expected the relaunch to land on the host the last launch was left on",
      timeout: 15
    )
  }

  /// `TerminalPresenter.open(hostID:paneID:)` resolves the host, connects on its own, and
  /// lands on the pane's chat. It is the path a notification tap takes, driven here by
  /// `-uiTestingOpen`.
  ///
  /// The flag is read in `DriverrApp.init`, before `ContentView` configures the presenter,
  /// so this exercises the pending-open route. A presenter that dropped an early request
  /// fails here.
  ///
  /// Asserted on the scene's own content, because XCUITest sees the host list behind it.
  func testOpenLandsOnTheNamedPanesChat() {
    let app = XCUIApplication()
    app.launchArguments += [
      "-uiTesting", "-uiTestingSeedHost", "-uiTestingConnected", "-uiTestingOpen", "w1:p1",
    ]
    app.launch()

    waitFor(
      app,
      "pane.chat",
      "Expected -uiTestingOpen to present w1:p1's chat",
      timeout: 30
    )
    // Which pane. `w1:p1` is `terminal wiring`, and the scene's title is the pane's.
    XCTAssertTrue(
      app.navigationBars["terminal wiring"].waitForExistence(timeout: 10),
      "Expected the cover to be showing w1:p1.\nTree was:\n\(app.debugDescription)"
    )
    waitForPaneScene(app, "Expected the pane scene's own chrome")
  }

  /// A card's host URL opens that host's tree, and no pane.
  ///
  /// `-uiTestingOpenURL` is read in `DriverrApp.init` and handed to the same
  /// `ActivityURLRouter` as `onOpenURL`. It does not prove SwiftUI's URL delivery or the
  /// `CFBundleURLTypes` registration, which XCUITest cannot reach.
  func testAHostURLLandsOnTheHostsTreeAndOpensNoPane() {
    let app = XCUIApplication()
    app.launchArguments += [
      "-uiTesting", "-uiTestingSeedHost", "-uiTestingConnected",
      "-uiTestingOpenURL", "driverr://host?host=00000000-0000-0000-0000-00000000D701",
    ]
    app.launch()

    // `FakeControl.seededTree` has `w1:p2` blocked, so the tree has a Needs-you section.
    waitFor(
      app,
      "session.needsYou",
      "Expected a host URL to land on the seeded host's tree",
      timeout: 30
    )
    requireGone(app, "pane.chat", "A card naming no pane must not open one")
  }

  /// A host URL reopens the pane the reader was last in on that host, rather than the tree.
  ///
  /// A UI run's `LastPaneStore` is in memory, so `-uiTestingLastPane w1:p1` seeds the
  /// record. `w1:p1` is `terminal wiring`. This covers a cold launch, not a tap while the
  /// app is suspended.
  func testAHostURLResumesTheLastPaneOnThatHost() {
    let app = XCUIApplication()
    app.launchArguments += [
      "-uiTesting", "-uiTestingSeedHost", "-uiTestingConnected",
      "-uiTestingLastPane", "w1:p1",
      "-uiTestingOpenURL", "driverr://host?host=00000000-0000-0000-0000-00000000D701",
    ]
    app.launch()

    waitFor(
      app,
      "pane.chat",
      "Expected a host URL with a remembered pane to reopen that pane",
      timeout: 30
    )
    XCTAssertTrue(
      app.navigationBars["terminal wiring"].waitForExistence(timeout: 10),
      "Expected the resumed scene to be showing w1:p1.\nTree was:\n\(app.debugDescription)"
    )
    waitForPaneScene(app, "Expected the pane scene's own chrome")
  }

  /// A remembered pane that has since closed falls back silently to the host's tree, with
  /// no error and no empty pane scene.
  ///
  /// `w9:p9` is in no `FakeControl` tree, and `AppEnvironment.seededLastPanes` seeds a stale
  /// record for it. Without that record this would repeat
  /// `testAHostURLLandsOnTheHostsTreeAndOpensNoPane`.
  func testAHostURLWhoseRememberedPaneIsGoneLandsOnTheTree() {
    let app = XCUIApplication()
    app.launchArguments += [
      "-uiTesting", "-uiTestingSeedHost", "-uiTestingConnected",
      "-uiTestingLastPane", "w9:p9",
      "-uiTestingOpenURL", "driverr://host?host=00000000-0000-0000-0000-00000000D701",
    ]
    app.launch()

    waitFor(
      app,
      "session.needsYou",
      "Expected a stale remembered pane to fall back to the seeded host's tree",
      timeout: 30
    )
    requireGone(app, "pane.chat", "A remembered pane the host no longer has must not open")
  }

  /// A host URL puts the host's screen up at once, with the Connecting pill and Cancel,
  /// rather than leaving the reader on the list while the handshake runs.
  ///
  /// `-uiTestingSlowHandshake` keeps the connect running long enough to see. That stall
  /// outlasts the handshake deadline (`AppEnvironment.stalledHandshake`), so the pane never
  /// arrives here; `testAHostURLResumesTheLastPaneOnThatHost` covers the arrival.
  func testAHostURLShowsTheHostScreenBeforeTheConnectFinishes() {
    let app = XCUIApplication()
    app.launchArguments += [
      "-uiTesting", "-uiTestingSeedHost", "-uiTestingConnected", "-uiTestingSlowHandshake",
      "-uiTestingLastPane", "w1:p1",
      "-uiTestingOpenURL", "driverr://host?host=00000000-0000-0000-0000-00000000D701",
    ]
    app.launch()

    // Inside the thirty-second stall, so this is the connecting state.
    waitFor(
      app,
      "connect.progress",
      "Expected the host's own screen, with its Connecting pill, while the connect runs",
      timeout: 20
    )
    XCTAssertTrue(
      app.buttons["connect.cancel"].waitForExistence(timeout: 10),
      "Expected Cancel under the pill — the reader must be able to end the wait.\n"
        + "Tree was:\n\(app.debugDescription)"
    )
  }

  /// Waits for absence. XCUITest sees through a push, and a single `exists` samples a
  /// hierarchy mid-transition.
  private func requireGone(
    _ app: XCUIApplication,
    _ identifier: String,
    _ message: String,
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let match = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
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
}
