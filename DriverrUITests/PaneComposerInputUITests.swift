import XCTest

/// What the composer offers while typing: slash-command suggestions, the host's installed
/// skills, arrow-key navigation over the suggestions, the pending attachment and saved prompts.
///
/// `PaneComposerUITests` covers where the bar is drawn and what a send does. The shared
/// helpers are `PaneComposerUITestCase`.
///
/// Relaunches per test: connecting records a trust decision and leaves a pane scene open, and
/// the saved-prompt tests save prompts that outlive the test.
@MainActor
final class PaneComposerInputUITests: PaneComposerUITestCase {
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

  /// Choosing a command whose whole name is already typed closes the list.
  ///
  /// The field never reports the caret a completion hands it, so the list has to learn it
  /// from `PaneComposerBar.choose` itself. Read from before the completion, the caret sits
  /// at the end of the typed name, ahead of the inserted space, and the list reopens on a
  /// finished command.
  func testChoosingAFullyTypedCommandClosesTheList() {
    let app = composerOnACommandTranscript()

    let field = require(app, "composer.text", "Expected the composer field")
    field.tap()
    app.typeText("/code-review")

    let row = require(app, "composer.suggestions.row.0", "Expected /code-review to be offered")
    XCTAssertEqual(row.label, "/code-review", "Expected the typed command first")
    row.tap()

    XCTAssertEqual(
      field.value as? String,
      "/code-review ",
      "Choosing must add only the trailing space. Field held: \(String(describing: field.value))"
    )
    requireGone(
      app,
      "composer.suggestions.row.0",
      "The list must close once a command has been chosen, even one typed in full"
    )
  }

  /// A `/word` after prose offers commands, and choosing one replaces only that word.
  ///
  /// Mid-sentence, Claude Code sends a built-in as prose, so the fixture's built-in
  /// `/compact`, offered for a leading `/co`, must be missing here. The token and splice
  /// rules are `SlashTokenTests` and `SlashCompletionTests`.
  func testAMidSentenceSlashOffersCommandsAndChoosingKeepsTheSentence() {
    let app = composerOnACommandTranscript()

    let field = require(app, "composer.text", "Expected the composer field")
    field.tap()
    app.typeText("fix this /co")

    require(app, "composer.suggestions.row.0", "A /word after prose must offer commands")
    let offered = offeredCommands(app)
    XCTAssertEqual(
      offered,
      ["/code-review", "/commit"],
      "Mid-sentence /co must offer the session's own commands and no built-in: \(offered)"
    )

    app.typeText("de")
    let row = require(app, "composer.suggestions.row.0", "Expected /code to offer a command")
    let chosen = row.label
    row.tap()

    XCTAssertEqual(
      field.value as? String,
      "fix this " + chosen + " ",
      """
      Choosing a suggestion mid-sentence must replace only the /word and keep the sentence.
      Field held: \(String(describing: field.value))
      """
    )
    requireGone(
      app,
      "composer.suggestions.row.0",
      "The list must close once a command has been chosen"
    )
  }

  /// With text after the `/word`, choosing keeps that text and leaves the caret after the
  /// command, not at the end of the field. The next keystroke shows where the caret is.
  func testChoosingBeforeLaterTextLeavesTheCaretAfterTheCommand() {
    let app = composerOnACommandTranscript()

    let field = require(app, "composer.text", "Expected the composer field")
    field.tap()
    app.typeText("fix /co more")
    // Back over " more", to the end of "/co".
    for _ in 0..<5 { app.typeKey(.leftArrow, modifierFlags: []) }

    let row = require(
      app, "composer.suggestions.row.0", "A caret at the end of /co must offer commands")
    XCTAssertEqual(row.label, "/code-review", "Expected /code-review first for /co")
    row.tap()

    XCTAssertEqual(
      field.value as? String,
      "fix /code-review more",
      """
      Choosing must replace only /co and reuse the space after it.
      Field held: \(String(describing: field.value))
      """
    )
    app.typeText("X")
    XCTAssertEqual(
      field.value as? String,
      "fix /code-review Xmore",
      """
      The caret must sit after the command and its space, where an argument goes.
      Field held: \(String(describing: field.value))
      """
    )
  }

  /// A fast burst of keys arrives whole once the field has reported a caret.
  ///
  /// When a burst's first key puts UIKit into hardware-keyboard mode, the key queue is held
  /// for a few tens of milliseconds and the keys pile up behind it. A field handed back a
  /// selection it had already reported drained that queue mid-update and wrote stale text
  /// over the drained keys: five to seven of these 36 went missing, in 8 of 8 launches on
  /// `Driverr iPad`. See `PaneComposerBar.reportedSelection`.
  ///
  /// One key first, so the field has a caret to report. A burst into a field that has not
  /// reported one arrived whole even with the old binding, so it cannot fail. The software
  /// keyboard leaves when typing starts and comes back within a second; the burst waits for
  /// it, so its first key flips the mode again.
  func testAFastBurstArrivesIntact() {
    let app = composerOnACommandTranscript()

    let field = require(app, "composer.text", "Expected the composer field")
    field.tap()
    app.typeText("_")
    XCTAssertTrue(
      app.keyboards.firstMatch.waitForExistence(timeout: 10),
      "Expected the software keyboard back after the first key"
    )
    let burst = "abcdefghijklmnopqrstuvwxyz0123456789"
    app.typeText(burst)

    XCTAssertEqual(
      field.value as? String,
      "_" + burst,
      "Every key of a fast burst must reach the field. Field held: \(String(describing: field.value))"
    )

    // The other path: straight after a completion from the `/` list, the one time the field
    // is handed a caret. A caret still being handed over when the burst lands is the same
    // loss.
    app.typeText(" /co")
    let row = require(app, "composer.suggestions.row.0", "A /word after prose must offer commands")
    let chosen = row.label
    row.tap()
    XCTAssertTrue(
      app.keyboards.firstMatch.waitForExistence(timeout: 10),
      "Expected the software keyboard after choosing"
    )
    app.typeText(burst)

    XCTAssertEqual(
      field.value as? String,
      "_" + burst + " " + chosen + " " + burst,
      """
      Every key of a burst typed after a completion must reach the field.
      Field held: \(String(describing: field.value))
      """
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

  /// Up and Down still reach the list when the field has wrapped onto a second line.
  ///
  /// A mid-sentence token can sit at the end of wrapped text, where the field could take Up
  /// to move its caret a line up. That would move the caret off the token and close the list,
  /// so the check is that the highlight moved, the list is still up, and the text is unchanged.
  func testArrowKeysMoveTheHighlightWhenTheFieldHasWrapped() {
    let app = composerOnACommandTranscript()

    let field = require(app, "composer.text", "Expected the composer field")
    field.tap()
    let oneLine = field.frame.height
    // About 140 characters, so it wraps in the iPad's chat column as well as on a phone. The
    // 64 this used to type fit on one line in that column, and the test measured nothing.
    let text =
      "please look at the retry path again, then read the timeout handling in the uploader "
      + "and the reconnect loop, and when all of that is done run /"
    app.typeText(text)
    require(app, "composer.suggestions.row.0", "A trailing / must offer commands")
    // Measured once every key has landed, so the height is the whole text's.
    XCTAssertEqual(field.value as? String, text, "Expected the whole text in the field")
    XCTAssertGreaterThan(
      field.frame.height,
      oneLine * 1.5,
      "The text must wrap, or this test measures the one-line case. Height \(field.frame.height)"
    )

    app.typeKey(.downArrow, modifierFlags: [])
    XCTAssertEqual(highlightedRows(app), [0], "Down must highlight the first row.")

    app.typeKey(.upArrow, modifierFlags: [])
    XCTAssertEqual(
      highlightedRows(app),
      [SlashCommandRowLimit.maximum - 1],
      """
      Up from the first row must wrap to the last, not move the field's caret up a line.
      Tree was:
      \(app.debugDescription)
      """
    )
    XCTAssertEqual(
      field.value as? String,
      text,
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

extension PaneComposerInputUITests {
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
    pickFromTheAttachMenu(app, "composer.attach.photos")

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
    pickFromTheAttachMenu(app, "composer.attach.photos")

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

    pickFromTheAttachMenu(app, "composer.attach.photos")

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

  /// Opens the Attach menu and picks `item` from it: `composer.attach.photos` or
  /// `composer.attach.files`.
  private func pickFromTheAttachMenu(_ app: XCUIApplication, _ item: String) {
    require(app, "composer.attach", "Expected an attach control").tap()
    require(app, item, "Expected \(item) in the attach menu").tap()
  }

  /// Files hands a picked file to the same row and the same upload, and the row names it.
  ///
  /// `-uiTestingPickedFile` stands in for the document picker, which runs out of process. The
  /// app writes "build log.txt" itself, so the read and the remote name run on a real file.
  func testAPickedFileGetsARowThatSettlesOnceThePaneHasIt() {
    let app = composerWithAPickedImage(["-uiTestingPickedFile"])
    pickFromTheAttachMenu(app, "composer.attach.files")

    let row = require(app, "composer.attachment.row", "Expected a row for the picked file")
    XCTAssertEqual(
      row.label, "File",
      "A file's glyph says File; its name is the text beside it.\nTree was:\n"
        + app.debugDescription
    )
    // On screen, not only in the label: a `doc` glyph cannot say which file it is.
    let name = require(app, "composer.attachment.name", "Expected the row to show the file's name")
    XCTAssertEqual(name.label, "build log.txt", "The row shows the name the file was picked as")
    let progress = require(app, "composer.attachment.progress", "Expected the row's status")
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline && !progress.label.contains(Self.handedOverNotice) {
      usleep(150_000)
    }
    XCTAssertTrue(
      progress.label.contains(Self.handedOverNotice),
      "Expected the row to report the hand-off, got '\(progress.label)'.\nTree was:\n"
        + app.debugDescription
    )
    requireGone(app, "composer.attachment.failure", "A readable file must not fail")
  }

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
    pickFromTheAttachMenu(app, "composer.attach.photos")
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
    pickFromTheAttachMenu(app, "composer.attach.photos")

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

  // MARK: - Saved prompts

  /// Opens a blocked pane, focuses the field and opens the saved list. The list's button is
  /// in the card, which the focus brings.
  private func composerWithSavedPrompts(_ launchArguments: [String] = []) -> XCUIApplication {
    let app = connectedHost(launchArguments)
    treePaneRow(app, titled: "needs a decision").tap()
    require(app, "composer.text", "Expected the composer").tap()
    return app
  }

  private func openSavedPrompts(_ app: XCUIApplication) {
    require(app, "composer.prompts", "Expected a saved prompts button in the card").tap()
    require(app, "composer.prompts.dismiss", "Expected the saved list to open over the card")
  }

  /// Nothing in the field changed after an insert was sent: a send clears the field and
  /// brings the conversation's foot back saying "Sent".
  private func requireNotSent(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let activity = element(app, "pane.chat.activity")
    if activity.exists {
      XCTAssertFalse(
        activity.label.contains("Sent"),
        "Inserting a saved prompt must not send it. The conversation said: \(activity.label)",
        file: file,
        line: line
      )
    }
  }

  /// The field's text is saved from the list's header, shows at the top of the list, and a
  /// tap on it appends it to the field after one space without sending anything.
  ///
  /// Starts with nothing saved, so the empty sentence and the save are both this test's own.
  func testSavingTheFieldThenInsertingItAppendsWithoutSending() {
    let app = composerWithSavedPrompts()
    app.typeText("check the build")
    openSavedPrompts(app)
    require(app, "composer.prompts.empty", "Expected the list to say nothing is saved yet")

    require(app, "composer.prompts.save", "Expected Save current text").tap()

    let row = require(app, "composer.prompts.row.0", "Expected the saved text as the first row")
    XCTAssertEqual(row.label, "check the build", "The row is named after the saved text")
    requireGone(app, "composer.prompts.empty", "The empty sentence must go once a prompt is saved")
    XCTAssertFalse(
      element(app, "composer.prompts.save").isEnabled,
      "Save must be off for text that is already saved")

    row.tap()

    let field = element(app, "composer.text")
    XCTAssertEqual(
      field.value as? String,
      "check the build check the build",
      "An insert appends after one space. Field held: \(String(describing: field.value))"
    )
    requireGone(app, "composer.prompts.dismiss", "The list must close after an insert")
    requireNotSent(app)
  }

  /// Rename is inline, from the row's menu: the field takes the name over, and Done puts the
  /// new name on the same row.
  func testRenamingASavedPromptRetitlesItsRow() {
    let app = composerWithSavedPrompts(["-uiTestingSavedPrompts"])
    openSavedPrompts(app)
    XCTAssertEqual(
      require(app, "composer.prompts.row.1", "Expected the second seeded prompt").label,
      "Review the diff")

    require(app, "composer.prompts.row.1.more", "Expected the row's menu").tap()
    require(app, "composer.prompts.rename", "Expected Rename in the row's menu").tap()

    let field = require(app, "composer.prompts.rename.field", "Expected an inline rename field")
    // The field takes focus itself and selects the whole name; the deletes clear whatever is
    // left if the selection had not landed when the keys arrived.
    waitUntilStill(app, field)
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + "Diff check")
    require(app, "composer.prompts.rename.done", "Expected Done").tap()

    requireGone(app, "composer.prompts.rename.field", "Done must close the rename field")
    let renamed = require(app, "composer.prompts.row.1", "Expected the renamed row in its place")
    XCTAssertEqual(renamed.label, "Diff check", "Rename must retitle the row it was opened on")
    XCTAssertEqual(
      element(app, "composer.prompts.row.0").label, "Run the tests",
      "Rename must leave the other row alone")
    XCTAssertEqual(
      element(app, "composer.text").value as? String ?? "", "",
      "Rename must not touch the composer's text")
  }

  /// A rename field that loses the keyboard some other way than Done or Cancel ends the
  /// rename unsaved. Here a tap on the composer's field takes the keyboard: the rename field
  /// goes, the row keeps its name, and the keyboard stays with the composer.
  ///
  /// Left running, the rename would keep reporting the composer as focused to the chat with
  /// no field holding the keyboard.
  func testTheRenameEndsWhenItsFieldLosesTheKeyboard() {
    let app = composerWithSavedPrompts(["-uiTestingSavedPrompts"])
    openSavedPrompts(app)
    require(app, "composer.prompts.row.1.more", "Expected the row's menu").tap()
    require(app, "composer.prompts.rename", "Expected Rename in the row's menu").tap()

    let renameField = require(app, "composer.prompts.rename.field", "Expected a rename field")
    let renameFocused = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: renameField)
    XCTAssertEqual(
      XCTWaiter().wait(for: [renameFocused], timeout: 5), .completed,
      "Expected the rename field to take the keyboard first")

    let composer = element(app, "composer.text")
    composer.tap()

    requireGone(
      app, "composer.prompts.rename.field",
      "The rename must end when its field loses the keyboard")
    let composerFocused = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: composer)
    XCTAssertEqual(
      XCTWaiter().wait(for: [composerFocused], timeout: 5), .completed,
      "The keyboard must stay with the composer's field")
    XCTAssertEqual(
      require(app, "composer.prompts.row.1", "Expected the list back").label,
      "Review the diff",
      "A rename that ended this way must not save")
  }

  /// Delete, from the row's menu, removes that prompt and only that one.
  func testDeletingASavedPromptRemovesItsRow() {
    let app = composerWithSavedPrompts(["-uiTestingSavedPrompts"])
    openSavedPrompts(app)
    require(app, "composer.prompts.row.1", "Expected two seeded prompts")

    require(app, "composer.prompts.row.0.more", "Expected the row's menu").tap()
    require(app, "composer.prompts.delete", "Expected Delete in the row's menu").tap()

    requireGone(app, "composer.prompts.row.1", "Delete must leave one row")
    XCTAssertEqual(
      require(app, "composer.prompts.row.0", "Expected the other prompt to stay").label,
      "Review the diff",
      "Delete must remove the prompt it was opened on")
  }
}

/// `SlashCommandMatcher.maximumSuggestions`, restated because the UI test bundle does not
/// link `DriverrKit`.
private enum SlashCommandRowLimit {
  static let maximum = 3
}
