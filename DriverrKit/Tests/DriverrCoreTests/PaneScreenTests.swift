import Testing

@testable import DriverrCore

/// The boundary that stops remote bytes reaching a `Text`. Sanitising is the safety half:
/// nothing but printable characters survives, and no line is unbounded. Marking is the
/// honesty half: most real screens carry no marker, so a missing one is the ordinary answer
/// and inventing one is the only unrecoverable error.
@Suite("PaneScreen")
struct PaneScreenTests {

  // MARK: - Sanitising

  @Test("SGR becomes a style, and no escape survives as text")
  func stylesRatherThanEscapes() {
    let screen = PaneScreen.sanitised("\u{1B}[38;5;15mhello\u{1B}[0m", lines: 10)

    #expect(screen.lines.count == 1)
    #expect(screen.text == "hello")
    #expect(screen.lines[0].spans.count == 1)
    #expect(screen.lines[0].spans[0].text == "hello")
    #expect(screen.lines[0].spans[0].style.foreground == .brightWhite)
  }

  @Test("a style change starts a new span, and a reset ends it")
  func spansSplitOnStyleChange() {
    let screen = PaneScreen.sanitised("\u{1B}[38;5;7m⏺ \u{1B}[0mReading a file", lines: 10)

    #expect(screen.lines[0].spans.count == 2)
    #expect(screen.lines[0].spans[0].text == "⏺ ")
    #expect(screen.lines[0].spans[0].style.foreground == .white)
    #expect(screen.lines[0].spans[1].text == "Reading a file")
    #expect(screen.lines[0].spans[1].style == .plain)
  }

  @Test("bold, dim and italic are the whole of the attribute vocabulary")
  func attributes() {
    let screen = PaneScreen.sanitised("\u{1B}[1mB\u{1B}[22m\u{1B}[2mD\u{1B}[0m\u{1B}[3mI\u{1B}[0m", lines: 10)

    let spans = screen.lines[0].spans
    #expect(spans.map(\.text) == ["B", "D", "I"])
    #expect(spans[0].style.isBold)
    #expect(!spans[0].style.isDim)
    #expect(spans[1].style.isDim)
    #expect(!spans[1].style.isBold)
    #expect(spans[2].style.isItalic)
  }

  @Test("basic, bright and 256-colour forms map to the same sixteen names")
  func colourForms() {
    #expect(PaneScreen.sanitised("\u{1B}[31mx", lines: 1).lines[0].spans[0].style.foreground == .red)
    #expect(PaneScreen.sanitised("\u{1B}[38;5;1mx", lines: 1).lines[0].spans[0].style.foreground == .red)
    #expect(PaneScreen.sanitised("\u{1B}[91mx", lines: 1).lines[0].spans[0].style.foreground == .brightRed)
    #expect(PaneScreen.sanitised("\u{1B}[38;5;9mx", lines: 1).lines[0].spans[0].style.foreground == .brightRed)
    #expect(PaneScreen.sanitised("\u{1B}[48;5;8mx", lines: 1).lines[0].spans[0].style.background == .brightBlack)
    #expect(PaneScreen.sanitised("\u{1B}[100mx", lines: 1).lines[0].spans[0].style.background == .brightBlack)
  }

  /// The theme owns the palette, so a nearest match would invent a colour the pane never
  /// showed.
  @Test("a colour outside the named sixteen is dropped, not guessed")
  func unnameableColoursAreDropped() {
    #expect(PaneScreen.sanitised("\u{1B}[38;5;200mx", lines: 1).lines[0].spans[0].style.foreground == nil)
    #expect(
      PaneScreen.sanitised("\u{1B}[38;2;185;185;185mx", lines: 1).lines[0].spans[0].style.foreground == nil
    )
  }

  /// `PaneScreenColor` maps a 256-colour index by case position, so reordering its cases
  /// would repaint every screen.
  @Test("every named palette index maps to the colour that terminals number it")
  func paletteIndicesAreTheAnsiOrder() {
    let expected: [PaneScreenColor] = [
      .black, .red, .green, .yellow, .blue, .magenta, .cyan, .white,
      .brightBlack, .brightRed, .brightGreen, .brightYellow,
      .brightBlue, .brightMagenta, .brightCyan, .brightWhite,
    ]
    for (index, colour) in expected.enumerated() {
      #expect(
        PaneScreen.sanitised("\u{1B}[38;5;\(index)mx", lines: 1).lines[0].spans[0].style.foreground
          == colour,
        "palette index \(index)"
      )
    }
    #expect(PaneScreen.sanitised("\u{1B}[38;5;16mx", lines: 1).lines[0].spans[0].style.foreground == nil)
  }

  /// A parser that skipped `38` alone would read `5` as blink and `200` as text.
  @Test("an unnameable colour's parameters do not leak into the text")
  func extendedColourParametersAreConsumed() {
    let screen = PaneScreen.sanitised("\u{1B}[38;2;1;2;3mx\u{1B}[48;5;200my", lines: 1)

    #expect(screen.text == "xy")
  }

  @Test("a cursor-movement sequence is dropped without eating the text around it")
  func nonSGRSequencesAreDropped() {
    let screen = PaneScreen.sanitised("\u{1B}[2Jhello\u{1B}[1;1Hthere\u{1B}[?25l!", lines: 10)

    #expect(screen.text == "hellothere!")
  }

  @Test("an OSC sequence takes its payload with it")
  func oscPayloadIsDropped() {
    #expect(PaneScreen.sanitised("\u{1B}]0;a title\u{07}ok", lines: 10).text == "ok")
    #expect(PaneScreen.sanitised("\u{1B}]8;;https://example.com\u{1B}\\link", lines: 10).text == "link")
  }

  @Test("a sequence the far side never terminated cannot leak the rest of the line")
  func unterminatedSequence() {
    #expect(PaneScreen.sanitised("safe\u{1B}[38;5;", lines: 10).text == "safe")
    #expect(PaneScreen.sanitised("safe\u{1B}]0;never ended", lines: 10).text == "safe")
    #expect(PaneScreen.sanitised("safe\u{1B}", lines: 10).text == "safe")
  }

  @Test("a bare control character never survives")
  func controlCharactersAreDropped() {
    let screen = PaneScreen.sanitised("a\u{00}b\u{07}c\u{7F}d\u{08}e\u{0D}f\u{9B}g", lines: 10)

    #expect(screen.text == "abcdefg")
  }

  @Test("a tab is expanded to the next eight-column stop")
  func tabsBecomeSpaces() {
    #expect(PaneScreen.sanitised("a\tb", lines: 10).text == "a       b")
    #expect(PaneScreen.sanitised("\tx", lines: 10).text == "        x")
  }

  @Test("no capture of a real pane leaves an escape or a control character behind")
  func realCapturesAreClean() {
    for capture in PaneScreenFixture.all {
      let text = PaneScreen.sanitised(capture, lines: 200).text
      #expect(!text.unicodeScalars.contains { $0.value == 0x1B })
      #expect(
        !text.unicodeScalars.contains {
          ($0.value < 0x20 && $0 != "\n") || $0.value == 0x7F || (0x80...0x9F).contains($0.value)
        }
      )
    }
  }

  // MARK: - Bounds

  /// A terminal cannot produce an unbounded line, but what arrives is whatever the far side
  /// sent.
  @Test("an over-long line is bounded here, not by the view")
  func longLinesAreBounded() {
    let screen = PaneScreen.sanitised(String(repeating: "x", count: 5000), lines: 10)

    #expect(screen.lines.count == 1)
    #expect(screen.lines[0].text.count == PaneScreen.maximumLineLength)
    #expect(screen.lines[0].isTruncated)
  }

  @Test("a line that fits is not marked as truncated")
  func shortLinesAreNotTruncated() {
    #expect(!PaneScreen.sanitised("short", lines: 10).lines[0].isTruncated)
  }

  /// A line of escapes must not smuggle a megabyte past the bound.
  @Test("the length bound counts rendered characters, not bytes on the wire")
  func boundCountsRenderedCharacters() {
    let styled = String(repeating: "\u{1B}[38;5;7mx\u{1B}[0m", count: 5000)

    #expect(PaneScreen.sanitised(styled, lines: 10).lines[0].text.count == PaneScreen.maximumLineLength)
  }

  @Test("only the last lines asked for come back")
  func lineLimit() {
    let screen = PaneScreen.sanitised("one\ntwo\nthree\nfour", lines: 2)

    #expect(screen.lines.map(\.text) == ["three", "four"])
  }

  @Test("a screen taller than any reply surface is bounded whatever was asked for")
  func absoluteLineCeiling() {
    let tall = (1...500).map(String.init).joined(separator: "\n")

    #expect(PaneScreen.sanitised(tall, lines: 10_000).lines.count == PaneScreen.maximumLines)
  }

  @Test("trailing blank rows are dropped, and interior ones are kept")
  func trailingBlanksAreDropped() {
    let screen = PaneScreen.sanitised("a\n\nb\n   \n\n", lines: 10)

    #expect(screen.lines.map(\.text) == ["a", "", "b"])
  }

  /// A blank screen is an empty value; a refusal is `CLIControl`'s to throw.
  @Test("an empty read is an empty screen rather than a screen with a blank line in it")
  func emptyReadIsEmpty() {
    #expect(PaneScreen.sanitised("", lines: 10).isEmpty)
    #expect(PaneScreen.sanitised("\n\n\n", lines: 10).isEmpty)
    #expect(PaneScreen.blank.isEmpty)
  }

  // MARK: - Marking the agent's message

  /// Row 42 carries the same `⏺` glyph but is a tool call, foreground 7 rather than 15.
  @Test("the last assistant message is marked, and a tool call wearing the same glyph is not")
  func marksTheLastAssistantMessage() throws {
    let screen = PaneScreen.sanitised(PaneScreenFixture.claudeCodeAssistantMessage, lines: 200)

    let message = try #require(screen.agentMessage)
    let marked = screen.lines[message].map(\.text)
    #expect(marked.first == "⏺ I'll start by reading the plan,")
    #expect(
      marked == [
        "⏺ I'll start by reading the plan,",
        "  then the guide for contributors,",
        "  (already loaded above) and the two",
        "  test files the plan names.",
      ]
    )

    let toolCall = try #require(screen.lines.firstIndex { $0.text.hasPrefix("⏺ Reading") })
    #expect(screen.lines[toolCall].marker == nil)
  }

  /// The only record glyph here is a system notice, foreground 11.
  @Test("a system notice wearing the record glyph is never the agent's message")
  func systemNoticeIsNotAMessage() {
    let screen = PaneScreen.sanitised(PaneScreenFixture.claudeCodeSystemNoticeOnly, lines: 200)

    #expect(screen.lines.contains { $0.text.contains("Remote Control disconnected") })
    #expect(screen.agentMessage == nil)
    #expect(screen.lines.allSatisfy { $0.marker == nil })
  }

  /// Most agent kinds have no table, and a cleared pane has nothing on it.
  @Test("a screen with no record glyph carries no marker and no claim")
  func noGlyphNoClaim() {
    let screen = PaneScreen.sanitised(PaneScreenFixture.claudeCodeFreshSession, lines: 200)

    #expect(!screen.isEmpty)
    #expect(screen.agentMessage == nil)
    #expect(screen.lines.allSatisfy { $0.marker == nil })
  }

  @Test("an agent kind Driverr has never seen renders with no marker at all")
  func unknownAgentKind() {
    let screen = PaneScreen.sanitised("gemini> thinking\nsome output\ngemini> done", lines: 10)

    #expect(screen.lines.count == 3)
    #expect(screen.agentMessage == nil)
  }

  @Test("an earlier message is not marked once a later one exists")
  func onlyTheLastMessage() throws {
    let screen = PaneScreen.sanitised(
      """
      \u{1B}[0m\u{1B}[38;5;15m⏺ \u{1B}[0mfirst
      \u{1B}[0m\u{1B}[38;5;15m⏺ \u{1B}[0msecond
      """,
      lines: 10
    )

    let message = try #require(screen.agentMessage)
    #expect(screen.lines[message].map(\.text) == ["⏺ second"])
    #expect(screen.lines[0].marker == nil)
  }

  /// A message that began above the fold is unrecoverable, so continuation lines alone get
  /// no marker.
  @Test("continuation lines with no glyph above them are never a message on their own")
  func continuationWithoutAGlyph() {
    let screen = PaneScreen.sanitised("  the second half of a sentence\n  that began above.", lines: 10)

    #expect(screen.agentMessage == nil)
  }

  // MARK: - Marking a user turn, and refusing to

  /// Rows 7 and 9 were sent: grey background, above the prompt box. Row 53 is the composer:
  /// same glyph, no background, inside the box. Marking composer text as sent would have
  /// someone act on a message that was never sent.
  @Test("a sent turn is marked and the composer's caret on the same screen is not")
  func marksOnlyASentTurn() throws {
    let screen = PaneScreen.sanitised(PaneScreenFixture.claudeCodeSentUserTurns, lines: 200)

    let carets = screen.lines.indices.filter { screen.lines[$0].text.hasPrefix("❯") }
    #expect(carets.count == 3)

    let sent = carets.filter { screen.lines[$0].marker == .userTurn }
    #expect(sent.count == 2)
    #expect(screen.lines[sent[0]].text.contains("/clear"))
    #expect(screen.lines[sent[1]].text.contains("/rename notes"))

    let composer = try #require(carets.last)
    #expect(screen.lines[composer].marker == nil)
    #expect(composer > sent[1])
  }

  /// This caret carries a foreground and no background, neither shape the table names.
  @Test("a caret with no background is never a sent turn")
  func caretWithoutBackground() {
    let screen = PaneScreen.sanitised(PaneScreenFixture.claudeCodeAssistantMessage, lines: 200)

    #expect(screen.lines.contains { $0.text.hasPrefix("❯") })
    #expect(screen.lines.allSatisfy { $0.marker != .userTurn })
  }

  /// `❯ ping me when they're done` is text still being typed. Nothing above it is marked
  /// either, because that message's glyph row is above the fold.
  @Test("real composer text is never marked, and nothing above it is invented")
  func realComposerTextIsUnmarked() throws {
    let screen = PaneScreen.sanitised(PaneScreenFixture.claudeCodeComposerText, lines: 200)

    let caret = try #require(screen.lines.firstIndex { $0.text.hasPrefix("❯") })
    #expect(screen.lines[caret].text.contains("ping me when they're done"))
    #expect(screen.lines[caret].marker == nil)
    #expect(screen.agentMessage == nil)
    #expect(screen.userTurns.isEmpty)
  }

  /// Without the prompt box there is no telling which side of it a caret is on.
  @Test("a caret carrying the background is still unmarked when no prompt box was found")
  func backgroundWithoutABox() {
    let screen = PaneScreen.sanitised(
      "\u{1B}[0m\u{1B}[38;5;7m\u{1B}[48;5;8m❯\u{1B}[0m\u{1B}[48;5;8m ship it\u{1B}[0m",
      lines: 10
    )

    #expect(screen.lines[0].marker == nil)
  }

  @Test("a caret inside the prompt box is unmarked however it is styled")
  func caretInsideTheBox() {
    let rule = "\u{1B}[0m\u{1B}[38;5;7m" + String(repeating: "─", count: 40) + "\u{1B}[0m"
    let screen = PaneScreen.sanitised(
      """
      \u{1B}[0m\u{1B}[38;5;15m⏺ \u{1B}[0mdone
      \(rule)
      \u{1B}[0m\u{1B}[38;5;7m\u{1B}[48;5;8m❯\u{1B}[0m\u{1B}[48;5;8m staged text\u{1B}[0m
      \(rule)
      """,
      lines: 10
    )

    #expect(screen.lines[2].text.hasPrefix("❯"))
    #expect(screen.lines[2].marker == nil)
  }

  /// No real capture shows this shape: above the box, no background. A sent turn always has
  /// the background, so this is most likely a composer whose box was cut off.
  @Test("a caret above the prompt box with no background is still unmarked")
  func caretAboveTheBoxWithoutBackground() {
    let rule = "\u{1B}[0m\u{1B}[38;5;7m" + String(repeating: "─", count: 40) + "\u{1B}[0m"
    let screen = PaneScreen.sanitised(
      """
      \u{1B}[0m\u{1B}[38;5;7m❯\u{A0}ping me when they're done\u{1B}[0m
      \(rule)
      \u{1B}[0m\u{1B}[38;5;7m❯\u{A0}\u{1B}[0m
      \(rule)
      """,
      lines: 10
    )

    #expect(screen.lines[0].text.hasPrefix("❯"))
    #expect(screen.lines[0].marker == nil)
    #expect(screen.userTurns.isEmpty)
  }

  @Test("a caret above the prompt box carrying the background is the one marked case")
  func caretAboveTheBox() {
    let rule = "\u{1B}[0m\u{1B}[38;5;7m" + String(repeating: "─", count: 40) + "\u{1B}[0m"
    let screen = PaneScreen.sanitised(
      """
      \u{1B}[0m\u{1B}[38;5;7m\u{1B}[48;5;8m❯\u{1B}[0m\u{1B}[48;5;8m ship it\u{1B}[0m
      \(rule)
      \u{1B}[0m\u{1B}[38;5;7m❯\u{1B}[0m
      \(rule)
      """,
      lines: 10
    )

    #expect(screen.lines[0].marker == .userTurn)
    #expect(screen.lines[2].marker == nil)
  }
}
