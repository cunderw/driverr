import XCTest

/// Walks the accessibility tree the app publishes and asserts what a VoiceOver user depends
/// on, since Accessibility Inspector cannot be driven from a test. Nothing is announced as
/// an SF Symbol name, and the app works at the largest accessibility text size.
///
/// Relaunches per test: tests connect, and one records a trust decision.
@MainActor
final class AccessibilityUITests: XCTestCase {
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

  /// Finds a row that may be below the fold at accessibility text size, where the blocked
  /// pane's card alone is taller than the screen and later rows are not built until
  /// scrolled to.
  @discardableResult
  private func requireAfterScrolling(
    _ app: XCUIApplication,
    _ identifier: String,
    _ message: String,
    maxSwipes: Int = 15,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> XCUIElement {
    let match = element(app, identifier)
    for _ in 0..<maxSwipes {
      if match.exists { return match }
      app.swipeUp()
    }
    XCTAssertTrue(
      match.exists,
      "\(message)\nLooked for '\(identifier)' after scrolling. Tree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
    return match
  }

  /// The host list, on a launch that has the seeded host but has not opened it.
  ///
  /// - Parameter seedingConnection: `false` leaves the host without a stored password, the
  ///   only way to see the password field and Connect. With one stored, the host connects
  ///   on appearance.
  private func launch(
    textSize: String? = nil,
    seedingConnection: Bool = true
  ) -> XCUIApplication {
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments += ["-uiTesting", "-uiTestingSeedHost"]
    if seedingConnection { app.launchArguments += ["-uiTestingConnected"] }
    if let textSize {
      app.launchArguments += ["-UIPreferredContentSizeCategoryName", textSize]
    }
    app.launch()
    return app
  }

  /// The seeded host, already connected. Pinned to portrait first, because orientation
  /// survives the previous test.
  private func connectedHost(_ launchArguments: [String] = []) -> XCUIApplication {
    XCUIDevice.shared.orientation = .portrait
    return connectedHostApp(launchArguments)
  }

  /// A label that is really an SF Symbol name, such as `arrow.clockwise`: lowercase words
  /// joined by dots, with no spaces.
  private func looksLikeASymbolName(_ label: String) -> Bool {
    guard label.contains("."), !label.contains(" "), label.count > 3 else { return false }
    return label.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "." }
  }

  private func auditLabels(
    _ app: XCUIApplication,
    _ screen: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    for kind in [app.buttons, app.images, app.switches] {
      for element in kind.allElementsBoundByIndex where element.exists {
        let label = element.label
        XCTAssertFalse(
          looksLikeASymbolName(label),
          // The identifier and frame say which element leaked, since one symbol is drawn in
          // several places. The tree includes the screen behind the current one, so an
          // element found on "the terminal" may belong to the host screen.
          "On \(screen), an element is announced as the SF Symbol name '\(label)'. "
            + "VoiceOver reads that literally. Give it a label, or hide it if decorative.\n"
            + "identifier: '\(element.identifier)'  type: \(element.elementType.rawValue)  "
            + "frame: \(element.frame)\n"
            + "Tree was:\n\(app.debugDescription)",
          file: file,
          line: line
        )
      }
    }
  }

  /// Nothing anywhere in the main flow is announced as a symbol name.
  func testNothingIsAnnouncedAsAnSFSymbolName() {
    // Not `connectedHost`, because the host list is audited before the host opens.
    let app = launch()

    auditLabels(app, "the host list")

    require(app, "hosts.row", "Expected the seeded host").tap()
    // A seeded host connects on appearance.
    require(app, "connect.connected", "Expected the seeded host to connect", timeout: 15)
    require(app, "session.workspace", "Expected the session tree")

    auditLabels(app, "the host screen and session tree")

    // The chat carries the provenance header's `checkmark.circle`. Opened from the tree
    // row, without the keyboard, and by name, because the Gemini pane has no chat.
    treePaneRow(app, titled: "needs a decision").tap()
    require(app, "pane.chat", "Expected the pane to open on its chat")

    auditLabels(app, "the pane chat")

    require(app, "pane.surface.terminal", "Expected the Terminal segment").tap()
    require(app, "terminal.view", "Expected the terminal")

    auditLabels(app, "the terminal")
  }

  /// The headings rotor lists `You` and `Claude`. `XCUIElement` exposes no `.isHeader`
  /// trait, so this asserts the precondition: each speaker label is its own element.
  /// `TranscriptTurnView.speech(text:identifier:isHuman:)` applies the trait.
  func testSpeakerLabelsAreDistinctElementsForTheHeadingsRotor() {
    let app = connectedHost()

    // The Claude pane's tree row: the Gemini pane has no turns, and the Needs-you row opens
    // with the keyboard over them.
    treePaneRow(app, titled: "needs a decision").tap()
    require(app, "pane.chat", "Expected the pane to open on its chat")
    require(app, "pane.chat.turn.assistant", "Expected the agent's turn to have rendered")

    let you = app.staticTexts.matching(NSPredicate(format: "label == %@", "You")).firstMatch
    let claude = app.staticTexts.matching(NSPredicate(format: "label == %@", "Claude")).firstMatch
    XCTAssertTrue(
      you.waitForExistence(timeout: 10),
      "Expected a 'You' speaker label as its own element.\nTree was:\n\(app.debugDescription)"
    )
    XCTAssertTrue(
      claude.exists,
      "Expected a 'Claude' speaker label as its own element.\nTree was:\n\(app.debugDescription)"
    )
  }

  /// `composer.send` and the reply chips are at least 44 pt at the default text size.
  /// `composer.stop` is exempt by design: a small pill for a control that is neither the
  /// primary action nor tapped often.
  func testComposerAndChipTargetsAreAtLeast44Points() {
    let app = connectedHost(["-uiTestingPendingTranscript"])

    // Named, not by position, because the section re-sorts. Only "needs a decision" has a
    // pending chip. The Needs-you row, because its focused composer puts Send on screen.
    waitForBothBlockedPanes(app)
    blockedPaneRow(app, titled: "needs a decision").tap()
    require(app, "pane.chat", "Expected the pane to open on its chat")

    let send = require(app, "composer.send", "Expected the send button")
    let approve = require(
      app, "pane.chat.turn.pending.chip.Approve", "Expected an Approve chip under the turn")

    for (name, element) in [("composer.send", send), ("chip.Approve", approve)] {
      XCTAssertGreaterThanOrEqual(element.frame.height, 44, "\(name) is under 44 pt tall: \(element.frame)")
      XCTAssertGreaterThanOrEqual(element.frame.width, 44, "\(name) is under 44 pt wide: \(element.frame)")
    }

    // An upper bound too, because 44 pt is a floor for a target, not a size to draw. A
    // bordered style sizes its chrome around a 44 pt label and draws a 58 pt control.
    XCTAssertLessThanOrEqual(
      send.frame.width,
      48,
      "composer.send has grown past its 44 pt target — it is a floor, not a size: \(send.frame)"
    )

    // The same for the chips, which drew about 60 pt for a two-word answer.
    XCTAssertLessThanOrEqual(
      approve.frame.height,
      52,
      "chip.Approve is drawing its 44 pt target rather than meeting it: \(approve.frame)"
    )
  }

  /// Status is legible without hearing a colour.
  func testStatusIsSpokenAsWordsNotColours() {
    let app = connectedHost()

    // `checkmark.circle` brings its own element announced as "Selected". The badge must be
    // one element, saying the word, with no selected trait.
    let connected = element(app, "connect.connected")
    XCTAssertEqual(connected.label, "Connected", "Tree was:\n\(app.debugDescription)")
    XCTAssertFalse(connected.isSelected, "The connected badge announces itself as selected")
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "connect.connected").count,
      1,
      "The connected badge publishes more than one element.\nTree was:\n\(app.debugDescription)"
    )

    require(app, "session.workspace", "Expected the session tree")

    // The badge is a coloured glyph, so what VoiceOver says must carry the meaning.
    let blocked = element(app, "status.blocked")
    XCTAssertTrue(blocked.waitForExistence(timeout: 10), "Expected a blocked badge")
    XCTAssertEqual(
      blocked.label,
      "Waiting for you",
      "A blocked agent must announce itself in words.\nTree was:\n\(app.debugDescription)"
    )

    // The row is the Reply control, so it meets the 44 pt floor. Named, not by position,
    // because `firstMatch` can report a row that is mid-reorder.
    waitForBothBlockedPanes(app)
    let blockedRow = blockedPaneRow(app, titled: "needs a decision")
    XCTAssertGreaterThanOrEqual(
      blockedRow.frame.height,
      44,
      "The blocked-pane reply target is under 44 pt tall: \(blockedRow.frame)"
    )
  }

  /// The app is usable at the largest accessibility text size.
  ///
  /// Catches a label that pushes a control off the screen. The terminal is exempt, because
  /// it has its own font-size setting.
  func testTheAppWorksAtTheLargestAccessibilityTextSize() {
    // Prove the size took. UIKit silently ignores an unrecognised category name, and every
    // check below would then pass at the default size. A default-size launch gives the
    // baseline.
    //
    // No stored password, so the password field and Connect are drawn at all.
    let baselineApp = launch(seedingConnection: false)
    let baselineRow = require(baselineApp, "hosts.row", "Expected the seeded host at default size")
    let baselineRowHeight = baselineRow.frame.height
    baselineApp.terminate()

    let app = launch(
      textSize: "UICTContentSizeCategoryAccessibilityXXXL",
      seedingConnection: false
    )

    let row = require(app, "hosts.row", "Expected the seeded host at accessibility size")
    XCTAssertTrue(row.isHittable, "The host row is on screen but not reachable")
    XCTAssertGreaterThan(
      row.frame.height,
      baselineRowHeight,
      "The host row is \(row.frame.height)pt tall at accessibility size, no taller than the "
        + "\(baselineRowHeight)pt default — the content-size category did not take."
    )
    row.tap()

    require(app, "connect.password", "Expected the password field").tap()
    app.typeText("hunter2")
    // Scrolled to, because at this size Connect is below what SwiftUI has built.
    let connect = requireAfterScrolling(app, "connect.connect", "Expected the connect button")
    // Once built, the keyboard covers it, so swipe it clear as a finger would.
    for _ in 0..<8 where !connect.isHittable { app.swipeUp() }
    XCTAssertTrue(
      connect.isHittable,
      "The connect button is not reachable at this size, even after a scroll to clear "
        + "the keyboard. frame: \(connect.frame) window: \(app.windows.firstMatch.frame)\n"
        + "Tree was:\n\(app.debugDescription)"
    )
    connect.tap()
    // First contact, because the key and password are seeded together or not at all
    // (`AppEnvironment.isSeedingConnection`). Wait for Trust before scrolling for it; the
    // wrapped fingerprint can push it below the fold.
    let trust = require(app, "hostkey.trust", "Expected the trust prompt on first contact")
    for _ in 0..<8 where !trust.isHittable { app.swipeUp() }
    XCTAssertTrue(
      trust.isHittable,
      "The trust prompt's button never came into reach at this size.\n"
        + "Tree was:\n\(app.debugDescription)"
    )
    // On `Driverr iPad` the prompt is a form sheet that settles after it arrives. See
    // `waitUntilStill`.
    waitUntilStill(app, trust, waitingForKeyboard: false)
    trust.tap()

    // The session still renders and the blocked pane is reachable.
    requireAfterScrolling(app, "session.workspace", "Expected the session tree at accessibility size")

    // The blocked pane sits above the tree, so scroll back up for it.
    for _ in 0..<15 { app.swipeDown() }
    // By name, because the section's order is not fixed.
    let pane = blockedPaneRow(app, titled: "needs a decision")
    XCTAssertTrue(pane.isHittable, "The blocked pane is not reachable at this size")

    // The pane screen's chrome is asserted reachable, not only present. Opened from the tree
    // row, because the Needs-you row brings a keyboard that covers most of the screen.
    treePaneRow(app, titled: "needs a decision").tap()
    let segment = require(app, "pane.surface.terminal", "Expected the segment at this size")
    XCTAssertTrue(segment.isHittable, "The Terminal segment is not reachable at this size")
    let header = require(app, "pane.chat.header", "Expected the provenance header")
    XCTAssertTrue(header.isHittable, "The provenance header is not reachable at this size")

    let turn = require(app, "pane.chat.turn.assistant", "Expected the agent's turn")
    XCTAssertTrue(turn.isHittable, "The agent's turn is not reachable at this size")

    // On a blocked pane the unfocused composer is the field and Send.
    let field = require(app, "composer.text", "Expected the composer at accessibility size")
    XCTAssertTrue(field.isHittable, "The composer's field is not reachable at this size")
    let send = require(app, "composer.send", "Expected the send button")
    XCTAssertTrue(send.isHittable, "The send button is not reachable at this size")
    XCTAssertFalse(
      field.frame.intersects(send.frame),
      "Send is on top of the field at this size: field \(field.frame), send \(send.frame)"
    )

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "accessibility-text-size"
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// Settings is where selection is conveyed by a checkmark, which VoiceOver cannot see.
  func testSettingsAnnouncesWhichOptionIsSelected() {
    let app = launch()

    openHostsOverflow(app)
    require(app, "settings.open", "Expected a way into settings").tap()
    require(app, "settings.theme.system", "Expected the theme rows")

    // Exactly one theme row carries the selected trait.
    let themes = ["settings.theme.system", "settings.theme.solarized", "settings.theme.nord"]
    let selected = themes.filter { element(app, $0).isSelected }
    XCTAssertEqual(
      selected.count,
      1,
      "Expected exactly one theme to be marked selected, got \(selected).\n"
        + "Tree was:\n\(app.debugDescription)"
    )
  }

  /// The working row is outside a scrolled-back reader's accessibility tree, which is why the
  /// app announces it.
  ///
  /// The transcript is a `UICollectionView`, which realises only visible cells, and the row
  /// lands at the end, away from a reader up in the history.
  ///
  /// The absence is proved against a row known to exist: scroll back, take the way back and
  /// read the row, then scroll back again and wait for it to go. The announcement itself
  /// leaves nothing in the tree; `ChatActivityAnnouncement` decides it, in `swift test`.
  func testTheWorkingRowIsOutsideAScrolledBackReadersTree() {
    let app = connectedHost([
      "-uiTestingBoundedTranscript", "-uiTestingSlowTranscript", "-uiTestingAgentStartsWorking",
    ])

    // The tree row, so no keyboard covers the conversation this test scrolls.
    treePaneRow(app, titled: "terminal wiring").tap()
    let chat = require(app, "pane.chat", "Expected the conversation")
    require(app, "pane.chat.turn.assistant", "Expected the agent's turn")
    // Let the slow transcript land and the chat settle before dragging.
    usleep(2_500_000)

    let activity = element(app, "pane.chat.activity")
    let jump = element(app, "pane.chat.jumpToLatest")

    scrollBack(app, chat)
    XCTAssertTrue(
      jump.exists,
      """
      The drag never took the reader off the end, so nothing below is a result about a reader \
      who has scrolled back. Chat \(chat.frame).
      Tree was:
      \(app.debugDescription)
      """)

    // Bounded, as in `PaneChatUITests.testAReaderScrolledBackIsNotMovedByANewWorkingRow`:
    // nothing this reader can see marks the flip, ten seconds after the stream opens.
    let deadline = Date().addingTimeInterval(18)
    while Date() < deadline && !activity.exists {
      usleep(250_000)
    }

    // The way back realises the cell, and proves the agent did start.
    XCTAssertTrue(
      jump.exists,
      "The reader lost the way back to the end.\nTree was:\n\(app.debugDescription)")
    jump.tap()
    let visible = require(
      app,
      "pane.chat.activity",
      """
      The agent never started working, so this test can say nothing about what a scrolled-back \
      reader can reach. Taking the way back to the end is what realises the row's cell.
      """,
      timeout: 15
    )

    // On screen, it reads as a sentence, not empty and not a symbol name.
    let label = visible.label
    XCTAssertFalse(
      label.isEmpty,
      "The working row is in the tree with no label at all.\nTree was:\n\(app.debugDescription)")
    XCTAssertFalse(
      looksLikeASymbolName(label),
      "The working row is announced as the SF Symbol name '\(label)'.\n"
        + "Tree was:\n\(app.debugDescription)")

    // The claim: back in the history, the row leaves the tree with its cell.
    scrollBack(app, chat)
    requireGone(
      app,
      "pane.chat.activity",
      """
      A reader scrolled back through the history can still reach the working row, which would \
      mean the working-row announcement is compensating for a limit that no longer exists. If \
      this fails because a collection view now realises cells past the viewport, the \
      announcement is redundant and `PaneChatView`'s posting can go — read it as news rather \
      than as a bug.
      """
    )
  }

  /// One drag off the end of the conversation, inside it, because `app.swipeDown()` starts
  /// on the composer.
  private func scrollBack(_ app: XCUIApplication, _ chat: XCUIElement) {
    let start = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.20))
    let end = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
    start.press(forDuration: 0.4, thenDragTo: end)
    usleep(2_000_000)
  }

  /// Polls until `identifier` is gone. XCUITest sees through a presentation and a push, so
  /// absence has to be waited for.
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
        "\(message)\n'\(identifier)' was still there after \(timeout)s.\n"
          + "Tree was:\n\(app.debugDescription)",
        file: file,
        line: line
      )
      return
    }
  }
}
