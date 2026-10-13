import XCTest

/// The composer bar at the bottom of the pane screen, under whichever chat-side surface is
/// showing.
///
/// The send states, copy and wire traffic are `PaneComposerState` and
/// `PaneComposerModelTests` in cheaper tiers. This class covers where the bar is drawn, that
/// a reply reaches the pane, that the bar stays for a pane that is not blocked, and where
/// Reply lands.
///
/// Relaunches per test: connecting records a trust decision and leaves a pane scene open.
///
/// Tests open panes through `treePaneRow`, because a Needs-you row opens with the keyboard
/// up. Two exceptions use `blockedPaneRow`: `schema sync`, which has no tree row (see its
/// call site), and `testReplyFromTheSidebarReachesTheComposer`, whose subject is that row.
@MainActor
final class PaneComposerUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

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

  /// Waits for absence. XCUITest sees a hierarchy mid-transition, so a single
  /// `XCTAssertFalse(exists)` passes or fails on timing.
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

  /// Waits for the status line to say something in particular.
  ///
  /// Polled, because the element can still hold the previous sentence when first read, and
  /// `Sent · waiting for the agent` retires itself after three seconds. The verdict renders
  /// at the foot of the conversation, not in the composer.
  private func requireStatus(
    _ app: XCUIApplication,
    saying expected: String,
    _ message: String,
    timeout: TimeInterval = 10,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let status = require(
      app, "pane.chat.activity", message, timeout: timeout, file: file, line: line)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline && !status.label.contains(expected) {
      usleep(150_000)
    }
    XCTAssertTrue(
      status.label.contains(expected),
      "\(message)\nStatus said '\(status.label)'. Tree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
  }

  /// The foot of the conversation says exactly this, and has not been replaced by a send
  /// verdict. Distinct from `requireStatus`, which waits for a verdict to *arrive*.
  private func requireActivity(
    _ app: XCUIApplication,
    saying expected: String,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let activity = require(app, "pane.chat.activity", message, file: file, line: line)
    XCTAssertEqual(
      activity.label,
      expected,
      "\(message)\nThe conversation said '\(activity.label)'.",
      file: file,
      line: line
    )
  }

  private func connectedHost(_ launchArguments: [String] = []) -> XCUIApplication {
    XCUIDevice.shared.orientation = .portrait
    // Seeded, because this class is not about connecting.
    let app = connectedHostApp(launchArguments)
    require(app, "session.workspace", "Expected the session tree")
    return app
  }

  // MARK: - Where the composer is

  /// The composer sits under the conversation with no terminal attached, so answering a
  /// blocked agent does not mean reading its TUI. On a blocked pane it is the field and Send,
  /// with no key grid and no Stop.
  func testTheComposerIsAtTheBottomOfAnAgentPaneScreen() {
    let app = connectedHost()

    treePaneRow(app, titled: "needs a decision").tap()

    require(app, "pane.chat", "Expected the pane to open on its conversation")
    require(app, "composer.text", "Expected the composer under the conversation")
    require(app, "composer.send", "Expected a send button")
    requireGone(app, "composer.stop", "Nothing is running on a blocked pane, so Stop must not show")
    requireGone(app, "composer.key.enter", "Enter must not be a composer key anymore")
    requireGone(app, "composer.key.esc", "Esc must not be a composer key anymore")
    requireGone(app, "terminal.view", "Answering a pane must not attach a terminal to it")

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "pane-composer"
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// The tool-run card's horizontal padding in `TranscriptTurnView`. Subtracting it from the
  /// tool-run row gives the turn card's painted edge.
  private static let toolRunCardInset: CGFloat = 10

  /// `ChatColumn.width`, written out because `DriverrUITests` does not import the app target.
  private static let columnWidth: CGFloat = 680

  /// The composer card and the conversation's turn cards share one column edge.
  ///
  /// It bites on `Driverr iPad`, where both views cap their width independently; on a phone
  /// neither cap binds. The bounds are relative, because on the iPad's detail route the
  /// column's x depends on the sidebar. Not a hosted test, because neither view opts into
  /// `measuredFrame`.
  ///
  /// No accessibility element reads the turn card's edge directly. The assistant turn's
  /// frame is 16 pt outside it, so the edge is read from `pane.chat.turn.tools` plus
  /// `toolRunCardInset`. The edges are one edge, so the tolerance is 2 pt of rounding.
  ///
  /// The width assertion guards the cap itself, since two uncapped views would still agree.
  /// It cannot fail in the portrait posture driven here; it guards the wide, sidebar-hidden
  /// posture.
  func testTheComposerStandsInTheSameColumnAsTheConversation() {
    let app = connectedHost()

    treePaneRow(app, titled: "needs a decision").tap()

    require(app, "pane.chat", "Expected the pane to open on its conversation")
    let field = require(app, "composer.text", "Expected the composer's field")
    let send = require(app, "composer.send", "Expected the send button")
    let row = require(
      app, "pane.chat.turn.tools", "Expected the tool run, which is what measures the column")

    let chat = require(app, "pane.chat", "Expected the conversation")
    let card = require(app, "composer.card", "Expected the composer's card")
    let turnCardStart = row.frame.minX - Self.toolRunCardInset
    let turnCardEnd = row.frame.maxX + Self.toolRunCardInset

    XCTAssertEqual(
      turnCardStart, card.frame.minX, accuracy: 2,
      "The conversation's turn card starts at x \(turnCardStart) and the composer's card at "
        + "x \(card.frame.minX). They are one edge on every window: where the readable column's "
        + "cap does not bind both sit a gutter in from the window, and where it does the cap has "
        + "taken that gutter and both sit on the conversation's own frame \(chat.frame)."
    )
    XCTAssertEqual(
      turnCardEnd, card.frame.maxX, accuracy: 2,
      "The conversation's turn card ends at x \(turnCardEnd) and the composer's card at "
        + "x \(card.frame.maxX), so one of the two is capped differently from the other."
    )

    XCTAssertLessThanOrEqual(
      send.frame.maxX - field.frame.minX, Self.columnWidth,
      "The reply row runs \(send.frame.maxX - field.frame.minX) pt wide, past "
        + "ChatColumn.width. A composer that spans a 13-inch iPad edge to edge reads as a "
        + "form rather than as a reply bar."
    )

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "composer-column"
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// An agent with no transcript reader opens on its captured screen, and the composer is
  /// there too, because there is nothing else to answer from.
  func testTheComposerIsAlsoUnderTheCapturedScreen() {
    let app = connectedHost()

    // `schema sync` is in the unfocused workspace `w2`, which has no tree rows on arrival.
    // `FakeControl.blockingScript`'s second snapshot blocks it, so its Needs-you row is the
    // way in.
    blockedPaneRow(app, titled: "schema sync").tap()

    require(app, "pane.screen", "Expected an unreadable agent to open on its captured screen")
    require(app, "composer.text", "Expected the composer under the captured screen too")
    require(app, "composer.send", "Expected a send button under the captured screen")
  }

  /// The composer stays for a working pane, and the foot of the conversation, not the
  /// composer, says what the pane is doing.
  func testTheComposerStaysForAPaneThatIsNotBlocked() {
    let app = connectedHost()

    treePaneRow(app, titled: "terminal wiring").tap()

    require(app, "composer.text", "The composer must not disappear for a pane that is not blocked")
    requireGone(app, "composer.header", "The composer reports nothing about the agent anymore")
    let activity = require(
      app, "pane.chat.activity", "Expected the conversation to say what the pane is doing")
    XCTAssertEqual(
      activity.label,
      "Claude is working.",
      """
      The foot of the conversation is what changes for a pane that is not blocked.
      Tree was:
      \(app.debugDescription)
      """
    )
  }

  /// A blocked pane says nothing at the foot, because the turn being answered is already
  /// emphasised and carries its chips.
  func testABlockedPaneSaysNothingUnderTheConversation() {
    let app = connectedHost()

    treePaneRow(app, titled: "needs a decision").tap()

    require(app, "pane.chat", "Expected the pane to open on its conversation")
    requireGone(app, "pane.chat.activity", "A blocked pane has nothing in flight to report")
    requireGone(app, "composer.header", "The composer reports nothing about the agent anymore")
  }

  // MARK: - What a send says

  /// The verdict says herdr took the reply, not that the agent answered, so the same answer
  /// is not sent twice.
  func testSendingSaysHerdrTookItAndNotThatTheAgentAnswered() {
    let app = connectedHost()
    treePaneRow(app, titled: "needs a decision").tap()

    require(app, "composer.text", "Expected the composer").tap()
    app.typeText("yes")
    require(app, "composer.send", "Expected a send button").tap()

    requireStatus(
      app,
      saying: "Sent · waiting for the agent",
      "Expected the composer to say herdr took the reply, not that it was answered"
    )
  }

  // MARK: - No keys on this side at all

  /// The composer has no keyboard accessory row. Chips answer questions, Stop interrupts,
  /// and the Terminal side keeps the full key row.
  ///
  /// Asserted after focusing, which is when a row would be drawn.
  func testTheComposerHasNoKeyboardKeyRow() {
    let app = connectedHost()
    treePaneRow(app, titled: "needs a decision").tap()

    require(app, "composer.text", "Expected the composer field").tap()

    for key in ["esc", "tab", "ctrl", "left", "up", "down", "right", "enter"] {
      requireGone(app, "composer.key.\(key)", "No \(key) key belongs on the chat composer")
    }
    requireGone(app, "composer.keyboard.dismiss", "No dismiss key belongs on the chat composer")
  }

  /// Focusing the field leaves the composer above the keyboard as drawn.
  ///
  /// Geometry, not existence, because a covered field still exists and is hittable. The
  /// keyboard's top comes from the app; see `assertComposerClearsTheDrawnKeyboard`.
  func testFocusingTheFieldDoesNotLeaveItBehindTheKeyboard() {
    let app = connectedHost([uiTestingKeyboardMetrics])
    treePaneRow(app, titled: "needs a decision").tap()

    let field = require(app, "composer.text", "Expected the composer field")
    field.tap()

    XCTAssertTrue(
      app.keyboards.firstMatch.waitForExistence(timeout: 10),
      "The keyboard never came up.\nTree was:\n\(app.debugDescription)"
    )
    // Send is the lowest thing on the card, so the keyboard reaches it first.
    require(app, "composer.send", "Expected the send button")

    let settle = Date().addingTimeInterval(3)
    while Date() < settle && keyboardMetrics(app).keyboardTop == nil { usleep(200_000) }
    assertComposerClearsTheDrawnKeyboard(app, "portrait")
  }

  /// The transcript runs underneath the composer, so the composer's material has turns to
  /// blur rather than rendering as a flat fill. Asserted on the scroll view's frame, not on
  /// pixels.
  func testTheTranscriptRunsUnderneathTheComposer() {
    let app = connectedHost()
    treePaneRow(app, titled: "needs a decision").tap()

    let chat = require(app, "pane.chat", "Expected the pane to open on its chat")
    let field = require(app, "composer.text", "Expected the composer field")

    XCTAssertGreaterThan(
      chat.frame.maxY,
      field.frame.minY,
      """
      The transcript stops above the composer, so its material has nothing to blur.
      chat:     \(chat.frame)
      composer: \(field.frame)
      """
    )
  }

  // MARK: - Stop only exists while the agent is working

  /// `terminal wiring` is working, the one state Stop belongs to. The blocked half is
  /// `testTheComposerIsAtTheBottomOfAnAgentPaneScreen`.
  func testStopOnlyAppearsWhileTheAgentIsWorking() {
    let app = connectedHost()

    treePaneRow(app, titled: "terminal wiring").tap()
    require(app, "composer.stop", "Expected Stop on a working pane")
  }

  /// A single tap must never send the interrupt.
  func testASingleStopTapDoesNotSendTheInterrupt() {
    let app = connectedHost()
    treePaneRow(app, titled: "terminal wiring").tap()

    require(app, "composer.stop", "Expected Stop on a working pane").tap()

    // Not `requireGone`: a working pane's foot row exists either way. The claim is that no
    // verdict replaced it.
    requireActivity(
      app, saying: "Claude is working.", "A single tap must not have sent anything yet")
    let confirm = require(app, "composer.stop.confirm", "Expected the two-step confirm to appear")
    let cancel = require(app, "composer.stop.cancel", "Expected a way to back out of the confirm")

    // A floor and a ceiling. A `.bordered` style pads its chrome around a label already
    // 44 pt tall, which drew these at 58 pt. 52 pt is the ceiling `AccessibilityUITests`
    // pins on the chips.
    for (name, element) in [("composer.stop.confirm", confirm), ("composer.stop.cancel", cancel)] {
      XCTAssertGreaterThanOrEqual(
        element.frame.height, 44, "\(name) is under the 44 pt target: \(element.frame)")
      XCTAssertLessThanOrEqual(
        element.frame.height, 52,
        "\(name) is drawing its 44 pt target rather than meeting it: \(element.frame)")
    }
  }

  /// The confirmed path sends the interrupt and reports its own verdict, not the ordinary
  /// "Sent · waiting for the agent", which would read as a reply.
  func testTheConfirmedStopSendsTheInterrupt() {
    let app = connectedHost()
    treePaneRow(app, titled: "terminal wiring").tap()

    require(app, "composer.stop", "Expected Stop on a working pane").tap()
    require(app, "composer.stop.confirm", "Expected the confirm button").tap()

    requireStatus(
      app, saying: "Claude was interrupted",
      "Expected the interrupt's own verdict, not the ordinary send sentence")
  }

  /// Cancelling the confirm sends nothing and returns to the idle bar.
  func testCancellingTheStopConfirmSendsNothing() {
    let app = connectedHost()
    treePaneRow(app, titled: "terminal wiring").tap()

    require(app, "composer.stop", "Expected Stop on a working pane").tap()
    require(app, "composer.stop.cancel", "Expected a Cancel button").tap()

    requireActivity(
      app, saying: "Claude is working.", "Cancelling the confirm must send nothing")
    require(app, "composer.stop", "Expected Stop to return once the confirm is cancelled")
  }

  // MARK: - Where Reply lands

  /// The Needs-you row is the Reply control. It opens the pane's own screen with the
  /// composer focused, under the question it answers, and no terminal.
  func testReplyFromTheSidebarReachesTheComposer() {
    let app = connectedHost()

    require(app, "session.needsYou", "Expected the blocked section")
    // Named, not by position, because the section re-sorts when the fake blocks a second
    // pane.
    waitForBothBlockedPanes(app)
    blockedPaneRow(app, titled: "needs a decision").tap()

    let field = require(app, "composer.text", "Expected Reply to reach a working composer")
    require(app, "composer.send", "Expected the composer to be able to send")
    // With no question on the pane, the focus request waits for the chat's read and then
    // focuses. `hasKeyboardFocus`, because `app.keyboards.count` reads 1 with a hardware
    // keyboard.
    let focused = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
    XCTAssertEqual(
      XCTWaiter().wait(for: [focused], timeout: 10), .completed,
      "Reply on a pane with no question of its own must still focus the composer")
    requireGone(app, "terminal.view", "Reply must not attach a terminal")
    require(app, "pane.surface.chat", "Expected Reply to land on the pane screen")
  }

  // MARK: - Slash command autocomplete

  /// A connected app serving the six-command fixture, on the pane whose conversation it is.
  ///
  /// The list is mined from the transcript's command turns, and the default fixture has
  /// none. The slow transcript, because the fake otherwise answers before the view is up.
  private func composerOnACommandTranscript() -> XCUIApplication {
    XCUIDevice.shared.orientation = .portrait
    let app = connectedHostApp(["-uiTestingSlashCommandTranscript", "-uiTestingSlowTranscript"])
    require(app, "session.workspace", "Expected the session tree")
    treePaneRow(app, titled: "needs a decision").tap()
    require(app, "pane.chat", "Expected the pane to open on its conversation")
    return app
  }

  /// The labels of the rows currently offered, top to bottom.
  ///
  /// Probes two rows past `SlashCommandRowLimit.maximum`, so a build that ignored the cap
  /// fails the equality checks instead of returning only the first rows.
  private func offeredCommands(_ app: XCUIApplication) -> [String] {
    (0..<(SlashCommandRowLimit.maximum + 2)).compactMap { index in
      let row = element(app, "composer.suggestions.row.\(index)")
      return row.exists ? row.label : nil
    }
  }

  /// Typing `/` offers the commands this session has used, and typing further filters them.
  /// Both halves are needed, because a list that ignored the text would pass the first.
  /// Counting and ordering are `SlashCommandMatcherTests`.
  func testTypingASlashOffersCommandsAndTypingFurtherFiltersThem() {
    let app = composerOnACommandTranscript()

    require(app, "composer.text", "Expected the composer field").tap()
    app.typeText("/")

    require(app, "composer.suggestions.row.0", "Typing / must offer the session's commands")
    let bare = offeredCommands(app)
    XCTAssertEqual(
      bare,
      ["/run-tests", "/push", "/lint"],
      """
      The fixture has six distinct commands and the list is capped at \
      \(SlashCommandRowLimit.maximum), so a bare / must offer exactly the three most \
      recently used, newest first.
      Offered: \(bare)
      """
    )

    // The third row is Claude Code's built-in `/compact`. The ranking puts the session's
    // recents first, in their own order, then everything else alphabetically.
    app.typeText("co")
    let filtered = offeredCommands(app)
    XCTAssertEqual(
      filtered,
      ["/code-review", "/commit", "/compact"],
      "Expected /co to offer the session's own two first, then the built-in: \(filtered)"
    )
  }

  /// Choosing a row completes into the field and does not send, because a mis-sent command
  /// reaches a live agent.
  ///
  /// The fixture used `/code-review high --fix`, so the exact-value check also proves the
  /// completion invents no arguments.
  func testChoosingASuggestionCompletesTheFieldWithoutSending() {
    let app = composerOnACommandTranscript()

    let field = require(app, "composer.text", "Expected the composer field")
    field.tap()
    app.typeText("/code")

    let row = require(app, "composer.suggestions.row.0", "Expected /code to offer a command")
    let chosen = row.label
    row.tap()

    XCTAssertEqual(
      field.value as? String,
      chosen + " ",
      """
      Choosing a suggestion must complete the command and nothing else \
      — no invented argument, and a trailing space for one to be typed into.
      Field held: \(String(describing: field.value))
      """
    )
    // Not sent, checked twice. A send clears the field, so the text above proves half. The
    // foot is absent on this fixture until something happens, and a send would bring it back
    // saying "Sent", so the check is "no foot, or a foot that does not say Sent".
    let activity = element(app, "pane.chat.activity")
    if activity.exists {
      XCTAssertFalse(
        activity.label.contains("Sent"),
        """
        Choosing a suggestion must not send the message.
        The conversation said: \(activity.label)
        """
      )
    }
    // The list closes, because the field is no longer a bare command word.
    requireGone(
      app,
      "composer.suggestions.row.0",
      "The list must close once a command has been chosen"
    )
  }

  /// The list dismisses without choosing. The dismiss control is its own row
  /// (`PaneComposerBar.suggestionsHeader`), so this also proves it is a separate target from
  /// the top suggestion.
  func testDismissingHidesTheListWithoutChangingTheField() {
    let app = composerOnACommandTranscript()

    let field = require(app, "composer.text", "Expected the composer field")
    field.tap()
    app.typeText("/")

    require(app, "composer.suggestions.row.0", "Expected the list before dismissing it")
    require(app, "composer.suggestions.dismiss", "Expected a dismiss control on the list").tap()

    requireGone(app, "composer.suggestions.row.0", "Dismiss must hide the list")
    XCTAssertEqual(
      field.value as? String,
      "/",
      "Dismissing must leave what was typed alone. Field held: \(String(describing: field.value))"
    )
  }

  // MARK: - The host's installed skills and commands

  /// A session with no command history still offers what the host has installed, with its
  /// description, and choosing one completes only the command.
  ///
  /// The launch omits `-uiTestingSlashCommandTranscript`, so every row comes from the
  /// catalogue. The ranking is `SlashCommandCatalogTests` and the parse is
  /// `SkillCatalogTests`.
  func testTypingASlashOffersTheHostsInstalledSkillsWithTheirDescriptions() {
    XCUIDevice.shared.orientation = .portrait
    let app = connectedHostApp(["-uiTestingSkillCatalog", "-uiTestingSlowTranscript"])
    require(app, "session.workspace", "Expected the session tree")
    treePaneRow(app, titled: "needs a decision").tap()
    require(app, "pane.chat", "Expected the pane to open on its conversation")

    let field = require(app, "composer.text", "Expected the composer field")
    field.tap()
    // `/dep` matches one skill in the fixture and no built-in.
    app.typeText("/dep")

    let row = require(
      app,
      "composer.suggestions.row.0",
      "A session with no command history must still offer the host's installed skills"
    )
    XCTAssertEqual(
      row.label,
      "/deploy-preview",
      """
      The row's label must be the command itself, so a completion can be read off it.
      Offered: \(offeredCommands(app))
      """
    )
    // The description is the row's accessibility value, so VoiceOver reads it after the name.
    // The fixture writes it as a folded `description: >-` block, which a parser reading only
    // the marker line would leave empty.
    XCTAssertTrue(
      (row.value as? String ?? "").hasPrefix("Build the branch and put it on a preview host"),
      """
      Expected the row to carry the skill's own description.
      Value was: \(String(describing: row.value))
      """
    )

    row.tap()
    XCTAssertEqual(
      field.value as? String,
      "/deploy-preview ",
      """
      Choosing an installed skill must complete the command and nothing else.
      Field held: \(String(describing: field.value))
      """
    )
  }

  // MARK: - External keyboard navigation

  /// Which offered rows report themselves selected, top to bottom. Read from the
  /// `.isSelected` trait, which is what VoiceOver reads, rather than from the tint.
  private func highlightedRows(_ app: XCUIApplication) -> [Int] {
    (0..<SlashCommandRowLimit.maximum).filter { index in
      let row = element(app, "composer.suggestions.row.\(index)")
      return row.exists && row.isSelected
    }
  }

  /// Up and Down move the highlight, and nothing is highlighted until one is pressed.
  ///
  /// The wrapping is `SlashSuggestionSelectionTests`. This proves a key press reaches the view
  /// rather than moving the field's caret. The highlighted set is compared whole, so a build
  /// that lit every row fails.
  func testArrowKeysMoveTheHighlightOverTheSuggestions() {
    let app = composerOnACommandTranscript()

    require(app, "composer.text", "Expected the composer field").tap()
    app.typeText("/")
    require(app, "composer.suggestions.row.0", "Typing / must offer the session's commands")

    XCTAssertEqual(
      highlightedRows(app),
      [],
      "Nothing may be highlighted before an arrow key is pressed — Return has to fall through."
    )

    app.typeKey(.downArrow, modifierFlags: [])
    XCTAssertEqual(
      highlightedRows(app),
      [0],
      """
      Down must highlight the first row and only the first row.
      Tree was:
      \(app.debugDescription)
      """
    )

    app.typeKey(.downArrow, modifierFlags: [])
    XCTAssertEqual(highlightedRows(app), [1], "A second Down must move to the next row.")

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "slash-suggestions-highlighted-row-1"
    shot.lifetime = .keepAlways
    add(shot)

    app.typeKey(.upArrow, modifierFlags: [])
    XCTAssertEqual(highlightedRows(app), [0], "Up must move back to the row above.")

    // Up from the top wraps to the bottom, and the field is untouched throughout.
    app.typeKey(.upArrow, modifierFlags: [])
    XCTAssertEqual(
      highlightedRows(app),
      [SlashCommandRowLimit.maximum - 1],
      "Up from the first row must wrap to the last."
    )
    XCTAssertEqual(
      element(app, "composer.text").value as? String,
      "/",
      "Arrow keys must move the highlight, never type into the field."
    )
  }

  // There is no Return or Escape test. XCUITest does not deliver either key to the app on
  // the simulator: `typeKey(.downArrow)` and `typeKey(.tab)` arrive, but Return and Escape,
  // with or without modifiers, reach no handler at all, including the shipped Command-Return
  // shortcut on Send. `PaneComposerBar.withSlashKeyHandling` handles both by the mechanism
  // the arrow test proves, but they are verified only on a device with a hardware keyboard.
  // No `XCTSkip`, because a skipped test reads as covered.
}


// MARK: - The pending image attachment

extension PaneComposerUITests {
  /// A pane screen with the composer on it and a photograph already picked.
  ///
  /// `-uiTestingPickedImage` stands in for `PhotosPicker`, which runs out of process where
  /// XCUITest cannot reach it. The app generates the bytes and the attach button hands them
  /// to the composer, so everything after the pick is exercised.
  ///
  /// `-uiTestingSlowUpload` stretches the fake upload to about 3.2 seconds. Without it the
  /// row finishes before the first assertion, and a build that never reported a byte passes.
  private func composerWithAPickedImage(_ extraArguments: [String] = []) -> XCUIApplication {
    XCUIDevice.shared.orientation = .portrait
    let app = connectedHostApp(
      ["-uiTestingPickedImage", "-uiTestingSlowUpload"] + extraArguments)
    require(app, "session.workspace", "Expected the session tree")
    treePaneRow(app, titled: "needs a decision").tap()
    require(app, "pane.chat", "Expected the pane to open on its conversation")
    return app
  }

  /// The attach control is hittable, not only present, because the composer floats over a
  /// scrolling conversation. Its 44 pt target is `AccessibilityUITests`.
  func testTheComposerOffersAWayToAttachAnImage() {
    let app = composerWithAPickedImage()

    let attach = require(app, "composer.attach", "Expected an attach control on the composer")
    XCTAssertTrue(
      attach.isHittable,
      "The attach control must be reachable, not merely present.\nTree was:\n"
        + app.debugDescription
    )
    requireGone(
      app, "composer.attachment.row", "Nothing is attached until the attach control is tapped")
  }

  /// The row reports bytes sent while the upload runs.
  ///
  /// Checked mid-flight, which proves the transfer drives the progress. The string is
  /// `PaneAttachmentCopy`'s.
  func testAttachingShowsARowThatReportsBytesSent() {
    let app = composerWithAPickedImage()
    require(app, "composer.attach", "Expected an attach control").tap()

    // Polled straight off the tap. Each element lookup costs a tree snapshot, and lookups
    // before this loop can outlast the upload.
    let progress = element(app, "composer.attachment.progress")

    // "Preparing…" comes first, so wait for the " of " that joins the two sizes.
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline && !progress.label.contains(" of ") {
      usleep(100_000)
    }
    XCTAssertTrue(
      progress.label.contains(" of "),
      "Expected bytes sent over total while uploading, got '\(progress.label)'.\nTree was:\n"
        + app.debugDescription
    )
    require(app, "composer.attachment.row", "Expected a row for the pending image")
  }

  /// When the upload finishes, the row settles on a notice rather than a byte count.
  ///
  /// It waits for the hand-off sentence, because `FakeControl.sendText` returns at once and
  /// `Sent to the host` shows for about one main-actor hop.
  ///
  /// The path goes to the pane over `sendText`, never into Driverr's field, where it would
  /// type over what the reader was writing.
  func testTheRowSettlesOnceTheHostHasTheImage() {
    let app = composerWithAPickedImage()
    require(app, "composer.attach", "Expected an attach control").tap()

    let progress = require(app, "composer.attachment.progress", "Expected the row")
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline && !progress.label.contains(Self.handedOverNotice) {
      usleep(150_000)
    }
    XCTAssertTrue(
      progress.label.contains(Self.handedOverNotice),
      "Expected the row to report the hand-off, got '\(progress.label)'.\nTree was:\n"
        + app.debugDescription
    )

    // Asserted on what the field does not hold, not on its placeholder, which is copy.
    let field = require(app, "composer.text", "Expected the composer field")
    let typed = (field.value as? String) ?? ""
    XCTAssertFalse(
      typed.contains(".driverr/inbox") || typed.contains(".png"),
      "The path goes to the pane over sendText, never into the composer field, and the field "
        + "held '" + typed + "'."
    )
  }

  /// The row reports the hand-off while the field keeps what the reader typed before and
  /// after Attach. The wire traffic is `PaneComposerModelTests`.
  ///
  /// `app.keyboards.count` is not asserted, because it reads 1 with a hardware keyboard.
  /// Typing that lands in the field proves the field kept focus.
  func testTheRowReportsTheHandOffWhileTheFieldKeepsWhatWasTyped() {
    let app = composerWithAPickedImage()

    let field = require(app, "composer.text", "Expected the composer field")
    field.tap()
    field.typeText("look")

    require(app, "composer.attach", "Expected an attach control").tap()

    let progress = require(app, "composer.attachment.progress", "Expected the row")
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline && !progress.label.contains(Self.handedOverNotice) {
      usleep(150_000)
    }
    XCTAssertTrue(
      progress.label.contains(Self.handedOverNotice),
      "Expected the row to report that the pane was told, got '\(progress.label)'.\nTree was:\n"
        + app.debugDescription
    )

    field.typeText(" at this")

    let typed = (field.value as? String) ?? ""
    XCTAssertTrue(
      typed.contains("look") && typed.contains("at this"),
      "The hand-off must leave the reader typing where they were. The field held '"
        + typed + "'.\nTree was:\n" + app.debugDescription
    )
    XCTAssertFalse(
      typed.contains(".driverr/inbox"),
      "The path belongs in the pane, not in the field. The field held '" + typed + "'."
    )
  }

  /// `PaneAttachmentCopy.handedOver`, restated because the UI test bundle does not link
  /// `DriverrKit`.
  private static let handedOverNotice = "Added to the pane’s prompt"

  /// Remove clears the row and stops the running upload.
  ///
  /// `PaneAttachmentModel` ignores phases from an abandoned run, so the row clears even if
  /// the transfer continues. The stop is read off `debug.upload`, which the fake writes when
  /// its sleep is cancelled. The wire side is `ImageUploaderTests`.
  ///
  /// `-uiTestingStalledUpload` makes the upload take forty seconds, so the cancel lands on a
  /// live transfer despite the lookups before it.
  func testRemovingTheAttachmentClearsTheRowAndStopsTheUpload() {
    let app = composerWithAPickedImage(["-uiTestingStalledUpload"])
    require(app, "composer.attach", "Expected an attach control").tap()
    require(app, "composer.attachment.row", "Expected a row for the pending image")

    // Under way, not only staged.
    let progress = require(app, "composer.attachment.progress", "Expected the row's status")
    let uploading = Date().addingTimeInterval(10)
    while Date() < uploading && !progress.label.contains(" of ") {
      usleep(100_000)
    }
    XCTAssertTrue(
      progress.label.contains(" of "),
      "Expected the upload to be under way before Remove, got '\(progress.label)'."
    )

    let probe = require(
      app, "debug.upload", "Expected the upload probe under -uiTestingPickedImage")
    XCTAssertFalse(
      probe.label.contains("cancelled"),
      "Nothing has been cancelled yet, so the probe must be empty. It said '\(probe.label)'."
    )

    require(app, "composer.attachment.remove", "Expected a way to remove the attachment").tap()

    requireGone(app, "composer.attachment.row", "Remove must take the pending image away")
    requireGone(app, "composer.attachment.progress", "Remove must take the row's status with it")

    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline && !probe.label.contains("cancelled at") {
      usleep(100_000)
    }
    XCTAssertTrue(
      probe.label.contains("cancelled at"),
      """
      Remove must stop the upload, not only clear the row. The probe said '\(probe.label)'.
      Tree was:
      \(app.debugDescription)
      """
    )
  }

  /// A failed upload says so inline on the bar, with no alert, and the row stays so Remove is
  /// still the way out. The sentence is `PaneAttachmentFailureCopy`.
  func testAFailedUploadSaysSoInlineAndKeepsTheRow() {
    let app = composerWithAPickedImage(["-uiTestingUploadFails"])
    require(app, "composer.attach", "Expected an attach control").tap()

    let failure = require(
      app,
      "composer.attachment.failure",
      "Expected the failure to render on the bar",
      timeout: 15
    )
    XCTAssertFalse(
      failure.label.isEmpty,
      "The inline failure must say something.\nTree was:\n\(app.debugDescription)"
    )
    require(app, "composer.attachment.row", "A failed upload must not discard the picked image")
    require(app, "composer.attachment.remove", "Remove must still be the way out after a failure")
    XCTAssertEqual(
      app.alerts.count, 0,
      "The failure is inline. A sheet or an alert is the shape CLAUDE.md forbids here."
    )
  }
}

/// `SlashCommandMatcher.maximumSuggestions`, restated because the UI test bundle does not
/// link `DriverrKit`.
private enum SlashCommandRowLimit {
  static let maximum = 3
}
