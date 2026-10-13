import Testing

@testable import DriverrCore

/// What the captured-screen surface says, and how a screen is laid out. The captured screen
/// is the permanent state for most agent kinds, so the surface must neither apologise nor
/// claim what the screen does not show. `TerminalSettingsTests` covers which layout is drawn.
@Suite("PaneScreen presentation")
struct PaneScreenPresentationTests {

  private func screen(_ rows: [String]) -> PaneScreen {
    screen(rows.joined(separator: "\n"))
  }

  /// A fixture is already one joined string; see `PaneScreenFixture`.
  private func screen(_ ansi: String) -> PaneScreen {
    PaneScreen.sanitised(ansi, lines: PaneScreen.maximumLines)
  }

  // MARK: - How wide the screen is

  @Test("the column count is the widest row, in the characters the parser counts")
  func columnsIsTheWidestRow() {
    let measured = screen(["short", "the longest row here", "mid"])

    #expect(measured.columns == 20)
  }

  @Test("a blank screen is nought columns rather than a guess")
  func blankScreenHasNoColumns() {
    #expect(PaneScreen.blank.columns == 0)
  }

  @Test("the column count ignores styling, because SGR occupies no columns")
  func columnsIgnoresStyling() {
    let styled = PaneScreen.sanitised("\u{1B}[38;5;15mhello\u{1B}[0m", lines: 10)

    #expect(styled.columns == 5)
  }

  @Test("a real capture measures its own width rather than the pane's rect")
  func columnsOfARealCapture() {
    let real = screen(PaneScreenFixture.claudeCodeAssistantMessage)

    // herdr's snapshot has no column count to match `viewport_rows`.
    #expect(real.columns > 0)
    #expect(real.columns <= PaneScreen.maximumLineLength)
  }

  // MARK: - The caption

  @Test("the caption states the line count and that there is nothing behind the screen")
  func captionNamesTheLineCount() {
    let caption = PaneScreenCaption(screen: screen(["a", "b", "c"]))

    #expect(caption.lines == "The last 3 lines of the pane — earlier output is not kept.")
  }

  @Test("one line is one line, not '1 lines'")
  func captionIsSingularForOneLine() {
    let caption = PaneScreenCaption(screen: screen(["only this"]))

    #expect(caption.lines == "The last line of the pane — earlier output is not kept.")
  }

  /// Agent panes report `total_rows == viewport_rows`, so there is no scrollback to point to.
  @Test("the caption offers no route to output that does not exist")
  func captionOffersNoRouteToWhatIsNotKept() {
    let caption = PaneScreenCaption(screen: screen(["a", "b"]))

    #expect(!caption.lines.lowercased().contains("terminal"))
    #expect(!caption.lines.lowercased().contains("for the rest"))
  }

  @Test("the caption reads as one sentence to a screen reader")
  func captionSpeaksAsOneThing() {
    let caption = PaneScreenCaption(screen: screen(["a", "b"]))

    #expect(caption.accessibilityLabel == caption.lines)
  }

  // MARK: - What the screen may claim about an agent's message

  /// Most real mid-conversation screens carry no assistant message.
  @Test("an unmarked screen makes no claim about an agent message")
  func unmarkedScreenClaimsNothing() {
    let plain = screen(["$ swift build", "Build complete.", "$ "])

    #expect(plain.agentMessage == nil)
    #expect(plain.agentMessageLabel(agentName: "Claude") == nil)
  }

  @Test("a marked screen names the agent whose message it is")
  func markedScreenNamesTheAgent() {
    let marked = screen(PaneScreenFixture.claudeCodeAssistantMessage)

    #expect(marked.agentMessage != nil)
    #expect(marked.agentMessageLabel(agentName: "Claude") == "Claude's latest message")
    #expect(marked.agentMessageLabel(agentName: "Codex") == "Codex's latest message")
  }

  // MARK: - Laying a screen out

  @Test("clipped is one drawn row per screen line, in order")
  func clippedIsOneRowPerLine() {
    let rows = screen(["one", "two", "three"]).rows(wrappedTo: nil)

    #expect(rows.map(\.text) == ["one", "two", "three"])
    #expect(rows.map(\.line) == [0, 1, 2])
    #expect(rows.allSatisfy { !$0.isContinuation })
  }

  @Test("a line that fits is not wrapped")
  func aLineThatFitsIsOneRow() {
    let rows = screen(["12345"]).rows(wrappedTo: 10)

    #expect(rows.count == 1)
    #expect(rows[0].text == "12345")
    #expect(!rows[0].isContinuation)
  }

  /// A continuation is marked so the view can hang it and it never reads as a new line.
  @Test("a line that does not fit continues into marked rows")
  func aLongLineWrapsIntoContinuations() {
    // 10 on the first row, then 8 per continuation: the hanging indent costs two.
    let rows = screen(["abcdefghijklmnopqrst"]).rows(wrappedTo: 10)

    #expect(rows.map(\.text) == ["abcdefghij", "klmnopqr", "st"])
    #expect(rows.map(\.isContinuation) == [false, true, true])
    #expect(rows.allSatisfy { $0.line == 0 })
  }

  @Test("wrapping never loses or invents a character")
  func wrappingPreservesTheText() {
    let original = screen(PaneScreenFixture.claudeCodeAssistantMessage)
    let rows = original.rows(wrappedTo: 24)

    for (index, line) in original.lines.enumerated() {
      let joined = rows.filter { $0.line == index }.map(\.text).joined()
      #expect(joined == line.text)
    }
  }

  /// A terminal screen is a grid. Reflowing on words would move characters the pane placed.
  @Test("wrapping cuts at the column rather than at a word boundary")
  func wrappingCutsAtTheColumn() {
    let rows = screen(["hello world"]).rows(wrappedTo: 8)

    #expect(rows.map(\.text) == ["hello wo", "rld"])
  }

  @Test("a span's styling survives a wrap that falls inside it")
  func wrappingKeepsStyling() {
    let styled = PaneScreen.sanitised("\u{1B}[1;38;5;12mabcdefgh\u{1B}[0m", lines: 10)
    let rows = styled.rows(wrappedTo: 4)

    #expect(rows.map(\.text) == ["abcd", "ef", "gh"])
    for row in rows {
      #expect(row.spans.allSatisfy { $0.style.foreground == .brightBlue && $0.style.isBold })
    }
  }

  @Test("a marked line carries its marker onto every row it wraps into")
  func wrappingCarriesTheMarker() {
    let marked = screen(PaneScreenFixture.claudeCodeAssistantMessage)
    guard let range = marked.agentMessage else {
      Issue.record("the fixture is supposed to carry a marked agent message")
      return
    }
    let rows = marked.rows(wrappedTo: 12).filter { range.contains($0.line) }

    #expect(!rows.isEmpty)
    #expect(rows.allSatisfy { $0.marker == .agentMessage })
  }

  /// `isTruncated` means the boundary cut the line, which is not the same as wrapping.
  @Test("a line cut at the boundary reports it on its last row only")
  func truncationLandsOnTheLastRow() {
    let long = String(repeating: "x", count: PaneScreen.maximumLineLength + 40)
    let cut = screen([long])
    #expect(cut.lines[0].isTruncated)

    let rows = cut.rows(wrappedTo: 100)

    #expect(rows.count > 1)
    #expect(rows.dropLast().allSatisfy { !$0.isTruncated })
    #expect(rows.last?.isTruncated == true)
  }

  @Test("a blank row stays a row, because a screen is a grid")
  func aBlankRowSurvivesWrapping() {
    let rows = screen(["one", "", "three"]).rows(wrappedTo: 10)

    #expect(rows.map(\.text) == ["one", "", "three"])
  }

  @Test("a blank screen lays out to nothing at all")
  func aBlankScreenHasNoRows() {
    #expect(PaneScreen.blank.rows(wrappedTo: 40).isEmpty)
    #expect(PaneScreen.blank.rows(wrappedTo: nil).isEmpty)
  }

  /// A phone in accessibility text sizes gets this narrow.
  @Test("an absurdly narrow width still lays every character out")
  func aVeryNarrowWidthStillMakesProgress() {
    let rows = screen(["abcdef"]).rows(wrappedTo: 1)

    #expect(rows.map(\.text).joined() == "abcdef")
    #expect(rows.count <= 6)
  }

  @Test("every drawn row has a distinct identity, so a list can key on it")
  func rowsAreIdentifiable() {
    let rows = screen(["a long line that will wrap", "and another"]).rows(wrappedTo: 8)

    #expect(Set(rows.map(\.id)).count == rows.count)
  }

  // MARK: - The surface's fixed words

  /// A refusal is a fault and gets a retry; a blank screen is an answer. Collapsing them
  /// gives a spinner that never resolves or a false calm.
  @Test("a refusal and a blank screen say different things")
  func aRefusalIsNotABlankScreen() {
    #expect(PaneScreenCopy.refusalTitle == "Couldn't read the pane")
    #expect(PaneScreenCopy.blankTitle != PaneScreenCopy.refusalTitle)
    #expect(!PaneScreenCopy.blankMessage.isEmpty)
    #expect(PaneScreenCopy.retry == "Retry")
  }

  @Test("nothing the surface says apologises for being a screen")
  func theSurfaceDoesNotApologise() {
    let words = [
      PaneScreenCopy.blankTitle,
      PaneScreenCopy.blankMessage,
      PaneScreenCopy.reading,
      PaneScreenCopy.wrapTitle,
      PaneScreenCopy.wrapFooter,
      PaneScreenCaption(screen: PaneScreen.sanitised("hello", lines: 4)).lines,
    ]
    for word in words {
      #expect(!word.lowercased().contains("sorry"))
      #expect(!word.lowercased().contains("unfortunately"))
      #expect(!word.lowercased().contains("error"))
      #expect(!word.lowercased().contains("failed"))
    }
  }
}
