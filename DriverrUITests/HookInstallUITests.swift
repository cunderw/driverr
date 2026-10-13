import XCTest

/// Driverr's hook install, offered on connect and from the host row's menu.
///
/// This covers the offer appearing at the root, "View Full Command" never showing the
/// user's settings file, Install reporting its result, and the menu working after a
/// decline. The rules and the install are `HookOfferTests` and `HookInstallerTests`.
///
/// Relaunches per test, because an install writes the fake host's settings file and Not Now
/// records a decline.
///
/// `-uiTestingHookOffer` starts the fake host without the hooks. Every other UI run's host
/// has them, so no other class meets this sheet.
@MainActor
final class HookInstallUITests: XCTestCase {
  /// `AppEnvironment.hookFixtureSecret`, a value in the fake host's `env` that must never
  /// reach the screen.
  private let secret = "sk-uitest-NOT-A-REAL-KEY-644"

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  func testConnectOffersTheHooksShowsTheCommandAndInstalls() {
    let app = connectedHostApp(["-uiTestingHookOffer"])

    waitFor(app, "hooks.absent", "Expected the hook offer after the connect", timeout: 15)
    let hook = waitFor(app, "hooks.hook", "Expected the hook's overview")
    XCTAssertTrue(hook.label.contains("Show Claude’s questions in the chat"), "Unexpected overview: \(hook.label)")

    waitFor(app, "hooks.viewCommand", "Expected View Full Command").tap()
    waitFor(app, "hooks.command.read", "Expected the read command")
    let added = waitFor(app, "hooks.command.added", "Expected the JSON the install adds")
    XCTAssertTrue(added.label.contains("AskUserQuestion"), "The added JSON does not name the matcher: \(added.label)")
    requireNoSecret(app)

    app.navigationBars.buttons.element(boundBy: 0).tap()
    waitFor(app, "hooks.install", "Expected Install back on the overview").tap()
    let result = waitFor(app, "hooks.result", "Expected the install's result", timeout: 15)
    XCTAssertTrue(result.label.contains("Installed on"), "Unexpected result: \(result.label)")
    requireNoSecret(app)

    waitFor(app, "hooks.done", "Expected Done after the install").tap()
    requireGone(app, "hooks.done", "Done did not close the sheet")
  }

  func testAFileThatChangedIsReportedAndTryAgainInstalls() {
    let app = connectedHostApp(["-uiTestingHookOffer", "-uiTestingHookChangedOnce"])

    waitFor(app, "hooks.install", "Expected the hook offer after the connect", timeout: 15).tap()
    let failure = waitFor(app, "hooks.failure", "Expected the changed-file failure", timeout: 15)
    XCTAssertTrue(failure.label.contains("changed after Driverr read it"), "Unexpected failure: \(failure.label)")
    let retry = waitFor(app, "hooks.install", "Expected Try Again")
    XCTAssertTrue(retry.label.contains("Try Again"), "Expected Try Again, found: \(retry.label)")
    retry.tap()
    waitFor(app, "hooks.result", "Expected the retry to install", timeout: 15)
  }

  func testNotNowDeclinesAndTheMenuStillInstalls() {
    let app = connectedHostApp(["-uiTestingHookOffer"])

    waitFor(app, "hooks.notNow", "Expected Not Now on the offer", timeout: 15).tap()
    requireGone(app, "hooks.notNow", "Not Now did not close the sheet")

    // Back to the list on the phone; the iPad's sidebar never left.
    let row = app.descendants(matching: .any).matching(identifier: "hosts.row").firstMatch
    if !row.isHittable {
      app.navigationBars.buttons.element(boundBy: 0).tap()
    }
    XCTAssertTrue(row.waitForExistence(timeout: 10), "Expected the host list")
    row.press(forDuration: 1.0)
    waitFor(app, "hosts.menuInstallHooks", "Expected Install Driverr Hooks in the row's menu").tap()

    // The menu ignores the decline and says where the host stands.
    waitFor(app, "hooks.absent", "Expected the sheet from the menu after a decline", timeout: 15)
    XCTAssertFalse(
      app.descendants(matching: .any).matching(identifier: "hooks.notNow").firstMatch.exists,
      "The menu's sheet offered Not Now, which would record a second decline")
    waitFor(app, "hooks.install", "Expected Install").tap()
    waitFor(app, "hooks.result", "Expected the install's result", timeout: 15)
    waitFor(app, "hooks.done", "Expected Done").tap()

    // Asked again, the menu reports the hooks are there.
    row.press(forDuration: 1.0)
    waitFor(app, "hosts.menuInstallHooks", "Expected the menu item again").tap()
    waitFor(app, "hooks.installed", "Expected the sheet to say the hooks are installed", timeout: 15)
    XCTAssertFalse(
      app.descendants(matching: .any).matching(identifier: "hooks.install").firstMatch.exists,
      "Install was offered on a host that already has the hooks")
  }

  /// A launch that restores the last host connects it with nobody having asked, so it must
  /// not offer. The first launch's host already has the hooks and only stores the
  /// selection. The fixture is per process, so the second launch's host lacks them, and
  /// only the missing row tap keeps the offer away.
  func testARestoredHostConnectsWithoutAnOffer() {
    let app = XCUIApplication()
    app.launchArguments += ["-uiTesting", "-uiTestingSeedHost", "-uiTestingConnected"]
    app.launch()
    waitFor(app, "hosts.row", "Expected the seeded host").tap()
    waitFor(app, "connect.connected", "Expected the tapped host to connect", timeout: 15)
    app.terminate()

    app.launchArguments += ["-uiTestingRestoreSelection", "-uiTestingHookOffer"]
    app.launch()
    waitFor(app, "connect.connected", "Expected the restored host to connect on its own", timeout: 15)
    let offer = app.descendants(matching: .any).matching(identifier: "hooks.absent").firstMatch
    XCTAssertFalse(
      offer.waitForExistence(timeout: 5),
      "A restored selection offered the hooks, which only a row tap may do.\nTree was:\n\(app.debugDescription)")
  }

  /// Nothing on screen carries a value from the host's settings file.
  private func requireNoSecret(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let leaks = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", secret))
    XCTAssertEqual(leaks.count, 0, "A value from the settings file reached the screen", file: file, line: line)
  }

  /// Waits for absence rather than sampling once.
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
