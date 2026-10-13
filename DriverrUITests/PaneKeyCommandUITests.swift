import XCTest

/// The hardware keys: that a key reaches the app and moves the screen. What the keys mean
/// is `PaneStripModelShortcutsTests`. The pane keys are items in the Pane menu
/// (`PaneCommands`).
///
/// What XCUITest can and cannot deliver shapes these tests:
///
/// - Escape and Return reach no handler, so the Escape rule is `TerminalScreenEscapeTests`.
/// - `typeKey("]", modifierFlags: [.command, .shift])` delivers nothing, but
///   `typeKey("}", modifierFlags: .command)` fires the ⌘⇧] shortcut, as a hardware keyboard
///   reports it.
/// - The first press after the pane scene appears can be swallowed, and a longer settle
///   does not help. Every press goes through `press`, which tries three times and still
///   fails a key that never works.
/// - A software keyboard swallows ⌘W, so scenes open from the tree row, unfocused.
/// - ⌘, reaches no binding under XCUITest, over an open pane or on the phone's host list,
///   and no iPad binds it (`KeyCommand.settings`). So there is no ⌘, test.
///
/// Relaunches per test: every test connects, which records a trust decision, and leaves a
/// pane scene open.
@MainActor
final class PaneKeyCommandUITests: XCTestCase {
  /// `FakeControl.seededTree` in `SessionTree.allPanes` order, which is the order the
  /// switcher's places are in and therefore the order ⌘1 … ⌘9 count.
  private enum Pane {
    static let first = "terminal wiring"  // w1:p1, ⌘1
    static let second = "needs a decision"  // w1:p2, ⌘2, where every test starts
    static let third = "swift test"  // w1:p3, ⌘3
  }

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
    timeout: TimeInterval = 15,
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

  /// Which pane the scene is on, read off the navigation bar's title.
  ///
  /// Scoped to the navigation bar, because a pane's name also appears on the sheet's tiles.
  private func requireCurrentPane(
    _ app: XCUIApplication,
    is title: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let heading = app.navigationBars.staticTexts[title]
    XCTAssertTrue(
      heading.waitForExistence(timeout: 15),
      "Expected the scene to be on “\(title)”.\nTree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
  }

  /// Waits for an element to stop existing. XCUITest sees through a presentation, and
  /// `XCTAssertFalse(exists)` samples once.
  private func requireGone(
    _ app: XCUIApplication,
    _ identifier: String,
    _ message: String,
    timeout: TimeInterval = 15,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let predicate = NSPredicate(format: "exists == false")
    let waiter = XCTNSPredicateExpectation(
      predicate: predicate, object: element(app, identifier)
    )
    if XCTWaiter().wait(for: [waiter], timeout: timeout) != .completed {
      XCTFail(
        "\(message)\n'\(identifier)' was still there after \(timeout)s."
          + "\nTree was:\n\(app.debugDescription)",
        file: file,
        line: line
      )
    }
  }

  /// Presses a key until the app answers it, up to three times. This tolerates a swallowed
  /// first press (see the class comment) and still fails a key that never works.
  private func press(
    _ app: XCUIApplication,
    _ key: String,
    _ modifiers: XCUIElement.KeyModifierFlags,
    untilExists element: XCUIElement,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    for _ in 1...3 {
      app.typeKey(key, modifierFlags: modifiers)
      if element.waitForExistence(timeout: 5) { return }
    }
    XCTFail(
      "\(message)\nThree presses of that key changed nothing."
        + "\nTree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
  }

  /// The same, for a key whose answer is something leaving the screen.
  private func press(
    _ app: XCUIApplication,
    _ key: String,
    _ modifiers: XCUIElement.KeyModifierFlags,
    untilGone identifier: String,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let target = element(app, identifier)
    for _ in 1...3 {
      app.typeKey(key, modifierFlags: modifiers)
      let waiter = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "exists == false"), object: target
      )
      if XCTWaiter().wait(for: [waiter], timeout: 5) == .completed { return }
    }
    XCTFail(
      "\(message)\n'\(identifier)' was still there after three presses."
        + "\nTree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
  }

  /// The navigation bar's heading for one pane.
  private func heading(_ app: XCUIApplication, _ title: String) -> XCUIElement {
    app.navigationBars.staticTexts[title]
  }

  /// A pane scene on the blocked pane `w1:p2`, the second place, so both neighbour keys
  /// mean something.
  ///
  /// Opened from the tree row, unfocused, because a software keyboard swallows ⌘W.
  private func sceneOnTheBlockedPane() -> XCUIApplication {
    XCUIDevice.shared.orientation = .portrait
    let app = connectedHostApp()
    let row = app.descendants(matching: .any)
      .matching(identifier: "session.pane")
      .matching(NSPredicate(format: "label CONTAINS %@", Pane.second))
      .firstMatch
    // Wait before scrolling. The tree arrives after the screen is up, and only "below the
    // fold" is fixed by swiping.
    XCTAssertTrue(
      row.waitForExistence(timeout: 20),
      "Expected a tree row for “\(Pane.second)”.\nTree was:\n\(app.debugDescription)"
    )
    for _ in 0..<6 where !row.isHittable { app.swipeUp() }
    row.tap()
    requireCurrentPane(app, is: Pane.second)
    require(app, "pane.chat", "Expected the conversation")
    return app
  }

  // MARK: - The keys

  /// ⌘1 and ⌘3, because the third place is the one an off-by-one in the Needs-you entry
  /// would move. The seeded tree has a blocked pane, so that entry is drawn.
  func testCommandDigitSwitchesToThePaneAtThatIndex() {
    let app = sceneOnTheBlockedPane()

    press(
      app, "1", .command,
      untilExists: heading(app, Pane.first), "Expected ⌘1 to open the first pane"
    )

    press(
      app, "3", .command,
      untilExists: heading(app, Pane.third), "Expected ⌘3 to open the third pane"
    )
  }

  /// Both directions, so the second proves the first moved.
  ///
  /// Typed as `}` and `{` with Command, the only form the harness delivers; they fire the
  /// shortcuts declared ⌘⇧] and ⌘⇧[.
  func testCommandShiftBracketsStepToTheNeighbouringPanes() {
    let app = sceneOnTheBlockedPane()

    press(
      app, "}", .command,
      untilExists: heading(app, Pane.third), "Expected ⌘⇧] to step to the next pane"
    )

    press(
      app, "{", .command,
      untilExists: heading(app, Pane.second), "Expected ⌘⇧[ to step back to it"
    )
  }

  /// ⌘⇧T is the `Chat | Terminal` segment from the keyboard. An agent pane opens on its
  /// chat, so the terminal appearing is the claim.
  func testCommandShiftTSwitchesBetweenTheChatAndTheTerminal() {
    let app = sceneOnTheBlockedPane()
    XCTAssertFalse(
      element(app, "terminal.view").exists,
      "Expected an agent pane to open on its chat."
    )

    press(
      app, "t", [.command, .shift],
      untilExists: element(app, "terminal.view"), "Expected ⌘⇧T to show the terminal"
    )

    press(
      app, "t", [.command, .shift],
      untilGone: "terminal.view", "Expected ⌘⇧T to go back to the chat"
    )
  }

  /// ⌘W leaves the scene through `TerminalPresenter.dismiss()`, as the back controls do.
  func testCommandWLeavesThePaneScene() {
    let app = sceneOnTheBlockedPane()

    // `pane.chat` is the marker, because it exists only inside the scene and the phone's
    // back button carries no identifier.
    press(app, "w", .command, untilGone: "pane.chat", "Expected ⌘W to leave the scene")

    require(app, "connect.connected", "Expected to be back on the host screen")
  }

  /// ⌘W with the pane switcher open closes the switcher and stays on the pane.
  ///
  /// The Pane menu is live while a sheet covers the pane, because `focusedSceneValue` is
  /// scene-wide. Without this rule ⌘W left the scene from behind the sheet, and a disabled
  /// item let iPadOS close the window. See `KeyCommand.commandW`.
  func testCommandWClosesTheSwitcherAndStaysOnThePane() {
    let app = sceneOnTheBlockedPane()
    require(app, "terminal.panes", "Expected the panes button").tap()
    require(app, "terminal.sheet.pane", "Expected the pane sheet to open")

    press(
      app, "w", .command,
      untilGone: "terminal.sheet.pane", "Expected ⌘W to close the switcher"
    )

    // Long enough for a pop that the same key started to finish.
    Thread.sleep(forTimeInterval: 2)
    XCTAssertEqual(app.state, .runningForeground, "Expected the app's window to stay open")
    requireCurrentPane(app, is: Pane.second)
    require(app, "pane.chat", "Expected ⌘W to leave the pane scene where it was")
  }

  /// With a root sheet over the pane, the Pane menu's keys leave the pane alone.
  ///
  /// On regular width the sidebar can present sheets from `ContentView`'s root over the
  /// pane. `TerminalScreen.isBehindRootPresentation` stops ⌘W leaving the pane from behind
  /// one without closing the window. Regular width only, because on the phone there is no
  /// Add Host button beside the pane.
  func testPaneKeysDoNothingBehindARootSheet() throws {
    let app = sceneOnTheBlockedPane()
    let width = app.windows.firstMatch.frame.width
    try XCTSkipIf(
      width < Self.regularWidth,
      "This window is \(width) pt wide; the host list is not beside the pane here."
    )
    require(app, "hosts.add", "Expected the sidebar's Add Host button").tap()
    require(app, "host.name", "Expected the Add Host sheet")

    for key in ["w", "1", "w"] {
      app.typeKey(key, modifierFlags: .command)
      Thread.sleep(forTimeInterval: 2)
    }

    XCTAssertEqual(app.state, .runningForeground, "Expected the app's window to stay open")
    require(app, "host.name", "Expected the Add Host sheet to still be up")
    XCTAssertTrue(
      element(app, "pane.chat").exists,
      "Expected ⌘W to leave the pane scene alone.\nTree was:\n\(app.debugDescription)"
    )
    requireCurrentPane(app, is: Pane.second)
  }

  /// ⌘N is on the real toolbar button, so this also checks the button is where the key
  /// expects.
  func testCommandNOpensTheAddHostForm() {
    let app = XCUIApplication()
    app.launchArguments += ["-uiTesting", "-uiTestingSeedHost"]
    app.launch()
    require(app, "hosts.row", "Expected the seeded host list")

    press(
      app, "n", .command,
      untilExists: element(app, "host.hostname"), "Expected ⌘N to open the add-host form"
    )
  }

  /// The width at which this window is regular. See `PaneDetailColumnUITests`.
  private static let regularWidth: CGFloat = 900

  /// ⌘W on the host screen, with no pane open, leaves the host screen and keeps the window.
  ///
  /// A disabled ⌘W item lets iPadOS close the app's only window, and only an enabled app
  /// command stops it. So ⌘W is Leave Host here, and with no host selected it is a Close
  /// item that does nothing.
  func testCommandWLeavesTheHostScreenAndKeepsTheWindow() {
    XCUIDevice.shared.orientation = .portrait
    let app = connectedHostApp()

    press(
      app, "w", .command,
      untilGone: "connect.connected", "Expected ⌘W to leave the host screen"
    )
    XCTAssertEqual(app.state, .runningForeground, "Expected the app's window to stay open")
    let isRegular = app.windows.firstMatch.frame.width >= Self.regularWidth
    // On the iPad the detail column falls back to its placeholder; on the phone the stack
    // pops to the list.
    require(
      app, isRegular ? "detail.empty" : "hosts.row", "Expected ⌘W to go back to the host list"
    )

    app.typeKey("w", modifierFlags: .command)
    Thread.sleep(forTimeInterval: 2)
    XCTAssertEqual(
      app.state, .runningForeground, "Expected ⌘W with no host selected to keep the window"
    )
    require(
      app, isRegular ? "detail.empty" : "hosts.row",
      "Expected ⌘W with no host selected to leave the host list where it was"
    )
  }
}
