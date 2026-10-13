import XCTest

/// The pane scene in the split view's detail column: on a regular-width window, opening a
/// pane keeps the host list visible, with a back control and no Done.
///
/// The routing rule is `TerminalSceneRouteTests`; this is the wiring it feeds. The class runs
/// wherever the window is regular width; see `requireRegularWidth`.
///
/// There is no ⌘, case, because no iPad binds ⌘,. See `KeyCommand.settings`.
///
/// Relaunches per test: each test connects, which records a trust decision.
@MainActor
final class PaneDetailColumnUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  /// Waits for an element to stop existing. `XCTAssertFalse(element.exists)` samples once,
  /// and right after a dismissal the old screen is often still in the tree.
  private func requireGone(
    _ app: XCUIApplication,
    _ identifier: String,
    _ message: String,
    timeout: TimeInterval = 10,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let waiter = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"),
      object: element(app, identifier)
    )
    guard XCTWaiter().wait(for: [waiter], timeout: timeout) == .completed else {
      XCTFail(
        "\(message)\n'\(identifier)' was still there after \(timeout)s.\nTree was:\n"
          + app.debugDescription,
        file: file,
        line: line
      )
      return
    }
  }

  /// Skips unless the window is regular width, where the route exists.
  ///
  /// Measured off the window, not the idiom, because `Driverr iPhone 17 Pro Max` is compact in
  /// portrait and regular in landscape. 900 pt separates the repo's simulators: the iPhone 17
  /// is at most 874 wide, the Pro Max in landscape 956, the iPad at least 1032.
  ///
  /// This skips a claim that is false by construction on a compact window. It is not a
  /// skipped rotation; the rotation below is asserted.
  private func requireRegularWidth(_ app: XCUIApplication) throws {
    let width = app.windows.firstMatch.frame.width
    try XCTSkipUnless(
      width >= 900,
      "The detail-column route exists on regular width; this window is \(width) pt wide."
    )
  }

  /// A connected host with a pane open from its tree row, which opens without the keyboard.
  ///
  /// The Terminal segment is tapped because an agent pane opens on its chat, and this class
  /// uses `terminal.view` as the sign that the scene is up.
  private func openedPane(_ launchArguments: [String] = []) throws -> XCUIApplication {
    let app = connectedHostApp(launchArguments)
    // After the launch, because the guard reads the app's window.
    try requireRegularWidth(app)
    treePaneRow(app, titled: "needs a decision").tap()
    waitFor(app, "pane.surface.terminal", "Expected the Terminal segment", timeout: 20).tap()
    waitFor(app, "terminal.view", "Expected the pane scene to open", timeout: 20)
    return app
  }

  /// Three claims that fail differently: the host list stays, Done is absent, and a back
  /// control offers the way out. A route with no Done and no replacement would pass the
  /// first two and strand the user.
  func testAPaneOpensInTheDetailColumnBesideTheHostList() throws {
    let app = try openedPane()

    XCTAssertTrue(
      element(app, "hosts.row").exists,
      "The host list has to stay visible beside the pane scene.\nTree was:\n"
        + app.debugDescription
    )
    requireGone(app, "terminal.done", "No Done button belongs on the detail route")

    let back = waitFor(app, "terminal.back", "Expected the detail column's back control")
    // Named for the host it goes back to. `Host.uiTestSeed` is workbox.
    XCTAssertTrue(
      back.label.contains("workbox"),
      "The back control has to carry the host's name; its label was '\(back.label)'."
    )
  }

  /// The back control returns the column to the host screen. Asserted by `terminal.view`
  /// going, because the host screen is beside the scene the whole time on this route.
  func testTheBackControlReturnsTheColumnToTheHostScreen() throws {
    let app = try openedPane()

    leavePaneScene(app)

    requireGone(app, "terminal.view", "Expected the detail column back on the host screen")
    XCTAssertTrue(
      element(app, "connect.terminal").waitForExistence(timeout: 10),
      "Expected the host screen in the detail column.\nTree was:\n\(app.debugDescription)"
    )
  }

  /// Rotating keeps the scene. A rotation is the cheapest way to rebuild the whole scene,
  /// and the nearest this tier gets to a size-class flip, which XCUITest cannot drive and
  /// `TerminalPresenterTests.onlyDismissingEndsTheScene` pins instead.
  ///
  /// The rotation is asserted with the erase remedy, as in
  /// `PaneSwitchUITests.rotateToLandscape`.
  func testTheSceneSurvivesARotation() throws {
    XCUIDevice.shared.orientation = .portrait
    let app = try openedPane()

    XCUIDevice.shared.orientation = .landscapeLeft
    let window = app.windows.firstMatch
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline && window.frame.width <= window.frame.height {
      _ = window.waitForExistence(timeout: 0.2)
    }
    XCTAssertGreaterThan(
      window.frame.width,
      window.frame.height,
      "The scene never rotated — the window is still \(window.frame). That is the simulator "
        + "and not the app: erase this device (`xcrun simctl erase <udid>`) and run again."
    )

    waitFor(app, "terminal.view", "The rotation ended the pane scene", timeout: 20)
    waitFor(app, "terminal.back", "The rotation lost the way out of the pane scene")
    XCTAssertTrue(
      element(app, "hosts.row").exists,
      "The rotation lost the host list.\nTree was:\n\(app.debugDescription)"
    )

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "pane-detail-column-landscape"
    shot.lifetime = .keepAlways
    add(shot)

    XCUIDevice.shared.orientation = .portrait
  }

  // MARK: - The sidebar and the column have to name the same host

  /// One host row, named. Every row shares `hosts.row`, so the label is what picks one.
  private func hostRow(_ app: XCUIApplication, named name: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(identifier: "hosts.row")
      .matching(NSPredicate(format: "label CONTAINS %@", name))
      .firstMatch
  }

  /// A sidebar tap on another host leaves the pane scene and shows that host, so the list and
  /// the column name the same machine. The rule is
  /// `TerminalPresenterTests.aSidebarChoiceEndsTheScene`.
  ///
  /// `terminal.back` must go as well as `terminal.view`, because the back control is the
  /// scene's own chrome on this route.
  func testASidebarTapOnAnotherHostLeavesTheSceneForThatHost() throws {
    let app = try openedPane(["-uiTestingSecondHost"])

    let beta = hostRow(app, named: "beta")
    XCTAssertTrue(
      beta.waitForExistence(timeout: 15),
      "Expected the second seeded host's row.\nTree was:\n\(app.debugDescription)"
    )
    beta.tap()

    requireGone(app, "terminal.view", "The sidebar tap left the pane scene in the column")
    requireGone(app, "terminal.back", "The scene's back control outlived the scene")
    // The column is on beta. `HostDetailView` titles itself with the host's name, while
    // `connect.terminal` alone would pass for either host.
    XCTAssertTrue(
      app.navigationBars["beta"].waitForExistence(timeout: 20),
      "Expected beta's host screen in the detail column.\nTree was:\n"
        + app.debugDescription
    )
    XCTAssertTrue(
      element(app, "connect.terminal").waitForExistence(timeout: 20),
      "Expected a host screen rather than a placeholder.\nTree was:\n"
        + app.debugDescription
    )
  }

  /// A cross-host pick from the switcher moves the sidebar highlight to that host.
  ///
  /// `isSelected` is the highlight. Leaving the scene afterwards proves the selection itself
  /// moved, because the detail column resolves `selectedHostID`.
  func testACrossHostPickMovesTheSidebarHighlight() throws {
    let app = XCUIApplication()
    app.launchArguments += [
      "-uiTesting", "-uiTestingSeedHost", "-uiTestingSecondHost", "-uiTestingConnected",
    ]
    app.launch()
    try requireRegularWidth(app)

    // Beta first, then workbox, so beta is warm in the registry and the scene opens on
    // workbox.
    connect(app, to: "beta")
    connect(app, to: "workbox")

    treePaneRow(app, titled: "needs a decision").tap()
    waitFor(app, "pane.surface.terminal", "Expected the Terminal segment", timeout: 20).tap()
    waitFor(app, "terminal.view", "Expected the pane scene to open", timeout: 20)

    waitFor(app, "terminal.panes", "Expected the panes button", timeout: 20).tap()
    // The sheet has detents, so `swipeUp()` is inert. See `dragSheetToReveal`. The host
    // header is always on screen, so it is the anchor.
    let otherTile = dragSheetToReveal(
      app,
      "terminal.sheet.otherPane",
      anchoredAt: "terminal.sheet.host",
      "Expected a tile for a pane on the other host."
    )
    otherTile.tap()

    // The scene is on beta first. The back control carries the host's name.
    let back = waitFor(app, "terminal.back", "Expected the pick to open a scene", timeout: 20)
    XCTAssertTrue(
      back.label.contains("beta"),
      "The pick did not land on the other host; the back control read '\(back.label)'."
    )

    // `app.buttons`, not `app.cells`. A `NavigationLink` row here is a Button carrying
    // `hosts.row`, and a cell query finds nothing.
    let betaRow = app.buttons
      .matching(identifier: "hosts.row")
      .matching(NSPredicate(format: "label CONTAINS 'beta'"))
      .firstMatch
    XCTAssertTrue(
      betaRow.waitForExistence(timeout: 10),
      "Expected beta's row in the sidebar.\nTree was:\n\(app.debugDescription)"
    )
    XCTAssertTrue(
      betaRow.isSelected,
      "The sidebar is still highlighting the host the scene left.\nTree was:\n"
        + app.debugDescription
    )

    leavePaneScene(app)
    XCTAssertTrue(
      app.navigationBars["beta"].waitForExistence(timeout: 20),
      "Leaving the scene landed on the wrong host's screen.\nTree was:\n"
        + app.debugDescription
    )
  }

  /// herdr can drop a pane for one poll. The conversation must keep its column across that.
  /// The assertion is the turn's offset from the caption, before against after; see
  /// `conversationInset`.
  func testTheConversationKeepsItsColumnWhenHerdrDropsThePane() throws {
    let app = connectedHostApp([
      "-uiTestingRichTranscript", "-uiTestingSlowTranscript", "-uiTestingPaneVanishesOnce",
    ])
    try requireRegularWidth(app)
    treePaneRow(app, titled: "needs a decision").tap()
    waitFor(app, "pane.chat", "Expected the conversation", timeout: 20)
    let before = conversationInset(app)

    // `FakeControl.vanishingPaneScript`'s fifth snapshot has no `w1:p2`, so the chat is torn
    // out of `TerminalScreen.paneSurfaces` and put back on the next poll.
    requireGone(
      app,
      "pane.chat",
      "Expected herdr's snapshot without the pane to take the conversation down",
      timeout: 40
    )
    waitFor(app, "pane.chat", "Expected the pane back on the next poll", timeout: 40)
    let after = conversationInset(app)

    // Half a point of tolerance for rounding. The drift guarded against is 375 pt.
    XCTAssertEqual(
      before,
      after,
      accuracy: 0.5,
      "The conversation moved inside its own column across the drop: "
        + "\(before) pt of inset before, \(after) pt after.\nTree was:\n"
        + app.debugDescription
    )
    // This checks that the conversation is in its column at all. The equality above also passes for a
    // conversation that was out of its column before the drop and stayed there.
    //
    // Measured against the composer's card, which shares the turn card's edge. The caption
    // keeps its own inset, so it sits right of the turn card here by design. The column rule
    // is asserted to 2 pt in
    // `PaneComposerUITests.testTheComposerStandsInTheSameColumnAsTheConversation`.
    let composerCard = waitFor(
      app, "composer.card", "Expected the composer's card to measure the column against",
      timeout: 20)
    let turnCard = waitFor(
      app, "pane.chat.turn.assistant", "Expected an answer to measure", timeout: 20)
    XCTAssertEqual(
      turnCard.frame.minX,
      composerCard.frame.minX,
      accuracy: Self.turnOverhangBound,
      "The conversation's turn starts at x \(turnCard.frame.minX) and the composer's card at "
        + "x \(composerCard.frame.minX), so the conversation has left the column the composer "
        + "still sits in.\nTree was:\n" + app.debugDescription
    )
  }

  /// How far a turn's accessibility element may sit outside the card it paints: 4 pt for a
  /// full-width answer and 16 for a chat bubble, on `Driverr iPad`. Bounded rather than
  /// encoded, because neither number is a fact about the column.
  private static let turnOverhangBound: CGFloat = 24

  /// How far the newest turn's leading edge sits from the caption above the conversation.
  ///
  /// Not from `pane.chat`, whose scroll view spans the whole window under the floating
  /// sidebar, so an offset from it barely separates the 375 pt drift from a correct layout.
  /// The caption stayed put while the rows drifted, and it moves with the column when the
  /// sidebar hides. The tool-run row is absent on this fixture.
  ///
  /// Two agreeing reads 100 ms apart, because both elements are rebuilt by the transition
  /// and one read can land mid-rebuild. Not `waitUntilStill`, which resets whenever the
  /// element goes and so would outlast the one-poll drop that `requireGone` is waiting for.
  private func conversationInset(
    _ app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> CGFloat {
    let caption = waitFor(
      app, "pane.chat.header", "Expected the conversation's caption", timeout: 30,
      file: file, line: line)
    let turn = waitFor(
      app, "pane.chat.turn.assistant", "Expected an answer to measure", timeout: 30,
      file: file, line: line)

    let deadline = Date().addingTimeInterval(20)
    var previous: CGFloat?
    var latest: CGFloat?
    while Date() < deadline {
      guard caption.exists, turn.exists else {
        previous = nil
        usleep(100_000)
        continue
      }
      let inset = turn.frame.minX - caption.frame.minX
      latest = inset
      if let previous, abs(previous - inset) < 0.5 { return inset }
      previous = inset
      usleep(100_000)
    }
    XCTFail(
      "The conversation never held a leading edge still for 100 ms in 20 s. The last read was "
        + "\(String(describing: latest)).\nTree was:\n" + app.debugDescription,
      file: file,
      line: line
    )
    return latest ?? 0
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
    waitFor(
      app,
      "connect.connected",
      "Expected '\(name)' to connect on appearance",
      timeout: 20,
      file: file,
      line: line
    )
  }
}
