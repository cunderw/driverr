import XCTest

/// The composer bar at the bottom of the pane screen, under whichever chat-side surface is
/// showing.
///
/// The send states, copy and wire traffic are `PaneComposerState` and
/// `PaneComposerModelTests` in cheaper tiers. This class covers where the bar is drawn, that
/// a reply reaches the pane, that the bar stays for a pane that is not blocked, and where
/// Reply lands.
///
/// What the composer offers while typing (slash commands, skills, arrow keys, attachments and
/// saved prompts) is `PaneComposerInputUITests`.
///
/// Relaunches per test: connecting records a trust decision and leaves a pane scene open.
///
/// Tests open panes through `treePaneRow`, because a Needs-you row opens with the keyboard
/// up. Two exceptions use `blockedPaneRow`: `schema sync`, which has no tree row (see its
/// call site), and `testReplyFromTheSidebarReachesTheComposer`, whose subject is that row.
@MainActor
final class PaneComposerUITests: PaneComposerUITestCase {
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

  // MARK: - Shift-Tab, Claude Code's mode

  /// The button is wiring: one tap sends Shift-Tab and says so. When it shows is
  /// `PaneModeControlTests` and `ShiftTabReachTests`, in `swift test`.
  func testTheModeButtonSendsShiftTab() {
    let app = connectedHost()
    treePaneRow(app, titled: "terminal wiring").tap()

    let mode = require(app, "composer.mode", "Expected the mode button on a Claude pane")
    XCTAssertEqual(mode.label, "Change mode", "VoiceOver has only the label for a glyph")
    XCTAssertGreaterThanOrEqual(mode.frame.height, 44, "Under the 44 pt target: \(mode.frame)")
    XCTAssertGreaterThanOrEqual(mode.frame.width, 44, "Under the 44 pt target: \(mode.frame)")
    mode.tap()

    // The pane is still working, so the notice joins that line rather than replacing it.
    requireStatus(
      app, saying: "Claude is working. · Sent Shift-Tab",
      "Expected the key's notice beside the working line, not in its place")
  }

  /// At a permission prompt Claude Code binds Shift-Tab to approving, so the button is off.
  func testTheModeButtonIsOffWhileThePaneIsBlocked() {
    let app = connectedHost()
    treePaneRow(app, titled: "needs a decision").tap()

    let mode = require(app, "composer.mode", "Expected the mode button, drawn and off")
    XCTAssertFalse(mode.isEnabled, "Shift-Tab would approve the blocked pane's request")
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
    // On the chat, the surface toggle leads to the terminal.
    require(app, "pane.surface.terminal", "Expected Reply to land on the pane's chat")
  }
}
