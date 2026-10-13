import XCTest

/// The sidebar tree against `FakeControl`.
///
/// Relaunches per test: connecting records a trust decision, and several tests rename.
///
/// Ordering, rollups and title fallbacks are covered in `DriverrKit` against the same seed.
/// This shows the tree reaching the screen with its three levels intact.
@MainActor
final class SessionTreeUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func all(_ app: XCUIApplication, _ identifier: String) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: identifier)
  }

  /// Scrolls the host screen until a row with this text is on it. A lazily built row below
  /// the fold never appears on its own, so `require` would call it missing.
  @discardableResult
  private func scrollToText(
    _ app: XCUIApplication,
    _ text: String,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> XCUIElement {
    let match = app.staticTexts[text]
    for _ in 0..<6 {
      if match.exists { return match }
      app.swipeUp()
    }
    XCTAssertTrue(
      match.exists,
      "\(message)\nLooked for '\(text)' after scrolling. Tree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
    return match
  }

  /// Any element whose label is exactly `text`, of whatever type.
  ///
  /// Not `staticTexts`: a shell pane's row is a `Button` with no badge or subtitle, so it
  /// publishes no `StaticText` and a static-text query skips it.
  private func labelled(_ app: XCUIApplication, _ text: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "label == %@", text))
      .firstMatch
  }

  /// Scrolls to the workspace row whose label mentions `name`. Matched by `CONTAINS`
  /// because the row's label combines status, name and tab count: "Finished, wiki, 1 tab".
  private func workspaceRow(
    _ app: XCUIApplication,
    naming name: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> XCUIElement {
    let row = all(app, "session.workspace")
      .matching(NSPredicate(format: "label CONTAINS %@", name))
      .firstMatch
    // Wait before scrolling. The tree arrives after the screen is up, and only "below the
    // fold" is fixed by swiping. The wait is on any workspace row, because the named one
    // may be below the fold and never appear on its own.
    _ = all(app, "session.workspace").firstMatch.waitForExistence(timeout: 10)
    for _ in 0..<6 where !row.exists {
      app.swipeUp()
    }
    XCTAssertTrue(
      row.exists,
      "Expected a workspace row naming '\(name)'.\nTree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
    return row
  }

  /// Waits for the fixture's scripted flip, so rows are looked up where they will stay.
  ///
  /// `FakeControl.blockingScript`'s second snapshot blocks a second pane soon after
  /// connect. That adds a Needs-you row and moves the tree down, which on the phone takes a
  /// row near the bottom out of the tree. The last snapshot repeats, so nothing moves after.
  private func waitForSettledTree(_ app: XCUIApplication) {
    let blocked = all(app, "session.blockedPane")
    expectation(for: NSPredicate(format: "count >= 2"), evaluatedWith: blocked)
    waitForExpectations(timeout: 20)
  }

  /// Waits until nothing is labelled `text`. A collapse is animated, so a single check
  /// catches the row on its way out.
  private func requireTextGone(
    _ app: XCUIApplication,
    _ text: String,
    _ message: String,
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let waiter = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"),
      object: labelled(app, text)
    )
    guard XCTWaiter().wait(for: [waiter], timeout: timeout) == .completed else {
      XCTFail(
        "\(message)\n'\(text)' was still there after \(timeout)s.\nTree was:\n\(app.debugDescription)",
        file: file,
        line: line
      )
      return
    }
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

  // No exhaustive scroll-and-search. A `Form` is lazy and recycling, so no assertion can see
  // a long tree at once, and long swipe loops got tests killed. Exhaustive content is a
  // `DriverrKit` question.

  /// A connected seeded host, which puts a herdr session on screen.
  private func connectedHost() -> XCUIApplication {
    XCUIDevice.shared.orientation = .portrait
    return connectedHostApp()
  }

  func testConnectingShowsTheHerdrTree() {
    let app = connectedHost()

    require(app, "session.workspace", "Expected the session tree to render")

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "session-tree"
    shot.lifetime = .keepAlways
    add(shot)

    // All three levels reached the screen. No exact counts, because a lazy `Form`'s row
    // count is the viewport's size, not the session's.
    XCTAssertGreaterThan(all(app, "session.workspace").count, 0, "expected a workspace row")
    XCTAssertGreaterThan(all(app, "session.tab").count, 0, "expected a tab row")
    XCTAssertGreaterThan(all(app, "session.pane").count, 0, "expected a pane row")
    XCTAssertTrue(app.staticTexts["driverr"].exists, "expected the first workspace by name")
    XCTAssertTrue(app.staticTexts["app"].exists, "expected its first tab by name")
  }

  func testPanesShowTheirAgentAndTitle() {
    let app = connectedHost()
    require(app, "session.pane", "Expected panes")

    // In screen order, and scrolled to. Rows below the fold are not built, and the fold
    // moves when the fake's second poll adds a Needs-you row.
    XCTAssertTrue(app.staticTexts["needs a decision"].exists, "expected the blocked pane")
    scrollToText(app, "terminal wiring", "Expected a pane title")
    // The agent's name and state share the subtitle, so there is no bare "Claude".
    XCTAssertTrue(
      app.staticTexts["Claude · Working"].firstMatch.exists,
      "expected the agent and its state"
    )
  }

  func testPullingTheHostFormRefreshesTheSession() {
    let app = connectedHost()
    let workspace = require(app, "session.workspace", "Expected the session tree")

    // Pull to refresh.
    app.swipeDown()

    // A refresh that blanks the sidebar reads as having lost the session.
    XCTAssertTrue(
      workspace.waitForExistence(timeout: 5),
      "Expected the tree to survive a refresh"
    )
    XCTAssertTrue(
      app.staticTexts["needs a decision"].exists,
      "Expected the tree to still be there after a refresh"
    )
  }

  /// A workspace opens and closes, and only the focused one starts open, so one large
  /// workspace does not bury the others.
  func testAWorkspaceCollapsesAndExpands() {
    let app = connectedHost()
    require(app, "session.workspace", "Expected the session tree")
    waitForSettledTree(app)

    // `terminal wiring` is in the focused workspace `driverr`.
    scrollToText(app, "terminal wiring", "Expected the focused workspace to start open")
    // `index rebuild` is in the unfocused `wiki`.
    requireTextGone(app, "index rebuild", "Expected an unfocused workspace to start shut")

    workspaceRow(app, naming: "wiki").tap()
    scrollToText(app, "index rebuild", "Expected the workspace to open on a tap")

    // A finished agent shows as done, not as unknown.
    XCTAssertTrue(
      element(app, "status.done").exists,
      "Expected a finished agent to say so.\nTree was:\n\(app.debugDescription)"
    )

    workspaceRow(app, naming: "wiki").tap()
    requireTextGone(app, "index rebuild", "Expected the workspace to close again")
    XCTAssertTrue(
      workspaceRow(app, naming: "wiki").exists,
      "Expected to still be looking at the tree"
    )
  }

  /// The sidebar updates with no refresh. The fake's second snapshot blocks `schema sync`,
  /// so a second blocked row appearing with no interaction proves the poll loop ran.
  func testTheTreeUpdatesWithoutAManualRefresh() {
    let app = connectedHost()
    require(app, "session.workspace", "Expected the session tree")

    // Counted on `session.blockedPane`, not on badges. A blocked pane wears a badge in
    // Needs you and in the tree, so the seed already starts with two badges.
    let blocked = all(app, "session.blockedPane")
    let secondAppeared = NSPredicate(format: "count >= 2")
    expectation(for: secondAppeared, evaluatedWith: blocked)
    waitForExpectations(timeout: 20)

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "session-tree-live-update"
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// Opens a row's context menu, retrying the press, because one press does not reliably
  /// open it on an unchanged tree.
  @discardableResult
  private func openMenu(
    _ app: XCUIApplication,
    on row: XCUIElement,
    expecting item: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> XCUIElement {
    let match = element(app, item)
    for _ in 0..<4 where !match.exists {
      row.press(forDuration: 1.2)
      _ = match.waitForExistence(timeout: 3)
    }
    XCTAssertTrue(
      match.exists,
      "Expected '\(item)' in the row's context menu.\nTree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
    return match
  }

  /// Reveals a row's trailing swipe action, retrying the swipe.
  ///
  /// `SessionTreeView` animates each three-second poll's new tree on purpose, and a swipe
  /// that lands during one is swallowed. So settle the row, swipe, and retry if nothing
  /// appeared, as `HostDeleteUITests.swipeToDelete` does.
  @discardableResult
  private func revealSwipeAction(
    _ app: XCUIApplication,
    on row: XCUIElement,
    expecting action: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> XCUIElement {
    let match = element(app, action)
    for _ in 0..<4 where !match.exists {
      waitUntilStill(app, row, waitingForKeyboard: false, file: file, line: line)
      row.swipeLeft()
      _ = match.waitForExistence(timeout: 3)
    }
    XCTAssertTrue(
      match.exists,
      "Expected '\(action)' behind the row's swipe.\nTree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
    return match
  }

  /// Types into the inline rename field and commits.
  private func rename(_ app: XCUIApplication, to name: String) {
    let field = require(app, "session.rename.field", "Expected an inline rename field")
    // The field asks for focus itself and selects the whole draft, so this replaces the
    // name rather than appending to it.
    waitUntilStill(app, field)
    field.typeText(name)
    require(app, "session.rename.commit", "Expected a Rename button").tap()
  }

  /// A workspace is renamed from the tree, and the new name shows without waiting for the
  /// poll.
  ///
  /// The fake edits its own tree on a rename, so this proves the right target was renamed.
  /// A long press, because a `DisclosureGroup` in this `Form` takes no `swipeActions`.
  func testRenamingAWorkspaceFromItsMenuShowsTheNewName() {
    let app = connectedHost()
    waitForSettledTree(app)
    let row = workspaceRow(app, naming: "driverr")

    openMenu(app, on: row, expecting: "session.workspace.renameMenu").tap()
    rename(app, to: "shipping")

    let renamed = all(app, "session.workspace")
      .matching(NSPredicate(format: "label CONTAINS %@", "shipping"))
      .firstMatch
    XCTAssertTrue(
      renamed.waitForExistence(timeout: 10),
      "Expected the workspace to be called 'shipping'.\nTree was:\n\(app.debugDescription)"
    )

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "session-tree-renamed-workspace"
    shot.lifetime = .keepAlways
    add(shot)

    // The others are untouched, since a rename of the wrong target could also produce the
    // row above.
    XCTAssertTrue(
      all(app, "session.workspace").matching(NSPredicate(format: "label CONTAINS %@", "tower"))
        .firstMatch.exists,
      "Expected the other workspaces to keep their names.\nTree was:\n\(app.debugDescription)"
    )
    XCTAssertEqual(
      all(app, "session.workspace").matching(NSPredicate(format: "label CONTAINS %@", "driverr"))
        .count,
      0,
      "Expected no workspace still called 'driverr'.\nTree was:\n\(app.debugDescription)"
    )
  }

  /// A tab header is a plain row, so it takes a swipe action. See `workspaceGroup` in
  /// `SessionTreeView`.
  func testRenamingATabFromASwipe() {
    let app = connectedHost()
    waitForSettledTree(app)
    let tab = all(app, "session.tab")
      .matching(NSPredicate(format: "label CONTAINS %@", "app"))
      .firstMatch
    XCTAssertTrue(
      tab.waitForExistence(timeout: 15),
      "Expected the 'app' tab header.\nTree was:\n\(app.debugDescription)"
    )

    revealSwipeAction(app, on: tab, expecting: "session.tab.rename").tap()
    rename(app, to: "build logs")

    let renamed = all(app, "session.tab")
      .matching(NSPredicate(format: "label CONTAINS %@", "build logs"))
      .firstMatch
    XCTAssertTrue(
      renamed.waitForExistence(timeout: 10),
      "Expected the tab to be called 'build logs'.\nTree was:\n\(app.debugDescription)"
    )
    XCTAssertTrue(
      workspaceRow(app, naming: "driverr").exists,
      "Expected the workspace holding it to keep its own name"
    )

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "session-tree-renamed-tab"
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// An inline tab is renamed from the workspace row's menu.
  ///
  /// `tower` holds one named tab, so `Workspace.tabHeaderStyle` folds it into the workspace
  /// row as "tower · api" with no tab row. The workspace menu is its only route.
  func testRenamingAnInlineTabFromTheWorkspaceMenu() {
    let app = connectedHost()
    waitForSettledTree(app)
    let row = workspaceRow(app, naming: "tower")

    openMenu(app, on: row, expecting: "session.workspace.renameTabMenu").tap()
    rename(app, to: "gateway")

    // An inline tab's name is drawn on the workspace row; there is no `session.tab`.
    let renamed = all(app, "session.workspace")
      .matching(NSPredicate(format: "label CONTAINS %@", "gateway"))
      .firstMatch
    XCTAssertTrue(
      renamed.waitForExistence(timeout: 10),
      "Expected the inline tab to be called 'gateway'.\nTree was:\n\(app.debugDescription)"
    )
    // The workspace keeps its name. A rename sent with the workspace id would pass the check
    // above.
    XCTAssertTrue(
      renamed.label.contains("tower"),
      "Expected the workspace to still be called 'tower', not renamed in its place. "
        + "Row label was: \(renamed.label)"
    )

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "session-tree-renamed-inline-tab"
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// Cancelling leaves the name alone. A long press is easy to make by accident while
  /// scrolling.
  func testCancellingARenameLeavesTheNameAlone() {
    let app = connectedHost()
    waitForSettledTree(app)
    let row = workspaceRow(app, naming: "driverr")

    openMenu(app, on: row, expecting: "session.workspace.renameMenu").tap()
    let field = require(app, "session.rename.field", "Expected an inline rename field")
    waitUntilStill(app, field)
    field.typeText("not this")
    require(app, "session.rename.cancel", "Expected a way to back out").tap()

    // Waited for, because the row animates out.
    let gone = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"),
      object: element(app, "session.rename.field")
    )
    XCTAssertEqual(
      XCTWaiter().wait(for: [gone], timeout: 5),
      .completed,
      "Expected the rename row to close.\nTree was:\n\(app.debugDescription)"
    )
    XCTAssertTrue(
      workspaceRow(app, naming: "driverr").exists,
      "Expected the workspace to keep its name"
    )
  }

  func testDisconnectingTakesTheSessionWithIt() {
    let app = connectedHost()
    require(app, "session.workspace", "Expected the session tree")

    // Disconnect is behind the pill once connected.
    require(app, "connect.connected", "Expected the connection pill").tap()
    require(app, "connect.disconnect", "Expected a disconnect button").tap()

    // A session left on screen after disconnecting is stale state shown as current.
    let gone = NSPredicate(format: "exists == false")
    expectation(for: gone, evaluatedWith: element(app, "session.workspace"))
    waitForExpectations(timeout: 5)
  }
}
