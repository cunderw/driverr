import XCTest

/// The pane screen's chat: which panes get a `Chat | Terminal` segment, how a transcript
/// renders, and where `Show the screen` lands.
///
/// Every sentence on this screen is asserted in cheaper tiers (`TranscriptPresentationTests`,
/// `PaneTranscriptModelTests`, `PaneScreenPresentationTests`, `TranscriptPickerTests`). This
/// class covers what no value can hold: which views the screen builds, what it opens on,
/// that switching surfaces keeps both alive, routing, and the absence of a transcript behind
/// a refusal.
///
/// Relaunches per test: connecting records a trust decision and leaves a pane scene open.
@MainActor
final class PaneChatUITests: XCTestCase {
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

  private func connectedHost(
    truncatedTranscript: Bool = false,
    ambiguousTranscript: Bool = false,
    pagedTranscript: Bool = false,
    boundedTranscript: Bool = false,
    pendingTranscript: Bool = false,
    multiQuestionTranscript: Bool = false,
    answeredQuestionTranscript: Bool = false,
    richTranscript: Bool = false,
    imageTranscript: Bool = false,
    agentEventTranscript: Bool = false,
    orchestratorTranscript: Bool = false,
    stalledTranscript: Bool = false,
    growingTranscript: Bool = false,
    growingAnswer: Bool = false,
    slowTranscript: Bool = false,
    agentStartsWorking: Bool = false,
    askingWhileWorking: Bool = false,
    screenQuestion: Bool = false,
    screenQuestionHandover: Bool = false,
    usageLimited: Bool = false,
    subagents: Bool = false
  ) -> XCUIApplication {
    XCUIDevice.shared.orientation = .portrait
    var flags: [String] = []
    if truncatedTranscript { flags += ["-uiTestingTruncatedTranscript"] }
    if ambiguousTranscript { flags += ["-uiTestingAmbiguousTranscript"] }
    if pagedTranscript { flags += ["-uiTestingPagedTranscript"] }
    if boundedTranscript { flags += ["-uiTestingBoundedTranscript"] }
    if pendingTranscript { flags += ["-uiTestingPendingTranscript"] }
    // Ends on an `AskUserQuestion` with two questions, so its chips can fail the one-group
    // parse.
    if multiQuestionTranscript { flags += ["-uiTestingMultiQuestionTranscript"] }
    // The same two questions, answered, with the reply record behind them.
    if answeredQuestionTranscript { flags += ["-uiTestingAnsweredQuestionTranscript"] }
    if richTranscript { flags += ["-uiTestingRichTranscript"] }
    // Human turns with real base64 PNGs, plus one image block with no payload.
    if imageTranscript { flags += ["-uiTestingImageTranscript"] }
    if agentEventTranscript { flags += ["-uiTestingAgentEventTranscript"] }
    // This session's own spawns, stops and outgoing messages, read off `tool_use` blocks.
    if orchestratorTranscript { flags += ["-uiTestingOrchestratorTranscript"] }
    if stalledTranscript { flags += ["-uiTestingStalledTranscript"] }
    // Gains an assistant turn fifteen seconds after the first transcript command, while the
    // herdr tree stays still.
    if growingTranscript { flags += ["-uiTestingGrowingTranscript"] }
    // The final answer grows in place eight seconds after the stream opens, keeping its record
    // id, so a diffable data source sees no change. `-uiTestingGrowingTranscript` appends a
    // new id instead.
    if growingAnswer { flags += ["-uiTestingGrowingAnswer"] }
    // Answers at a real host's speed. The connection is seeded but the transcript never is,
    // because an instant transcript hides open-time defects the phone shows. See
    // `testTheChatOpensAtTheEndOfATallNewestTurn`.
    if slowTranscript { flags += ["-uiTestingSlowTranscript"] }
    // Flips `terminal wiring` from idle to working ten seconds after the pane's stream opens.
    if agentStartsWorking { flags += ["-uiTestingAgentStartsWorking"] }
    // Reports the asking pane as `working` while its file already carries the question.
    // Pairs with any transcript flag above.
    if askingWhileWorking { flags += ["-uiTestingAskingWhileWorking"] }
    // The question is on the blocked pane's screen and not in its file.
    if screenQuestion { flags += ["-uiTestingScreenQuestion"] }
    // As above, then the session file gains the question eight seconds after the pane opens.
    if screenQuestionHandover { flags += ["-uiTestingScreenQuestionHandover"] }
    // Ends on Claude Code's usage-limit record, resetting two hours after the fetch.
    if usageLimited { flags += ["-uiTestingUsageLimited"] }
    // Two spawn lines with a sub-agent file behind each: a finished plain spawn and a running
    // teammate.
    if subagents { flags += ["-uiTestingSubagents"] }
    // Seeded, because this class is not about connecting.
    let app = connectedHostApp(flags)
    require(app, "session.workspace", "Expected the session tree")
    return app
  }

  /// Taps the pane whose title is `title`, preferring its tree row.
  ///
  /// The Needs-you row opens the pane with the keyboard up, which halves the viewport these
  /// tests read and scroll. The fallback is for `schema sync`, which lives in the collapsed
  /// `tower` workspace and has only a Needs-you row. It matches any element type, because a
  /// shell row publishes no `StaticText` (see `SessionTreeUITests.labelled`), and takes
  /// `firstMatch`, because a blocked pane appears twice.
  private func tapPane(_ app: XCUIApplication, titled title: String) {
    let treeRow = app.descendants(matching: .any)
      .matching(identifier: "session.pane")
      .matching(NSPredicate(format: "label CONTAINS %@", title))
      .firstMatch
    let row =
      treeRow.waitForExistence(timeout: 10)
      ? treeRow
      : app.descendants(matching: .any)
        .matching(NSPredicate(format: "label == %@", title))
        .firstMatch
    // Wait before scrolling. The session tree arrives after the screen is up, and only
    // "below the fold" is fixed by swiping.
    _ = row.waitForExistence(timeout: 10)
    for _ in 0..<6 where !row.exists {
      app.swipeUp()
    }
    XCTAssertTrue(
      row.exists,
      "Expected a pane titled '\(title)' after scrolling.\nTree was:\n\(app.debugDescription)"
    )
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline && !row.isHittable {
      usleep(200_000)
    }
    // Scroll toward the row: it can be under the navigation bar or below the fold.
    for _ in 0..<6 where !row.isHittable {
      if row.frame.midY > app.frame.maxY - 44 {
        app.swipeUp()
      } else {
        app.swipeDown()
      }
    }
    XCTAssertTrue(
      row.isHittable,
      "Pane '\(title)' never became tappable at \(row.frame).\nTree was:\n\(app.debugDescription)"
    )
    row.tap()
  }

  // MARK: - Which panes get a segment

  /// The segment appears if and only if the pane has an agent, and an agent pane opens on
  /// Chat.
  func testAnAgentPaneOpensOnChatWithASegment() {
    let app = connectedHost()

    tapPane(app, titled: "needs a decision")

    require(app, "pane.surface.chat", "Expected a Chat segment on an agent pane")
    require(app, "pane.surface.terminal", "Expected a Terminal segment on an agent pane")
    require(app, "pane.chat", "Expected the pane to open on the chat")
    // The terminal is laid out behind the chat and hidden from accessibility. If it were
    // findable here, a later "switching shows the terminal" assertion would prove nothing.
    requireGone(app, "terminal.view", "Expected the terminal to be hidden behind the chat")
  }

  func testAShellPaneHasNoSegmentAndOpensOnTheTerminal() {
    let app = connectedHost()

    // A pane with no agent.
    tapPane(app, titled: "swift test")

    require(app, "terminal.view", "Expected a shell pane to open straight into the terminal")
    requireGone(app, "pane.surface.chat", "Expected no Chat segment on a shell pane")
    requireGone(app, "pane.surface.terminal", "Expected no Terminal segment on a shell pane")
  }

  // MARK: - What the chat draws

  /// The seeded fixture is one human turn, a seven-call tool run, a markdown assistant turn
  /// and the agent's question. Every shape renders, and the run renders closed.
  func testTheChatRendersTurnsAndAClosedToolRun() {
    let app = connectedHost()

    tapPane(app, titled: "needs a decision")

    require(app, "pane.chat.turn.human", "Expected the human turn")
    require(app, "pane.chat.turn.assistant", "Expected the agent's turn")
    let run = require(app, "pane.chat.turn.tools", "Expected the tool run as one closed row")
    // Closed shows its recent rows separately, so the header announces only the total; the
    // tally belongs to the opened state where the closed rows no longer make it redundant.
    XCTAssertEqual(
      run.label,
      "7 tool calls.",
      "A closed run must not announce the tally it does not draw.\nTree was:\n\(app.debugDescription)"
    )
    // The elapsed line reaches the screen. Its wording is `swift test`'s. The newest turn is
    // checked because the chat opens at the bottom and a turn further up may not be built.
    // The last fixture turn carries 15,228 ms.
    require(app, "pane.chat.turn.duration", "Expected the turn's elapsed time under the answer")
    let durations = app.descendants(matching: .any)
      .matching(identifier: "pane.chat.turn.duration")
    let labels = (0..<durations.count).map { durations.element(boundBy: $0).label }
    XCTAssertTrue(
      labels.contains("Crunched for 15s"),
      "The newest turn must say the recorded figure. Saw \(labels).\n"
        + "Tree was:\n\(app.debugDescription)"
    )
  }

  /// A turn with bold, inline code and a fenced block renders as markdown. Asserted by the
  /// absence of the raw markers, with a screenshot for the shape.
  func testMarkdownRendersRatherThanDrawingRawSyntax() {
    let app = connectedHost()

    tapPane(app, titled: "needs a decision")

    let turns = app.descendants(matching: .any).matching(identifier: "pane.chat.turn.assistant")
    let markdownTurn = turns.element(
      matching: NSPredicate(format: "label CONTAINS %@", "Pool::acquire")
    )
    XCTAssertTrue(
      markdownTurn.waitForExistence(timeout: 10),
      "Expected the markdown-bearing fixture turn.\nTree was:\n\(app.debugDescription)"
    )
    XCTAssertFalse(
      markdownTurn.label.contains("**"),
      "Bold markers must not draw literally: '\(markdownTurn.label)'"
    )
    XCTAssertFalse(
      markdownTurn.label.contains("```"),
      "Fence markers must not draw literally: '\(markdownTurn.label)'"
    )

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "markdown-turn"
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// A unified diff in an agent's answer is drawn as a diff card, not as raw `+`/`-` lines.
  ///
  /// This asserts only that the card reached the screen. The card's content is
  /// `TranscriptDiffTests`.
  func testAFileDiffRendersAsADiffCard() {
    let app = connectedHost(richTranscript: true, slowTranscript: true)

    tapPane(app, titled: "needs a decision")

    let turn = require(app, "pane.chat.turn.assistant", "Expected the agent's turn")
    XCTAssertTrue(
      turn.label.contains("Diff of src/pool.rs"),
      "Expected the diff card's own sentence in the turn, got '\(turn.label)'.\n"
        + "Tree was:\n\(app.debugDescription)"
    )
    XCTAssertFalse(
      turn.label.contains("@@ -12,7"),
      "A hunk header drawn as text means the patch rendered flat: '\(turn.label)'"
    )

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "diff-turn"
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// An image turn draws a thumbnail, a tap opens it full size, and Done puts it away.
  ///
  /// The mapping is `TranscriptImageMappingTests`. The fixture serves real PNG bytes
  /// (`FakeTranscriptHost.tinyPNG`), because an undecodable payload draws the same label an
  /// absent one does.
  func testAnImageTurnDrawsAThumbnailThatOpensFullSize() {
    let app = connectedHost(imageTranscript: true, slowTranscript: true)

    tapPane(app, titled: "needs a decision")

    require(app, "pane.chat.turn.human", "Expected the human turn")
    // Matched on the prefix, because an image's id contains the record's uuid.
    let thumbnails = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "chat.image.")
    )
    let thumbnail = thumbnails.firstMatch
    XCTAssertTrue(
      thumbnail.waitForExistence(timeout: 15),
      "Expected a thumbnail in the image turn.\nTree was:\n\(app.debugDescription)"
    )

    let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    before.name = "image-turn"
    before.lifetime = .keepAlways
    add(before)

    // Tap the thumbnail with the keyboard up. The keyboard is its own window, so no in-app
    // overlay covers it. This is the only check on `TerminalScreen.onOpenImage` resigning the
    // first responder; without it the viewer still opens, under the keys.
    require(app, "composer.text", "Expected the composer field").tap()
    var keyboardUp = app.keyboards.count > 0
    for _ in 0..<20 where !keyboardUp {
      usleep(300_000)
      keyboardUp = app.keyboards.count > 0
    }
    XCTAssertTrue(
      keyboardUp,
      """
      The keyboard never came up, so the tap below is not the keyboard-up case and nothing
      under it is a result about dismissing one. A hardware keyboard connected to the
      simulator is the usual cause.
      Tree was:
      \(app.debugDescription)
      """)

    thumbnail.tap()

    require(app, "chat.image.full", "Expected the full-size image after tapping a thumbnail")
    let opened = require(app, "chat.image.close", "Expected a Done button over the image")

    // Counted, not measured: `frame` on a query with no match raises an error instead of
    // failing the assertion.
    var keyboards = app.keyboards.count
    for _ in 0..<20 where keyboards > 0 {
      usleep(300_000)
      keyboards = app.keyboards.count
    }
    // Printed so a passing run still records the keyboard state.
    print("[keyboard] keyboards up before the tap: \(keyboardUp), after opening: \(keyboards)")

    let overKeyboard = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    overKeyboard.name = "image-full-keyboard-dismissed"
    overKeyboard.lifetime = .keepAlways
    add(overKeyboard)

    XCTAssertEqual(
      keyboards, 0,
      """
      Opening an image must take the keyboard away, because a keyboard is its own window and
      no in-app overlay can cover one.
      Tree was:
      \(app.debugDescription)
      """)

    let full = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    full.name = "image-full"
    full.lifetime = .keepAlways
    add(full)

    opened.tap()

    requireGone(app, "chat.image.full", "Done must put the full-size image away")
    XCTAssertTrue(
      thumbnail.waitForExistence(timeout: 5),
      "The conversation must still be there behind it.\nTree was:\n\(app.debugDescription)"
    )
  }

  /// Four drawable payloads take only the three slots the narrow phone can show. The last
  /// shown thumbnail carries the `+1` scrim as its accessibility value; the scrim itself is
  /// hidden, so VoiceOver does not stop on the same image twice.
  func testAnImageTurnWithFourPayloadsShowsThePlusOneBadge() {
    let app = connectedHost(imageTranscript: true, slowTranscript: true)

    tapPane(app, titled: "needs a decision")

    let chat = require(app, "pane.chat", "Expected the image transcript")
    let first = app.buttons["Image 1 of 4"]
    let second = app.buttons["Image 2 of 4"]
    let badge = app.buttons["Image 3 of 4"]
    for _ in 0..<6 where !badge.isHittable {
      chat.swipeDown(velocity: .slow)
    }
    for thumbnail in [first, second, badge] {
      XCTAssertTrue(
        thumbnail.waitForExistence(timeout: 5) && thumbnail.isHittable,
        "Expected a visible thumbnail in the four-image turn.\nTree was:\n\(app.debugDescription)"
      )
    }
    XCTAssertFalse(
      app.buttons["Image 4 of 4"].exists,
      "A four-image turn must not draw a fourth thumbnail on the narrow phone"
    )
    XCTAssertEqual(badge.value as? String, "+1 more", "The third thumbnail must carry +1")

    let badgeCapture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    badgeCapture.name = "image-turn-plus-one"
    badgeCapture.lifetime = .keepAlways
    add(badgeCapture)
  }

  /// The newest turn is never bounded, however long. An equally long earlier turn is bounded,
  /// and `Show all` appears because it measured as truncated.
  func testTheNewestTurnIsNeverCutAndAnEarlierOneOffersShowAll() {
    let app = connectedHost(boundedTranscript: true)

    tapPane(app, titled: "needs a decision")

    let chat = require(app, "pane.chat", "Expected the pane to open on its chat")

    // Scrolled to, not waited for. The chat opens at the end, and the bounded turn above the
    // thirty-line newest one is not built until it scrolls into view.
    let expandButtons = app.descendants(matching: .any)
      .matching(identifier: "pane.chat.turn.expand")
    for _ in 0..<16 where !expandButtons.firstMatch.exists {
      chat.swipeDown(velocity: .slow)
    }
    XCTAssertTrue(
      expandButtons.firstMatch.exists,
      "Expected Show All on the earlier long turn.\nTree was:\n\(app.debugDescription)"
    )
    // Both long turns must be built, so "exactly one" below is about the pair.
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "pane.chat.turn.assistant").count,
      2,
      "Expected both long turns to be laid out before counting Show All buttons.\n"
        + "Tree was:\n\(app.debugDescription)"
    )
    XCTAssertEqual(
      expandButtons.count,
      1,
      "Expected exactly one Show All button (the newest turn must never offer one).\n"
        + "Tree was:\n\(app.debugDescription)"
    )

    expandButtons.firstMatch.tap()
    let showLess = require(app, "pane.chat.turn.expand", "Expected Show Less after expanding")
    XCTAssertEqual(showLess.label, "Show Less")
  }

  /// A slash command the person typed renders as a human turn, not dropped.
  func testASlashCommandRendersAsAHumanCommandTurn() {
    let app = connectedHost(boundedTranscript: true)

    tapPane(app, titled: "needs a decision")
    let chat = require(app, "pane.chat", "Expected the pane to open on its chat")

    // The command turn is the oldest, behind two long turns, so it is not built until it
    // scrolls into view.
    let human = element(app, "pane.chat.turn.human")
    for _ in 0..<16 where !(human.exists && human.isHittable) {
      chat.swipeDown(velocity: .slow)
    }
    XCTAssertTrue(
      human.exists && human.isHittable,
      "Never scrolled back to the command turn.\nTree was:\n\(app.debugDescription)"
    )
    XCTAssertEqual(human.label, "/run-tests")
  }

  /// An unanswered tool call names itself, so the reader need not open Terminal.
  func testAPendingToolCallNamesItself() {
    let app = connectedHost(pendingTranscript: true)

    tapPane(app, titled: "needs a decision")

    let pending = require(app, "pane.chat.turn.pending", "Expected the pending-call row")
    XCTAssertEqual(pending.label, "Waiting for permission · Bash cargo test")
  }

  /// An inter-agent event is a compact muted line, not a human turn, and tapping it opens
  /// the body. What the line says is `TranscriptAgentEventTests`.
  func testAnAgentEventIsAMutedLineThatExpands() {
    let app = connectedHost(agentEventTranscript: true, slowTranscript: true)

    tapPane(app, titled: "needs a decision")
    require(app, "pane.chat", "Expected the pane to open on its chat")

    let lines = app.descendants(matching: .any).matching(identifier: "pane.chat.turn.agentEvent")
    let newest = lines.element(
      matching: NSPredicate(format: "label CONTAINS %@", "tester's report")
    )
    XCTAssertTrue(
      newest.waitForExistence(timeout: 20),
      "Expected the newest agent-event line.\nTree was:\n\(app.debugDescription)"
    )
    // The newest record has two blocks, so two lines. Named rather than counted, because
    // whether the older lines above the fold are built depends on scrolling.
    let sibling = lines.element(
      matching: NSPredicate(format: "label CONTAINS %@", "machinery")
    )
    XCTAssertTrue(
      sibling.waitForExistence(timeout: 10),
      "The two blocks of the newest relayed record must be two lines.\n"
        + "Tree was:\n\(app.debugDescription)"
    )
    // The recipient prefix stays, because it says who was addressed.
    XCTAssertEqual(newest.label, "qa-6: [to main] tester's report is in")
    let humanTurns = app.descendants(matching: .any).matching(identifier: "pane.chat.turn.human")
      .allElementsBoundByIndex.map(\.label)
    XCTAssertFalse(
      humanTurns.contains { $0.contains("tester's report") },
      "An agent event must not be drawn as a human turn. Human turns were: \(humanTurns)"
    )

    // Adjacent event lines sit one 44 pt tap frame apart. With the stack's 18 pt spacing they
    // read looser than the turns around them.
    let pitch = newest.frame.minY - sibling.frame.minY
    print("agent-event pitch: \(pitch) pt")
    XCTAssertEqual(
      pitch, 44, accuracy: 1,
      "Two adjacent event lines must sit one 44 pt tap target apart, not 44 + the stack's 18."
    )

    requireGone(
      app, "pane.chat.turn.agentEvent.body", "Nothing should be open before the line is tapped")
    newest.tap()
    let body = require(
      app, "pane.chat.turn.agentEvent.body", "Expected the body after tapping the line")
    XCTAssertTrue(
      body.label.contains("Approved with no changes"),
      "Expected the relayed body, got: '\(body.label)'"
    )
    // This is the record's last block, and the fixture puts a sentence after its closing tag.
    // A parse that read past the tag would show that sentence here.
    XCTAssertFalse(
      body.label.contains("relay-footer-sentinel"),
      "Text after the record's last closing tag must not reach the screen: '\(body.label)'"
    )
    // The body is quoted, so another agent's words do not read as this pane's agent. Only the
    // direction of the inset is asserted: a combined accessibility element reports a frame
    // offset from the laid-out text, so the 28 pt is checked on the screenshot.
    let offset = body.frame.minX - newest.frame.minX
    print("agent-event body offset (accessibility frame): \(offset) pt")
    XCTAssertGreaterThan(
      offset, 0,
      "The quoted body must be inset from the line, so another agent's words cannot read as "
        + "this one's."
    )

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "agent-event-expanded"
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// This session's own spawns, stops and outgoing messages draw as muted agent-event lines,
  /// not as entries in a tool run's tally. Their wording is `TranscriptAgentTrafficTests`.
  func testASessionsOwnSpawnsStopsAndMessagesAreMutedLines() {
    let app = connectedHost(orchestratorTranscript: true, slowTranscript: true)

    tapPane(app, titled: "needs a decision")
    require(app, "pane.chat", "Expected the pane to open on its chat")

    let lines = app.descendants(matching: .any).matching(identifier: "pane.chat.turn.agentEvent")
    // Named rather than counted, as in `testAnAgentEventIsAMutedLineThatExpands`.
    func line(containing text: String) -> XCUIElement {
      lines.element(matching: NSPredicate(format: "label CONTAINS %@", text))
    }

    let stopped = line(containing: "Stopped analyst-1")
    XCTAssertTrue(
      stopped.waitForExistence(timeout: 20),
      "Expected the stop to be a line of its own.\nTree was:\n\(app.debugDescription)"
    )
    // The stopped task's title is resolved through this page's own `Agent` call.
    XCTAssertEqual(stopped.label, "Stopped analyst-1 · Plan the async pool migration")
    // This one's spawn is before the page's window, so it has no title.
    XCTAssertEqual(line(containing: "verifier-3").label, "Stopped verifier-3")
    XCTAssertEqual(
      line(containing: "To engineer-2").label,
      "To engineer-2 · Hold the build until the pool migration lands"
    )

    // The two spawns are older, so scroll back to build them.
    let chat = require(app, "pane.chat", "Expected the chat while finding the earlier spawns")
    let analyst = line(containing: "Started analyst-1")
    for _ in 0..<16 where !(analyst.exists && analyst.isHittable) {
      chat.swipeDown(velocity: .slow)
    }
    XCTAssertEqual(analyst.label, "Started analyst-1 · Plan the async pool migration")
    XCTAssertEqual(
      line(containing: "Started engineer-2").label,
      "Started engineer-2 · Implement the session timeout"
    )

    // No run counts an `Agent`, a `TaskStop` or a `SendMessage`, and no human turn carries
    // one.
    let runs = app.descendants(matching: .any).matching(identifier: "pane.chat.turn.tools")
      .allElementsBoundByIndex.map(\.label)
    XCTAssertFalse(
      runs.contains {
        $0.contains("Agent") || $0.contains("TaskStop")
          || $0.contains("SendMessage")
      },
      "Agent traffic must leave the run entirely. Runs were: \(runs)"
    )
    let humanTurns = app.descendants(matching: .any).matching(identifier: "pane.chat.turn.human")
      .allElementsBoundByIndex.map(\.label)
    XCTAssertFalse(
      humanTurns.contains { $0.contains("analyst-1") },
      "A spawn must not be drawn as a human turn. Human turns were: \(humanTurns)"
    )

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "own-agent-traffic-spawns"
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// A spawn line opens that sub-agent's conversation in the same chat. Nothing is pushed: a
  /// back bar replaces the provenance row, the composer goes, and the opening prompt is
  /// labelled as the parent's. Back restores the pane's chat and the composer.
  ///
  /// The claim is wiring from a tap in the collection view to the pane's model and back to
  /// `TerminalScreen`. The slow transcript makes the sub-agent's page arrive after its chat
  /// is up, as on a phone.
  func testASpawnLineOpensItsSubagentAndTheBackBarReturns() {
    let app = connectedHost(slowTranscript: true, subagents: true)

    tapPane(app, titled: "needs a decision")
    require(app, "pane.chat", "Expected the pane to open on its chat")
    require(app, "composer.text", "Expected the composer under the pane's chat")
    require(app, "pane.chat.header", "Expected the provenance row over the pane's chat")

    let lines = app.descendants(matching: .any).matching(identifier: "pane.chat.turn.agentEvent")
    let verifier = lines.element(
      matching: NSPredicate(format: "label CONTAINS %@", "Started verifier-7"))
    XCTAssertTrue(
      verifier.waitForExistence(timeout: 20),
      "Expected the teammate's spawn line.\nTree was:\n\(app.debugDescription)")
    XCTAssertTrue(verifier.isHittable, "The teammate's spawn line is not tappable")
    verifier.tap()

    let back = require(app, "pane.chat.subagent.back", "Expected the back bar over the sub-agent")
    XCTAssertEqual(
      require(app, "pane.chat.subagent.title", "Expected the sub-agent's name").label,
      "verifier-7")
    let parent = app.staticTexts["Prompt from the parent agent"]
    XCTAssertTrue(
      parent.waitForExistence(timeout: 20),
      "Expected the teammate's opening prompt, labelled as the parent's.\nTree was:\n"
        + app.debugDescription)
    let prompt = app.descendants(matching: .any).matching(identifier: "pane.chat.turn.human")
      .element(matching: NSPredicate(format: "label CONTAINS %@", "Review the config loader"))
    XCTAssertTrue(prompt.exists, "Expected the teammate's own prompt, not the pane's turns")
    requireGone(app, "composer.text", "The composer must go while a sub-agent is shown")
    requireGone(app, "pane.chat.header", "The back bar takes the provenance row's place")
    let opened = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    opened.name = "subagent-opened"
    opened.lifetime = .keepAlways
    add(opened)

    back.tap()
    requireGone(app, "pane.chat.subagent.back", "Back must return to the pane's chat")
    require(app, "composer.text", "The composer must come back with the pane's chat")
    require(app, "pane.chat.header", "The provenance row must come back with the pane's chat")
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "pane.chat.turn.assistant")
        .element(matching: NSPredicate(format: "label CONTAINS %@", "The analyst is done"))
        .waitForExistence(timeout: 10),
      "Closing must return to the pane's newest turn")
    let closed = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    closed.name = "subagent-closed"
    closed.lifetime = .keepAlways
    add(closed)
  }

  /// The list under the provenance row names every sub-agent the session's meta files hold,
  /// including one whose spawn line is not on the page, and a row opens that sub-agent.
  ///
  /// The claim is wiring: the list command through the model to the bar, and a row's tap to
  /// `openSubagent`. The mapping and the state merge are kit tests (`SubagentListTests`,
  /// `SubagentListReaderTests`). The slow transcript makes the page, and so the list, arrive
  /// after the chat is up, as on a phone.
  func testTheSubagentListNamesEverySubagentAndARowOpensOne() {
    let app = connectedHost(slowTranscript: true, subagents: true)

    tapPane(app, titled: "needs a decision")
    require(app, "pane.chat", "Expected the pane to open on its chat")
    let bar = require(
      app, "pane.chat.subagents", "Expected the sub-agent list under the provenance row",
      timeout: 20)
    XCTAssertEqual(bar.label, "3 sub-agents · 1 running")
    XCTAssertEqual(bar.value as? String, "Collapsed")
    bar.tap()

    let rows = app.descendants(matching: .any).matching(identifier: "pane.chat.subagents.row")
    // Spawned before the page's first turn, so only the meta files know it.
    let lookup = rows.element(
      matching: NSPredicate(format: "label CONTAINS %@", "Find the config loader's callers"))
    XCTAssertTrue(
      lookup.waitForExistence(timeout: 10),
      "Expected the off-page sub-agent's row.\nTree was:\n\(app.debugDescription)")
    XCTAssertEqual(rows.count, 3, "Expected one row per meta file")
    XCTAssertTrue(
      rows.element(matching: NSPredicate(format: "label CONTAINS %@", "verifier-7")).exists,
      "Expected the teammate's row")
    let expanded = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    expanded.name = "subagent-list-expanded"
    expanded.lifetime = .keepAlways
    add(expanded)
    lookup.tap()

    let back = require(app, "pane.chat.subagent.back", "Expected the back bar over the sub-agent")
    XCTAssertEqual(
      require(app, "pane.chat.subagent.title", "Expected the sub-agent's name").label, "Explore")
    let prompt = app.descendants(matching: .any).matching(identifier: "pane.chat.turn.human")
      .element(matching: NSPredicate(format: "label CONTAINS %@", "Find every caller of load_config"))
    XCTAssertTrue(
      prompt.waitForExistence(timeout: 20),
      "Expected the off-page sub-agent's own prompt.\nTree was:\n\(app.debugDescription)")
    requireGone(app, "pane.chat.subagents", "The list is not drawn over a sub-agent's chat")

    back.tap()
    requireGone(app, "pane.chat.subagent.back", "Back must return to the pane's chat")
    let returned = require(app, "pane.chat.subagents", "The list must come back with the pane's chat")
    XCTAssertEqual(returned.value as? String, "Collapsed", "Opening a row closes the list")
  }

  /// Leaving the pane scene closes a sub-agent opened in it, so coming back finds the pane's
  /// own chat and composer. The claim is about `TerminalScreen` going away, which no cheaper
  /// tier hosts.
  func testLeavingThePaneSceneClosesAnOpenSubagent() {
    let app = connectedHost(slowTranscript: true, subagents: true)

    tapPane(app, titled: "needs a decision")
    require(app, "pane.chat", "Expected the pane to open on its chat")
    let verifier = app.descendants(matching: .any)
      .matching(identifier: "pane.chat.turn.agentEvent")
      .element(matching: NSPredicate(format: "label CONTAINS %@", "Started verifier-7"))
    XCTAssertTrue(
      verifier.waitForExistence(timeout: 20),
      "Expected the teammate's spawn line.\nTree was:\n\(app.debugDescription)")
    verifier.tap()
    require(app, "pane.chat.subagent.back", "Expected the back bar over the sub-agent")
    requireGone(app, "composer.text", "The composer must go while a sub-agent is shown")

    leavePaneScene(app, "Expected a way out of the pane scene")
    requireGone(app, "pane.chat", "Expected to have left the pane scene")
    tapPane(app, titled: "needs a decision")
    require(app, "pane.chat", "Expected the pane to reopen on its chat")
    require(app, "composer.text", "Coming back must find the pane's own chat and its composer")
    requireGone(app, "pane.chat.subagent.back", "The sub-agent must close with the pane scene")
  }

  /// A raw prompt with no structured options gets an Approve/Deny pair under the turn, not a
  /// key grid in the composer, and a tap sends through the composer.
  func testPendingChipsRenderUnderTheTurnAndSend() {
    let app = connectedHost(pendingTranscript: true)

    tapPane(app, titled: "needs a decision")

    require(app, "pane.chat.turn.pending", "Expected the pending-call row")
    let approve = require(
      app, "pane.chat.turn.pending.chip.Approve", "Expected an Approve chip under the turn")
    require(app, "pane.chat.turn.pending.chip.Deny", "Expected a Deny chip under the turn")
    requireGone(app, "composer.key.enter", "No key grid belongs in the composer while pending")
    // A single-answer call sends on the tap, so a Send button would have nothing to do.
    requireGone(app, "pane.chat.turn.pending.send", "A single-answer call must draw no Send")

    approve.tap()

    let status = require(
      app, "pane.chat.activity", "Expected the send verdict at the foot of the conversation")
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline && !status.label.contains("Sent") {
      usleep(150_000)
    }
    XCTAssertTrue(
      status.label.contains("Sent"),
      "Expected tapping the chip to send through the composer, got '\(status.label)'.\n"
        + "Tree was:\n\(app.debugDescription)"
    )
  }

  /// An `AskUserQuestion` with two questions draws a labelled group of chips per question,
  /// and the reply goes on Send, not on the tap that completes the set.
  ///
  /// The second question is multi-select. Sending on the completing tap would let the reader
  /// name Ann or Bo but never both.
  ///
  /// The two questions' labels differ on purpose. A shared word would put two elements under
  /// one identifier.
  func testAMultiQuestionCallDrawsAGroupPerQuestionAndSendsOnSend() {
    let app = connectedHost(multiQuestionTranscript: true)

    tapPane(app, titled: "needs a decision")

    require(app, "pane.chat.turn.pending", "Expected the pending-call row")
    let first = require(
      app, "pane.chat.turn.pending.question.q0", "Expected the first question's heading")
    let second = require(
      app, "pane.chat.turn.pending.question.q1", "Expected the second question's heading")
    XCTAssertEqual(first.label, "Which branch?")
    XCTAssertEqual(second.label, "Who reviews it?")
    // Each question's header, and a description under an option.
    XCTAssertEqual(
      require(app, "pane.chat.turn.pending.header.q0", "Expected the first question's header")
        .label, "Branch")
    XCTAssertEqual(
      require(app, "pane.chat.turn.pending.detail.q1.Bo", "Expected Bo's description").label,
      "Owns the build.")

    let release = require(
      app, "pane.chat.turn.pending.chip.q0.release", "Expected the first question's chips")
    require(app, "pane.chat.turn.pending.chip.q0.main", "Expected the first question's chips")
    let ann = require(
      app, "pane.chat.turn.pending.chip.q1.Ann", "Expected the second question's chips")
    let bo = require(
      app, "pane.chat.turn.pending.chip.q1.Bo", "Expected the second question's chips")

    // Only the multi-select question says it takes more than one answer. Otherwise the two
    // look identical.
    let hint = require(
      app, "pane.chat.turn.pending.hint.q1",
      "Expected the multi-select question to say it takes more than one answer")
    XCTAssertEqual(hint.label, "Choose any")
    requireGone(
      app, "pane.chat.turn.pending.hint.q0",
      "A single-answer question must not promise a second answer")

    // Send is on screen from rest and disabled, so it does not appear under the finger that
    // completes the set.
    let send = require(
      app, "pane.chat.turn.pending.send", "Expected a Send button on a multi-select call")
    XCTAssertFalse(
      send.isEnabled, "Send must be disabled while the call is unanswered.\n"
        + "Tree was:\n\(app.debugDescription)")

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "multi-question-chips"
    shot.lifetime = .keepAlways
    add(shot)

    // The count is on screen from rest. Without it, one answered question looks the same as
    // none, and the send that does not happen reads as a broken chip.
    let status = require(
      app, "pane.chat.activity", "Expected the answered count under a two-question call")
    XCTAssertEqual(status.label, "0 of 2 answered")

    // Nothing may be sent while the other question is unanswered.
    release.tap()
    waitFor(status, toSay: "1 of 2 answered")
    XCTAssertFalse(
      send.isEnabled, "Send must stay disabled with one of two questions answered.\n"
        + "Tree was:\n\(app.debugDescription)")

    // The set is complete and nothing has been sent, so the second reviewer can still be
    // named.
    ann.tap()
    waitFor(status, toSay: "2 of 2 answered")
    XCTAssertFalse(
      status.label.contains("Sent"),
      "The tap that completed the set must send nothing — the multi-select answer is not "
        + "finished. Activity said '\(status.label)'.\nTree was:\n\(app.debugDescription)")
    XCTAssertTrue(
      send.isEnabled, "Send must be enabled once every question has an answer.\n"
        + "Tree was:\n\(app.debugDescription)")
    requireGone(
      app, "pane.chat.turn.pending.hint.q1",
      "The hint has done its job once that question has an answer")

    bo.tap()
    XCTAssertFalse(
      status.label.contains("Sent"),
      "A second multi-select answer must still send nothing. Activity said "
        + "'\(status.label)'.\nTree was:\n\(app.debugDescription)")

    let chosen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    chosen.name = "multi-question-complete-unsent"
    chosen.lifetime = .keepAlways
    add(chosen)

    send.tap()
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline && !status.label.contains("Sent") {
      usleep(150_000)
    }
    XCTAssertTrue(
      status.label.contains("Sent"),
      "Expected Send to send the reply, got '\(status.label)'.\n"
        + "Tree was:\n\(app.debugDescription)"
    )

    // Send leaves with the reply, because a disabled Send looks the same before and after.
    // The chips stay as the record of which answers went.
    requireGone(
      app, "pane.chat.turn.pending.send",
      "Send must leave once the reply has gone — a disabled Send is indistinguishable from "
        + "the unanswered state")
    require(
      app, "pane.chat.turn.pending.chip.q1.Bo",
      "The chosen chips stay under the sent reply — they are the record of it")

    let sent = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    sent.name = "multi-question-sent"
    sent.lifetime = .keepAlways
    add(sent)
  }

  /// Reply on a waiting question leaves the keyboard down, and the chat rests on the first
  /// question's header rather than on Send.
  ///
  /// With the keyboard up only the last option, Send and the count fit on screen. The rules
  /// are `ComposerFocusGate` and `ChatReplyAnchor` in `swift test`. The slow transcript
  /// matters, because the gate has to wait for the read.
  func testReplyOnAWaitingQuestionKeepsTheKeyboardDownAndShowsTheFirstHeader() {
    let app = connectedHost(multiQuestionTranscript: true, slowTranscript: true)

    let reply = app.descendants(matching: .any)
      .matching(identifier: "session.blockedPane")
      .matching(NSPredicate(format: "label CONTAINS %@", "needs a decision"))
      .firstMatch
    XCTAssertTrue(reply.waitForExistence(timeout: 10), "Expected the Needs-you row")
    reply.tap()

    // The header and the focus decision arrive on the same update.
    let header = require(
      app, "pane.chat.turn.pending.header.q0", "Expected the first question's header")
    let field = require(app, "composer.text", "Expected the composer field")
    // An inverted wait, because a broken gate focuses a frame after the header draws.
    // `hasKeyboardFocus`, because `app.keyboards.count` reads 1 with a hardware keyboard.
    let focused = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
    focused.isInverted = true
    XCTAssertEqual(
      XCTWaiter().wait(for: [focused], timeout: 3), .completed,
      "Reply on a waiting question must leave the keyboard down.\nTree was:\n\(app.debugDescription)"
    )
    let chat = app.descendants(matching: .any).matching(identifier: "pane.chat").firstMatch
    XCTAssertTrue(
      header.frame.minY >= chat.frame.minY && header.frame.maxY <= chat.frame.maxY,
      "The first header must be on screen at rest: header \(header.frame), chat \(chat.frame)")
  }

  /// A question that is only on the pane's screen reaches the chat, and a chip answers it.
  ///
  /// Claude Code writes a pending `AskUserQuestion` to the session file only once it is
  /// answered, so the chips come from the screen read. The slow transcript, because the chat's
  /// read and the screen's race on a phone.
  func testAQuestionOnlyOnTheScreenDrawsItsChipsAndSends() {
    let app = connectedHost(slowTranscript: true, screenQuestion: true)

    tapPane(app, titled: "needs a decision")

    // Drawn as the agent's turn, with the line the transcript's tool card would carry.
    XCTAssertEqual(
      require(app, "pane.chat.turn.pending", "Expected the waiting line over the chips").label,
      "Waiting for your answer · AskUserQuestion")
    XCTAssertEqual(
      require(app, "pane.chat.turn.pending.header.q0", "Expected the screen question's header")
        .label, "Fruit")
    XCTAssertEqual(
      require(app, "pane.chat.turn.pending.question.q0", "Expected the screen question's text")
        .label, "Pick a fruit")
    XCTAssertEqual(
      require(app, "pane.chat.turn.pending.detail.Banana", "Expected Banana's description")
        .label, "A soft, creamy yellow tropical fruit")

    require(app, "pane.chat.turn.pending.chip.Banana", "Expected a chip per option").tap()

    let status = require(
      app, "pane.chat.activity", "Expected the send verdict at the foot of the conversation")
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline && !status.label.contains("Sent") {
      usleep(150_000)
    }
    XCTAssertTrue(
      status.label.contains("Sent"),
      "Expected the chip to send through the composer, got '\(status.label)'.\n"
        + "Tree was:\n\(app.debugDescription)"
    )
  }

  /// When the transcript takes a question over from the screen, there is still one card and
  /// its chips do not move. Where the chat rests is `ChatReplyAnchor.headroom`.
  func testTheTranscriptTakesAScreenQuestionOverWithOneCardAndTheChipsInPlace() {
    let app = connectedHost(slowTranscript: true, screenQuestionHandover: true)

    tapPane(app, titled: "needs a decision")

    let chips = app.descendants(matching: .any).matching(
      identifier: "pane.chat.turn.pending.chip.Apple")
    let apple = require(app, "pane.chat.turn.pending.chip.Apple", "Expected the screen's chips")
    let run = app.descendants(matching: .any).matching(identifier: "pane.chat.turn.tools")
      .firstMatch
    XCTAssertFalse(run.exists, "The precondition: the session file has no call yet")
    XCTAssertEqual(chips.count, 1, "Expected one card from the screen")
    let before = apple.frame

    XCTAssertTrue(
      run.waitForExistence(timeout: 30),
      "Expected the transcript's tool card once the session file gained the call")
    // One layout pass for the rest to settle on the new item.
    usleep(1_000_000)
    XCTAssertEqual(chips.count, 1, "Expected one card after the handover")
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "pane.chat.turn.pending").count, 1,
      "Expected one waiting line, the tool card's")
    let after = app.descendants(matching: .any)
      .matching(identifier: "pane.chat.turn.pending.chip.Apple").firstMatch.frame
    XCTAssertEqual(
      after.minY, before.minY, accuracy: 2,
      "The chips must stay where the reader saw them: before \(before), after \(after)")
  }

  /// The answers are drawn under the run that asked, one element per question.
  func testAnAnsweredQuestionShowsItsAnswerUnderTheRun() {
    let app = connectedHost(answeredQuestionTranscript: true)

    tapPane(app, titled: "needs a decision")

    let answered = app.descendants(matching: .any).matching(identifier: "pane.chat.turn.answered")
    XCTAssertTrue(
      answered.firstMatch.waitForExistence(timeout: 10),
      "Expected the answered questions under the run.\nTree was:\n\(app.debugDescription)")
    XCTAssertEqual(
      answered.allElementsBoundByIndex.map(\.label),
      [
        "Branch. Which branch? Answered: release",
        "Review. Who reviews it? Answered: Ann, Bo",
      ])
    // An answered call is not waiting on anybody, so it offers nothing to tap.
    requireGone(app, "pane.chat.turn.pending", "An answered call must not read as waiting")
  }

  /// Polls until the activity row says what is expected, since a tap's effect reaches the
  /// tree a frame or two later.
  private func waitFor(
    _ status: XCUIElement,
    toSay expected: String,
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline && status.label != expected {
      usleep(150_000)
    }
    XCTAssertEqual(status.label, expected, file: file, line: line)
  }

  /// A question keeps its chips when herdr reports the asking pane as working, not blocked.
  ///
  /// Every other fixture reports the asking pane `blocked`, so the file and herdr's status
  /// agree. `-uiTestingAskingWhileWorking` makes them disagree, and without it this test
  /// passes trivially.
  ///
  /// The foot says `0 of 2 answered`, not that Claude is working: the count outranks the
  /// pane's status while a question is unanswered. `ChatActivity.foot` owns that order.
  func testAQuestionKeepsItsChipsOnAPaneHerdrCallsWorking() {
    let app = connectedHost(multiQuestionTranscript: true, askingWhileWorking: true)

    tapPane(app, titled: "needs a decision")

    // The precondition. `composer.stop` is drawn only while `PaneComposerHeader.isWorking`,
    // so it proves herdr reports this pane as working.
    require(
      app, "composer.stop",
      "Stop is drawn only for a working pane, so herdr is not reporting the disagreement "
        + "this test needs")

    require(app, "pane.chat.turn.pending", "Expected the pending-call row")
    require(
      app, "pane.chat.turn.pending.chip.q0.release",
      "Expected the first question's chips on a pane herdr calls working")
    require(
      app, "pane.chat.turn.pending.chip.q1.Ann",
      "Expected the second question's chips on a pane herdr calls working")

    let counted = require(
      app, "pane.chat.activity", "Expected the answered count under a two-question call")
    XCTAssertEqual(
      counted.label, "0 of 2 answered",
      """
      The count has to outrank what the pane is doing, or the row the chips need is hidden by
      the one saying the agent is busy.
      Tree was:
      \(app.debugDescription)
      """
    )

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "chips-while-working"
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// `w1:p2` is the one seeded pane with an `agent_session`, so the header says herdr
  /// reported it. Every other Claude pane in the fixture is "matched by directory".
  func testTheHeaderCreditsHerdrWhenHerdrReportedTheSession() {
    let app = connectedHost()

    tapPane(app, titled: "needs a decision")

    let header = require(app, "pane.chat.header", "Expected the provenance header")
    XCTAssertTrue(
      header.label.hasPrefix("Claude session · reported by herdr"),
      "Expected the exact variant, got '\(header.label)'"
    )
    // The context count is the header's value. `FakeTranscriptHost` writes usage on every
    // assistant record, so an empty value means the count is missing.
    let value = header.value as? String ?? ""
    XCTAssertTrue(
      value.hasSuffix(" tokens in context") && !value.hasPrefix("0 "),
      "Expected the header to speak the context count, got '\(value)'"
    )
  }

  /// A conversation that ends on a usage-limit record shows the stop notice, with the reset
  /// time in the phone's zone rather than the host's.
  ///
  /// The copy and the time zone are `AgentStopTests`. The slow transcript is on, because the
  /// notice arrives with the page.
  func testAUsageLimitedAgentShowsTheStopNotice() {
    let app = connectedHost(slowTranscript: true, usageLimited: true)

    tapPane(app, titled: "needs a decision")

    let notice = require(app, "pane.chat.agentStop", "Expected the stop notice")
    XCTAssertTrue(
      notice.label.hasPrefix("Agent stopped. Usage limit reached. Resets ")
        && !notice.label.contains("America/Chicago"),
      "Expected the reset time in the phone's zone, got '\(notice.label)'"
    )
    // The record's own turn, in the host's clock, is hidden while the notice stands. Read off
    // the chat's turns, because the host screen under the push can quote the agent too.
    require(app, "pane.chat.turn.assistant", "Expected the agent's turn before the stop")
    let turns = app.descendants(matching: .any).matching(identifier: "pane.chat.turn.assistant")
    let labels = (0..<turns.count).map { turns.element(boundBy: $0).label }
    XCTAssertFalse(
      labels.contains { $0.contains("session limit") },
      "The limit record's own turn must not draw beside the notice. Saw \(labels)."
    )
  }

  /// `w1:p1` has no reported session, so its file is matched by directory and the header
  /// says so.
  func testAPaneWithNoReportedSessionNamesItsEvidence() {
    let app = connectedHost()

    tapPane(app, titled: "terminal wiring")

    let header = require(app, "pane.chat.header", "Expected the provenance header")
    XCTAssertTrue(
      header.label.hasPrefix("Claude session · matched by directory"),
      "Expected the matched variant, got '\(header.label)'"
    )
    XCTAssertTrue(
      header.label.contains("written"),
      "The matched variant must state the file's age, not just claim a match. Got "
        + "'\(header.label)'"
    )
  }

  /// An agent pane whose transcript Driverr cannot read keeps the segment and opens straight
  /// onto its captured screen, with no notice. An agent with no reader is a normal state,
  /// not an error. The seed's `schema sync` pane is a Gemini agent.
  func testAnUnreadableAgentOpensStraightOntoItsScreen() {
    let app = connectedHost()

    tapPane(app, titled: "schema sync")

    require(app, "pane.surface.chat", "An agent pane keeps its segment even with no transcript")
    require(app, "pane.screen", "Expected the captured screen as the Chat side itself")
    let caption = require(app, "pane.screen.caption", "Expected the screen to be captioned")
    XCTAssertTrue(
      caption.label.contains("earlier output is not kept"),
      "The caption must say what is not kept, got '\(caption.label)'"
    )
    requireGone(app, "pane.chat.notice", "An unreadable agent kind must not be given a notice")
    requireGone(app, "pane.chat.showScreen", "There is no exit to take when this is the way in")
    requireGone(app, "pane.chat.progress", "Expected no spinner left over")
    requireGone(app, "terminal.view", "The screen renders under Chat, not on the Terminal side")
  }

  /// Terminal, Chat, Terminal, Chat on a pane whose Chat side is the captured screen leaves
  /// the app answering. This sequence soft-locked an iPad.
  ///
  /// The scene chain is `PaneSurfaceSwitchTests` in `DriverrTests`. What is left is a layout
  /// on `PaneScreenView` that never settles, which only shows as a running app failing to go
  /// idle.
  ///
  /// Terminals are never torn down by a switch, so each side is asserted through
  /// `pane.screen`, which is a plain `if` in `TerminalScreen.paneSurfaces` and does go.
  func testSwitchingSurfacesTwiceOnAnUnreadableAgentKeepsTheAppAnswering() {
    let app = connectedHost()

    tapPane(app, titled: "schema sync")
    require(app, "pane.screen", "Expected the captured screen as the Chat side itself")

    for round in 1...2 {
      require(app, "pane.surface.terminal", "Round \(round): expected the Terminal segment")
        .tap()
      require(app, "terminal.view", "Round \(round): expected the terminal after switching")
      requireGone(app, "pane.screen", "Round \(round): the screen must go with the chat")

      require(app, "pane.surface.chat", "Round \(round): expected the Chat segment").tap()
      require(app, "pane.screen", "Round \(round): expected the captured screen back")
      requireGone(app, "pane.chat.notice", "Round \(round): an unreadable kind gets no notice")
    }

    // The claim: the app still answers. A parked scene chain or a layout that never settles
    // shows here as an idle timeout or a menu that never opens. Pane actions queue on the
    // same chain as the switch.
    require(app, "pane.actions", "Expected the pane's own controls to still respond").tap()
    require(app, "pane.rename", "The pane menu must still open after four surface switches")
  }

  /// A notice pane survives Terminal to Chat with the keyboard up.
  ///
  /// Resigning first responder inside `updateUIView` laid the window out again, and a
  /// notice's `GeometryReader` rendered inside the running render, until the watchdog killed
  /// the app. A pane with turns does not take that path. Not a hosted test, because it needs
  /// the software keyboard's own dismissal.
  func testSwitchingBackToANoticeWithTheKeyboardUpKeepsTheAppAnswering() {
    XCUIDevice.shared.orientation = .portrait
    let app = connectedHostApp(["-uiTestingFirstMessage"])
    require(app, "session.workspace", "Expected the session tree")

    tapPane(app, titled: "needs a decision")
    require(app, "pane.chat.notice", "Expected the no-session-file notice")

    require(app, "pane.surface.terminal", "Expected the Terminal segment").tap()
    let terminal = require(app, "terminal.view", "Expected the terminal after switching")
    if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { terminal.tap() }
    XCTAssertTrue(
      app.keyboards.firstMatch.waitForExistence(timeout: 10),
      "The software keyboard must be up before the switch back, or this is not the case "
        + "that hung. A connected hardware keyboard hides it.\nTree was:\n\(app.debugDescription)"
    )

    require(app, "pane.surface.chat", "Expected the Chat segment").tap()
    require(app, "pane.chat.notice", "Expected the notice back after the switch")
    // The terminal gave the keyboard back, so the resign did happen, only later.
    let keyboardGone = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"),
      object: app.keyboards.firstMatch
    )
    XCTAssertEqual(
      XCTWaiter().wait(for: [keyboardGone], timeout: 10),
      .completed,
      "Expected the keyboard to go with the terminal"
    )
    require(app, "pane.actions", "Expected the pane's own controls to still respond").tap()
    require(app, "pane.rename", "The pane menu must still open after the switch back")
  }

  /// The only chat failure that renders under turns that did parse, so it needs its own
  /// launch. The other notices render through the centred path, with their copy asserted in
  /// `swift test`.
  func testAFileThatEndsMidRecordShowsWhatParsedAndNamesTheTail() {
    let app = connectedHost(truncatedTranscript: true)

    tapPane(app, titled: "needs a decision")

    require(app, "pane.chat.turn.assistant", "Expected the turns that did parse")
    let notice = require(app, "pane.chat.notice", "Expected the tail to be named")
    // A `.blocked` pane keeps the fault wording, with the size beside the turn count.
    XCTAssertTrue(
      notice.label.hasPrefix("The file ends mid-record. 2 turns ·"),
      "The notice must say how much of the file is being shown, got '\(notice.label)'"
    )
    XCTAssertTrue(
      notice.label.hasSuffix("parsed. Anything after that is unreadable."),
      "The notice must say how much of the file is being shown, got '\(notice.label)'"
    )
    require(app, "pane.chat.showScreen", "Every failure offers the screen as a way out")
  }

  // MARK: - The first message on a pane with no session file yet

  /// The no-session-file notice invites a send, and the send carries the chat to `.ready`.
  ///
  /// `-uiTestingFirstMessage` gives `w1:p2`'s Claude no `agent_session` and an empty project
  /// directory, so the pane resolves `.noSessionFiles` on arrival.
  func testSendingTheFirstMessageAnswersTheNoSessionFileNotice() {
    XCUIDevice.shared.orientation = .portrait
    let app = connectedHostApp(["-uiTestingFirstMessage"])
    require(app, "session.workspace", "Expected the session tree")

    tapPane(app, titled: "needs a decision")

    let notice = require(app, "pane.chat.notice", "Expected the no-session-file notice")
    XCTAssertTrue(
      notice.label.contains("Send a message below to start the conversation"),
      "The notice must say the composer below can start the conversation, got '\(notice.label)'"
    )
    require(app, "composer.text", "Expected the composer under the notice").tap()
    app.typeText("get started")
    require(app, "composer.send", "Expected a send button under the notice").tap()

    require(
      app, "pane.chat.turn.assistant", "Expected the chat to reach .ready once the agent wrote",
      timeout: 15
    )
    requireGone(app, "pane.chat.notice", "The notice must not survive the first reply")
  }

  // MARK: - The chat keeps looking

  /// A turn the agent writes while the chat is open arrives with no tap. An agent that keeps
  /// writing while it stays `working` changes no herdr status, so the status path cannot
  /// carry it.
  ///
  /// `-uiTestingGrowingTranscript` holds the herdr tree still while the file grows. The
  /// absence check at the open stops a fixture that served the grown file from the start
  /// passing.
  func testATurnWrittenWhileTheChatIsOpenArrivesWithNoTap() {
    let app = connectedHost(growingTranscript: true, slowTranscript: true)

    tapPane(app, titled: "needs a decision")
    require(app, "pane.chat", "Expected the conversation")

    let turns = app.descendants(matching: .any).matching(identifier: "pane.chat.turn.assistant")
    let newTurn = turns.element(
      matching: NSPredicate(format: "label CONTAINS %@", "Both call sites now await the pool")
    )
    // The precondition: the new turn is not in the file when the chat opens. Read once,
    // because `AppEnvironment.armTheGrowth` waits for this pane's stream and then eight
    // seconds, so the turn cannot be here yet.
    XCTAssertFalse(
      newTurn.exists,
      """
      The grown conversation was already on screen when the chat opened, so nothing below \
      is about the chat noticing anything. Tree was:
      \(app.debugDescription)
      """)
    // The seeded conversation is checked first, so a failure below means "never updated",
    // not "never loaded".
    let seeded = turns.element(
      matching: NSPredicate(format: "label CONTAINS %@", "Proceed with the migration?")
    )
    XCTAssertTrue(
      seeded.waitForExistence(timeout: 10),
      "Expected the seeded conversation before the agent writes again.\nTree was:\n"
        + app.debugDescription)

    // The turn lands fifteen seconds after the first transcript command, plus the watcher's
    // three-second cadence.
    XCTAssertTrue(
      newTurn.waitForExistence(timeout: 30),
      """
      The agent wrote a turn while the chat was open and it never arrived. Nothing \
      was tapped, which is the point: the chat has to keep looking. Tree was:
      \(app.debugDescription)
      """)

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "chat-after-growth"
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// A turn that arrives while the reader rests at the end scrolls into view, rather than
  /// landing half behind the composer under the jump-to-latest arrow.
  ///
  /// The arrow's absence is the strong assertion. An element's frame is its label's and
  /// under-reports the row, so a frame check alone can pass on a row cut in half.
  func testATurnArrivingWhileYouRestAtTheEndReachesYou() {
    let app = connectedHost(growingTranscript: true, slowTranscript: true)

    tapPane(app, titled: "needs a decision")
    let chat = require(app, "pane.chat", "Expected the conversation")
    require(app, "pane.chat.turn.assistant", "Expected the seeded conversation")

    // The open's scroll corrections run after the transcript lands, so let the layout settle.
    // The growth is armed eight seconds after the stream opened, well after this.
    usleep(2_500_000)

    let turns = app.descendants(matching: .any).matching(identifier: "pane.chat.turn.assistant")
    let newTurn = turns.element(
      matching: NSPredicate(format: "label CONTAINS %@", "Both call sites now await the pool")
    )
    XCTAssertFalse(
      newTurn.exists,
      "The turn was already there, so nothing below is about it arriving.\nTree was:\n"
        + app.debugDescription)

    // The precondition: the reader is within the jump tolerance of the end.
    let readableAtOpen = min(chat.frame.maxY, composerTop(in: app) ?? chat.frame.maxY)
    let newestAtOpen = turns.element(boundBy: turns.count - 1)
    print(
      "[arrival] at open: newest \(newestAtOpen.frame) readableBottom \(readableAtOpen) "
        + "jump \(element(app, "pane.chat.jumpToLatest").exists)")
    XCTAssertLessThanOrEqual(
      newestAtOpen.frame.maxY - readableAtOpen,
      64,  // `ChatEndProximity.jumpTolerance`, which the UI target cannot import.
      """
      The chat opened with the reader more than the jump tolerance above the end, so this \
      run is not about a reader resting at the end. Newest turn \(newestAtOpen.frame), \
      readable to \(readableAtOpen).
      """)

    XCTAssertTrue(
      newTurn.waitForExistence(timeout: 30),
      "The turn never arrived at all.\nTree was:\n"
        + app.debugDescription)
    // The correction is animated and budgeted, so the row has to be read where it settles.
    usleep(2_000_000)

    let frame = newTurn.frame
    let readableBottom = min(chat.frame.maxY, composerTop(in: app) ?? chat.frame.maxY)
    print(
      "[arrival] after growth: turn \(frame) readableBottom \(readableBottom) "
        + "jump \(element(app, "pane.chat.jumpToLatest").exists)")

    requireGone(
      app, "pane.chat.jumpToLatest",
      """
      A turn arrived while the reader rested at the end and they were left short of it, with \
      the jump-to-latest arrow over the conversation. Turn \(frame), conversation \
      readable to \(readableBottom)
      """,
      timeout: 8)
    XCTAssertLessThanOrEqual(
      frame.maxY,
      readableBottom,
      """
      The turn that arrived landed below the readable region, where a reader resting at the \
      end never sees it. Turn \(frame) against a conversation readable to \
      \(readableBottom).
      Tree was:
      \(app.debugDescription)
      """)

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "turn-arrival-followed"
    shot.lifetime = .keepAlways
    add(shot)
  }

  // MARK: - Switching

  /// An `if` in place of the `opacity` would rebuild both surfaces and SwiftTerm's emulators
  /// with them, and would look identical in a screenshot.
  func testSwitchingToTheTerminalAndBackKeepsTheTranscript() {
    let app = connectedHost()

    tapPane(app, titled: "needs a decision")
    require(app, "pane.chat.turn.assistant", "Expected the agent's turn before switching")

    require(app, "pane.surface.terminal", "Expected the Terminal segment").tap()
    require(app, "terminal.view", "Expected the terminal after switching to it")

    require(app, "pane.surface.chat", "Expected the Chat segment").tap()
    // No spinner, because the transcript is cached on the connection.
    requireGone(app, "pane.chat.progress", "Expected no re-fetch on the way back to the chat")
    require(app, "pane.chat.turn.assistant", "Expected the same turns after switching back")
  }

  /// Leaving and reopening a pane lands on the surface it was left on.
  ///
  /// `PaneSurfaceMemoryTests` and `TerminalSceneModelTests` cover the values. This proves
  /// that a real leave and reopen are two scenes over one `ConnectionRegistry` connection;
  /// with a fresh `ConnectionModel` the unit tests still pass and the pane comes back on
  /// Chat. `pane.chat` gone is asserted too, because the chat draws over a laid-out terminal.
  func testAPaneReopensOnTheSurfaceItWasLeftOn() {
    let app = connectedHost()

    tapPane(app, titled: "needs a decision")
    require(app, "pane.chat", "Expected the pane to open on its chat the first time")
    require(app, "pane.surface.terminal", "Expected the Terminal segment").tap()
    require(app, "terminal.view", "Expected the terminal after switching to it")

    leavePaneScene(app, "Expected a way out of the pane screen")
    require(app, "session.workspace", "Expected the session tree back")

    tapPane(app, titled: "needs a decision")

    require(
      app,
      "terminal.view",
      "Reopening the pane did not land on the terminal it was left on"
    )
    requireGone(app, "pane.chat", "The reopened pane came back on its chat")
  }

  // MARK: - The captured screen

  /// `Show the screen` from a chat failure lands on the captured screen under the Chat side,
  /// not on the Terminal side.
  ///
  /// Driven from the truncated transcript, because that failure keeps its notice and so has
  /// an exit. The copy is `PaneScreenPresentationTests`; this is the routing.
  func testShowTheScreenFromAChatFailureDrawsTheCapturedScreen() {
    let app = connectedHost(truncatedTranscript: true)

    tapPane(app, titled: "needs a decision")

    require(app, "pane.chat.showScreen", "Expected the way out of a chat failure").tap()

    require(app, "pane.screen", "Expected the pane's captured screen")
    requireGone(
      app,
      "terminal.view",
      "The captured screen renders under Chat, not by switching to the Terminal side"
    )

    let caption = require(app, "pane.screen.caption", "Expected the screen to be captioned")
    XCTAssertTrue(
      caption.label.contains("earlier output is not kept"),
      "The caption must say what is not kept, got '\(caption.label)'"
    )
    // Earlier output is not in the terminal either, so the caption must not send the reader
    // there.
    XCTAssertFalse(
      caption.label.lowercased().contains("terminal"),
      "The caption must offer no route to output that is not kept, got '\(caption.label)'"
    )
  }

  // MARK: - Refusing to guess, and the way out of it

  /// Nothing is drawn behind the refusal to pick between two live sessions. A guess behind a
  /// warning could be another agent's conversation, and somebody would read it.
  func testTwoLiveSessionsRefuseWithNothingDrawnBehindThem() {
    let app = connectedHost(ambiguousTranscript: true)

    // `w1:p1` has no reported session, and its directory holds two live files.
    tapPane(app, titled: "terminal wiring")

    let notice = require(app, "pane.chat.notice", "Expected the refusal")
    XCTAssertTrue(
      notice.label.contains("won't pick for you"),
      "The refusal must say Driverr will not choose, got '\(notice.label)'"
    )
    let candidates = require(app, "pane.chat.candidates", "Expected the candidate files listed")
    XCTAssertTrue(
      candidates.label.contains("0a1b2c3d") && candidates.label.contains("4e5f6a7b"),
      "Both candidate files must be listed, got '\(candidates.label)'"
    )

    requireGone(app, "pane.chat", "No transcript may be drawn behind the refusal")
    requireGone(app, "pane.chat.header", "No provenance header may claim a file behind the refusal")
    requireGone(app, "pane.chat.turn.assistant", "No turn may be drawn behind the refusal")

    // Both ways out. The screen exit is tapped, because an exit that does nothing still
    // exists.
    require(app, "pane.chat.chooseFile", "Expected the picker to be offered")
    require(app, "pane.chat.showScreen", "Expected the screen to stay a first-class exit").tap()
    require(app, "pane.screen", "The screen must be reachable from the refusal, not just offered")
  }

  /// The picker's rows lead with what somebody typed, because uuids and close mtimes do not
  /// tell two sessions apart.
  ///
  /// The pick is the only route to a `chosenByHand` provenance. The conversation is asserted
  /// as well as the header, because a pick could credit one file and draw the other.
  func testChoosingAFileByItsOpeningLineCreditsThePick() {
    let app = connectedHost(ambiguousTranscript: true)

    tapPane(app, titled: "terminal wiring")
    require(app, "pane.chat.chooseFile", "Expected the picker to be offered").tap()
    require(app, "pane.chat.picker", "Expected the picker")

    // The order is `TranscriptFile.newestFirst`.
    let newest = require(app, "pane.chat.picker.candidate.0", "Expected the newest candidate")
    XCTAssertTrue(
      newest.label.hasPrefix("review the diff on the focus branch"),
      "A row must lead with what somebody typed, got '\(newest.label)'"
    )
    let older = require(app, "pane.chat.picker.candidate.1", "Expected the second candidate")
    XCTAssertTrue(
      older.label.hasPrefix("start on the pane-focus bug"),
      "A row must lead with what somebody typed, got '\(older.label)'"
    )

    older.tap()

    let header = require(app, "pane.chat.header", "Expected the picked file's header")
    XCTAssertTrue(
      header.label.hasPrefix("Claude session · you picked this file"),
      "A pick is credited, never laundered into a match, got '\(header.label)'"
    )
    XCTAssertTrue(
      header.label.contains("4e5f6a7b"),
      "The header must name the file that was picked, got '\(header.label)'"
    )
    let said = require(app, "pane.chat.turn.assistant", "Expected the picked file's turns")
    XCTAssertTrue(
      said.label.contains("focus retry policy"),
      "The picked file's conversation must be the one drawn, got '\(said.label)'"
    )
    requireGone(app, "pane.chat.notice", "The refusal is answered, so it must be gone")
  }

  /// The marker on the captured screen names the pane's own agent. `schema sync` runs
  /// Gemini, so a hard-coded "Claude" fails here.
  func testAMarkedScreenNamesThePanesOwnAgent() {
    let app = connectedHost()

    // This agent has no reader, so the pane opens on its screen.
    tapPane(app, titled: "schema sync")

    let marker = require(app, "pane.screen.marker", "Expected the marked message to be labelled")
    XCTAssertEqual(
      marker.label,
      "Gemini's latest message",
      "The label must name this pane's agent.\nTree was:\n\(app.debugDescription)"
    )
  }

  /// A Codex pane's Chat surface is its conversation, not the captured screen.
  ///
  /// The routing is `CodexResolverTests` and the model is `PaneCodexTranscriptTests`. This is
  /// the wiring from `PaneChatView`'s branch to the conversation. It reads a line of the
  /// rollout back, because a Codex pane resolved against Claude's file would draw a good chat
  /// of the wrong conversation.
  func testACodexPaneOpensOnItsOwnConversation() {
    let app = connectedHost()

    // `index rebuild` is in `wiki`, which is not focused and so starts collapsed, below the
    // fold. Wait before swiping, as in `treePaneRow`.
    let wiki = app.descendants(matching: .any)
      .matching(identifier: "session.workspace")
      .matching(NSPredicate(format: "label CONTAINS %@", "wiki"))
      .firstMatch
    _ = wiki.waitForExistence(timeout: 10)
    for _ in 0..<6 where !wiki.exists {
      app.swipeUp()
    }
    XCTAssertTrue(
      wiki.exists,
      "Expected the wiki workspace row.\nTree was:\n\(app.debugDescription)"
    )
    for _ in 0..<6 where !wiki.isHittable {
      app.swipeUp()
    }
    wiki.tap()

    tapPane(app, titled: "index rebuild")

    require(app, "pane.chat", "A Codex pane must open on its conversation, not its screen")
    // `pane.chat` existing does not prove the fallback is gone.
    requireGone(app, "pane.screen", "A Codex pane with a rollout must not fall to the screen")
    requireGone(app, "pane.chat.notice", "A readable Codex pane has nothing to apologise for")

    // Only `AppEnvironment.seededCodexRollout` says this; the Claude fixture does not.
    let said = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "rebuild the search index"))
      .firstMatch
    XCTAssertTrue(
      said.waitForExistence(timeout: 10),
      "Expected the Codex rollout's own turn on screen. A Claude session file would render "
        + "just as well and say something else entirely.\nTree was:\n\(app.debugDescription)"
    )

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "codex-pane-chat"
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// Wrapping is a global setting, so the captured screen carries no wrap control.
  func testTheScreenCarriesNoWrapControl() {
    let app = connectedHost()

    tapPane(app, titled: "schema sync")

    require(app, "pane.screen.caption", "Expected the screen to still be captioned")
    requireGone(
      app,
      "pane.screen.layout",
      "Wrapping is a Settings toggle; the pane screen must carry no control for it"
    )
  }

  // MARK: - Paging back through the file

  /// Coming back from the Terminal side lands on the newest turn.
  ///
  /// The switch rebuilds `PaneChatView`, so the open runs again before the rows are measured.
  /// The jump control's absence is an independent check that the chat came back to the end.
  @MainActor
  func testComingBackFromTheTerminalLandsOnTheNewestTurn() {
    let app = connectedHost(pagedTranscript: true)
    tapPane(app, titled: "needs a decision")
    require(app, "pane.chat", "Expected the pane to open on its chat")

    let newest = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "Step 45:")).firstMatch
    XCTAssertTrue(newest.waitForExistence(timeout: 10), "The newest turn was never built")
    XCTAssertTrue(newest.isHittable, "The chat did not open on the newest turn")

    require(app, "pane.surface.terminal", "Expected the Terminal side of the segment").tap()
    require(app, "terminal.view", "Expected the terminal to come up", timeout: 20)

    require(app, "pane.surface.chat", "Expected the Chat side of the segment").tap()
    require(app, "pane.chat", "Expected the conversation back")

    // Check existence before hittability. The conversation is a `UICollectionView`, so a cell
    // is briefly absent while it rebuilds, and `isHittable` on an absent element raises
    // instead of returning false.
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline && !(newest.exists && newest.isHittable) {
      usleep(200_000)
    }
    XCTAssertTrue(
      newest.exists && newest.isHittable,
      """
      Coming back from the terminal left the reader up in the history.
      newest exists: \(newest.exists)
      Tree was:
      \(app.debugDescription)
      """
    )
    requireGone(
      app,
      "pane.chat.jumpToLatest",
      "The chat came back short of the newest turn — the jump control says so"
    )
  }

  /// The jump-to-latest control is absent at the newest turn, present once the reader
  /// scrolls away, and gone again after it is used.
  ///
  /// Asserting that it goes away catches a jump that scrolls nowhere, such as a scroll API
  /// given an `Optional` id.
  @MainActor
  func testTheJumpToLatestControlAppearsOnlyWhenThereIsSomewhereToGo() {
    let app = connectedHost(pagedTranscript: true)
    tapPane(app, titled: "needs a decision")
    let chat = require(app, "pane.chat", "Expected the conversation's scroll view")

    requireGone(
      app, "pane.chat.jumpToLatest", "The chat opens at the newest turn, so there is no jump")

    let jump = element(app, "pane.chat.jumpToLatest")
    for _ in 0..<6 where !jump.exists {
      chat.swipeDown(velocity: .slow)
    }
    XCTAssertTrue(
      jump.exists,
      "Scrolling back through the conversation offered no way to return.\nTree was:\n\(app.debugDescription)"
    )

    jump.tap()
    requireGone(
      app,
      "pane.chat.jumpToLatest",
      "The jump left the reader short of the newest turn — see the Optional-id note above",
      timeout: 8
    )
  }

  /// Opening the keyboard keeps the newest turn on screen.
  ///
  /// The keyboard takes about 40% of the viewport, and holding a turn at the top of what is
  /// left pushes the newest turn off the bottom.
  @MainActor
  func testTheKeyboardOpeningKeepsTheNewestTurnOnScreen() {
    let app = connectedHost(pagedTranscript: true)
    tapPane(app, titled: "needs a decision")
    require(app, "pane.chat", "Expected the conversation's scroll view")

    let newest = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "Step 45:")).firstMatch
    XCTAssertTrue(newest.waitForExistence(timeout: 10), "The newest turn was never built")
    XCTAssertTrue(newest.isHittable, "The chat did not open on the newest turn")

    require(app, "composer.text", "Expected the composer field").tap()
    XCTAssertTrue(
      app.keyboards.firstMatch.waitForExistence(timeout: 10),
      "The keyboard never came up"
    )

    // Hittable, because a row below the shrunken viewport is still in the tree.
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline && !newest.isHittable {
      usleep(200_000)
    }
    XCTAssertTrue(
      newest.isHittable,
      """
      Opening the keyboard pushed the newest turn off screen — the reader is looking at \
      history with the question they came to answer scrolled away.
      newest:   \(newest.frame)
      keyboard: \(app.keyboards.firstMatch.frame)
      """
    )
  }

  /// A sixty-turn page opens with the newest turn visible and resting at the end. The
  /// seven-turn fixture fits on one screen and cannot show this.
  ///
  /// Hittable, not present, because a row past the viewport is still in the tree. The turn
  /// is named by its text because it is the tail of the file and so on every page.
  @MainActor
  func testALongPageOpensOnTheNewestTurn() {
    let app = connectedHost(pagedTranscript: true)
    tapPane(app, titled: "needs a decision")

    let chat = require(app, "pane.chat", "Expected the conversation's scroll view")

    let newest = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "Step 45:")).firstMatch
    XCTAssertTrue(
      newest.waitForExistence(timeout: 10),
      "The newest turn was never built.\nTree was:\n\(app.debugDescription)")
    XCTAssertTrue(
      newest.isHittable,
      """
      A 60-turn page opened without the newest turn on screen.
      Newest turn frame \(newest.frame) against a chat of \(chat.frame).
      Tree was:
      \(app.debugDescription)
      """)

    // The newest turn rests against the end of the readable region, not above empty space.
    // The tolerance is the stack's bottom padding plus a point.
    //
    // Measured against the composer's top, because the scroll view extends under the
    // composer and `chat.frame.maxY` is the bottom of the window.
    let readableBottom = min(chat.frame.maxY, composerTop(in: app) ?? chat.frame.maxY)
    let below = readableBottom - newest.frame.maxY
    XCTAssertLessThan(
      below,
      80,
      """
      The newest turn opened \(below) points above the end of the page — a reader arriving \
      on a blocked pane is looking at empty space rather than at the last thing the agent \
      said. Newest turn \(newest.frame) in a chat of \(chat.frame), readable to \
      \(readableBottom).
      """)

    // The bill sits above the oldest turn, so it is reached by scrolling, last.
    let held = app.descendants(matching: .any).matching(identifier: "pane.chat.paging.held")
      .firstMatch
    for _ in 0..<12 where !held.exists {
      app.swipeDown()
    }
    XCTAssertTrue(held.exists, "Expected the pager to say what it holds, above the oldest turn")
  }

  /// The priced control is on screen, and a tap reaches `PaneTranscriptModel.loadMore`.
  ///
  /// What the pager says is `TranscriptPagingTests`. Reaching the pager already fetches the
  /// whole file, so a tap cannot widen the page; the prepend is measured by
  /// `testScrollingBackFetchesTheEarlierTurnsWithNoTap`. The slow transcript keeps the
  /// in-flight state on screen for 900 ms.
  @MainActor
  func testPagingPricesTheNextPageAndSpendsItOnATap() {
    let app = connectedHost(pagedTranscript: true, slowTranscript: true)
    tapPane(app, titled: "needs a decision")

    // Scroll until the control is hittable and enabled, not until first seen. Scrolling back
    // fetches on its own, so a page can land mid-loop and carry the control out of the tree;
    // on `Driverr iPad` the first sighting was always stale. Swiping down always ends at the
    // front of the file, where the control is.
    let held = app.descendants(matching: .any).matching(identifier: "pane.chat.paging.held")
      .firstMatch
    let more = app.descendants(matching: .any)
      .matching(identifier: "pane.chat.paging.more").firstMatch
    var ready = false
    let reachable = Date().addingTimeInterval(60)
    while Date() < reachable && !ready {
      ready = more.exists && more.isHittable && more.isEnabled && held.exists
      if !ready { app.swipeDown() }
    }
    XCTAssertTrue(
      ready,
      "Expected a priced Load more control that could be tapped.\n"
        + "Tree was:\n\(app.debugDescription)")
    XCTAssertTrue(
      held.label.contains("fetched"),
      "Expected a measured figure, got '\(held.label)'")
    XCTAssertFalse(
      held.label.contains("~"),
      "The fetched figure is measured — a tilde there would claim it is a guess")
    // The control's accessibility label is `spokenLoadMore`, which spells the figure out
    // instead of reading a tilde and "KB".
    XCTAssertTrue(
      more.label.contains("more turns") && more.label.contains("about"),
      "Expected the wired control to speak the load-more figure in words, got '\(more.label)'")
    XCTAssertFalse(
      more.label.contains("~"),
      "The spoken label should spell out the figure rather than read a tilde, got '\(more.label)'")

    more.tap()

    // While `PaneTranscriptModel.isPagingBack` holds, the control reads `Reading earlier
    // turns…` and is disabled. Polled every 50 ms, because an `XCTNSPredicateExpectation`
    // re-evaluates about once a second and the window is 900 ms.
    var spent = false
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline && !spent {
      spent = more.label == "Reading earlier turns…" || !more.isEnabled
      if !spent { usleep(50_000) }
    }
    XCTAssertTrue(
      spent,
      "The tap never reached the model: the control stayed at '\(more.label)'.\n"
        + "Tree was:\n\(app.debugDescription)")
  }

  /// Scrolling back fetches the page behind the conversation with no tap, and the arriving
  /// page does not move the reader.
  ///
  /// The rule is `ChatBackfill` in `swift test`. This checks it is wired to the scroll.
  /// `AppEnvironment.pagedTranscript` is ninety turns whose first page starts at `step 16`,
  /// so any turn under sixteen is the fetch.
  ///
  /// The prepend adds about 1,700 points above the reader, and the anchor puts them back as a
  /// correction over the next layout passes. So the check is that a first-page turn is on
  /// screen within two seconds, not that the reader never moved.
  ///
  /// Asserting the pager's bill instead is unstable, because hunting for the pager scrolls
  /// to the front of the file by itself.
  @MainActor
  func testScrollingBackFetchesTheEarlierTurnsWithNoTap() {
    let app = connectedHost(pagedTranscript: true, slowTranscript: true)
    tapPane(app, titled: "needs a decision")

    let screen = app.frame
    // Turns one to fifteen, from behind the first page. Existence, not visibility, because
    // they arrive above the reader.
    let earlier = app.staticTexts
      .matching(NSPredicate(format: "label MATCHES %@", "step ([1-9]|1[0-5]):.*"))
    // Turns sixteen and up, from the first page.
    let firstPage = app.staticTexts
      .matching(NSPredicate(format: "label MATCHES %@", "step (1[6-9]|[2-9][0-9]):.*"))

    var landed = false
    for _ in 0..<20 {
      if earlier.count > 0 {
        landed = true
        break
      }
      app.swipeDown()
    }
    XCTAssertTrue(
      landed,
      "Scrolling back should have fetched the turns behind the first page with no tap.\n"
        + "Tree was:\n\(app.debugDescription)")

    // Polled, because the reader is put back a layout pass or two after the prepend.
    var heldPlace = false
    let anchorDeadline = Date().addingTimeInterval(2)
    while Date() < anchorDeadline && !heldPlace {
      heldPlace = firstPage.allElementsBoundByIndex.contains { $0.frame.intersects(screen) }
      if !heldPlace { usleep(50_000) }
    }
    XCTAssertTrue(
      heldPlace,
      "The arriving page moved the reader off the turns they were reading.\n"
        + "Tree was:\n\(app.debugDescription)")
  }
  /// At the start of the file the load-more control is gone, not disabled, so it never
  /// offers a page that does not exist.
  @MainActor
  func testAWholeFileRemovesTheControlRatherThanDisablingIt() {
    let app = connectedHost()
    tapPane(app, titled: "needs a decision")

    let notice = app.descendants(matching: .any)
      .matching(identifier: "pane.chat.paging.startOfFile").firstMatch
    for _ in 0..<12 where !notice.exists {
      app.swipeDown()
    }
    XCTAssertTrue(notice.exists, "Expected the start-of-file notice above the oldest turn")
    XCTAssertFalse(
      app.descendants(matching: .any).matching(identifier: "pane.chat.paging.more").firstMatch
        .exists,
      "Nothing is behind this page, so the control must be absent rather than disabled")
    XCTAssertFalse(
      require(app, "pane.chat.paging.held", "Expected the pager to say what it holds")
        .label.contains("Last"),
      "A page that is the whole file says All, not Last")
  }

  /// A page the reader stopped growing before it held the turns it asked for says so. The
  /// sentence is `TranscriptPagingTests`; this checks it is on screen.
  @MainActor
  func testAPageTheReaderStoppedGrowingSaysSoRatherThanReadingAsTheWholeSession() {
    let app = connectedHost(stalledTranscript: true)
    tapPane(app, titled: "needs a decision")

    // The block sits above the oldest turn.
    let notice = app.descendants(matching: .any)
      .matching(identifier: "pane.chat.paging.stoppedShort").firstMatch
    for _ in 0..<12 where !notice.exists {
      app.swipeDown()
    }
    XCTAssertTrue(
      notice.exists,
      "Expected the pager to say the reader stopped short of the turns it asked for")
    // The bill still says `Last`, as a three-turn session's would, which is why the notice
    // is needed.
    let held = require(app, "pane.chat.paging.held", "Expected the pager to say what it holds")
    XCTAssertTrue(
      held.label.contains("Last"),
      "A page with file behind it says Last, got '\(held.label)'")
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "pane.chat.paging.more").firstMatch
        .exists,
      "A stalled page always has a way forward, so the control must be present")
  }

  /// The top of the composer card, which is the bottom of what a reader can see. The scroll
  /// view runs on underneath the card.
  ///
  /// Read from the card, via `PaneComposerBar.cardFrameProbe`, because the field starts 14 pt
  /// below the card's top. `nil` for a surface with no composer, such as the captured
  /// screen, and the caller falls back to the scroll view's frame.
  ///
  /// A missing probe on a screen with `composer.text` fails the test. The fallback is below
  /// the composer, so it would silently loosen every readable-region assertion here.
  private func composerTop(
    in app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> CGFloat? {
    let card = app.descendants(matching: .any).matching(identifier: "composer.card").firstMatch
    guard card.exists else {
      if element(app, "composer.text").exists {
        XCTFail(
          """
          'composer.card' is missing on a screen that has 'composer.text'. Every \
          readable-region assertion in this class would silently fall back to the scroll \
          view's own bottom, which is below the composer, and pass on a hidden row. \
          Check `PaneComposerBar.cardFrameProbe` and its -uiTesting gate.
          Tree was:
          \(app.debugDescription)
          """,
          file: file,
          line: line)
      }
      return nil
    }
    return card.frame.minY
  }

  // MARK: - Opening at the end when the newest turn is taller than the screen

  /// The chat opens at the end of the conversation, not at the top of its last turn.
  ///
  /// It needs both fixtures to fail. `-uiTestingBoundedTranscript` has a thirty-line newest
  /// turn, taller than the phone. `-uiTestingSlowTranscript` makes the transcript arrive
  /// after the chat is on screen, as over SSH; with an instant fixture the open resolves
  /// against content already measured.
  ///
  /// Geometry, not existence, because the turn is one accessibility element either way.
  func testTheChatOpensAtTheEndOfATallNewestTurn() {
    let app = connectedHost(boundedTranscript: true, slowTranscript: true)

    tapPane(app, titled: "needs a decision")
    require(app, "pane.chat", "Expected the conversation")
    require(app, "pane.chat.turn.assistant", "Expected the agent's turn")

    let turns = app.descendants(matching: .any)
      .matching(identifier: "pane.chat.turn.assistant")
    let newest = turns.element(boundBy: turns.count - 1)
    let window = app.windows.firstMatch.frame
    XCTAssertLessThanOrEqual(
      newest.frame.maxY, window.maxY,
      "The chat opened at the top of the newest turn rather than at the end of the "
        + "conversation: the turn ends at \(newest.frame.maxY), below a window ending at "
        + "\(window.maxY)")
    // No jump control at the end. This open has the least settled layout to decide on.
    requireGone(
      app, "pane.chat.jumpToLatest",
      "The chat opened at the end and still offered to take the reader there")
  }

  /// The jump control appears as soon as the end of the conversation leaves the screen,
  /// while part of a tall newest turn is still visible.
  ///
  /// The arrow and the visible turn are asserted together. An arrow alone proves nothing,
  /// because one also appears once the reader clears the whole turn.
  ///
  /// One drag, clipped to the conversation. `app.swipeDown()` starts at the app's centre,
  /// which lands on the composer, and a longer drag would clear the turn. It moves the reader
  /// about 200 points on `Driverr iPhone 17` and 420 on `Driverr iPad`, against a 660-point
  /// turn. The fixtures are those of `testTheChatOpensAtTheEndOfATallNewestTurn`.
  func testTheJumpAppearsWhileTheNewestTurnIsStillOnScreen() {
    let app = connectedHost(boundedTranscript: true, slowTranscript: true)

    tapPane(app, titled: "needs a decision")
    let chat = require(app, "pane.chat", "Expected the conversation")
    require(app, "pane.chat.turn.assistant", "Expected the agent's turn")

    // The open's scroll corrections run after the transcript lands. Let the layout settle
    // before dragging.
    usleep(2_500_000)

    // The precondition: no arrow before the drag.
    requireGone(
      app, "pane.chat.jumpToLatest",
      "The chat opens at the end of the conversation, so there is nowhere to jump to")

    let before = chat.frame
    let start = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.20))
    let end = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.60))
    start.press(forDuration: 0.4, thenDragTo: end)
    usleep(2_000_000)

    let turns = app.descendants(matching: .any).matching(identifier: "pane.chat.turn.assistant")
    let newest = turns.element(boundBy: turns.count - 1)
    let newestFrame = newest.frame
    let jump = element(app, "pane.chat.jumpToLatest")
    let readableBottom = min(chat.frame.maxY, composerTop(in: app) ?? chat.frame.maxY)
    let stillShowing = newestFrame.minY < readableBottom && newestFrame.maxY > chat.frame.minY

    // Printed so a passing run still records the state it passed in.
    print(
      "[jump] chat \(chat.frame) newest \(newestFrame) readableBottom \(readableBottom) "
        + "showing \(stillShowing) jump \(jump.exists) turns \(turns.count)")

    // The height proves the index found the thirty-line turn (660 to 690 points). Every
    // other turn in the fixture is a few lines.
    XCTAssertGreaterThan(
      newestFrame.height, 400,
      """
      The last assistant turn is only \(newestFrame.height) points tall, so this is not the \
      thirty-line answer this test is about and nothing below is a result about it.
      Chat was \(before), is \(chat.frame). Tree was:
      \(app.debugDescription)
      """)
    XCTAssertTrue(
      stillShowing,
      """
      One drag scrolled the newest turn off screen entirely, so an arrow here would be the \
      old behaviour rather than the new one and this test could not fail for its own reason.
      Newest turn \(newestFrame) against a chat readable to \(readableBottom).
      """)
    XCTAssertTrue(
      jump.exists,
      """
      Scrolling off the end of the conversation offered no way back. The reader is \
      \(readableBottom - newestFrame.maxY) points above the end of a turn that is still on \
      screen, which is exactly the stretch the old signal called "at the bottom".
      Newest turn \(newestFrame), chat \(chat.frame).
      Tree was:
      \(app.debugDescription)
      """)
  }

  /// A re-read that changes nothing on screen must not pull back the reader's next scroll.
  ///
  /// An update to the newest turn that keeps its height can leave the follow logic's
  /// recorded newest turn stale, so the reader's next drag reads as an arrival and the chat
  /// scrolls them back to the end.
  ///
  /// `FakeTranscriptHost` stamps records with the current clock, so every re-read produces
  /// that update. A re-read needs two ticks of `PaneTranscriptModel.watchInterval` plus the
  /// slow fixture's 900 ms, and fourteen seconds covers at least two.
  @MainActor
  func testScrollingBackAfterAQuietReReadStaysWhereTheReaderPutIt() {
    let app = connectedHost(boundedTranscript: true, slowTranscript: true)

    tapPane(app, titled: "needs a decision")
    let chat = require(app, "pane.chat", "Expected the conversation")
    require(app, "pane.chat.turn.assistant", "Expected the agent's turn")

    usleep(14_000_000)
    requireGone(
      app, "pane.chat.jumpToLatest",
      "The chat opens at the end of the conversation, so there is nowhere to jump to")

    let start = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.20))
    let end = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.60))
    start.press(forDuration: 0.4, thenDragTo: end)
    usleep(2_000_000)

    let turns = app.descendants(matching: .any).matching(identifier: "pane.chat.turn.assistant")
    let newest = turns.element(boundBy: turns.count - 1)
    let readableBottom = min(chat.frame.maxY, composerTop(in: app) ?? chat.frame.maxY)
    print("[re-read] after drag: newest \(newest.frame) readableBottom \(readableBottom)")
    XCTAssertTrue(
      element(app, "pane.chat.jumpToLatest").exists,
      """
      The reader scrolled back from the end after a re-read that changed nothing on screen, \
      and the chat took them back to the end. Newest turn \(newest.frame), readable to \
      \(readableBottom).
      Tree was:
      \(app.debugDescription)
      """)
  }

  // MARK: - Staying at the end while the composer grows

  /// The end of the answer stays above the composer as newlines make the composer taller.
  ///
  /// Each wrapped line shrinks the conversation's viewport, and anchoring that change at the
  /// top put the end of the answer back under the composer. The fixtures are those of
  /// `testTheChatOpensAtTheEndOfATallNewestTurn`: without a tall turn, its end and its top
  /// are in the same place.
  func testTheComposerGrowingKeepsTheEndOfTheAnswerOnScreen() {
    let app = connectedHost(boundedTranscript: true, slowTranscript: true)

    tapPane(app, titled: "needs a decision")
    require(app, "pane.chat", "Expected the conversation")
    require(app, "pane.chat.turn.assistant", "Expected the agent's turn")

    let assistantRows = app.descendants(matching: .any)
      .matching(identifier: "pane.chat.turn.assistant")
    var newestLabel: String?
    // Record the newest turn's label now, at rest at the end, while it is certainly the last
    // realised row. After focusing, the last row is the thing under test.
    if assistantRows.count > 0 {
      newestLabel = assistantRows.element(boundBy: assistantRows.count - 1).label
    }

    let field = require(app, "composer.text", "Expected the composer field")
    field.tap()
    XCTAssertTrue(
      app.keyboards.firstMatch.waitForExistence(timeout: 10), "The keyboard never came up")

    // The last realised row, which must carry the label recorded above.
    //
    // Only realised cells are in the tree, and on `Driverr iPad` the older answer leaves it as
    // the composer grows. So `count - 1` is re-derived on every read, and the label check
    // stops the helper measuring the older turn if the newest one is pushed out. A row count
    // cannot tell those cases apart.
    //
    // Polled, because the scroll the keyboard triggers is deferred a run-loop turn.
    func newestTurnBottom() -> CGFloat {
      let count = assistantRows.count
      guard count > 0 else { return .infinity }
      let row = assistantRows.element(boundBy: count - 1)
      guard row.exists else { return .infinity }
      if let newestLabel, row.label != newestLabel { return .infinity }
      return row.frame.maxY
    }
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline && newestTurnBottom() > (composerTop(in: app) ?? .infinity) {
      usleep(200_000)
    }
    let focused = newestTurnBottom()
    // The card's top, not the field's. See `composerTop(in:)`.
    let focusedCeiling = composerTop(in: app) ?? field.frame.minY
    XCTAssertLessThanOrEqual(
      focused, focusedCeiling,
      """
      Focusing the field did not bring the end of the answer above the keyboard.
      Nothing below can be read as a result about what typing does to it.
      Newest turn ends at \(focused), composer card top \(focusedCeiling), field \(field.frame).
      """)

    // `typeText` sends each newline as Return, and the composer grows a line each time.
    app.typeText("one\ntwo\nthree")
    // Wait for three lines, then let the layout settle. The re-anchor lands a moment after
    // the growth, so an earlier read passes on the broken build.
    let grown = Date().addingTimeInterval(5)
    while Date() < grown && field.frame.height < 55 {
      usleep(200_000)
    }
    XCTAssertGreaterThan(
      field.frame.height, 55,
      "The composer never grew to three lines, so nothing here exercised a growing composer. "
        + "Field \(field.frame).")
    usleep(1_500_000)

    // The keyboard must still be up. XCUITest's key events can take the software keyboard
    // away (see `terminalText`), and the reading below would then be the keyboard-down layout,
    // which fails by a point for a reason that is not a defect. That layout is pinned by
    // `ChatCollectionViewTests.theOwnerRestsTheConversationUnderAHomeIndicator`.
    //
    // Checked on the frame, because a dismissed keyboard can linger in the tree with an empty
    // rect.
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(
      keyboard.exists && keyboard.frame.height > 0,
      """
      The software keyboard went away while the composer was being typed into, so the layout \
      below is the keyboard-down one and nothing in it is a result about a growing composer.
      Keyboard frame \(keyboard.exists ? "\(keyboard.frame)" : "absent"), field \(field.frame), \
      composer card top \(composerTop(in: app).map { "\($0)" } ?? "none").
      A hardware keyboard attached to the simulator is the usual cause, and XCUITest's own key \
      events are the other — see this assertion's comment. Re-run the class rather \
      than reading the numbers below.
      """)

    let grownCeiling = composerTop(in: app) ?? field.frame.minY
    let grownBottom = newestTurnBottom()
    XCTAssertLessThanOrEqual(
      grownBottom, grownCeiling,
      """
      Typing three newlines pushed the end of the agent's answer back under the composer.
      The reader is looking at the middle of the turn they came to answer.
      The turn ended at \(focused) with the keyboard up and ends at \(grownBottom) now,
      against a composer card starting at \(grownCeiling) and a field at \(field.frame.minY),
      with the keyboard \(keyboard.exists ? "at \(keyboard.frame)" : "absent").
      """)
  }

  // MARK: - Scrolling with the keyboard up

  /// Scrolling back through the conversation in portrait keeps the keyboard up.
  ///
  /// Scroll-to-dismiss exists so a landscape reader can bring back the hidden
  /// `Chat | Terminal` band. In portrait the band never hides, and dismissing would take the
  /// keyboard mid-reply. The fixtures are those of
  /// `testTheChatOpensAtTheEndOfATallNewestTurn`, so there is somewhere to scroll back to.
  ///
  /// The keyboard is checked on its frame, not its existence, because a dismissed keyboard
  /// can linger with an empty rect.
  func testScrollingBackInPortraitKeepsTheKeyboard() {
    let app = connectedHost(boundedTranscript: true, slowTranscript: true)

    tapPane(app, titled: "needs a decision")
    require(app, "pane.chat", "Expected the conversation")
    require(app, "pane.chat.turn.assistant", "Expected the agent's turn")

    let field = require(app, "composer.text", "Expected the composer field")
    field.tap()
    XCTAssertTrue(
      app.keyboards.firstMatch.waitForExistence(timeout: 10), "The keyboard never came up")
    let opened = app.keyboards.firstMatch.frame
    XCTAssertGreaterThan(
      opened.height, 0,
      "The keyboard element exists with an empty frame \(opened), so this test would be "
        + "measuring the keyboard-down layout and could not fail for the reason it exists.")

    // Focus scrolls to the newest turn, and a correction follows. Let both settle.
    usleep(1_500_000)

    // The drag has to stay above the keyboard. The scroll view runs the whole way down the
    // window, so `swipeDown()` starts on the keys and scrolls nothing. Both ends come from the
    // chat's frame clipped to the keyboard's top.
    let chat = element(app, "pane.chat")
    let chatFrame = chat.frame
    let visibleHeight = min(chatFrame.maxY, opened.minY) - chatFrame.minY
    XCTAssertGreaterThan(
      visibleHeight, 100,
      "Only \(visibleHeight) pt of conversation is visible above the keyboard, which is not "
        + "enough to drag inside. Chat \(chatFrame), keyboard \(opened).")
    let start = chat.coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: (visibleHeight * 0.15) / chatFrame.height))
    let end = chat.coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: (visibleHeight * 0.85) / chatFrame.height))

    // Drag until the jump control proves the reader left the end. A gesture the scroll view
    // never saw cannot dismiss a keyboard either, so the assertion needs that proof. A turn's
    // frame cannot give it, because an index names a different turn once scrolling builds
    // more rows. The 660 pt turn needs several drags to clear.
    let jump = element(app, "pane.chat.jumpToLatest")
    // The precondition: no control yet, or the loop runs zero drags.
    XCTAssertFalse(
      jump.exists,
      """
      The chat was already offering the jump-to-latest control before any drag, so the loop
      below runs no drags and nothing under it is a result about scrolling.
      Tree was:
      \(app.debugDescription)
      """)
    for _ in 0..<6 where !jump.exists {
      start.press(forDuration: 0.1, thenDragTo: end)
      usleep(700_000)
    }
    usleep(1_500_000)

    // Counted before measured, because `frame` on a query with no match raises an error.
    let stillUp = app.keyboards.count > 0
    let after = stillUp ? app.keyboards.firstMatch.frame : .zero

    // Printed so a passing run still records the state it passed in.
    print(
      "[keyboard scroll] chat \(chatFrame) jumpToLatest \(jump.exists) "
        + "keyboard \(opened) -> \(after) count \(app.keyboards.count)")

    XCTAssertTrue(
      jump.exists,
      """
      Six drags never took the reader off the end of the conversation, so nothing below is a
      result about what scrolling does to the keyboard.
      Chat \(chatFrame), keyboard \(opened).
      """)
    XCTAssertTrue(
      stillUp,
      """
      Scrolling back through the conversation in portrait dismissed the keyboard.
      The reader loses the keyboard mid-reply for glancing at what they came to answer.
      The keyboard was \(opened) before the drag and is gone from the tree now.
      """)
    // A dismissed keyboard can linger in the tree with an empty rect.
    XCTAssertGreaterThan(
      after.height, 0,
      """
      Scrolling back through the conversation in portrait left the keyboard in the tree with no
      frame, which is off screen.
      The keyboard was \(opened) before the drag and is \(after) now.
      """)
  }

  // MARK: - The working row is a row in the conversation

  /// The working row is the last row of the conversation and scrolls with it, rather than
  /// being pinned above the composer. Jump-to-latest lands past it.
  ///
  /// The drag is the direct claim. A pinned row keeps its place and label after any scroll,
  /// so no check on its label or existence tells the two apart.
  ///
  /// `terminal wiring` is the seeded pane whose agent is `working`. The fixtures are those
  /// of `testTheChatOpensAtTheEndOfATallNewestTurn`.
  func testTheWorkingRowIsTheLastRowAndScrollsWithIt() {
    let app = connectedHost(boundedTranscript: true, slowTranscript: true)

    tapPane(app, titled: "terminal wiring")
    let chat = require(app, "pane.chat", "Expected the conversation")
    require(app, "pane.chat.turn.assistant", "Expected the agent's turn")

    // Let the open's scroll corrections settle before dragging.
    usleep(2_500_000)

    let activity = require(
      app, "pane.chat.activity", "Expected the working row at the foot of the conversation")
    XCTAssertEqual(
      activity.label,
      "Claude is working.",
      "Expected the working pane's own sentence.\nTree was:\n\(app.debugDescription)")

    let turns = app.descendants(matching: .any).matching(identifier: "pane.chat.turn.assistant")
    let newest = turns.element(boundBy: turns.count - 1)
    let readableBottom = min(chat.frame.maxY, composerTop(in: app) ?? chat.frame.maxY)
    let before = activity.frame

    // Below the newest turn. A pinned row would pass this too.
    XCTAssertGreaterThanOrEqual(
      before.minY,
      newest.frame.maxY,
      """
      The working row is not below the newest turn: row \(before), newest turn \
      \(newest.frame).
      """)
    // The chat opens past this row, so it is readable on arrival.
    XCTAssertLessThanOrEqual(
      before.maxY,
      readableBottom,
      """
      The chat opened with the working row below the readable region: row \(before) against \
      a conversation readable to \(readableBottom).
      """)
    requireGone(
      app, "pane.chat.jumpToLatest",
      "The chat opened at the end of the conversation, past the working row")

    // One drag inside the conversation, because `app.swipeDown()` starts on the composer.
    let start = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.20))
    let end = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.60))
    start.press(forDuration: 0.4, thenDragTo: end)
    usleep(2_000_000)

    // A row scrolled far enough leaves the tree, and `frame` on it would raise. Either
    // outcome means the row moved with the content.
    let stillThere = activity.exists
    let after = stillThere ? activity.frame : .null
    let moved = !stillThere || abs(after.minY - before.minY) > 20

    // Printed so a passing run still records the state it passed in.
    let afterDescription = stillThere ? "\(after)" : "gone from the tree"
    print(
      "[working row] chat \(chat.frame) activity \(before) -> \(afterDescription) "
        + "readableBottom \(readableBottom)")

    XCTAssertTrue(
      moved,
      """
      Scrolling the conversation left the working row exactly where it was, so it is pinned \
      above the composer rather than being the last row of the transcript.
      The row was \(before) and is \(after) after a drag that moved the conversation.
      Tree was:
      \(app.debugDescription)
      """)

    // The way back lands past the row, not at the last turn with the row below the fold.
    let jump = element(app, "pane.chat.jumpToLatest")
    XCTAssertTrue(
      jump.exists,
      """
      The drag never took the reader off the end of the conversation, so nothing below is a \
      result about the jump. Chat \(chat.frame).
      Tree was:
      \(app.debugDescription)
      """)
    jump.tap()
    usleep(1_500_000)
    requireGone(
      app, "pane.chat.jumpToLatest", "The jump left the reader short of the end", timeout: 8)
    XCTAssertTrue(
      activity.exists,
      "The jump landed short of the working row.\nTree was:\n\(app.debugDescription)")
    let landed = activity.frame
    let landedBottom = min(chat.frame.maxY, composerTop(in: app) ?? chat.frame.maxY)
    XCTAssertLessThanOrEqual(
      landed.maxY,
      landedBottom,
      """
      Jump-to-latest landed with the working row still below the readable region: row \
      \(landed) against a conversation readable to \(landedBottom).
      """)
  }

  /// A conversation with nothing to report ends at its last turn, with no space held above
  /// the composer. `needs a decision` is `blocked`, which `ChatActivity` says nothing for.
  ///
  /// The bounded fixture's tall turn puts the end of the conversation at the bottom of the
  /// viewport.
  func testAnIdleConversationEndsAtItsLastTurnWithNoRow() {
    let app = connectedHost(boundedTranscript: true, slowTranscript: true)

    tapPane(app, titled: "needs a decision")
    let chat = require(app, "pane.chat", "Expected the conversation")
    require(app, "pane.chat.turn.assistant", "Expected the agent's turn")
    usleep(2_500_000)

    requireGone(
      app, "pane.chat.activity", "A blocked pane has nothing in flight to report")

    let turns = app.descendants(matching: .any).matching(identifier: "pane.chat.turn.assistant")
    let newest = turns.element(boundBy: turns.count - 1)
    let readableBottom = min(chat.frame.maxY, composerTop(in: app) ?? chat.frame.maxY)
    let gap = readableBottom - newest.frame.maxY
    print("[working row] idle newest \(newest.frame) readableBottom \(readableBottom) gap \(gap)")
    // The tolerance of `testALongPageOpensOnTheNewestTurn`.
    XCTAssertLessThan(
      gap,
      80,
      """
      The conversation stops \(gap) points above the composer with no row to fill it, so \
      something is holding space for news that is not there.
      Newest turn \(newest.frame), readable to \(readableBottom).
      """)
  }

  // MARK: - A row that appears while you are reading

  /// A reader resting at the end sees the working row arrive.
  ///
  /// An agent going from idle to working adds a row of about thirty points just under the
  /// fold. That is inside `ChatEndProximity.jumpTolerance`, so no jump control offers the way
  /// to it, and the chat has to follow on its own.
  ///
  /// `-uiTestingAgentStartsWorking` opens the chat on an idle `terminal wiring` and flips it
  /// ten seconds after the pane's stream opens (`AppEnvironment.armTheWorkingRow`). It is the
  /// only fixture with the transition; every other working-row test has the row from the
  /// open.
  func testANewWorkingRowReachesAReaderRestingAtTheEnd() {
    let app = connectedHost(
      boundedTranscript: true, slowTranscript: true, agentStartsWorking: true)

    tapPane(app, titled: "terminal wiring")
    let chat = require(app, "pane.chat", "Expected the conversation")
    require(app, "pane.chat.turn.assistant", "Expected the agent's turn")

    // Let the open's scroll corrections settle.
    usleep(2_500_000)

    // The precondition: the pane is idle when the chat opens.
    requireGone(
      app, "pane.chat.activity",
      "The pane was already working when the chat opened, so there is no transition to test",
      timeout: 3)
    // The precondition: the reader is within `ChatEndProximity.jumpTolerance` of the end.
    let turnsAtOpen = app.descendants(matching: .any)
      .matching(identifier: "pane.chat.turn.assistant")
    let newestAtOpen = turnsAtOpen.element(boundBy: turnsAtOpen.count - 1)
    let readableAtOpen = min(chat.frame.maxY, composerTop(in: app) ?? chat.frame.maxY)
    // A second settle. With the slow fixture's 900 ms read, the open is only starting to be
    // stable after the first.
    usleep(2_500_000)
    print(
      "[working row] at open: newest \(newestAtOpen.frame) readableBottom \(readableAtOpen) "
        + "jump \(element(app, "pane.chat.jumpToLatest").exists)")
    XCTAssertLessThanOrEqual(
      newestAtOpen.frame.maxY - readableAtOpen,
      64,  // `ChatEndProximity.jumpTolerance`, which the UI target cannot import.
      """
      The chat opened with the reader more than the jump tolerance above the end of the \
      conversation, so this run is not about a reader resting at the end. Newest turn \
      \(newestAtOpen.frame), readable to \(readableAtOpen).
      """)

    // The flip lands ten seconds after the stream opens and the session polls every three,
    // so the row is up by about thirteen seconds. No tap.
    let activity = require(
      app, "pane.chat.activity",
      "The agent started working and no row ever appeared", timeout: 15)
    // The nudge is animated, and the row has to be read where it comes to rest.
    usleep(1_500_000)

    let frame = activity.frame
    let readableBottom = min(chat.frame.maxY, composerTop(in: app) ?? chat.frame.maxY)
    // Printed so a passing run still records the state it passed in.
    print(
      "[working row] resting reader: chat \(chat.frame) activity \(frame) "
        + "readableBottom \(readableBottom) "
        + "jump \(element(app, "pane.chat.jumpToLatest").exists)")

    XCTAssertEqual(
      activity.label,
      "Claude is working.",
      "Expected the working pane's own sentence.\nTree was:\n\(app.debugDescription)")

    // The jump control is the strong assertion. The row's accessibility frame is its label's
    // and under-reports the row, so a frame check passed with the row cut in half by the
    // composer. The control is up exactly when the end is neither visible nor within
    // `ChatEndProximity.jumpTolerance`.
    requireGone(
      app, "pane.chat.jumpToLatest",
      """
      The agent started working and the reader was left short of the end of the conversation, \
      with the new row against or behind the composer. Row \(frame), conversation \
      readable to \(readableBottom)
      """,
      timeout: 8)
    XCTAssertLessThanOrEqual(
      frame.maxY,
      readableBottom,
      """
      The agent started working and the row landed below the readable region, where a reader \
      resting at the end never sees it. Row \(frame) against a conversation readable \
      to \(readableBottom).
      Tree was:
      \(app.debugDescription)
      """)
    XCTAssertGreaterThanOrEqual(
      frame.minY,
      chat.frame.minY,
      "The row was pushed off the top of the conversation: row \(frame), chat \(chat.frame).")
  }

  /// A reader who has scrolled back is not dragged to a new working row.
  ///
  /// `ChatReaderPlace` tells this reader apart from the resting one. The status flip also
  /// arrives as `SessionModel.Changes.moved` and re-reads the conversation, and the reader
  /// must keep their place across that too.
  func testAReaderScrolledBackIsNotMovedByANewWorkingRow() {
    let app = connectedHost(
      boundedTranscript: true, slowTranscript: true, agentStartsWorking: true)

    tapPane(app, titled: "terminal wiring")
    let chat = require(app, "pane.chat", "Expected the conversation")
    require(app, "pane.chat.turn.assistant", "Expected the agent's turn")
    usleep(2_500_000)

    // One drag inside the conversation, because `app.swipeDown()` starts on the composer.
    let start = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.20))
    let end = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
    start.press(forDuration: 0.4, thenDragTo: end)
    usleep(2_000_000)

    let jump = element(app, "pane.chat.jumpToLatest")
    XCTAssertTrue(
      jump.exists,
      """
      The drag never took the reader off the end of the conversation, so nothing below is a \
      result about a reader who has scrolled back. Chat \(chat.frame).
      Tree was:
      \(app.debugDescription)
      """)

    let turns = app.descendants(matching: .any).matching(identifier: "pane.chat.turn.assistant")
    let newest = turns.element(boundBy: turns.count - 1)
    let before = newest.frame

    // The row cannot be waited for from here. Only realised cells are in the tree, and the
    // row lands at the end, away from this reader, with nothing else on screen marking the
    // flip. So the wait is bounded, covering the flip, the three-second poll and the 900 ms
    // re-read, and ends early if the row does realise. The arrival is proved at the foot of
    // the test, so a run where the agent never started still fails.
    let activity = element(app, "pane.chat.activity")
    let arrival = Date().addingTimeInterval(15)
    while Date() < arrival && !activity.exists {
      usleep(250_000)
    }

    let after = newest.frame
    print(
      "[working row] scrolled-back reader: newest turn \(before) -> \(after) chat \(chat.frame)")

    XCTAssertLessThan(
      abs(after.minY - before.minY),
      20,
      """
      The working row appearing moved a reader who had scrolled back: the turn they were \
      reading went from \(before) to \(after). A new row below the reader must not move the \
      turn they are reading.
      Tree was:
      \(app.debugDescription)
      """)
    XCTAssertTrue(
      jump.exists,
      "The reader lost the way back to the end of the conversation.\nTree was:\n"
        + app.debugDescription)

    // The agent did start working. Taking the way back realises the row's cell.
    jump.tap()
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline && !activity.exists {
      usleep(300_000)
    }
    XCTAssertTrue(
      activity.exists,
      "The agent never started working, so nothing above is a result.\nTree was:\n"
        + app.debugDescription)
  }

  // MARK: - An answer growing in place

  /// An answer that grows without changing its record id carries a reader resting at the end
  /// down with it.
  ///
  /// A diffable snapshot sees identical ids and so no change, so
  /// `ChatCollectionView.Coordinator.apply` diffs `turnsByID` and reconfigures changed items.
  /// See `AppEnvironment.grownAnswerTranscript` for the fixture.
  ///
  /// The jump control is the assertion, because the grown turn is taller than the screen and
  /// its frame always runs past the readable region.
  func testAnAnswerGrowingInPlaceReachesAReaderRestingAtTheEnd() {
    let app = connectedHost(growingAnswer: true, slowTranscript: true)

    tapPane(app, titled: "needs a decision")
    let chat = require(app, "pane.chat", "Expected the conversation")
    require(app, "pane.chat.turn.assistant", "Expected the seeded conversation")

    // Let the open's scroll corrections settle. The growth is armed eight seconds after the
    // stream opened, well after this.
    usleep(2_500_000)

    let turns = app.descendants(matching: .any).matching(identifier: "pane.chat.turn.assistant")
    let grown = turns.element(
      matching: NSPredicate(format: "label CONTAINS %@", "start with the session opener")
    )
    XCTAssertFalse(
      grown.exists,
      """
      The answer was already long when the chat opened, so nothing below is about it growing. \
      The fixture is supposed to serve the two-line answer first.
      Tree was:
      \(app.debugDescription)
      """)

    // The precondition: the reader is within the jump tolerance of the end.
    let readableAtOpen = min(chat.frame.maxY, composerTop(in: app) ?? chat.frame.maxY)
    let newestAtOpen = turns.element(boundBy: turns.count - 1)
    print(
      "[growth] at open: newest \(newestAtOpen.frame) readableBottom \(readableAtOpen) "
        + "jump \(element(app, "pane.chat.jumpToLatest").exists)")
    XCTAssertLessThanOrEqual(
      newestAtOpen.frame.maxY - readableAtOpen,
      64,  // `ChatEndProximity.jumpTolerance`, which the UI target cannot import.
      """
      The chat opened with the reader more than the jump tolerance above the end, so this run is \
      not about a reader resting at the end. Newest turn \(newestAtOpen.frame), readable to \
      \(readableAtOpen).
      """)

    XCTAssertTrue(
      grown.waitForExistence(timeout: 30),
      """
      The answer never got longer at all, so nothing below is a result. Nothing was tapped, \
      which is the point: the chat has to keep looking.
      Tree was:
      \(app.debugDescription)
      """)
    // The correction runs on a layout signal. Read after it settles.
    usleep(2_000_000)

    let readableBottom = min(chat.frame.maxY, composerTop(in: app) ?? chat.frame.maxY)
    print(
      "[growth] after growth: grown \(grown.frame) readableBottom \(readableBottom) "
        + "jump \(element(app, "pane.chat.jumpToLatest").exists)")

    requireGone(
      app, "pane.chat.jumpToLatest",
      """
      The final answer grew by several paragraphs while the reader rested at the end and they \
      were left above it, with the jump-to-latest arrow over the conversation. Grown turn \
      \(grown.frame), conversation readable to \(readableBottom)
      """,
      timeout: 8)

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "answer-growth-followed"
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// A reader who has scrolled back is not moved by the answer growing below them.
  ///
  /// `ChatReaderPlace` holds the reader by an item and a depth inside it, so the turn under
  /// their eye must not move by more than rounding. The wait and the proof of arrival follow
  /// `testAReaderScrolledBackIsNotMovedByANewWorkingRow`.
  func testAReaderScrolledBackIsNotMovedByAnAnswerGrowingInPlace() {
    let app = connectedHost(growingAnswer: true, slowTranscript: true)

    tapPane(app, titled: "needs a decision")
    let chat = require(app, "pane.chat", "Expected the conversation")
    require(app, "pane.chat.turn.assistant", "Expected the seeded conversation")
    usleep(2_500_000)

    // The answer above the one that grows, matched on its plain last line because its
    // markdown does not read back verbatim.
    let asked = app.descendants(matching: .any)
      .matching(identifier: "pane.chat.turn.assistant")
      .matching(NSPredicate(format: "label CONTAINS %@", "Running the tests now"))
      .firstMatch
    let jump = element(app, "pane.chat.jumpToLatest")

    // Drag until the reader is off the end with that turn in view. How far one drag goes
    // depends on how the answer wrapped. Inside the conversation, because `app.swipeDown()`
    // starts on the composer.
    for _ in 0..<3 where !(jump.exists && asked.exists) {
      let start = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.20))
      let end = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
      start.press(forDuration: 0.4, thenDragTo: end)
      usleep(2_000_000)
    }

    XCTAssertTrue(
      jump.exists,
      """
      The drag never took the reader off the end of the conversation, so nothing below is a \
      result about a reader who has scrolled back. Chat \(chat.frame).
      Tree was:
      \(app.debugDescription)
      """)
    XCTAssertTrue(
      asked.exists,
      "The drag did not bring the earlier answer into view.\nTree was:\n" + app.debugDescription)
    let before = asked.frame

    let grown = app.descendants(matching: .any)
      .matching(identifier: "pane.chat.turn.assistant")
      .matching(NSPredicate(format: "label CONTAINS %@", "start with the session opener"))
      .firstMatch
    let arrival = Date().addingTimeInterval(20)
    while Date() < arrival && !grown.exists {
      usleep(250_000)
    }

    let after = asked.frame
    print("[growth] scrolled-back reader: asked turn \(before) -> \(after) chat \(chat.frame)")

    XCTAssertLessThan(
      abs(after.minY - before.minY),
      2,
      """
      The final answer growing moved a reader who had scrolled back: the turn they were reading \
      went from \(before) to \(after). The growth lands below them and a place names an \
      item and a depth inside it, so this is supposed to be zero.
      Tree was:
      \(app.debugDescription)
      """)
    XCTAssertTrue(
      jump.exists,
      "The reader lost the way back to the end of the conversation.\nTree was:\n"
        + app.debugDescription)

    // The answer did grow. Taking the way back realises the grown cell.
    jump.tap()
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline && !grown.exists {
      usleep(300_000)
    }
    XCTAssertTrue(
      grown.exists,
      "The answer never grew, so nothing above is a result.\nTree was:\n" + app.debugDescription)
  }
}
