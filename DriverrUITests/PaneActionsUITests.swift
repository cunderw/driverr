import XCTest

/// The pane's controls in the terminal's toolbar.
///
/// What each action sends and the confirmation rule are `PaneActionsModelTests` against
/// `FakeControl`. This covers the menu in an attached terminal's toolbar, the inline
/// prompts, and the screen staying leavable afterwards.
///
/// Relaunches per test: tests connect, close panes and change Live Activity settings.
@MainActor
final class PaneActionsUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  /// Waits for an element to stop existing, and fails if it does not.
  ///
  /// `XCTAssertFalse(element.exists)` samples once, and right after a dismissal the old
  /// screen is often still in the tree. XCUITest also sees through a presentation and a
  /// push, so the screen behind proves nothing. Other classes carry private copies of this.
  private func requireGone(
    _ app: XCUIApplication,
    _ identifier: String,
    _ message: String,
    timeout: TimeInterval = 10,
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

  /// Connects, then opens the terminal on the seed's blocked pane.
  private func attachedTerminal() -> XCUIApplication {
    XCUIDevice.shared.orientation = .portrait
    // Seeded, because this class is not about connecting.
    let app = connectedHostApp()

    // Named, not by position, because the Needs-you section re-sorts when the fake blocks a
    // second pane. `testClosingAPaneAsksFirstAndThenLetsYouLeave` checks this pane leaves
    // the sidebar afterwards.
    waitForBothBlockedPanes(app)
    blockedPaneRow(app, titled: "needs a decision").tap()
    showTerminal(app)
    require(app, "terminal.view", "Expected the terminal to open on the pane")
    return app
  }


  /// An agent pane opens on its chat, so a test that wants the terminal asks for it. Every
  /// caller is on an agent pane, so a missing segment fails.
  private func showTerminal(_ app: XCUIApplication) {
    require(app, "pane.surface.terminal", "Expected the Terminal segment on an agent pane").tap()
  }

  /// Leaving a terminal attached to a pane, with nothing else done to it.
  func testDoneLeavesAnAttachedPaneTerminal() {
    let app = attachedTerminal()

    leavePaneScene(app, "Expected a way out")

    // The terminal has to go. The host screen is visible behind it either way.
    requireGone(app, "terminal.view", "Expected the terminal cover to be dismissed")

    XCTAssertTrue(
      element(app, "connect.terminal").waitForExistence(timeout: 10),
      "Expected to be back on the host screen.\nTree was:\n\(app.debugDescription)"
    )
  }

  func testTheToolbarCarriesThePaneActions() {
    let app = attachedTerminal()

    require(app, "pane.actions", "Expected a pane actions control in the toolbar").tap()

    for action in [
      "pane.rename", "pane.liveActivity", "pane.continueInBackground", "pane.close",
    ] {
      XCTAssertTrue(
        element(app, action).waitForExistence(timeout: 5),
        "Expected '\(action)' in the menu.\nTree was:\n\(app.debugDescription)"
      )
    }

    // Focus, Zoom and the Splits changed only herdr's own view, invisible in Driverr, so
    // they are not in the menu. Asserted, so they do not come back unnoticed.
    for gone in ["pane.focus", "pane.zoom", "pane.split.right", "pane.split.down"] {
      XCTAssertFalse(
        element(app, gone).exists,
        "Expected '\(gone)' to be gone from the menu.\nTree was:\n\(app.debugDescription)"
      )
    }

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "pane-actions-menu"
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// The per-host Start and Stop Live Activity item flips and is remembered.
  ///
  /// It is a `Button` that retitles itself, because a `Menu` cannot hold a `Toggle`. The
  /// retitle is the assertion, since the item existing proves only that it is drawn.
  func testStartAndStopLiveActivityFlipsTheMenuItem() {
    let app = attachedTerminal()

    require(app, "pane.actions", "Expected a pane actions control in the toolbar").tap()
    let item = require(app, "pane.liveActivity", "Expected Start/Stop Live Activity")
    XCTAssertEqual(
      item.label, "Stop Live Activity",
      "A host nobody has touched follows the global setting, which is on.\nTree was:\n"
        + app.debugDescription)
    item.tap()

    require(app, "pane.actions", "Expected the pane actions control after the tap").tap()
    let stopped = require(app, "pane.liveActivity", "Expected the item after stopping")
    XCTAssertEqual(
      stopped.label, "Start Live Activity",
      "Stopping this host must be remembered.\nTree was:\n\(app.debugDescription)")
    stopped.tap()

    require(app, "pane.actions", "Expected the pane actions control after starting again").tap()
    XCTAssertEqual(
      require(app, "pane.liveActivity", "Expected the item after starting again").label,
      "Stop Live Activity",
      "Starting the host again must be remembered.\nTree was:\n\(app.debugDescription)")
  }

  /// Continue in Background is on the menu and retitles itself from the moment of the tap.
  ///
  /// The request is queued, so a busy system makes the person wait for the handler, and a
  /// control that waited for it would read as a dead tap.
  ///
  /// `AppEnvironment.ephemeral` uses `SilentBackgroundWatchScheduler`, which accepts the
  /// request and sends nothing. A real task would draw iOS's progress card over later
  /// classes and outlive this process.
  func testContinueInBackgroundIsOfferedAndSaysWhenItIsRunning() {
    let app = attachedTerminal()

    require(app, "pane.actions", "Expected a pane actions control in the toolbar").tap()
    let item = require(app, "pane.continueInBackground", "Expected Continue in Background")
    XCTAssertEqual(
      item.label, "Continue in Background",
      "A host with no run up offers to start one.\nTree was:\n\(app.debugDescription)")
    item.tap()

    require(app, "pane.actions", "Expected the pane actions control after the tap").tap()
    let running = require(app, "pane.continueInBackground", "Expected the item after the tap")
    XCTAssertEqual(
      running.label, "Stop Continuing in Background",
      "The control has to say a run is up from the moment of the tap — the request is "
        + "queued, so waiting for the handler would read as a dead tap.\nTree was:\n"
        + app.debugDescription)

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "pane-menu-continue-in-background-running"
    shot.lifetime = .keepAlways
    add(shot)

    running.tap()

    require(app, "pane.actions", "Expected the pane actions control after stopping").tap()
    XCTAssertEqual(
      require(app, "pane.continueInBackground", "Expected the item after stopping").label,
      "Continue in Background",
      "Stopping must put the control back.\nTree was:\n\(app.debugDescription)")
  }

  /// The menu still works after Continue in Background.
  func testTheMenuStillWorksAfterContinueInBackground() {
    let app = attachedTerminal()

    require(app, "pane.actions", "Expected a pane actions control in the toolbar").tap()
    require(app, "pane.continueInBackground", "Expected Continue in Background").tap()

    require(app, "pane.actions", "Expected the pane actions control after the tap").tap()
    require(app, "pane.rename", "Expected the menu to still offer the pane's own actions")
  }

  func testRenamingAsksForTheNewLabelInline() {
    let app = attachedTerminal()

    require(app, "pane.actions", "Expected the menu").tap()
    require(app, "pane.rename", "Expected a rename action").tap()

    // Inline, not a modal. See `PanePromptBar`.
    let field = require(app, "pane.rename.field", "Expected somewhere to type the new label")
    require(app, "pane.rename.commit", "Expected a way to commit the rename")

    // Nothing presents this bar, so the field has to focus itself.
    let focusedOnOpen = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
    XCTAssertEqual(
      XCTWaiter().wait(for: [focusedOnOpen], timeout: 5), .completed,
      "Expected the rename field to focus itself with no extra tap"
    )

    // The existing name is selected, so the first keystroke replaces it.
    app.typeText("logs")
    XCTAssertEqual(
      field.value as? String, "logs",
      "Expected typing to replace the existing name, not append to it"
    )

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "pane-rename-prompt"
    shot.lifetime = .keepAlways
    add(shot)

    require(app, "pane.rename.cancel", "Expected a way to back out").tap()
    XCTAssertFalse(
      element(app, "pane.rename.field").exists,
      "Expected the prompt to go away"
    )
    XCTAssertFalse(
      app.keyboards.element.waitForExistence(timeout: 2),
      "Expected cancelling to take the keyboard back down"
    )

    // Committing resigns focus too. `commitRename` clears the prompt from inside a `Task`,
    // a separate path from `dismissPrompt`.
    require(app, "pane.actions", "Expected the menu").tap()
    require(app, "pane.rename", "Expected a rename action").tap()
    require(app, "pane.rename.commit", "Expected a way to commit the rename").tap()
    XCTAssertFalse(
      element(app, "pane.rename.field").exists,
      "Expected the prompt to go away after committing"
    )
    XCTAssertFalse(
      app.keyboards.element.waitForExistence(timeout: 2),
      "Expected committing to take the keyboard back down"
    )

    // The close confirmation has no field and must not raise a keyboard. Checked here, with
    // the keyboard already down, because the connect flow's password field does not resign
    // before the terminal opens, which would fail this for an unrelated reason.
    require(app, "pane.actions", "Expected the menu").tap()
    require(app, "pane.close", "Expected a close action").tap()
    let closeConfirm = require(app, "pane.close.confirm", "Expected the close confirmation")
    XCTAssertFalse(
      app.keyboards.element.exists,
      "Expected the close confirmation to never raise a keyboard"
    )

    // The same floor and ceiling as the interrupt confirm in `PaneComposerUITests`, whose
    // action row this bar shares.
    let closeCancel = require(app, "pane.close.cancel", "Expected a way to back out of the close")
    for (name, element) in [("pane.close.confirm", closeConfirm), ("pane.close.cancel", closeCancel)] {
      XCTAssertGreaterThanOrEqual(
        element.frame.height, 44, "\(name) is under the 44 pt target: \(element.frame)")
      XCTAssertLessThanOrEqual(
        element.frame.height, 52,
        "\(name) is drawing its 44 pt target rather than meeting it: \(element.frame)")
    }
    closeCancel.tap()

    // The screen is still leavable afterwards.
    leavePaneScene(app, "Expected a way out")
    XCTAssertTrue(
      element(app, "connect.terminal").waitForExistence(timeout: 10),
      "Expected to be back on the host screen.\nTree was:\n\(app.debugDescription)"
    )
  }

  /// Return commits the rename, so the user need not reach past the keyboard for a button.
  ///
  /// The prompt going away is the assertion. What herdr is asked for is
  /// `PaneActionsModelTests`.
  func testReturnCommitsTheRename() {
    let app = attachedTerminal()

    require(app, "pane.actions", "Expected the menu").tap()
    require(app, "pane.rename", "Expected a rename action").tap()

    let field = require(app, "pane.rename.field", "Expected somewhere to type the new label")
    let focused = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
    XCTAssertEqual(
      XCTWaiter().wait(for: [focused], timeout: 5), .completed,
      "Expected the rename field to focus itself with no extra tap"
    )

    // `\n` is what the keyboard's own Return key sends.
    app.typeText("logs\n")

    requireGone(
      app, "pane.rename.field",
      "Expected Return to commit the rename and take the bar down"
    )
    // No keyboard check. The terminal takes first responder back when the bar leaves, so the
    // keyboard staying up is by design.
    require(app, "terminal.view", "Expected to still be on the terminal")
  }

  /// Closing a pane asks first, and the screen can still be left afterwards. Either half
  /// alone passes on a build where the scene cannot be dismissed after a close.
  func testClosingAPaneAsksFirstAndThenLetsYouLeave() {
    let app = attachedTerminal()

    require(app, "pane.actions", "Expected the menu").tap()
    require(app, "pane.close", "Expected a close action").tap()

    // Destructive, so it asks, inline.
    require(app, "pane.close.confirm", "Expected a confirmation before closing")
    require(app, "pane.close.cancel", "Expected a way to back out of the close")

    require(app, "pane.close.confirm", "Expected a confirm button").tap()

    require(app, "terminal.pane.closed", "Expected the closed-pane banner", timeout: 15)

    leavePaneScene(app, "Expected a way out")
    XCTAssertTrue(
      element(app, "connect.terminal").waitForExistence(timeout: 15),
      "The cover would not dismiss after a close.\nTree was:\n\(app.debugDescription)"
    )

    // That pane is gone from the sidebar. By title, because the fake's second snapshot
    // blocks a different pane, so "no blocked pane" would fail for an unrelated reason.
    let closedPane = app.staticTexts.matching(
      NSPredicate(format: "label == %@", "needs a decision")
    ).firstMatch
    XCTAssertFalse(
      closedPane.waitForExistence(timeout: 5),
      "Expected the closed pane to be gone.\nTree was:\n\(app.debugDescription)"
    )
  }
}
