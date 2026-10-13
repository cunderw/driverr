extension String {
  /// This text with every default-text emoji asked to draw as text.
  ///
  /// A scalar such as ⏺ U+23FA, ⚠ U+26A0 or ✔ U+2714 is an emoji that defaults to text
  /// presentation, but a monospaced face has no glyph for most of them, and CoreText's
  /// fallback then reaches Apple Color Emoji: a colour picture, wider than a cell, in the
  /// middle of terminal output. U+FE0E (VARIATION SELECTOR-15) asks for the text form, and
  /// the fallback then finds a text face instead.
  ///
  /// The predicate is the one our SwiftTerm fork uses for the live terminal,
  /// `isEmoji && !isEmojiPresentation`, so the captured screen and the terminal draw the
  /// same glyph. Only a single-scalar cluster above U+00FF is touched: `#`, `*` and the
  /// digits are `isEmoji` too, and a cluster that already carries a selector, a skin tone
  /// or a joiner has said what it wants.
  ///
  /// For display only. `PaneScreenParser` compares clusters as `Character`s, and
  /// `"⏺\u{FE0E}"` is not `"⏺"`, so the parser's input must never pass through this.
  public var withTextPresentation: String {
    var result = String.UnicodeScalarView()
    for character in self {
      let scalars = character.unicodeScalars
      result.append(contentsOf: scalars)
      if scalars.count == 1, let scalar = scalars.first, scalar.value > 0xFF,
        scalar.properties.isEmoji, !scalar.properties.isEmojiPresentation
      {
        result.append("\u{FE0E}")
      }
    }
    return String(result)
  }
}
