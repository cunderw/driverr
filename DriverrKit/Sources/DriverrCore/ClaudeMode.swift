import Foundation

/// Claude Code's current mode, as the footer under its composer shows it.
///
/// The session file cannot say this: Claude Code writes the mode to it only with the next
/// prompt, not when Shift-Tab changes it. The screen says it at once, so the screen is read.
///
/// The rules follow captures of Claude Code 2.1.329 on the herdr TUI, a herdr-core terminal
/// and tmux, kept in `PaneScreenFixture`, and of 2.1.241 in the older fixtures there:
///
/// ```
/// ─────────────────────────────            ← the composer's upper rule
/// ❯ Try "write a test for <filepath>"      ← the composer, found or no answer
/// ─────────────────────────────            ← its lower rule
///   INSERT | harbour-sheets                ← status-line rows, any number
///   ctx:-- · Haiku 5.5
///   ⏸ manual mode on · ← 1 agent           ← the mode row
/// ```
///
/// - **Only rows below the lower rule count.** A conversation can say "plan mode on" too.
/// - **The words name the mode, not the glyph.** `⏸` marks both manual and plan.
/// - **Nothing after the name counts.** The row ends in `(shift+tab to cycle)`, in
///   `· ← 1 agent`, or in nothing, by width and version.
/// - **A narrow pane cuts the row.** At 18 columns it reads `⏸ manual mode` or
///   `⏵⏵ accept  · …`. A whole name still counts; a cut one is no answer.
/// - **No mode row is manual.** Claude Code 2.1.241 drew nothing in manual mode. 2.1.329
///   draws `⏸ manual mode on`.
public enum ClaudeMode: Hashable, Sendable {
  /// Claude asks before it edits or runs anything. Claude Code calls it "manual mode"; it is
  /// `--permission-mode default`.
  case manual
  case acceptEdits
  case plan
  case auto
  case bypassPermissions
  /// A mode this build does not know, by the footer's own words: `⏵⏵ <name> on`.
  case other(String)

  /// The mode the screen shows, or `nil` when the screen gives no answer: no composer, or a
  /// mode row cut too short to name one.
  public init?(screen: PaneScreen) {
    let rows = screen.lines.map(\.text)
    guard let lowerRule = Self.composerLowerRule(in: rows) else { return nil }
    let footer = rows[(lowerRule + 1)...]
    guard let row = footer.lazy.compactMap(Self.modeRowName).first else {
      self = .manual
      return
    }
    guard let mode = row else { return nil }
    self = mode
  }

  /// The button's words, short so the composer's field keeps its room. Claude Code's footer
  /// names every mode, manual included, and so does this. `spokenName` carries the long
  /// names.
  public var label: String {
    switch self {
    case .manual: "Manual"
    case .acceptEdits: "Edits"
    case .plan: "Plan"
    case .auto: "Auto"
    case .bypassPermissions: "Bypass"
    case .other(let name): Self.capitalised(name)
    }
  }

  /// What VoiceOver reads as the mode button's value.
  public var spokenName: String {
    switch self {
    case .manual: "Manual mode"
    case .acceptEdits: "Accept edits"
    case .plan: "Plan mode"
    case .auto: "Auto mode"
    case .bypassPermissions: "Bypass permissions"
    case .other(let name): Self.capitalised(name)
    }
  }

  // MARK: - Reading the footer

  /// The glyphs that open the mode row. Only these, because other footer rows open with a
  /// symbol too (`✔ Update installed`).
  static let glyphs: Set<String> = ["⏵⏵", "⏸", "⏵"]

  /// The names Claude Code writes before " on", lowercased as it writes them.
  static let names: [String: ClaudeMode] = [
    "manual mode": .manual,
    "default mode": .manual,
    "accept edits": .acceptEdits,
    "plan mode": .plan,
    "auto mode": .auto,
    "bypass permissions": .bypassPermissions,
  ]

  /// The composer's lower rule: the last rule row, when the row just under the rule before it
  /// is the composer's `❯`. `nil` when no composer is on screen, for example under a
  /// permission prompt.
  static func composerLowerRule(in rows: [String]) -> Int? {
    let rules = rows.indices.filter { isRule(rows[$0]) }
    guard rules.count >= 2 else { return nil }
    let lower = rules[rules.count - 1]
    let upper = rules[rules.count - 2]
    guard upper + 1 < lower, rows[upper + 1].first == "❯" else { return nil }
    return lower
  }

  /// A row that opens with a rule glyph and carries a run of four, as
  /// `PaneScreenParser.isRuleLine` decides it. A rule can carry the session's name.
  static func isRule(_ row: String) -> Bool {
    guard row.first == "─" else { return false }
    var run = 0
    for character in row {
      run = character == "─" ? run + 1 : 0
      if run >= 4 { return true }
    }
    return false
  }

  /// For a mode row, `.some` of the mode it names, or `.some(nil)` when it is cut too short
  /// to name one. `nil` for a row that is not the mode row.
  static func modeRowName(_ row: String) -> ClaudeMode?? {
    // `.whitespacesAndNewlines` covers the no-break space and herdr's carriage return.
    let trimmed = row.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let space = trimmed.firstIndex(of: " "),
      glyphs.contains(String(trimmed[..<space]))
    else { return nil }
    let rest = trimmed[trimmed.index(after: space)...]
    if let on = rest.range(of: " on", options: .literal), isNameEnd(rest[on.upperBound...]) {
      let name = rest[..<on.lowerBound].lowercased()
      return .some(names[name] ?? .other(name))
    }
    // Cut short: what is left before the suffix or the ellipsis counts only if it is a
    // whole known name.
    var name = Substring(rest)
    for cut in ["  ", " ·", " (", "…"] {
      if let range = name.range(of: cut) { name = name[..<range.lowerBound] }
    }
    return .some(names[name.trimmingCharacters(in: .whitespaces).lowercased()])
  }

  /// Whether " on" ends the name here: at the row's end or before its suffix.
  private static func isNameEnd(_ after: Substring) -> Bool {
    guard let next = after.first else { return true }
    return next == " " || next == "("
  }

  private static func capitalised(_ name: String) -> String {
    name.prefix(1).uppercased() + name.dropFirst()
  }
}
