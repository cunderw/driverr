import Foundation
import Testing

@testable import DriverrCore

/// The composer's `/` autocomplete, mined from the transcript's command turns.
@Suite("Slash command matching")
struct SlashCommandMatcherTests {
  private func turn(_ text: String, isCommand: Bool = true, id: String = UUID().uuidString)
    -> TranscriptTurn
  {
    TranscriptTurn(id: id, speech: .human(text), isCommand: isCommand)
  }

  private func transcript(_ turns: [TranscriptTurn]) -> Transcript {
    Transcript(turns: turns, window: .none)
  }

  @Test("Most recent use first, duplicates collapsed to their newest use")
  func recentCommandsOrdering() {
    let transcript = transcript([
      turn("/run-tests"),
      turn("/push"),
      turn("/run-tests"),
      turn("/code-review high --fix"),
    ])
    let recents = SlashCommandMatcher.recentCommands(in: transcript)
    #expect(recents.map(\.name) == ["/code-review", "/run-tests", "/push"])
  }

  @Test("Only command turns are mined, never prose or agent speech")
  func nonCommandTurnsAreIgnored() {
    let transcript = transcript([
      turn("/run-tests is my favourite command", isCommand: false),
      TranscriptTurn(id: "a1", speech: .assistant("/run-tests"), isCommand: false),
      turn("/run-tests"),
    ])
    #expect(SlashCommandMatcher.recentCommands(in: transcript).map(\.name) == ["/run-tests"])
  }

  @Test("Empty transcript offers nothing")
  func emptyTranscript() {
    #expect(SlashCommandMatcher.recentCommands(in: .empty).isEmpty)
  }

  @Test("A bare slash offers every recent command")
  func bareSlashOffersEverything() {
    let commands = [SlashCommand(name: "/run-tests"), SlashCommand(name: "/push")]
    #expect(SlashCommandMatcher.matches(commands, typed: "/") == commands)
  }

  @Test("Typing further filters by prefix, case-insensitively")
  func prefixFilters() {
    let commands = [
      SlashCommand(name: "/run-tests"), SlashCommand(name: "/push"),
      SlashCommand(name: "/code-review"),
    ]
    #expect(SlashCommandMatcher.matches(commands, typed: "/RUN").map(\.name) == ["/run-tests"])
    #expect(SlashCommandMatcher.matches(commands, typed: "/pu").map(\.name) == ["/push"])
  }

  @Test("A space ends command composition — nothing is offered for an argument")
  func spaceStopsMatching() {
    let commands = [SlashCommand(name: "/code-review")]
    #expect(SlashCommandMatcher.matches(commands, typed: "/code-review h").isEmpty)
  }

  @Test("Prose that does not start with a slash offers nothing")
  func noSlashOffersNothing() {
    let commands = [SlashCommand(name: "/run-tests")]
    #expect(SlashCommandMatcher.matches(commands, typed: "run").isEmpty)
    #expect(SlashCommandMatcher.matches(commands, typed: "").isEmpty)
  }

  @Test("The list is capped, and the cap keeps the most recently used")
  func theListIsCapped() {
    // Oldest first, so the cap must keep `/c7`, `/c6`, `/c5`. The count alone cannot check that.
    let turns = (1...7).map { turn("/c\($0)") }
    let recents = SlashCommandMatcher.recentCommands(in: transcript(turns))
    #expect(recents.count == 7)

    let offered = SlashCommandMatcher.matches(recents, typed: "/")
    #expect(offered.count == SlashCommandMatcher.maximumSuggestions)
    #expect(offered.map(\.name) == ["/c7", "/c6", "/c5"])
  }

  @Test("A filtered list is capped too, not just the bare slash")
  func filteringIsCappedAsWell() {
    let commands = (1...7).map { SlashCommand(name: "/code-\($0)") }
    let offered = SlashCommandMatcher.matches(commands, typed: "/code")
    #expect(offered.count == SlashCommandMatcher.maximumSuggestions)
    #expect(offered.map(\.name) == ["/code-1", "/code-2", "/code-3"])
  }

  /// The view passes a smaller limit at accessibility text sizes.
  @Test("An explicit limit overrides the default cap")
  func anExplicitLimitIsHonoured() {
    let commands = (1...7).map { SlashCommand(name: "/c\($0)") }
    let offered = SlashCommandMatcher.matches(
      commands,
      typed: "/",
      limit: SlashCommandMatcher.maximumSuggestionsAtAccessibilitySizes
    )
    #expect(offered.map(\.name) == ["/c1", "/c2"])

    // A guard on `typed == "/"` would let a filtered list through.
    let filtered = SlashCommandMatcher.matches(commands, typed: "/c", limit: 2)
    #expect(filtered.map(\.name) == ["/c1", "/c2"])
  }

  @Test("The accessibility cap is smaller than the default one")
  func theAccessibilityCapIsSmaller() {
    #expect(
      SlashCommandMatcher.maximumSuggestionsAtAccessibilitySizes
        < SlashCommandMatcher.maximumSuggestions
    )
  }

  @Test("A miss returns no commands")
  func noMatchReturnsEmpty() {
    let commands = [SlashCommand(name: "/run-tests")]
    #expect(SlashCommandMatcher.matches(commands, typed: "/zzz").isEmpty)
  }
}

/// Which part of the field the `/` list is completing. Offsets are `Character` offsets.
@Suite("Slash token at the caret")
struct SlashTokenTests {
  private func token(_ text: String, caret: Int? = nil) -> SlashToken? {
    SlashCommandMatcher.activeToken(in: text, caret: caret ?? text.count)
  }

  @Test("A slash word at the end of a sentence is the token")
  func midSentence() {
    #expect(token("fix this /co") == SlashToken(range: 9..<12, typed: "/co"))
    #expect(token("fix this /co")?.opensTheMessage == false)
  }

  @Test("A leading slash word is the token, and opens the message")
  func leading() {
    #expect(token("/co") == SlashToken(range: 0..<3, typed: "/co"))
    #expect(token("/") == SlashToken(range: 0..<1, typed: "/"))
    #expect(token("/co")?.opensTheMessage == true)
  }

  @Test("Leading whitespace does not open the message")
  func leadingWhitespace() {
    #expect(token("  /co") == SlashToken(range: 2..<5, typed: "/co"))
    #expect(token("  /co")?.opensTheMessage == false)
  }

  @Test("A path, a URL and an absolute path offer nothing")
  func pathsAndURLs() {
    #expect(token("look at src/foo") == nil)
    #expect(token("see https://x") == nil)
    // A second slash in the word: a path, not a command.
    #expect(token("run /usr/bin") == nil)
    #expect(token("/usr/") == nil)
  }

  @Test("A slash after a newline is a token")
  func afterANewline() {
    #expect(token("first line\n/co") == SlashToken(range: 11..<14, typed: "/co"))
  }

  @Test("A caret back in earlier text finds the word it is at the end of")
  func caretInEarlierText() {
    // "/co" ends at offset 7; the caret is there, with prose after it.
    #expect(token("fix /co and more", caret: 7) == SlashToken(range: 4..<7, typed: "/co"))
    // The caret at the end of a plain word.
    #expect(token("fix /co and more", caret: 11) == nil)
    // The caret inside a word: completing it would strand the rest of the word.
    #expect(token("fix /code more", caret: 7) == nil)
  }

  @Test("A caret after a space offers nothing")
  func caretAfterASpace() {
    #expect(token("fix /co ") == nil)
    #expect(token("/code-review ") == nil)
    #expect(token("") == nil)
  }

  @Test("A caret outside the text offers nothing")
  func caretOutOfRange() {
    #expect(token("/co", caret: 4) == nil)
    #expect(token("/co", caret: -1) == nil)
  }

  @Test("Offsets count characters, not UTF-16 units")
  func characterOffsets() {
    #expect(token("👍🏽 /co") == SlashToken(range: 2..<5, typed: "/co"))
  }
}

/// Choosing a row replaces only the token, and keeps everything else.
@Suite("Slash completion")
struct SlashCompletionTests {
  private let review = SlashCommand(name: "/code-review")

  private func complete(_ text: String, caret: Int? = nil) -> SlashCompletion? {
    guard let token = SlashCommandMatcher.activeToken(in: text, caret: caret ?? text.count)
    else { return nil }
    return SlashCommandMatcher.complete(text, token: token, with: review)
  }

  @Test("A mid-sentence token is replaced and the sentence kept")
  func midSentence() {
    #expect(
      complete("fix this /co") == SlashCompletion(text: "fix this /code-review ", caret: 22))
  }

  @Test("A leading token completes as it always did")
  func leading() {
    #expect(complete("/co") == SlashCompletion(text: "/code-review ", caret: 13))
  }

  @Test("Text after the token is kept, and the caret lands after the command")
  func textAfterTheToken() {
    #expect(
      complete("fix /co\nmore", caret: 7)
        == SlashCompletion(text: "fix /code-review \nmore", caret: 17))
  }

  /// An existing space is reused rather than doubled.
  @Test("A space already after the token is not doubled")
  func existingSpace() {
    #expect(
      complete("fix /co and more", caret: 7)
        == SlashCompletion(text: "fix /code-review and more", caret: 17))
  }
}

/// Mid-sentence, Claude Code sends a built-in as prose, so the list must not offer one there.
@Suite("Built-ins hidden mid-sentence")
struct SlashBuiltInFilterTests {
  @Test("A catalogue built-in is removed and a skill is kept")
  func builtInRemoved() {
    let catalog = SlashCommandCatalog.installed([
      SlashCommand(name: "/code-review", source: .userSkill)
    ])
    let offered = SlashCommandMatcher.offerings(recents: [], catalog: catalog)
    let kept = SlashCommandMatcher.withoutBuiltIns(offered, catalog: catalog)
    #expect(kept.map(\.name) == ["/code-review"])
  }

  /// A recent keeps `.recent` as its source, so the source alone cannot say it is a built-in.
  @Test("A recent built-in is removed too, before the catalogue arrives")
  func recentBuiltInRemoved() {
    let recents = [SlashCommand(name: "/compact"), SlashCommand(name: "/run-tests")]
    let offered = SlashCommandMatcher.offerings(recents: recents, catalog: .empty)
    let kept = SlashCommandMatcher.withoutBuiltIns(offered, catalog: .empty)
    #expect(kept.map(\.name) == ["/run-tests"])
  }

  /// `installed` lets the host win a name collision, so `/review` here is a project command.
  @Test("A host command that overrides a built-in's name is kept")
  func overrideKept() {
    let catalog = SlashCommandCatalog.installed([
      SlashCommand(name: "/review", source: .projectCommand)
    ])
    let recents = [SlashCommand(name: "/review")]
    let offered = SlashCommandMatcher.offerings(recents: recents, catalog: catalog)
    let kept = SlashCommandMatcher.withoutBuiltIns(offered, catalog: catalog)
    #expect(kept.map(\.name) == ["/review"])
  }
}

/// The arrow-key highlight over the suggestion list. Only an external keyboard reaches
/// these cases; touch never sets a highlight.
@Suite("Slash suggestion selection")
struct SlashSuggestionSelectionTests {
  private let three = [
    SlashCommand(name: "/run-tests"),
    SlashCommand(name: "/push"),
    SlashCommand(name: "/code-review"),
  ]

  @Test("Down from nothing selects the first row, then walks and wraps")
  func downWraps() {
    var selection = SlashSuggestionSelection()
    selection.moveDown(count: 3)
    #expect(selection.index == 0)
    selection.moveDown(count: 3)
    #expect(selection.index == 1)
    selection.moveDown(count: 3)
    #expect(selection.index == 2)
    selection.moveDown(count: 3)
    #expect(selection.index == 0)
  }

  /// From no highlight, Up and Down are different requests. Starting both at row 0 makes Up a
  /// no-op on the first press.
  @Test("Up from nothing selects the last row, then walks and wraps")
  func upWraps() {
    var selection = SlashSuggestionSelection()
    selection.moveUp(count: 3)
    #expect(selection.index == 2)
    selection.moveUp(count: 3)
    #expect(selection.index == 1)
    selection.moveUp(count: 3)
    #expect(selection.index == 0)
    selection.moveUp(count: 3)
    #expect(selection.index == 2)
  }

  /// The view gates handlers on an empty list, but a key can race the list emptying.
  @Test("An empty list cannot be highlighted in either direction")
  func emptyListHighlightsNothing() {
    var selection = SlashSuggestionSelection(index: 1)
    selection.moveDown(count: 0)
    #expect(selection.index == nil)

    var other = SlashSuggestionSelection(index: 1)
    other.moveUp(count: 0)
    #expect(other.index == nil)
  }

  @Test("Reset drops the highlight")
  func resetDropsTheHighlight() {
    var selection = SlashSuggestionSelection(index: 2)
    selection.reset()
    #expect(selection.index == nil)
    #expect(selection.highlighted(in: three) == nil)
  }

  @Test("The highlight names the row it points at")
  func highlightNamesItsRow() {
    #expect(SlashSuggestionSelection(index: 0).highlighted(in: three)?.name == "/run-tests")
    #expect(SlashSuggestionSelection(index: 2).highlighted(in: three)?.name == "/code-review")
    #expect(SlashSuggestionSelection().highlighted(in: three) == nil)
  }

  /// The list recomputes on every keystroke. Returning the row now at that index would
  /// complete a command nobody highlighted; `nil` lets Return fall through to Send.
  @Test("An index past the end of a shrunken list highlights nothing")
  func staleIndexHighlightsNothing() {
    let one = [SlashCommand(name: "/run-tests")]
    #expect(SlashSuggestionSelection(index: 2).highlighted(in: one) == nil)
    #expect(SlashSuggestionSelection(index: 0).highlighted(in: []) == nil)
    #expect(SlashSuggestionSelection(index: -1).highlighted(in: three) == nil)
  }

  /// Not `(stale + 1) % count`, which is an arbitrary row.
  @Test("Moving out of a stale index lands at the end the key was heading for")
  func movingOutOfAStaleIndex() {
    var down = SlashSuggestionSelection(index: 9)
    down.moveDown(count: 3)
    #expect(down.index == 0)

    var up = SlashSuggestionSelection(index: 9)
    up.moveUp(count: 3)
    #expect(up.index == 2)
  }
}
