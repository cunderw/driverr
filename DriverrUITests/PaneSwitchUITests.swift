import UIKit
import XCTest

/// The pane switcher: the toolbar's `terminal.panes` button and the sheet behind it.
///
/// What the sheet contains is `PaneStripModelTests` and `PaneThumbnailModelTests`. This
/// class covers that the button presents a tile per pane with the current one marked, that a
/// tile switches the terminal in place, that a warm switch shows no spinner, that New pane
/// produces a pane the scene follows, and that the screen is still leavable.
///
/// The count's absence when only the current pane is blocked is not asserted here, because
/// the fake blocks a second pane three seconds in and the test cannot know which side of that
/// tick it is on. `PaneStripModelTests` covers it.
///
/// Relaunches per test: every test connects, which records a trust decision, and leaves a
/// terminal open on a pane it switched to.
@MainActor
final class PaneSwitchUITests: XCTestCase {
  /// `FakeControl.seededTree` in `SessionTree.allPanes` order: three workspaces, six panes.
  /// The sheet must list exactly this, in this order.
  private let seededPaneTitles = [
    "terminal wiring",  // w1:p1, working
    "needs a decision",  // w1:p2, blocked
    "swift test",  // w1:p3, shell
    "schema sync",  // w2:p1, idle until the fake's second poll blocks it
    "index rebuild",  // w3:p1, done
    "wiki",  // w3:p2, shell
  ]

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  // MARK: - Plumbing

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

  /// Waits for an element to stop existing. `XCTAssertFalse(element.exists)` samples once,
  /// and XCUITest sees through a presentation, so it passes on one that never dismissed.
  private func requireGone(
    _ app: XCUIApplication,
    _ identifier: String,
    _ message: String,
    timeout: TimeInterval = 10,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    requireGone(
      app,
      element(app, identifier),
      named: identifier,
      message,
      timeout: timeout,
      file: file,
      line: line
    )
  }

  /// The same wait against an element the caller built.
  ///
  /// Lets a caller pass a narrower query than `descendants(matching: .any)`. Each evaluation
  /// is a full snapshot, and on `Driverr iPad`, with the host screen beside the terminal, one
  /// took about five seconds while the app was busy.
  private func requireGone(
    _ app: XCUIApplication,
    _ element: XCUIElement,
    named identifier: String,
    _ message: String,
    timeout: TimeInterval = 10,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let predicate = NSPredicate(format: "exists == false")
    let waiter = XCTNSPredicateExpectation(predicate: predicate, object: element)
    guard XCTWaiter().wait(for: [waiter], timeout: timeout) == .completed else {
      XCTFail(
        "\(message)\n'\(identifier)' was still there after \(timeout)s."
          + "\nTree was:\n\(app.debugDescription)",
        file: file,
        line: line
      )
      return
    }
  }

  /// Waits for the sheet to go, querying only buttons, since a tile is a `Button`.
  ///
  /// The budget is generous because the app is at its busiest here, opening another pane or
  /// splitting one, and the wait is bounded by how fast the app settles.
  private func requireSheetGone(
    _ app: XCUIApplication,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    requireGone(
      app,
      app.buttons.matching(identifier: "terminal.sheet.pane").firstMatch,
      named: "terminal.sheet.pane",
      message,
      timeout: 30,
      file: file,
      line: line
    )
  }

  /// The emulator paints on its own schedule, so poll rather than assert once.
  private func waitForTerminalText(
    _ terminal: XCUIElement,
    containing text: String,
    timeout: TimeInterval = 15
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if (terminal.value as? String)?.contains(text) == true { return true }
      _ = terminal.waitForExistence(timeout: 0.2)
    }
    return (terminal.value as? String)?.contains(text) == true
  }

  /// Connects to the seeded host and opens the terminal on the blocked pane `w1:p2`
  /// (`term_w1p2`).
  private func terminalOnTheBlockedPane() -> (app: XCUIApplication, terminal: XCUIElement) {
    XCUIDevice.shared.orientation = .portrait

    // Seeded, because this class is not about connecting.
    let app = connectedHostApp()

    // Named, not by position, because the Needs-you list re-sorts on the fake's second poll.
    waitForBothBlockedPanes(app)
    let row = blockedPaneRow(app, titled: "needs a decision")
    XCTAssertTrue(row.isHittable, "Expected the Needs-you row to be hittable before tapping.")
    row.tap()
    showTerminal(app)
    let terminal = require(app, "terminal.view", "Expected the terminal to open on the pane")
    return (app, terminal)
  }


  /// An agent pane opens on its chat, so a test that wants the terminal asks for it. Every
  /// caller is on an agent pane, so a missing segment fails.
  private func showTerminal(_ app: XCUIApplication) {
    require(app, "pane.surface.terminal", "Expected the Terminal segment on an agent pane").tap()
  }

  /// Every tile carrying `identifier`, in the sheet's own order.
  ///
  /// The identifier is on each tile, not on the grid, so the sheet reads as several elements
  /// sharing one identifier.
  private func tiles(_ app: XCUIApplication) -> [XCUIElement] {
    app.buttons.matching(identifier: "terminal.sheet.pane").allElementsBoundByIndex
  }

  /// The tile whose label starts with `title`. A tile's label reads "<title>, <state>", so a
  /// prefix match names one without depending on how the state is worded.
  private func paneTile(_ app: XCUIApplication, titled title: String) -> XCUIElement {
    app.buttons.matching(identifier: "terminal.sheet.pane")
      .matching(NSPredicate(format: "label BEGINSWITH %@", title))
      .firstMatch
  }

  /// Opens the sheet from the toolbar's panes button.
  @discardableResult
  private func openPaneSheet(
    _ app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> XCUIElement {
    require(app, "terminal.panes", "Expected the panes button", file: file, line: line)
      .tap()
    let title = app.staticTexts["Panes on workbox"]
    XCTAssertTrue(
      title.waitForExistence(timeout: 10),
      "Expected the sheet to be titled for the host.\nTree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
    return title
  }

  /// Drags the sheet until `element` is reachable.
  ///
  /// The sheet opens at its medium detent, so the last tiles and New pane start below the
  /// fold. Every tile exists from the start, because the grid is not lazy, but a tap needs one
  /// on screen. `swipeUp()` is inert on a detented sheet; see `dragSheetToReveal`.
  ///
  /// Anchored on the first workspace header, which is always on screen near the top.
  private func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
    let anchor = app.descendants(matching: .any)
      .matching(identifier: "terminal.sheet.workspace")
      .firstMatch
    // Tiles share one identifier, so a failure names the label.
    let description = element.label.isEmpty ? element.identifier : element.label
    dragSheetToReveal(
      app,
      element,
      describedAs: description,
      anchoredAt: anchor,
      "Expected the sheet to bring '\(description)' into reach"
    )
  }

  /// Switches pane through the sheet, and waits for the sheet to go, because XCUITest reads
  /// the terminal through a sheet that is still up.
  private func switchToPane(
    _ app: XCUIApplication,
    titled title: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    openPaneSheet(app, file: file, line: line)
    let tile = paneTile(app, titled: title)
    XCTAssertTrue(
      tile.waitForExistence(timeout: 10),
      "Expected a tile for '\(title)'.\nTree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
    reveal(app, tile)
    XCTAssertTrue(
      tile.isHittable,
      "Tile '\(title)' never became reachable at \(tile.frame).\nTree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
    tile.tap()
    requireSheetGone(
      app,
      "Expected choosing a pane to dismiss the sheet",
      file: file,
      line: line
    )
  }

  /// Everything the panes button says, in one string.
  ///
  /// `PanesButtonLabel` publishes the count as the button's accessibility value. The label
  /// and static texts are read too, so a failure prints all of it.
  private func badgeText(_ app: XCUIApplication) -> String {
    let button = element(app, "terminal.panes")
    guard button.exists else { return "" }
    var parts = [button.label, (button.value as? String) ?? ""]
    parts += button.staticTexts.allElementsBoundByIndex.map(\.label)
    return parts.joined(separator: " | ")
  }

  // MARK: - What the switcher shows

  /// The panes button counts the panes that need an answer elsewhere, so the reason to open
  /// the switcher is visible without opening it.
  ///
  /// The fake blocks `w2:p1` on its next poll while the terminal is on blocked `w1:p2`, so
  /// the count reads 1, not 2. The rule is `PaneStripModelTests`'
  /// `blockedElsewhereCountMatchesTheNeedsYouFilter`; this checks it reaches the screen.
  func testThePanesButtonCountsThePanesThatNeedYouElsewhere() {
    let app = terminalOnTheBlockedPane().app
    require(app, "terminal.panes", "Expected a panes button in the toolbar")

    // Zero at first, because the only blocked pane is on screen. Wait for the second poll.
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline && !badgeText(app).contains("1") {
      usleep(200_000)
    }

    let shown = badgeText(app)
    XCTAssertTrue(
      shown.contains("1"),
      "Expected the panes button to carry the count of panes needing an answer. It read "
        + "'\(shown)'.\nTree was:\n\(app.debugDescription)"
    )
    XCTAssertFalse(
      shown.contains("2"),
      "The pane on screen is blocked too and must not be counted. It read '\(shown)'."
    )
  }

  // MARK: - Switching

  /// Choosing another pane changes the scene in place, and coming back to a warm one paints
  /// with no opening state. That the sheet then agrees about the current pane is
  /// `testTappingATileSwitchesThePaneAndDismissesTheSheet`.
  func testChoosingAPaneSwitchesItInPlace() {
    let (app, terminal) = terminalOnTheBlockedPane()

    // The bridge frame names its terminal, which proves which pane is attached.
    XCTAssertTrue(
      waitForTerminalText(terminal, containing: "herdr pane term_w1p2"),
      "Expected to start on the blocked pane. Terminal showed: \(String(describing: terminal.value))"
    )

    switchToPane(app, titled: "swift test")
    XCTAssertTrue(
      waitForTerminalText(terminal, containing: "herdr pane term_w1p3"),
      "Expected the tile to switch the terminal to w1:p3. Terminal showed: "
        + String(describing: terminal.value)
    )

    // Back to a warm pane, which holds a live emulator and paints in the tap's frame, so the
    // opening spinner must never appear.
    let opening = element(app, "terminal.progress")
    switchToPane(app, titled: "needs a decision")
    XCTAssertFalse(
      opening.waitForExistence(timeout: 3),
      "A warm switch must not go through the opening state.\nTree was:\n\(app.debugDescription)"
    )
    XCTAssertTrue(
      waitForTerminalText(terminal, containing: "herdr pane term_w1p2"),
      "Expected to be back on w1:p2. Terminal showed: \(String(describing: terminal.value))"
    )
  }

  // MARK: - The toolbar button

  /// Switching pane is the app's main verb, so it gets a toolbar slot.
  func testThePanesButtonOpensTheSheetFromTheToolbar() {
    let (app, _) = terminalOnTheBlockedPane()

    require(app, "terminal.panes", "Expected a panes button in the toolbar").tap()

    require(app, "terminal.sheet.done", "Expected the pane sheet")
  }

  // MARK: - The sheet

  /// Every pane is on the sheet as a tile, in the tree's order, and the current one says so
  /// in words as well as colour. The contents are `PaneStripModel.targets`, tested in
  /// `PaneStripModelTests`.
  func testThePaneSheetListsEveryPaneWithTheCurrentOneMarked() {
    let app = terminalOnTheBlockedPane().app

    openPaneSheet(app)
    require(app, "terminal.sheet.pane", "Expected the sheet to draw a tile per pane")

    let labels = tiles(app).map(\.label)
    XCTAssertEqual(
      labels.count,
      seededPaneTitles.count,
      "Expected one tile per pane in the seeded tree, got \(labels)."
        + "\nTree was:\n\(app.debugDescription)"
    )
    for (label, title) in zip(labels, seededPaneTitles) {
      XCTAssertTrue(
        label.hasPrefix(title),
        "Tiles are out of the tree's order: expected '\(title)', got '\(label)'. All: \(labels)"
      )
    }

    // The ring is 2 pt of accent and invisible to both VoiceOver and a test, so the tile
    // says which one it is in words as well.
    let current = paneTile(app, titled: "needs a decision")
    XCTAssertEqual(
      current.value as? String,
      "Current pane",
      "Expected the pane being typed into to say so, not only to wear a ring"
    )
    XCTAssertNotEqual(
      paneTile(app, titled: "swift test").value as? String,
      "Current pane",
      "Expected exactly one tile to be the current one"
    )

    // The sheet names each workspace it cuts at. Which sections exist is
    // `PaneStripModel.groups` and `showsWorkspaceHeaders`.
    let headers = app.descendants(matching: .any)
      .matching(identifier: "terminal.sheet.workspace")
      .allElementsBoundByIndex
      .map(\.label)
    XCTAssertEqual(
      headers,
      ["driverr", "tower", "wiki"],
      "Expected the sheet to name each workspace it cuts at, got \(headers)."
        + "\nTree was:\n\(app.debugDescription)"
    )

    let newPane = require(app, "terminal.sheet.newPane", "Expected a New pane cell")
    reveal(app, newPane)

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "pane-sheet"
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// Done dismisses the sheet and leaves the terminal on the same pane. A drag is the only
  /// other way out, and on a phone that gesture is easily a scroll.
  func testDoneLeavesTheSheetWithoutSwitchingPanes() {
    let (app, terminal) = terminalOnTheBlockedPane()

    openPaneSheet(app)
    require(app, "terminal.sheet.done", "Expected a Done button on the pane sheet").tap()

    // XCUITest sees through a presented sheet, so wait for it to go.
    requireSheetGone(app, "Expected Done to dismiss the sheet")

    // The terminal's content proves the pane did not change.
    XCTAssertTrue(
      waitForTerminalText(terminal, containing: "herdr pane term_w1p2"),
      "Expected Done to leave the pane alone. Terminal showed: "
        + String(describing: terminal.value)
    )
  }

  /// On an iPad every pane is on the sheet without a drag.
  ///
  /// A `.medium` detent on regular width is a small form sheet, which `columns(for:)` reads
  /// as two columns with most rows hidden, so regular width uses page sizing. Skipped on a
  /// phone, where the medium detent is meant to leave the terminal behind it visible.
  func testEveryPaneIsOnTheSheetWithoutADragOnIPad() throws {
    try XCTSkipUnless(
      UIDevice.current.userInterfaceIdiom == .pad,
      "This checks the regular-width sheet; a phone's medium detent is meant to scroll."
    )
    let app = terminalOnTheBlockedPane().app

    openPaneSheet(app)
    require(app, "terminal.sheet.pane", "Expected the sheet to draw a tile per pane")

    let unreachable = tiles(app).filter { !$0.isHittable }.map(\.label)
    XCTAssertTrue(
      unreachable.isEmpty,
      "These tiles need a drag before they can be tapped on an iPad: \(unreachable). "
        + "Regular width must use page sizing.\nTree was:\n\(app.debugDescription)"
    )
    let newPane = require(app, "terminal.sheet.newPane", "Expected a New pane cell")
    XCTAssertTrue(
      newPane.isHittable,
      "The split cell needs a drag on an iPad, at \(newPane.frame)."
    )

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "pane-sheet-ipad"
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// A tile is a way to the pane, not a preview of it: tapping switches and the sheet goes.
  func testTappingATileSwitchesThePaneAndDismissesTheSheet() {
    let (app, terminal) = terminalOnTheBlockedPane()

    openPaneSheet(app)
    let tile = paneTile(app, titled: "swift test")
    XCTAssertTrue(tile.waitForExistence(timeout: 10), "Expected a tile for 'swift test'")
    reveal(app, tile)
    tile.tap()

    // XCUITest sees through a presented sheet, so wait for it to go.
    requireSheetGone(app, "Expected the sheet to dismiss on choosing a pane")

    XCTAssertTrue(
      waitForTerminalText(terminal, containing: "herdr pane term_w1p3"),
      "Expected the tile to switch the terminal to w1:p3. Terminal showed: "
        + String(describing: terminal.value)
    )

    // The reopened sheet agrees about the current pane. `openPaneSheet` waits on the title,
    // which arrives before the tiles, so the tiles are waited for separately.
    openPaneSheet(app)
    require(app, "terminal.sheet.pane", "Expected the reopened sheet to draw its tiles")
    XCTAssertEqual(
      paneTile(app, titled: "swift test").value as? String,
      "Current pane",
      "Expected the sheet to agree with the terminal about which pane is current."
        + "\nTree was:\n\(app.debugDescription)"
    )
  }

  /// New pane splits the pane being looked at, and the scene follows the pane it made.
  ///
  /// `pane split` does not report the new pane's id, so the new pane is identified by the
  /// next snapshot, and this counts tiles rather than naming one.
  func testNewPaneSplitsTheCurrentPaneAndTheSceneFollowsIt() {
    let (app, terminal) = terminalOnTheBlockedPane()

    openPaneSheet(app)
    require(app, "terminal.sheet.pane", "Expected the sheet to draw a tile per pane")
    XCTAssertEqual(tiles(app).count, seededPaneTitles.count)

    let newPane = require(app, "terminal.sheet.newPane", "Expected a New pane cell")
    reveal(app, newPane)
    newPane.tap()

    requireSheetGone(app, "Expected the sheet to dismiss on making a pane")

    // The scene adopts the new pane only once a snapshot carries it, so the count below
    // needs no polling.
    XCTAssertTrue(
      waitForTerminalText(terminal, containing: "herdr pane term_w1p7"),
      "Expected the scene to switch to the pane the split made. Terminal showed: "
        + String(describing: terminal.value)
    )

    // The tiles are waited for, because `openPaneSheet` waits only on the title, which is up
    // before the grid.
    openPaneSheet(app)
    require(app, "terminal.sheet.pane", "Expected the reopened sheet to draw its tiles")
    XCTAssertEqual(
      tiles(app).count,
      seededPaneTitles.count + 1,
      "Expected the pane the split made to appear in the sheet."
        + "\nTree was:\n\(app.debugDescription)"
    )
  }

  // MARK: - Leaving, and turning the phone over

  /// The pane scene can still be left after a switch, with several sessions alive in it.
  ///
  /// `schema sync` is the first pane of another workspace, below the fold at the medium
  /// detent, so this is the switch that exercises the drag inside `switchToPane`.
  func testDoneStillDismissesAfterSwitchingPanes() {
    let app = terminalOnTheBlockedPane().app

    switchToPane(app, titled: "schema sync")
    showTerminal(app)
    require(app, "terminal.view", "Expected the switched-to pane's terminal")

    leavePaneScene(app, "Expected a way out")

    requireGone(app, "terminal.view", "Expected the terminal cover to be dismissed")
    // A warm emulator left behind is a stream nothing on screen can close.
    requireGone(app, "terminal.view.warm", "Expected the warm panes to be released too")

    XCTAssertTrue(
      element(app, "connect.terminal").waitForExistence(timeout: 10),
      "Expected to be back on the host screen.\nTree was:\n\(app.debugDescription)"
    )
  }

  // MARK: - The other machines

  /// One host row, named. Every row shares `hosts.row`, so the label is what picks one.
  private func hostRow(_ app: XCUIApplication, named name: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(identifier: "hosts.row")
      .matching(NSPredicate(format: "label CONTAINS %@", name))
      .firstMatch
  }

  /// Opens `name`'s host screen and waits for it to connect on appearance.
  private func connect(
    _ app: XCUIApplication,
    to name: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let row = hostRow(app, named: name)
    XCTAssertTrue(
      row.waitForExistence(timeout: 15),
      "Expected a row for '\(name)'.\nTree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
    row.tap()
    require(
      app,
      "connect.connected",
      "Expected '\(name)' to connect on appearance",
      timeout: 20,
      file: file,
      line: line
    )
  }

  /// Back to the host list, on whichever width this is.
  ///
  /// On a phone the host screen was pushed, so this taps the Hosts back control. On
  /// `Driverr iPad` the sidebar never left and there is nothing to pop. Probed rather than
  /// branched on size class.
  private func returnToTheHostList(_ app: XCUIApplication) {
    let back = app.navigationBars.buttons["Hosts"].firstMatch
    if back.waitForExistence(timeout: 3), back.isHittable { back.tap() }
  }

  /// The switcher lists another connected host's panes, and a tile goes there.
  ///
  /// Section contents are `CrossHostPanesTests` and the pick's routing is
  /// `TerminalPresenterTests`. Both hosts run the same fixture, so their pane ids collide, as
  /// herdr's per-host ids really do. That is why the other host's tiles have no thumbnail
  /// (`PaneSheetView.otherTile`) and their own identifier.
  func testTheSwitcherListsAnotherConnectedHostAndGoesThere() {
    XCUIDevice.shared.orientation = .portrait

    // Both hosts seeded and credentialed. Connecting beta, then workbox, leaves beta warm in
    // the registry with the scene on workbox.
    let app = XCUIApplication()
    app.launchArguments += [
      "-uiTesting", "-uiTestingSeedHost", "-uiTestingSecondHost", "-uiTestingConnected",
    ]
    app.launch()

    connect(app, to: "beta")
    returnToTheHostList(app)
    connect(app, to: "workbox")

    waitForBothBlockedPanes(app)
    blockedPaneRow(app, titled: "needs a decision").tap()
    showTerminal(app)
    require(app, "terminal.view", "Expected the terminal to open on the pane")

    require(app, "terminal.panes", "Expected the panes button").tap()

    // With two hosts the sheet's title is generic and each grid is named by a header.
    let header = app.staticTexts.matching(identifier: "terminal.sheet.host")
      .matching(NSPredicate(format: "label == %@", "beta"))
      .firstMatch
    XCTAssertTrue(
      header.waitForExistence(timeout: 15),
      "Expected a section for the other connected host.\nTree was:\n\(app.debugDescription)"
    )

    let otherTile = app.buttons.matching(identifier: "terminal.sheet.otherPane").firstMatch
    XCTAssertTrue(
      otherTile.waitForExistence(timeout: 10),
      "Expected a tile for a pane on the other host.\nTree was:\n\(app.debugDescription)"
    )
    reveal(app, otherTile)
    XCTAssertTrue(
      otherTile.isHittable,
      "The other host's tile never became reachable at \(otherTile.frame)."
        + "\nTree was:\n\(app.debugDescription)"
    )
    otherTile.tap()

    requireSheetGone(app, "Expected the pick to dismiss the sheet")
    // The navigation bar's subtitle names the host.
    XCTAssertTrue(
      app.staticTexts["beta"].waitForExistence(timeout: 20),
      "Expected the scene to be on the other host.\nTree was:\n\(app.debugDescription)"
    )
    // A pane scene, not the host screen behind it.
    require(app, "terminal.panes", "Expected a pane scene on the other host", timeout: 20)
  }

  /// Rotates, and fails on the scene before anything laid out inside it.
  ///
  /// A simulator can stop applying interface rotation while still logging the device
  /// orientation change, and every later assertion then compares portrait with itself. The
  /// failure names the cure, erasing the device.
  ///
  /// Asserted, never skipped, on every device. The iPad simulator does rotate once erased,
  /// so a skip would hide the same wedge.
  private func rotateToLandscape(
    _ app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    XCUIDevice.shared.orientation = .landscapeLeft
    let window = app.windows.firstMatch
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline && window.frame.width <= window.frame.height {
      _ = window.waitForExistence(timeout: 0.2)
    }
    XCTAssertGreaterThan(
      window.frame.width,
      window.frame.height,
      "The scene never rotated — the window is still \(window.frame). That is the "
        + "simulator and not the app: erase this device (`xcrun simctl erase <udid>`) and "
        + "run again.",
      file: file,
      line: line
    )
  }

  // MARK: - Landscape, with the keyboard up

  /// The composer, the panes button and the way back to the terminal all survive a landscape
  /// phone with the keyboard up.
  ///
  /// Several pieces of chrome and a keyboard have to fit in about 150 points of height. The
  /// controls are asserted hittable, because a control squeezed to zero height or pushed under
  /// the keyboard still exists.
  func testLandscapeKeepsTheComposerAndTheSegmentReachable() throws {
    let app = chatOnTheBlockedPane([uiTestingKeyboardMetrics])

    try rotateToLandscape(app)

    let field = require(app, "composer.text", "Expected the composer in landscape")
    let panes = require(app, "terminal.panes", "Expected the panes button in landscape")
    let send = require(app, "composer.send", "Expected Send in landscape")
    field.tap()

    // The keyboard must be on screen. Without it the region is 324 pt rather than 100 and
    // everything below passes. A field rebuilt by an identity change resigns and takes the
    // keyboard away silently; see `PaneComposerBar.cardLayout`.
    let keyboardDeadline = Date().addingTimeInterval(10)
    while Date() < keyboardDeadline && app.keyboards.count == 0 { usleep(200_000) }
    XCTAssertGreaterThan(
      app.keyboards.count,
      0,
      "No software keyboard came up, so this test is measuring the keyboard-down layout and "
        + "cannot fail for the reason it exists.\nTwo causes, in the order to check them. "
        + "**The app**: something took the keyboard away again — a view whose identity "
        + "changed under the field does this, and it leaves no other trace. "
        + "**The simulator**: its software keyboard is off, which is what a connected "
        + "hardware keyboard does; turn it back on with Simulator's I/O > Keyboard > Connect "
        + "Hardware Keyboard, or XcodeBuildMCP's toggle_connect_hardware_keyboard.\nDo not "
        + "skip this test to get past it.\nTree was:\n\(app.debugDescription)"
    )
    let keyboard = app.keyboards.firstMatch
    XCTAssertGreaterThan(
      keyboard.frame.height,
      0,
      "The keyboard element exists with an empty frame \(keyboard.frame), so it is not "
        + "actually on screen and the region below is not the one this test is about."
    )

    let settle = Date().addingTimeInterval(5)
    while Date() < settle && !(field.isHittable && send.isHittable) { usleep(200_000) }

    // Printed so a passing run records the state it passed in. The test runner prints it,
    // because app-side `print` never reaches xcodebuild's log.
    print(
      "[landscape] acceptance: keyboard \(keyboard.frame) composer \(field.frame) "
        + "send \(send.frame) panes \(panes.frame) band exists "
        + "\(element(app, "pane.surface.terminal").exists)"
    )

    // Against the keyboard as drawn, which `keyboard.frame` is not.
    assertComposerClearsTheDrawnKeyboard(app, "landscape")

    // The surfaces stay inside their slot. `.frame(minHeight:)` centres a child it cannot
    // fit, so the surfaces can hang off both ends of the region, and `.clipped()` hides terminal
    // rows SwiftTerm has already reported to the far side.
    let metrics = keyboardMetrics(app)
    // Which part of the chat does not fit. `exists` before `frame`, because the Show the
    // screen row is absent in this posture and `frame` on it would fail the test.
    let showScreen = element(app, "pane.chat.showScreen")
    print(
      "[landscape] chat parts: scroll \(element(app, "pane.chat").frame) "
        + "showScreen \(showScreen.exists ? "\(showScreen.frame)" : "absent")"
    )
    print(
      "[landscape] surfaces: region \(metrics.regionTop)..\(metrics.regionBottom) "
        + "(\(metrics.regionHeight) pt) surfaces \(metrics.surfacesTop)..\(metrics.surfacesBottom) "
        + "terminal \(metrics.terminalTop)..\(metrics.terminalBottom) "
        + "chat \(metrics.chatTop)..\(metrics.chatBottom) "
        + "keyboardTop \(String(describing: metrics.keyboardTop)) "
        + "composerHeight \(metrics.composerHeight) composerBottom \(metrics.composerBottom) "
        + "grid \(metrics.grid) "
        + "overflow \(metrics.surfacesOverflow)"
    )
    XCTAssertGreaterThanOrEqual(
      metrics.surfacesTop,
      metrics.regionTop - 0.5,
      "The pane surfaces start \(metrics.regionTop - metrics.surfacesTop) pt above their own "
        + "region, so the top of the conversation is drawn under the navigation bar and "
        + "clipped: surfaces \(metrics.surfacesTop)..\(metrics.surfacesBottom) in a region "
        + "\(metrics.regionTop)..\(metrics.regionBottom)."
    )
    XCTAssertLessThanOrEqual(
      metrics.surfacesBottom,
      metrics.regionBottom + 0.5,
      "The pane surfaces run \(metrics.surfacesBottom - metrics.regionBottom) pt past their "
        + "own region, under the keyboard. Those are rows SwiftTerm has told the far side "
        + "about and nobody can read. Surfaces \(metrics.surfacesTop)..\(metrics.surfacesBottom) "
        + "in a region \(metrics.regionTop)..\(metrics.regionBottom), grid \(metrics.grid)."
    )
    XCTAssertLessThanOrEqual(
      metrics.terminalBottom,
      metrics.regionBottom + 0.5,
      "The terminals block ends at \(metrics.terminalBottom) against a region ending at "
        + "\(metrics.regionBottom), so the grid SwiftTerm sized from it (\(metrics.grid)) "
        + "counts rows below the visible region."
    )
    XCTAssertGreaterThanOrEqual(
      metrics.terminalTop,
      metrics.regionTop - 0.5,
      "The terminals block starts at \(metrics.terminalTop) against a region starting at "
        + "\(metrics.regionTop), so the grid's first rows are under the navigation bar."
    )

    // The band hides only on a phone. `TerminalScreen.isComposerCollapsed` needs a compact
    // vertical size class, and an iPad is regular even in landscape.
    if UIDevice.current.userInterfaceIdiom == .pad {
      // The band stays on iPad, so it must sit clear of the composer.
      let band = require(app, "pane.surface.terminal", "Expected the surface band on an iPad")
      XCTAssertTrue(
        band.isHittable,
        "The surface band is not reachable in landscape with the keyboard up on iPad: "
          + "\(band.frame)."
      )
      XCTAssertLessThanOrEqual(
        band.frame.maxY,
        field.frame.minY,
        "The surface band overlaps the composer in landscape with the keyboard up on iPad: "
          + "band \(band.frame) composer \(field.frame)."
      )
    } else {
      // The band hides here, or the conversation gets 3 pt. Asserted absent, which is
      // what `TerminalScreen.surfaceSegment` does; a hittable check let an overlap through.
      XCTAssertFalse(
        element(app, "pane.surface.terminal").exists,
        "The surface band is still on screen with the keyboard up in landscape. It is "
          + "supposed to hide there so the conversation gets the room — see "
          + "TerminalScreen.surfaceSegment.\nTree was:\n\(app.debugDescription)"
      )

      // The composer's bar must not inset the terminal. A `safeAreaBar` on `paneSurfaces`
      // insets every child, and `DriverrTerminalView.sizeChanged` would then resize the live
      // pane on the far side. The shrunken block passes every check above, so the one that
      // catches it is the terminals reaching the bottom of their region.
      XCTAssertGreaterThanOrEqual(
        metrics.terminalBottom,
        metrics.regionBottom - 0.5,
        "the composer's bar must not inset the terminal: the terminals end at "
          + "\(metrics.terminalBottom) against a region ending at \(metrics.regionBottom), "
          + "\(metrics.regionBottom - metrics.terminalBottom) pt short. SwiftTerm sizes its "
          + "grid from that frame and reports it to the far side, so a live pane is being "
          + "resized by a bar drawn over the conversation. Grid \(metrics.grid)."
      )
    }

    XCTAssertTrue(
      field.isHittable,
      "The composer is not reachable in landscape with the keyboard up: \(field.frame)"
    )
    XCTAssertTrue(
      send.isHittable,
      "Send is not reachable in landscape with the keyboard up: \(send.frame). A composer you "
        + "can type into and not send from is not a reply surface."
    )
    XCTAssertTrue(
      panes.isHittable,
      "The way to the other panes is not reachable in landscape: \(panes.frame)."
    )

    // The band comes straight back, which is what makes hiding it acceptable. Rotation is the
    // trigger tested, because a synthetic swipe inside the 46 pt conversation does not
    // register as a drag. Dismissing the keyboard, the other trigger, is not covered here.
    XCUIDevice.shared.orientation = .portrait
    let window = app.windows.firstMatch
    let upright = Date().addingTimeInterval(10)
    while Date() < upright && window.frame.height <= window.frame.width {
      _ = window.waitForExistence(timeout: 0.2)
    }
    XCTAssertGreaterThan(
      window.frame.height,
      window.frame.width,
      "The scene never rotated back — the window is still \(window.frame). That is the "
        + "simulator and not the app: erase this device (`xcrun simctl erase <udid>`) and "
        + "run again."
    )
    let segment = require(
      app,
      "pane.surface.terminal",
      "Expected the surface band back once the phone was upright"
    )
    XCTAssertTrue(
      segment.isHittable,
      "The band came back but is not reachable: \(segment.frame). It is a band under the "
        + "navigation bar, so this fails if the chrome above the surfaces has "
        + "eaten the screen."
    )
  }

  /// An agent pane, on its chat, in portrait.
  private func chatOnTheBlockedPane(_ launchArguments: [String] = []) -> XCUIApplication {
    XCUIDevice.shared.orientation = .portrait

    let app = connectedHostApp(launchArguments)

    // Named, not by position, as in `terminalOnTheBlockedPane`.
    waitForBothBlockedPanes(app)
    let row = blockedPaneRow(app, titled: "needs a decision")
    XCTAssertTrue(row.isHittable, "Expected the Needs-you row to be hittable before tapping.")
    row.tap()
    require(app, "pane.chat", "Expected the pane to open on its chat")
    return app
  }

  /// A rotation reflows the terminal to a different column count, which only a real screen
  /// can show.
  func testTheTerminalReflowsOnRotation() throws {
    let (app, terminal) = terminalOnTheBlockedPane()

    let portraitTerminal = terminal.frame

    try rotateToLandscape(app)

    // Rotation animates and the emulator re-lays out after it, so poll.
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline && terminal.frame.width <= portraitTerminal.width {
      _ = terminal.waitForExistence(timeout: 0.2)
    }

    XCTAssertGreaterThan(
      terminal.frame.width,
      portraitTerminal.width,
      "Expected the terminal to reflow to the wider screen"
    )

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "pane-landscape"
    shot.lifetime = .keepAlways
    add(shot)

    // Restored here, not in the nonisolated `tearDown`, where touching `XCUIDevice.shared`
    // warns under strict concurrency. Every test also pins portrait on the way in.
    XCUIDevice.shared.orientation = .portrait
  }
}
