import XCTest

/// Opening a run of tool calls.
///
/// What an opened run says is `ToolRunOpeningTests`. This class covers that a tap opens the
/// row, and that opening one does not move the reader, asserted from both ends of the scroll
/// range.
///
/// A run opened above the visible region cannot be driven, because the tap puts the row on
/// screen. The reader's place is held against a turn rather than an offset, so it survives
/// a size change wherever it lands; `OpenToolRuns` covers its half in `swift test`.
///
/// Relaunches per test: connecting records a trust decision and leaves a pane scene open.
@MainActor
final class PaneToolRunUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  // MARK: - Finding things

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  /// The nth call row of one identified run, or a query that matches nothing.
  ///
  /// Numbered rather than counted, because `descendants(matching: .any)` also matches what
  /// a row publishes under itself.
  private func call(_ app: XCUIApplication, runID: String, _ index: Int) -> XCUIElement {
    element(app, "pane.chat.turn.tools.\(runID).call.\(index)")
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

  /// One of the two runs in the fixture, by what its row says.
  private func runRow(_ app: XCUIApplication, saying prefix: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(
        NSPredicate(
          format: "identifier == %@ AND label BEGINSWITH %@", "pane.chat.turn.tools", prefix
        )
      )
      .firstMatch
  }

  // MARK: - Getting to a chat with two runs in it

  private func connectedHost() -> XCUIApplication {
    XCUIDevice.shared.orientation = .portrait
    // Two runs and more turns than fit on a phone, so opening a run could move the reader.
    // Seeded, because this class is not about connecting.
    let app = connectedHostApp(["-uiTestingBusyTranscript"])
    require(app, "session.workspace", "Expected the session tree")
    return app
  }

  /// Taps the pane's tree row, not its Needs-you row.
  ///
  /// The Needs-you row opens with the keyboard up. The scroll view runs under the composer,
  /// so `chat.swipeDown()` then starts its drag on the composer and the conversation never
  /// moves. No label fallback, which only `schema sync` in a collapsed workspace needs.
  private func tapPane(_ app: XCUIApplication, titled title: String) {
    treePaneRow(app, titled: title).tap()
  }

  /// The chat, with the conversation in it.
  private func openChat(_ app: XCUIApplication) -> XCUIElement {
    tapPane(app, titled: "needs a decision")
    let chat = require(app, "pane.chat", "Expected the pane to open on its chat")
    require(app, "pane.chat.turn.assistant", "Expected the conversation to have rendered")
    return chat
  }

  /// Scrolls until `row` is on screen and can actually be tapped.
  ///
  /// `swipeDown` walks back up the conversation. The chat opens at its newest turn, so every
  /// run in the fixture is at or above the start.
  private func scrollBackTo(
    _ row: XCUIElement,
    in chat: XCUIElement,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    // Slow, short swipes. A full-velocity swipe can carry a one-line row straight past the
    // viewport.
    for _ in 0..<16 where !(row.exists && row.isHittable) {
      chat.swipeDown(velocity: .slow)
    }
    XCTAssertTrue(
      row.exists && row.isHittable,
      "Never reached the run row by scrolling back through the conversation.",
      file: file,
      line: line
    )
  }

  /// The rows whose position is the reader's place, for a run about to be opened.
  ///
  /// Always the run's own row, since nothing above it changes size when it opens. Also the
  /// turn above it when that turn is built; an unbuilt turn's `.zero` frame would prove
  /// nothing.
  private func placeAnchors(
    _ app: XCUIApplication,
    run: XCUIElement
  ) -> [(String, XCUIElement)] {
    var anchors = [("the run's own row", run)]
    let above = element(app, "pane.chat.turn.human")
    if above.exists, above.frame.height > 0, above.frame.minY < run.frame.minY {
      anchors.append(("the turn above it", above))
    }
    return anchors
  }

  /// Compares the anchors' top edges before and after a run opens, to a point of tolerance.
  private func assertUnmoved(
    _ named: [(String, XCUIElement)],
    _ before: [CGRect],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    for (index, (name, element)) in named.enumerated() {
      XCTAssertEqual(
        element.frame.minY,
        before[index].minY,
        accuracy: 1,
        "Opening the run moved \(name): it was at \(before[index]) and is now at "
          + "\(element.frame). Opening a run must not cost the reader their place.",
        file: file,
        line: line
      )
    }
  }

  // MARK: - What opening a run shows

  /// The forty-call run, opened from where the chat starts. Closed, it names three calls and
  /// counts thirty-seven. Open, it names six and counts thirty-four, and the tapped row has
  /// not moved.
  func testOpeningTheLongRunNamesSixCallsCountsTheRestAndKeepsThePlace() {
    let app = connectedHost()
    let chat = openChat(app)

    let run = runRow(app, saying: "40 tool calls")
    let runID = "3f8c1d20-0000-4000-8000-000000000002-4"
    scrollBackTo(run, in: chat)
    // Closed names the last three calls (`ToolRun.closedLimit`).
    require(app, "pane.chat.turn.tools.\(runID).call.2", "A closed run names its last three calls")
    XCTAssertEqual(
      (0..<3).map { call(app, runID: runID, $0).label },
      ["Grep, open_session", "Read, pool.rs", "Edit, session.rs"],
      "The three most recent calls, spoken as name and target.\nTree was:\n\(app.debugDescription)"
    )
    requireGone(
      app, "pane.chat.turn.tools.\(runID).call.3", "Three is the whole of what a closed run names")
    XCTAssertEqual(
      require(app, "pane.chat.turn.tools.\(runID).more", "Expected the rest to be counted closed")
        .label,
      "+37 more",
      "A closed run counts what it did not name.\nTree was:\n\(app.debugDescription)"
    )
    requireGone(
      app, "pane.chat.turn.tools.\(runID).earlier",
      "The opened run's sentence belongs to the opened run"
    )
    let closedShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    closedShot.name = "tool-run-closed"
    closedShot.lifetime = .keepAlways
    add(closedShot)

    let anchors = placeAnchors(app, run: run)
    let before = anchors.map { $0.1.frame }
    run.tap()

    let earlier = require(
      app, "pane.chat.turn.tools.\(runID).earlier", "Expected the rest to be counted")
    XCTAssertEqual(
      earlier.label,
      "…and 34 earlier calls, same kinds.",
      "The opened run must count what it did not name.\nTree was:\n\(app.debugDescription)"
    )
    // Name and target, in the order the agent made them.
    require(app, "pane.chat.turn.tools.\(runID).call.5", "Expected six calls to be named")
    XCTAssertEqual(
      (0..<6).map { call(app, runID: runID, $0).label },
      // `TranscriptParser` reduces a `file_path` to its last component to fit the row.
      [
        "Read, session.rs",
        "Edit, pool.rs",
        "Bash, cargo test",
        "Grep, open_session",
        "Read, pool.rs",
        "Edit, session.rs",
      ],
      "The six most recent calls, spoken as name and target.\nTree was:\n\(app.debugDescription)"
    )
    requireGone(
      app, "pane.chat.turn.tools.\(runID).call.6", "Six is the whole of what an open run names")
    requireGone(
      app, "pane.chat.turn.tools.\(runID).more", "The closed count belongs to the closed run")
    let openedShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    openedShot.name = "tool-run-opened"
    openedShot.lifetime = .keepAlways
    add(openedShot)

    assertUnmoved(anchors, before)

    // Closing returns the row to its three calls and its count.
    run.tap()
    requireGone(
      app, "pane.chat.turn.tools.\(runID).call.3", "Closing a run puts the other three away")
    requireGone(
      app, "pane.chat.turn.tools.\(runID).earlier", "…and the sentence that counted the rest")
    require(app, "pane.chat.turn.tools.\(runID).more", "…and the closed count comes back")
    XCTAssertEqual(
      run.label,
      "40 tool calls.",
      "A closed run must not announce the tally that only its opened header draws.\nTree was:\n\(app.debugDescription)"
    )
  }

  /// A run of three opens to exactly three rows and no remainder line, which a hard-coded
  /// `suffix(6)` with a sentence under it would fail.
  ///
  /// Driven from back up the conversation, with content off screen below as well as above,
  /// the other end of the scroll range.
  func testAShortRunOpensToItsActualLengthAndKeepsThePlaceHigherUp() {
    let app = connectedHost()
    let chat = openChat(app)

    let run = runRow(app, saying: "3 tool calls")
    let runID = "3f8c1d20-0000-4000-8000-000000000002-1"
    scrollBackTo(run, in: chat)
    // Closed, a run of three already shows all three and counts nothing.
    require(app, "pane.chat.turn.tools.\(runID).call.2", "A closed run of three names all three")
    requireGone(
      app, "pane.chat.turn.tools.\(runID).more",
      "A closed run that named the whole run has nothing left to count"
    )

    let anchors = placeAnchors(app, run: run)
    let before = anchors.map { $0.1.frame }
    run.tap()

    require(app, "pane.chat.turn.tools.\(runID).call.2", "Expected all three calls to be named")
    XCTAssertEqual(
      (0..<3).map { call(app, runID: runID, $0).label },
      ["Read, Cargo.toml", "Read, mod.rs", "Grep, open_session"],
      "Every call in a short run is named.\nTree was:\n\(app.debugDescription)"
    )
    requireGone(
      app, "pane.chat.turn.tools.\(runID).call.3", "A run of three opens to exactly three rows")
    requireGone(
      app,
      "pane.chat.turn.tools.\(runID).earlier",
      "A run that opened to all of itself has nothing left to count"
    )
    // The kinds tally cannot be seen here. The header is one element with
    // `children: .ignore`, so the tally publishes nothing. `ToolRunOpeningTests` covers it.

    assertUnmoved(anchors, before)
  }

  // MARK: - What an open run survives

  /// An open run stays open across a switch to Terminal and back. The switch tears the chat
  /// down, because it is a plain `if` in `TerminalScreen.paneSurfaces`, so the state lives
  /// on `PaneTranscriptModel`, cached on the connection.
  func testAnOpenRunIsStillOpenAfterSwitchingToTheTerminalAndBack() {
    let app = connectedHost()
    let chat = openChat(app)

    let run = runRow(app, saying: "40 tool calls")
    let runID = "3f8c1d20-0000-4000-8000-000000000002-4"
    scrollBackTo(run, in: chat)
    run.tap()
    // The fourth row, because a closed run already names three.
    require(app, "pane.chat.turn.tools.\(runID).call.3", "Expected the run to have opened")

    require(app, "pane.surface.terminal", "Expected the Terminal segment").tap()
    require(app, "terminal.view", "Expected the terminal after switching to it")
    require(app, "pane.surface.chat", "Expected the Chat segment").tap()

    require(
      app,
      "pane.chat.turn.tools.\(runID).call.3",
      "A run the reader opened must still be open after a look at the terminal"
    )
  }
}
