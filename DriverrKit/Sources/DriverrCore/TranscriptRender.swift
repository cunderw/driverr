import Foundation

/// One assistant turn's markdown, already parsed.
///
/// Parsing in the view body re-split every visible turn on every body evaluation (scroll,
/// poll, keystroke) and parsed inline markdown twice per paragraph. A dictionary written
/// from a view body hits the "Modifying state during view update" trap
/// (`PaneTranscriptCache`), and a stored property on `TranscriptTurn` would make every parser
/// test pay for a parse. So the parse happens once per changed turn when the page settles.
public struct TranscriptTurnRender: Hashable, Sendable {
  /// One inline string, parsed both ways the chat needs it.
  public struct Inline: Hashable, Sendable {
    /// What `SwiftUI.Text` draws: bold, italic, inline code and links.
    public let attributed: AttributedString
    /// The string with markdown marks resolved away. The wrapped line count is taken from
    /// this, because `**` and `` ` `` are not visible characters.
    public let plain: String

    public init(attributed: AttributedString) {
      self.attributed = attributed
      self.plain = String(attributed.characters)
    }
  }

  /// The turn's source text, which alone decides whether a held render may be reused. See
  /// `TranscriptRender.rendering(_:reusing:parse:)`.
  public let text: String
  public let blocks: [TranscriptMarkdown.Block]
  /// Every inline string in `blocks` (paragraphs, heading titles, list items), keyed by the
  /// raw text the view asks with. Code and diff blocks are verbatim and not included.
  public let inlines: [String: Inline]

  public init(text: String, blocks: [TranscriptMarkdown.Block]) {
    self.text = text
    self.blocks = blocks
    var inlines: [String: Inline] = [:]
    for raw in Self.inlineStrings(in: blocks) where inlines[raw] == nil {
      inlines[raw] = Inline(attributed: TranscriptMarkdown.inline(raw))
    }
    self.inlines = inlines
  }

  /// The parsed form of `raw`, parsing it now if this render does not hold it, as for a
  /// preview or a turn drawn with no render.
  public func inline(_ raw: String) -> AttributedString {
    inlines[raw]?.attributed ?? TranscriptMarkdown.inline(raw)
  }

  /// `raw` with its markdown resolved, for measuring. Same fallback as `inline(_:)`.
  public func plain(_ raw: String) -> String {
    inlines[raw]?.plain ?? String(TranscriptMarkdown.inline(raw).characters)
  }

  private static func inlineStrings(in blocks: [TranscriptMarkdown.Block]) -> [String] {
    blocks.flatMap { block -> [String] in
      switch block {
      case .paragraph(let raw): [raw]
      case .heading(let title, _): [title]
      case .list(let items, _): items.map(\.text)
      case .code, .diff: []
      }
    }
  }
}

/// Every turn on the page, parsed, keyed by turn id. `PaneTranscriptModel` builds it when a
/// page settles and `PaneChatView` reads rows from it.
///
/// Reuse is keyed on id and text. Record ids are stable across polls, so id alone would
/// freeze the streaming newest turn at its first parse. With both, only changed turns
/// re-parse.
public struct TranscriptRender: Hashable, Sendable {
  /// Turn id to its render. A turn with nothing to parse (human text, a command, a tool run)
  /// is absent.
  public private(set) var turns: [String: TranscriptTurnRender]

  public init(turns: [String: TranscriptTurnRender] = [:]) {
    self.turns = turns
  }

  public subscript(id: TranscriptTurn.ID) -> TranscriptTurnRender? { turns[id] }

  public var isEmpty: Bool { turns.isEmpty }

  /// Parses the turns that need it, reusing what `previous` holds. `parse` is a parameter so
  /// a test can count calls. The map is rebuilt each time, so turns that left the page drop
  /// out.
  public static func rendering(
    _ turns: [TranscriptTurn],
    reusing previous: TranscriptRender = TranscriptRender(),
    parse: (String) -> [TranscriptMarkdown.Block] = { TranscriptMarkdown.blocks(from: $0) }
  ) -> TranscriptRender {
    var next: [String: TranscriptTurnRender] = [:]
    next.reserveCapacity(turns.count)
    for turn in turns {
      guard let text = markdownText(of: turn) else { continue }
      if let held = previous.turns[turn.id], held.text == text {
        next[turn.id] = held
        continue
      }
      next[turn.id] = TranscriptTurnRender(text: text, blocks: parse(text))
    }
    return TranscriptRender(turns: next)
  }

  /// The text a turn is drawn through markdown, or `nil`.
  ///
  /// Excluded, matching the view's branches: human text and commands are drawn verbatim, a
  /// tool run has no prose, and an agent event is a one-line notice whose body is parsed
  /// only when opened. The event is excluded explicitly rather than relying on its `text`
  /// being `nil`, so a change to `TranscriptTurn.text` cannot put every relayed body through
  /// the parse.
  private static func markdownText(of turn: TranscriptTurn) -> String? {
    guard turn.agentEvent == nil else { return nil }
    guard !turn.isHuman, !turn.isCommand, let text = turn.text, !text.isEmpty else {
      return nil
    }
    return text
  }
}
