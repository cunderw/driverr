import XCTest

/// Install a Key, from the host screen.
///
/// The sheet is presented at `ContentView`'s root from a row in the host screen, which on
/// iPad is the detail column, where a presentation of its own fails silently. This shows it
/// comes up, goes, and that the row goes with the password. The phases are
/// `KeyInstallModelTests`, and the command is `AuthorizedKeyInstallCommandsTests`.
///
/// Relaunches per test, because tests generate keys, write the fake host's
/// `authorized_keys` and save hosts with a key.
@MainActor
final class KeyInstallUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  func testInstallTestsTheKeyAndUseThisKeySwitchesTheHost() {
    let app = connectedHostApp()
    openSheet(app)

    waitFor(app, "keyInstall.intro", "Expected the sheet's first line")
    waitFor(app, "keyInstall.generate", "Expected Generate a New Key").tap()
    waitFor(app, "keyInstall.key", "Expected the new key in the list")
    waitFor(app, "keyInstall.install", "Expected Install").tap()

    let result = waitFor(app, "keyInstall.result", "Expected the install and the test login", timeout: 15)
    XCTAssertTrue(result.label.contains("Installed on"), "Unexpected result: \(result.label)")
    let useKey = waitFor(app, "keyInstall.useKey", "Expected Use This Key after a login that worked")
    // The offer's way out is Not Now. A Done there read as accepting the offer.
    waitFor(app, "keyInstall.notNow", "Expected Not Now beside the offer")
    XCTAssertFalse(element(app, "keyInstall.done").exists, "Done was offered beside Use This Key")
    useKey.tap()

    let switched = waitFor(app, "keyInstall.switched", "Expected the host to switch to the key", timeout: 15)
    XCTAssertTrue(switched.label.contains("now logs in with"), "Unexpected result: \(switched.label)")
    XCTAssertTrue(switched.label.contains("deleted the password"), "The password was not deleted: \(switched.label)")

    waitFor(app, "keyInstall.done", "Expected Done").tap()
    requireGone(app, "keyInstall.done", "Done did not close the sheet")
    requireGone(app, "host.installKey", "The row stayed on a host that now uses a key")
  }

  func testALoginThatFailsSaysSoAndDoesNotOfferTheSwitch() {
    let app = connectedHostApp(["-uiTestingKeyLoginRefused"])
    openSheet(app)

    waitFor(app, "keyInstall.generate", "Expected Generate a New Key").tap()
    waitFor(app, "keyInstall.install", "Expected Install").tap()

    let failure = waitFor(app, "keyInstall.loginFailed", "Expected the failed test login", timeout: 15)
    XCTAssertTrue(failure.label.contains("keeps using the password"), "Unexpected failure: \(failure.label)")
    XCTAssertFalse(element(app, "keyInstall.useKey").exists, "Use This Key was offered after a failed login")

    waitFor(app, "keyInstall.done", "Expected Done").tap()
    requireGone(app, "keyInstall.done", "Done did not close the sheet")
    XCTAssertTrue(element(app, "host.installKey").exists, "The row went although the host still uses a password")
  }

  func testAnInstallTheHostRefusesSaysWhy() {
    let app = connectedHostApp(["-uiTestingKeyInstallFails"])
    openSheet(app)

    waitFor(app, "keyInstall.generate", "Expected Generate a New Key").tap()
    waitFor(app, "keyInstall.install", "Expected Install").tap()

    let failure = waitFor(app, "keyInstall.failure", "Expected the host's refusal", timeout: 15)
    XCTAssertTrue(failure.label.contains("read-only file system"), "Unexpected failure: \(failure.label)")
    let retry = waitFor(app, "keyInstall.install", "Expected Try Again")
    XCTAssertTrue(retry.label.contains("Try Again"), "Expected Try Again, found: \(retry.label)")

    waitFor(app, "keyInstall.cancel", "Expected Cancel").tap()
    requireGone(app, "keyInstall.cancel", "Cancel did not close the sheet")
  }

  // MARK: - Helpers

  /// Swipes to the row at the bottom of the host screen and taps it. Waits for the connect's
  /// session first, so the form has stopped growing before it is swiped.
  private func openSheet(_ app: XCUIApplication) {
    waitFor(app, "session.pane", "Expected the seeded session on the host screen", timeout: 15)
    let row = element(app, "host.installKey")
    for _ in 0..<8 where !(row.exists && row.isHittable) {
      app.swipeUp()
    }
    XCTAssertTrue(row.waitForExistence(timeout: 5), "Expected Install a Key on the host screen")
    row.tap()
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
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
