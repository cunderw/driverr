extension PaneScreen {
  /// A pane's raw `--format ansi` screen, sanitised and marked.
  ///
  /// `lines` is how many rows the caller wants, taken from the tail, clamped to
  /// `maximumLines`. Every row is clamped to `maximumLineLength`.
  ///
  /// Marking happens after the tail is taken. A message whose glyph row was cut off has no
  /// visible start, so its remainder must not be marked as the agent's latest message.
  public static func sanitised(_ ansi: String, lines: Int) -> PaneScreen {
    PaneScreenParser.screen(from: ansi, lines: lines)
  }
}

/// Terminal control sequences out of a string, and nothing else.
///
/// The same scanner `PaneScreenParser` uses, for callers that want printable text without a
/// screen's semantics. `DriverrTranscript` needs it: a session file's text is prose, so the
/// screen's row and column bounds and glyph marking would be wrong, but the sanitising is
/// right. One escape grammar, so two copies cannot drift.
public enum PaneScreenText {
  /// Every escape sequence dropped with its payload, control characters dropped, tabs
  /// expanded, lines kept, and no length bound, so prose is never cut mid-sentence.
  public static func plain(_ text: String) -> String {
    guard text.contains(where: { $0 == "\u{1B}" || PaneScreenParser.isControlCharacter($0) })
    else { return text }
    let normalised = String(text.map { $0 == "\r\n" ? "\n" : $0 })
    return
      normalised
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { PaneScreenParser.plainRow(from: $0) }
      .joined(separator: "\n")
  }
}

/// Turns a terminal screen into something a `Text` can hold.
///
/// Sanitising: SGR becomes a `PaneScreenStyle`, every other escape sequence is consumed with
/// its payload, control characters are dropped, tabs become spaces, and rows and lines are
/// bounded. Nothing that arrives can make the view do anything.
///
/// Marking uses Claude Code v2.1.241's own screen vocabulary, glyph plus SGR. It is not a
/// protocol, may break on a version bump, and applies to no other agent kind:
///
/// | what it is | glyph | SGR |
/// |---|---|---|
/// | assistant message | `⏺` U+23FA | foreground 15 |
/// | system notice ("Remote Control disconnected") | `⏺` same glyph | foreground 11 |
/// | background-task notice | `⏺` same glyph | foreground 10 |
/// | tool call / result | `⎿` U+23BF, and `⏺` foreground 7 | foreground 7 |
/// | sent user turn | `❯` U+276F | foreground 7 on background 8 |
/// | composer, not sent | `❯` same glyph | none, then U+00A0 |
/// | message continuation | (none) | two-space indent |
///
/// Never invent a speaker or a boundary. An unmarked screen is a correct and common answer.
/// Marking composer text as a sent turn would lead someone to act on a message never sent,
/// so every ambiguity resolves to no marker.
enum PaneScreenParser {
  static func screen(from ansi: String, lines: Int) -> PaneScreen {
    let limit = min(max(lines, 1), PaneScreen.maximumLines)

    // `\r\n` is one `Character` in Swift, so a CRLF screen would otherwise be one row.
    let normalised = String(ansi.map { $0 == "\r\n" ? "\n" : $0 })

    var rows = normalised
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { row(from: $0) }

    // `--source visible` already trims the empty bottom, but a blank screen must come back
    // as nothing rather than as blank rows.
    while let last = rows.last, last.isBlank { rows.removeLast() }
    rows = Array(rows.suffix(limit))

    let marks = markers(for: rows)
    return PaneScreen(
      lines: rows.indices.map { index in
        PaneScreenLine(
          spans: rows[index].spans,
          marker: marks[index],
          isTruncated: rows[index].isTruncated
        )
      }
    )
  }

  // MARK: - Sanitising

  private struct Row {
    var spans: [PaneScreenSpan]
    var isTruncated: Bool

    var text: String { spans.map(\.text).joined() }
    var isBlank: Bool { text.allSatisfy(\.isWhitespace) }
  }

  /// The mutable form of `PaneScreenStyle`, so "reset the foreground" and "leave it alone"
  /// stay different.
  private struct Attributes {
    var foreground: PaneScreenColor?
    var background: PaneScreenColor?
    var isBold = false
    var isDim = false
    var isItalic = false

    var style: PaneScreenStyle {
      PaneScreenStyle(
        foreground: foreground,
        background: background,
        isBold: isBold,
        isDim: isDim,
        isItalic: isItalic
      )
    }
  }

  private static let escape: Character = "\u{1B}"
  private static let tabWidth = 8

  private static func row(
    from raw: Substring,
    lineLength: Int = PaneScreen.maximumLineLength
  ) -> Row {
    let characters = Array(raw)
    var index = 0
    var attributes = Attributes()
    var spans: [PaneScreenSpan] = []
    var pending = ""
    var pendingStyle = PaneScreenStyle.plain
    var column = 0
    var isTruncated = false

    func flush() {
      guard !pending.isEmpty else { return }
      spans.append(PaneScreenSpan(text: pending, style: pendingStyle))
      pending = ""
    }

    func emit(_ character: Character) {
      guard column < lineLength else {
        isTruncated = true
        return
      }
      if attributes.style != pendingStyle {
        flush()
        pendingStyle = attributes.style
      }
      pending.append(character)
      column += 1
    }

    while index < characters.count {
      let character = characters[index]
      if character == escape {
        index = skip(escapeAt: index, in: characters, attributes: &attributes)
        continue
      }
      if isControl(character) {
        // A tab becomes the spaces it stands for. Every other control character (a lone CR,
        // NUL, the C1 introducers) is dropped alone, leaving the text around it intact.
        if character == "\t" {
          let stop = ((column / tabWidth) + 1) * tabWidth
          while column < stop {
            let before = column
            emit(" ")
            if column == before { break }
          }
        }
        index += 1
        continue
      }
      emit(character)
      index += 1
    }
    flush()

    return Row(spans: spans, isTruncated: isTruncated)
  }

  /// One row's printable text, unbounded. See `PaneScreenText.plain`.
  static func plainRow(from raw: Substring) -> String {
    row(from: raw, lineLength: .max).text
  }

  /// Lets `PaneScreenText.plain` skip the scan for a string with nothing to sanitise, which
  /// is nearly every string.
  static func isControlCharacter(_ character: Character) -> Bool { isControl(character) }

  private static func isControl(_ character: Character) -> Bool {
    guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
      return false
    }
    return scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value)
  }

  private static func value(of character: Character) -> UInt32? {
    guard character.unicodeScalars.count == 1 else { return nil }
    return character.unicodeScalars.first?.value
  }

  /// Consumes one escape sequence and returns the index just past it.
  ///
  /// Only SGR changes anything. Every sequence is skipped whole, or an OSC would print its
  /// window title and `38;5;200` would print its `5;200`.
  private static func skip(
    escapeAt start: Int,
    in characters: [Character],
    attributes: inout Attributes
  ) -> Int {
    let index = start + 1
    guard index < characters.count else { return characters.count }
    switch characters[index] {
    case "[":
      return skipControlSequence(from: index + 1, in: characters, attributes: &attributes)
    // OSC, DCS, SOS, PM and APC all carry an arbitrary payload terminated by ST or BEL.
    case "]", "P", "X", "^", "_":
      return skipStringSequence(from: index + 1, in: characters)
    // Charset designators and the like: one more byte belongs to the sequence.
    case "(", ")", "*", "+", "%", "#":
      return min(index + 2, characters.count)
    default:
      return index + 1
    }
  }

  private static func skipControlSequence(
    from start: Int,
    in characters: [Character],
    attributes: inout Attributes
  ) -> Int {
    var index = start
    var parameters = ""
    while index < characters.count, let scalar = value(of: characters[index]),
      (0x30...0x3F).contains(scalar)
    {
      parameters.append(characters[index])
      index += 1
    }
    while index < characters.count, let scalar = value(of: characters[index]),
      (0x20...0x2F).contains(scalar)
    {
      index += 1
    }
    guard index < characters.count, let final = value(of: characters[index]),
      (0x40...0x7E).contains(final)
    else {
      // Never terminated. The rest of the row belongs to the sequence, so its parameters do
      // not leak as text.
      return characters.count
    }
    if characters[index] == "m" {
      apply(parameters, to: &attributes)
    }
    return index + 1
  }

  private static func skipStringSequence(from start: Int, in characters: [Character]) -> Int {
    var index = start
    while index < characters.count {
      let character = characters[index]
      if character == "\u{07}" || character == "\u{9C}" { return index + 1 }
      if character == escape {
        if index + 1 < characters.count, characters[index + 1] == "\\" { return index + 2 }
        return index + 1
      }
      index += 1
    }
    return characters.count
  }

  private static func apply(_ parameters: String, to attributes: inout Attributes) {
    // Sub-parameters may use `:` (`38:5:n`); normalising to `;` reads both spellings.
    let normalised = String(parameters.map { $0 == ":" ? ";" : $0 })
    let fields =
      normalised.isEmpty
      ? ["0"]
      : normalised.split(separator: ";", omittingEmptySubsequences: false).map(String.init)

    var index = 0
    while index < fields.count {
      // An empty field means zero: `ESC[1;;31m` is three codes.
      let code = Int(fields[index]) ?? 0
      switch code {
      case 0: attributes = Attributes()
      case 1: attributes.isBold = true
      case 2: attributes.isDim = true
      case 3: attributes.isItalic = true
      case 22:
        attributes.isBold = false
        attributes.isDim = false
      case 23: attributes.isItalic = false
      case 30...37: attributes.foreground = PaneScreenColor(paletteIndex: code - 30)
      case 39: attributes.foreground = nil
      case 40...47: attributes.background = PaneScreenColor(paletteIndex: code - 40)
      case 49: attributes.background = nil
      case 90...97: attributes.foreground = PaneScreenColor(paletteIndex: code - 90 + 8)
      case 100...107: attributes.background = PaneScreenColor(paletteIndex: code - 100 + 8)
      case 38, 48:
        let (colour, consumed) = extendedColour(fields, from: index + 1)
        if code == 38 {
          attributes.foreground = colour
        } else {
          attributes.background = colour
        }
        index += consumed
      default: break
      }
      index += 1
    }
  }

  /// The colour named by `38`/`48`'s sub-parameters, and how many it used.
  ///
  /// A 216-cube index, a greyscale ramp or a 24-bit literal return `nil`, because the theme
  /// owns the palette and approximating would invent a colour. The count matters too, or
  /// leftover sub-parameters would be read as SGR codes.
  private static func extendedColour(
    _ fields: [String],
    from start: Int
  ) -> (PaneScreenColor?, Int) {
    guard start < fields.count else { return (nil, 0) }
    switch Int(fields[start]) ?? 0 {
    case 5:
      guard start + 1 < fields.count else { return (nil, 1) }
      return (PaneScreenColor(paletteIndex: Int(fields[start + 1]) ?? -1), 2)
    case 2:
      return (nil, min(4, fields.count - start))
    default:
      return (nil, 1)
    }
  }

  // MARK: - Marking

  private static let recordGlyph: Character = "⏺"
  private static let caretGlyph: Character = "❯"
  private static let ruleGlyph: Character = "─"

  /// The foreground that means the agent is talking. Foreground 11 (system notice) and 10
  /// (background task) use the same glyph and are not messages.
  private static let assistantForeground = PaneScreenColor.brightWhite

  /// A corner or a tee, so a box drawn with rounded corners is recognised as a rule too.
  private static let boxCorners: Set<Character> = ["╭", "╰", "┌", "└", "├", "┬", "┴", "┏", "┗"]

  /// Glyphs that begin a row of their own kind, so an indented row carrying one is not a
  /// continuation.
  private static let structuralGlyphs: Set<Character> = [
    "⏺", "⎿", "❯", "⏵", "─", "│", "╭", "╰", "✶", "✻", "✽", "✢", "·", "▐", "▝", "⚠", "✔",
  ]

  private static func markers(for rows: [Row]) -> [PaneScreenMarker?] {
    var marks = [PaneScreenMarker?](repeating: nil, count: rows.count)
    let boxTop = promptBoxTop(in: rows)

    if let message = assistantMessage(in: rows, above: boxTop) {
      for index in message { marks[index] = .agentMessage }
    }
    for index in rows.indices where isSentUserTurn(rows[index], at: index, above: boxTop) {
      marks[index] = .userTurn
    }
    return marks
  }

  /// Where the pane's prompt box starts, when this screen shows one.
  ///
  /// The composer box's top border separates what happened from what is being typed. Taken
  /// as the last two rule lines, so a welcome banner higher up is not confused with it.
  /// `nil` when no box is visible, and everything that depends on it then refuses to guess.
  private static func promptBoxTop(in rows: [Row]) -> Int? {
    let rules = rows.indices.filter { isRuleLine(rows[$0]) }
    guard rules.count >= 2 else { return nil }
    let top = rules[rules.count - 2]
    let bottom = rules[rules.count - 1]
    // Rule lines far apart are two different boxes, not one prompt box.
    guard bottom - top <= maximumPromptBoxHeight else { return nil }
    return top
  }

  private static let maximumPromptBoxHeight = 8

  private static func isRuleLine(_ row: Row) -> Bool {
    let text = row.text
    guard let first = text.first, first == ruleGlyph || boxCorners.contains(first) else {
      return false
    }
    var run = 0
    for character in text {
      guard character == ruleGlyph else {
        run = 0
        continue
      }
      run += 1
      if run >= 4 { return true }
    }
    return false
  }

  /// The last assistant message on the screen, glyph row and continuations. Bounded above
  /// the prompt box, because a glyph inside the composer is something typed.
  private static func assistantMessage(in rows: [Row], above boxTop: Int?) -> Range<Int>? {
    let ceiling = min(boxTop ?? rows.count, rows.count)
    guard let start = (0..<ceiling).last(where: { isAssistantMessage(rows[$0]) }) else {
      return nil
    }
    var end = start + 1
    while end < ceiling, isContinuation(rows[end]) { end += 1 }
    return start..<end
  }

  private static func isAssistantMessage(_ row: Row) -> Bool {
    guard row.text.first == recordGlyph else { return false }
    return row.spans.first?.style.foreground == assistantForeground
  }

  /// A row continuing the message above: exactly two spaces of indent, then something that
  /// does not start a row of its own kind.
  private static func isContinuation(_ row: Row) -> Bool {
    let text = row.text
    guard !row.isBlank, text.hasPrefix("  ") else { return false }
    let third = text[text.index(text.startIndex, offsetBy: 2)]
    return third != " " && !structuralGlyphs.contains(third)
  }

  /// Whether Driverr is willing to say a person sent this row.
  ///
  /// Both signals are required: the grey background a sent turn has and the composer's caret
  /// lacks, and a position above the prompt box. Composer text wears the same `❯`, so a row
  /// missing either signal gets no marker.
  private static func isSentUserTurn(_ row: Row, at index: Int, above boxTop: Int?) -> Bool {
    guard row.text.first == caretGlyph else { return false }
    guard let boxTop, index < boxTop else { return false }
    return row.spans.first?.style.background != nil
  }
}
