import Foundation

/// An assistant turn's text, split into the block constructs that need their own treatment.
///
/// Not `AttributedString(markdown:)` with `.full` syntax: that yields one flat string with
/// `presentationIntent` attributes, which a view would have to re-segment to draw a themed
/// code block, and a diff needs per-line treatment. This splits headings, fences, lists and
/// unified diffs. Inline syntax (bold, italic, code, links) is left to `inline(_:)`.
public enum TranscriptMarkdown {
  /// One item of a bullet or numbered list.
  public struct ListItem: Hashable, Sendable {
    /// The item's own text, marker removed, still carrying its inline markdown.
    public let text: String
    /// Nesting level, 0 at the top. Read from leading whitespace at two spaces per level, as
    /// Claude Code writes it.
    public let depth: Int
    /// The number the writer gave an ordered item, so `3.` renders as `3.`. `nil` for a
    /// bullet.
    public let number: Int?

    public init(text: String, depth: Int = 0, number: Int? = nil) {
      self.text = text
      self.depth = depth
      self.number = number
    }
  }

  public enum Block: Hashable, Sendable {
    /// Prose, still carrying its inline markdown.
    case paragraph(String)
    /// `# ` through `###### `, with the marks and the leading space removed.
    case heading(String, level: Int)
    /// A run of consecutive list items. `isOrdered` says which marker opened it.
    case list([ListItem], isOrdered: Bool)
    /// The lines between a pair of `` ``` `` fences, fences and language tag removed. Verbatim:
    /// nothing re-parses markdown inside it.
    case code(String, language: String?)
    /// A unified diff, typed line by line. From a fence whose body has a hunk header, or from
    /// a diff pasted into the turn with no fence.
    case diff(TranscriptDiff)

    /// Whether this block is `.heading`, so the view can add a heading's top padding without
    /// matching the case.
    public var isHeading: Bool {
      if case .heading = self { return true }
      return false
    }
  }

  /// Splits `text` into blocks, in reading order.
  ///
  /// An unterminated fence runs to the end of the text rather than being dropped, because
  /// the newest turn may still be being written.
  public static func blocks(from text: String) -> [Block] {
    var blocks: [Block] = []
    var paragraphLines: [Substring] = []

    func flushParagraph() {
      guard !paragraphLines.isEmpty else { return }
      // Trim blank lines at both ends before joining. A paragraph collects the blank line
      // that opened it, and `.inlineOnlyPreservingWhitespace` would draw it as about 30 pt of
      // dead space. Interior blank lines survive.
      while let first = paragraphLines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
        paragraphLines.removeFirst()
      }
      while let last = paragraphLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
        paragraphLines.removeLast()
      }
      guard !paragraphLines.isEmpty else { return }
      let joined = paragraphLines.joined(separator: "\n")
      paragraphLines.removeAll()
      blocks.append(.paragraph(joined))
    }

    // Normalised as `TranscriptDiff` does. Swift treats `\r\n` as one `Character`, so
    // splitting on `"\n"` would leave a CRLF turn as a single block.
    let lines = TranscriptDiff.normalizedLines(of: text)
    var index = 0
    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if trimmed.hasPrefix("```") {
        flushParagraph()
        let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
        index += 1
        var codeLines: [Substring] = []
        while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
          codeLines.append(lines[index])
          index += 1
        }
        // Past the closing fence, or a no-op at `lines.count` when the fence never closed.
        index += 1
        let body = codeLines.joined(separator: "\n")
        // A fenced diff is a diff whatever the tag says. Agents tag patches `diff`, `patch`,
        // `swift` or nothing. The hunk header decides.
        if TranscriptDiff.looksLikeDiff(body) {
          blocks.append(.diff(TranscriptDiff.parse(body)))
        } else {
          blocks.append(.code(body, language: language.isEmpty ? nil : language))
        }
        continue
      }

      // Before the list and heading checks, because `--- a/x`, `+++ b/x` and `- removed` are
      // all list-shaped.
      if let run = unfencedDiff(in: lines, startingAt: index) {
        flushParagraph()
        blocks.append(.diff(TranscriptDiff.parse(lines[run].joined(separator: "\n"))))
        index = run.upperBound
        continue
      }

      if let level = headingLevel(of: trimmed) {
        flushParagraph()
        let title = String(trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))
        // A bare `#` or `#no-space` is not a heading, so it falls through to prose.
        if !title.isEmpty {
          blocks.append(.heading(title, level: level))
          index += 1
          continue
        }
      }

      if listItem(of: line) != nil {
        flushParagraph()
        var items: [ListItem] = []
        // The first marker decides the whole run, so mixed `-` and `1.` stay one list.
        let isOrdered = listItem(of: line)?.number != nil
        while index < lines.count, let item = listItem(of: lines[index]) {
          items.append(item)
          index += 1
        }
        blocks.append(.list(items, isOrdered: isOrdered))
        continue
      }

      paragraphLines.append(line)
      index += 1
    }
    flushParagraph()
    return blocks
  }

  /// 1–6 for a line opening on `#`s and a space; `nil` otherwise, including more than six
  /// and `#no-space`.
  private static func headingLevel(of trimmedLine: String) -> Int? {
    var level = 0
    for character in trimmedLine {
      guard character == "#" else { break }
      level += 1
    }
    guard (1...6).contains(level) else { return nil }
    let rest = trimmedLine.dropFirst(level)
    guard rest.first == " " else { return nil }
    return level
  }

  /// `- item`, `* item`, `+ item`, `1. item`, `2) item`, with its indent read as a depth.
  ///
  /// The space after the marker is required, which keeps `-5 degrees` and a removal line
  /// out. So is a body: a bare `-` is a rule or a typo.
  private static func listItem(of line: Substring) -> ListItem? {
    let indent = line.prefix { $0 == " " || $0 == "\t" }.count
    let rest = line.dropFirst(indent)
    guard let marker = rest.first else { return nil }

    if marker == "-" || marker == "*" || marker == "+" {
      guard rest.dropFirst().first == " " else { return nil }
      let text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty else { return nil }
      return ListItem(text: text, depth: indent / 2, number: nil)
    }

    let digits = rest.prefix { $0.isNumber }
    guard !digits.isEmpty, let number = Int(digits) else { return nil }
    let afterDigits = rest.dropFirst(digits.count)
    guard let punctuation = afterDigits.first, punctuation == "." || punctuation == ")",
      afterDigits.dropFirst().first == " "
    else { return nil }
    let text = afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    return ListItem(text: text, depth: indent / 2, number: number)
  }

  /// The line range of a diff written without a fence starting at `start`, or `nil`.
  ///
  /// It must open with a hunk header, or a preamble (`diff --git`, `---`, `+++`) leading to
  /// one, as `TranscriptDiff.looksLikeDiff` requires. That keeps a paragraph naming a file
  /// from swallowing the code below it.
  private static func unfencedDiff(in lines: [Substring], startingAt start: Int) -> Range<Int>? {
    guard start < lines.count, opensADiff(lines[start]) else { return nil }

    // Walk the preamble to the hunk header. Anything else means it was not a diff: a lone
    // `--- ` is a horizontal rule in some dialects.
    var scan = start
    while scan < lines.count, !TranscriptDiff.isHunkHeader(lines[scan]) {
      guard isPreamble(lines[scan]) else { return nil }
      scan += 1
    }
    guard scan < lines.count else { return nil }

    var end = scan
    while end < lines.count {
      let line = lines[end]
      if line.isEmpty {
        // An empty line is a trimmed blank context line only when the diff continues after
        // it. A following bullet list must not continue it, and a blank line inside a hunk
        // must. `listItem(of:)` tells them apart: a bullet needs a space after its marker,
        // so a line it accepts is not a plausible diff line (see `trimmedBlankIsContext` in
        // `TranscriptDiffTests`).
        let next = end + 1
        guard next < lines.count,
          TranscriptDiff.isHunkHeader(lines[next]) || isPreamble(lines[next])
            || (isBody(lines[next]) && listItem(of: lines[next]) == nil)
        else { break }
        end = next + 1
        continue
      }
      guard isBody(line) else { break }
      end += 1
    }
    return start..<end
  }

  private static func opensADiff(_ line: Substring) -> Bool {
    TranscriptDiff.isHunkHeader(line) || line.hasPrefix("diff --git ") || line.hasPrefix("--- ")
  }

  private static func isPreamble(_ line: Substring) -> Bool {
    line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("--- ")
      || line.hasPrefix("+++ ") || line.hasPrefix("old mode ") || line.hasPrefix("new mode ")
      || line.hasPrefix("new file mode ") || line.hasPrefix("deleted file mode ")
      || line.hasPrefix("similarity index ") || line.hasPrefix("rename ")
  }

  private static func isBody(_ line: Substring) -> Bool {
    TranscriptDiff.isHunkHeader(line) || isPreamble(line)
      || line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix(" ") || line.hasPrefix("\\")
  }

  // MARK: - Bounding a turn that is too tall to draw whole

  /// How many lines of each block a bounded turn may draw, given each block's full height.
  ///
  /// A turn is a stack of blocks, so the line bound is shared out: blocks take their full
  /// height in order, the block where the budget runs out gets the rest (so one huge opening
  /// paragraph shows its top), and later blocks get zero and are not drawn. A `budget` at or
  /// above the total leaves every count untouched, which tells the caller nothing was cut.
  public static func allowances(forLineCounts counts: [Int], budget: Int) -> [Int] {
    var remaining = max(0, budget)
    return counts.map { count in
      let allowed = min(max(0, count), remaining)
      remaining -= allowed
      return allowed
    }
  }
}

// MARK: - Inline markdown

extension TranscriptMarkdown {
  private static let inlineOptions = AttributedString.MarkdownParsingOptions(
    interpretedSyntax: .inlineOnlyPreservingWhitespace,
    failurePolicy: .returnPartiallyParsedIfPossible
  )

  /// Bold, italic, inline code and links, parsed by Foundation, falling back to the raw text.
  ///
  /// Here rather than in the view so `TranscriptTurnRender` can parse once per string when
  /// the page settles, off the main actor's redraw path.
  public static func inline(_ raw: String) -> AttributedString {
    (try? AttributedString(markdown: raw, options: inlineOptions)) ?? AttributedString(raw)
  }
}
