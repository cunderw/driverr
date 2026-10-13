import XCTest

/// Deleting a host asks first, with both buttons, from the root.
///
/// Clearing the password and the trusted key is `HostListModelTests`. A confirmation on a
/// `List` row would silently not appear, and the row is gone before it could be confirmed.
///
/// Cancel matters most. As a `confirmationDialog` at the root, with no source rectangle,
/// UIKit drew an anchorless popover and dropped the cancel action, with no warning.
///
/// Relaunches per test, because it deletes a host.
@MainActor
final class HostDeleteUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  /// Reveals the row's swipe actions and taps Delete.
  private func swipeToDelete(_ app: XCUIApplication) {
    let row = waitFor(app, "hosts.row", "Expected the seeded host")
    let delete = element(app, "hosts.delete")
    if !delete.exists {
      row.swipeLeft()
    }
    waitFor(app, "hosts.delete", "Expected a delete action behind the row's swipe").tap()
  }

  func testDeletingAHostAsksFirstAndCancelKeepsIt() {
    let app = XCUIApplication()
    app.launchArguments += ["-uiTesting", "-uiTestingSeedHost"]
    app.launch()

    swipeToDelete(app)

    // Asks first, because a swipe is easy to make by accident while scrolling.
    waitFor(app, "hosts.confirmDelete", "Expected a confirmation before anything is removed")
    // By identifier. `app.buttons["Cancel"]` also reads its string as an identifier.
    waitFor(app, "hosts.cancelDelete", "Expected a way to back out").tap()

    XCTAssertTrue(
      waitFor(app, "hosts.row", "Expected the host to survive a cancelled delete").exists,
      "Cancelling the confirmation removed the host anyway."
    )

    swipeToDelete(app)
    waitFor(app, "hosts.confirmDelete", "Expected the confirmation again").tap()

    // `app.images`, as in `LaunchUITests.testLaunchesToAnEmptyHostList`.
    XCTAssertTrue(
      app.images["hosts.empty"].waitForExistence(timeout: 10),
      "Confirming the delete left the host in the list.\nTree was:\n\(app.debugDescription)"
    )
  }
}
