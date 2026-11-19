import XCTest

/// New Agent, from the host screen: the sheet, the folder browser pushed inside it, and the
/// pane a start opens.
///
/// What only a simulator shows. The sheet is presented at `ContentView`'s root from a toolbar
/// button on the host screen, which on iPad is the detail column, where a presentation of its
/// own fails silently. The browser is a push on the sheet's own `NavigationStack`, and Use
/// Folder must pop back to the form with the folder in it. A start must take the sheet down and
/// open the pane scene on both routes. The rules are `swift test` (`NewAgentFormTests`,
/// `FakeDirectoryHostTests`, `AgentFoldersTests`) and the models are `DriverrTests`
/// (`NewAgentTests`).
///
/// Relaunches per test, because a start adds a workspace to the fake session.
@MainActor
final class NewAgentUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  func testTheBrowserPicksAFolderAndStartOpensThePane() {
    let app = connectedHostApp()
    openSheet(app)

    waitFor(app, "newAgent.browse", "Expected Browse Folders").tap()
    expectBrowser(app, at: "/home/uitest")
    folderRow(app, "dev").tap()
    expectBrowser(app, at: "/home/uitest/dev")
    folderRow(app, "tower").tap()
    expectBrowser(app, at: "/home/uitest/dev/tower")
    waitFor(app, "newAgent.browser.use", "Expected Use Folder").tap()

    requireGone(app, "newAgent.browser.path", "Use Folder did not return to the form")
    let folder = waitFor(app, "newAgent.folder", "Expected the folder field")
    XCTAssertEqual(folder.value as? String, "/home/uitest/dev/tower")

    let start = scrollIntoReach(app, "newAgent.start")
    XCTAssertTrue(start.label.contains("Claude Code"), "Unexpected Start label: \(start.label)")
    start.tap()

    requireGone(app, "newAgent.start", "A start did not take the sheet down", timeout: 15)
    waitForPaneScene(app, "Expected the started agent's pane to open")
    leavePaneScene(app)
  }

  func testTheBrowserSaysWhatItCannotOpenAndCutsALongList() {
    let app = connectedHostApp()
    openSheet(app)

    waitFor(app, "newAgent.browse", "Expected Browse Folders").tap()
    expectBrowser(app, at: "/home/uitest")
    folderRow(app, "Documents").tap()
    let error = waitFor(app, "newAgent.browser.error", "Expected the folder's failure")
    XCTAssertTrue(error.label.contains("Could not open"), "Unexpected failure: \(error.label)")
    XCTAssertFalse(
      element(app, "newAgent.browser.use").isEnabled, "Use Folder was offered for a folder that did not open")
    // The browser's own back button. The host screen's bar is in the tree too, under the sheet.
    app.navigationBars.containing(.any, identifier: "newAgent.browser.use").firstMatch
      .buttons.element(boundBy: 0).tap()

    expectBrowser(app, at: "/home/uitest")
    folderRow(app, "dev").tap()
    folderRow(app, "monorepo").tap()
    folderRow(app, "packages").tap()
    expectBrowser(app, at: "/home/uitest/dev/monorepo/packages")
    waitFor(app, "newAgent.browser.truncated", "Expected the notice for a cut listing")
  }

  func testARecentFolderFillsTheFieldAndCancelCloses() {
    let app = connectedHostApp()
    openSheet(app)

    let recent = app.descendants(matching: .any).matching(identifier: "newAgent.recent")
      .matching(NSPredicate(format: "label CONTAINS %@", "~/dev/tower")).firstMatch
    XCTAssertTrue(recent.waitForExistence(timeout: 10), "Expected the session's folders.\nTree was:\n\(app.debugDescription)")
    recent.tap()
    XCTAssertEqual(element(app, "newAgent.folder").value as? String, "~/dev/tower")

    // Codex renames the Start button, so the picker reaches the form.
    app.buttons["Codex"].firstMatch.tap()
    // Below the fold on a phone, where a lazy form has not built it yet.
    let start = scrollIntoReach(app, "newAgent.start")
    XCTAssertTrue(start.label.contains("Codex"), "Start did not follow the picker: \(start.label)")

    waitFor(app, "newAgent.cancel", "Expected Cancel").tap()
    requireGone(app, "newAgent.folder", "Cancel did not close the sheet")
  }

  /// herdr's TUI answers a missing program after its pane is open. The sheet says so inline and
  /// offers that pane, because a second start would open a second one.
  func testAnAgentThatDidNotStartOffersItsOpenPane() {
    let app = connectedHostApp(["-uiTestingAgentDidNotStart"])
    openSheet(app)

    waitFor(app, "newAgent.recent", "Expected the session's folders").tap()
    scrollIntoReach(app, "newAgent.start").tap()

    let error = scrollIntoReach(app, "newAgent.error")
    XCTAssertTrue(error.label.contains("did not start"), "Unexpected failure: \(error.label)")
    let open = scrollIntoReach(app, "newAgent.openPane")
    XCTAssertTrue(open.label.contains("Open driverr"), "Unexpected button: \(open.label)")
    open.tap()

    requireGone(app, "newAgent.openPane", "Open did not take the sheet down", timeout: 15)
    waitForPaneScene(app, "Expected the pane the start left open")
    leavePaneScene(app)
  }

  // MARK: - Helpers

  /// Waits for the seeded session, so the toolbar has its final buttons, then opens the sheet.
  private func openSheet(_ app: XCUIApplication) {
    waitFor(app, "session.pane", "Expected the seeded session on the host screen", timeout: 15)
    waitFor(app, "host.newAgent", "Expected New Agent in the host screen's toolbar").tap()
    waitFor(app, "newAgent.folder", "Expected the New Agent sheet")
  }

  /// Waits for the browser to show `path`. The header is the resolved path.
  private func expectBrowser(_ app: XCUIApplication, at path: String) {
    let header = app.descendants(matching: .any).matching(identifier: "newAgent.browser.path")
      .matching(NSPredicate(format: "label == %@", path)).firstMatch
    XCTAssertTrue(
      header.waitForExistence(timeout: 10),
      "Expected the browser at \(path).\nTree was:\n\(app.debugDescription)")
  }

  private func folderRow(_ app: XCUIApplication, _ name: String) -> XCUIElement {
    let row = app.descendants(matching: .any).matching(identifier: "newAgent.browser.folder")
      .matching(NSPredicate(format: "label == %@", name)).firstMatch
    XCTAssertTrue(
      row.waitForExistence(timeout: 10),
      "Expected the folder \(name).\nTree was:\n\(app.debugDescription)")
    return row
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  /// Waits for absence rather than sampling once. XCUITest sees through a push.
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
}
