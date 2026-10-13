import Testing

@testable import DriverrCore

/// `String.withTextPresentation`. Which glyph CoreText picks is `PaneScreenGlyphTests` in
/// `DriverrTests`, because only the simulator has the fonts.
@Suite("Text presentation")
struct TextPresentationTests {
  @Test("a default-text emoji gets the text selector", arguments: ["⏺", "⚠", "✔"])
  func defaultTextEmojiGetsTheSelector(glyph: String) {
    #expect(glyph.withTextPresentation == glyph + "\u{FE0E}")
  }

  @Test("the selector goes after each such glyph inside a row")
  func insideARow() {
    #expect("⏺ Bash(ls) ⚠ done".withTextPresentation == "⏺\u{FE0E} Bash(ls) ⚠\u{FE0E} done")
  }

  @Test("an emoji-presentation glyph and plain text are left alone", arguments: ["✅", "abc #1 *", "é ─│╭"])
  func othersAreLeftAlone(text: String) {
    #expect(text.withTextPresentation == text)
  }

  @Test("a cluster that already carries a selector is left alone", arguments: ["⏺\u{FE0E}", "⚠\u{FE0F}"])
  func existingSelectorIsKept(glyph: String) {
    #expect(glyph.withTextPresentation == glyph)
  }

  @Test("the character count is unchanged")
  func characterCountIsUnchanged() {
    let row = "⏺ Write(a.swift) ✔ ⚠ ✅"
    #expect(row.withTextPresentation.count == row.count)
    #expect(row.withTextPresentation != row)
  }
}
