import Foundation

/// A slash command the person can be offered in the composer's `/` autocomplete.
///
/// Recents come from the transcript: `TranscriptTurn.isCommand` is a typed fact, and the
/// parser normalises the envelope to `"/name args"` (`TranscriptParser.slashCommand(in:)`).
/// A recent is a command this agent has already accepted in this session. A pane whose
/// transcript this build cannot read produces no command turns, so needs no separate check.
public struct SlashCommand: Identifiable, Hashable, Sendable {
  /// Where a command was learned from. Carried because a recent is known to be accepted,
  /// while everything else is a file Driverr found on the host. The merge uses it to keep a
  /// recent's position and take the catalogue's description.
  public enum Source: Hashable, Sendable {
    /// Mined out of this pane's own transcript.
    case recent
    /// Shipped by Claude Code itself. See `SlashCommandCatalog.builtIns` for why this is a
    /// static list and what that costs.
    case builtIn
    /// A `~/.claude/skills/<name>/SKILL.md` on the host.
    case userSkill
    /// A `.claude/skills/<name>/SKILL.md` under the pane's own working directory.
    case projectSkill
    /// A `.claude/commands/<name>.md` under the pane's own working directory.
    case projectCommand
    /// A skill inside an installed plugin, named `plugin:skill` as Claude Code addresses it.
    case pluginSkill
  }

  /// The command as typed, slash included, arguments dropped: `"/run-tests"`, not
  /// `"/code-review high --fix"`. An argument is never invented.
  public let name: String

  /// What the command is for, in one sentence, or `nil`. `nil` is ordinary for a recent,
  /// since the transcript never says what a command does, and for a command file with no
  /// frontmatter.
  public let description: String?

  public let source: Source

  public var id: String { name }

  public init(name: String, description: String? = nil, source: Source = .recent) {
    self.name = name
    self.description = description
    self.source = source
  }

  /// This command with another's description, for a recent the host also has installed.
  func described(by other: SlashCommand) -> SlashCommand {
    guard description == nil, let borrowed = other.description else { return self }
    return SlashCommand(name: name, description: borrowed, source: source)
  }
}

/// Turns a transcript into a most-recently-used, typed-prefix-filtered list of slash
/// commands — the composer's `/` autocomplete.
public enum SlashCommandMatcher {
  /// How many rows the composer offers at once.
  ///
  /// A cap, not a page. The list sits above the composer with the keyboard up and must not
  /// cover the turn being answered. On an iPhone 17 that band is 299 pt, and three rows plus
  /// the header take about 145 pt (five took 213 pt and covered a turn). Enforced in the
  /// matcher so every caller gets it and `swift test` asserts it.
  ///
  /// No overflow affordance: the list is most-recent first, so typing another character is
  /// the better way to reach the rest. The header's caption makes the short list read as a
  /// summary rather than as one that ran out.
  public static let maximumSuggestions = 3

  /// The cap at an accessibility text size, where rows are about twice as tall. The view
  /// chooses between the two (`PaneComposerBar.slashSuggestions`), so the matcher does not
  /// read the environment.
  public static let maximumSuggestionsAtAccessibilitySizes = 2

  /// The distinct commands this transcript has used, most recent first. Walked backward, so
  /// a repeated command appears once, at its latest use.
  public static func recentCommands(in transcript: Transcript) -> [SlashCommand] {
    var seen = Set<String>()
    var result: [SlashCommand] = []
    for turn in transcript.turns.reversed() where turn.isCommand {
      guard case .human(let text) = turn.speech else { continue }
      guard let name = commandName(in: text) else { continue }
      guard seen.insert(name).inserted else { continue }
      result.append(SlashCommand(name: name))
    }
    return result
  }

  /// The recents and the host's catalogue as one list.
  ///
  /// Recents first, in their own order, because with three rows a command this session ran
  /// beats one merely installed. The rest alphabetically, not by source, because a reader
  /// typing `/co` expects name order. A recent that is also installed keeps its position and
  /// gains the catalogue's description. Not capped here; `matches(_:typed:limit:)` caps.
  public static func offerings(
    recents: [SlashCommand],
    catalog: SlashCommandCatalog
  ) -> [SlashCommand] {
    let installed = Dictionary(
      catalog.commands.map { ($0.name, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var seen = Set<String>()
    var result: [SlashCommand] = []
    for command in recents where seen.insert(command.name).inserted {
      guard let match = installed[command.name] else {
        result.append(command)
        continue
      }
      result.append(command.described(by: match))
    }
    // The catalogue is already sorted by name (`SlashCommandCatalog.installed`).
    result.append(contentsOf: catalog.commands.filter { !seen.contains($0.name) })
    return result
  }

  /// `commands` filtered to those `typed` could still be spelling (a case-insensitive
  /// prefix match), truncated to `limit`.
  ///
  /// Empty once `typed` is not a bare command word: it must start with `/` and contain no
  /// whitespace. After a space the person is typing an argument, and completing then would
  /// replace what they typed.
  public static func matches(
    _ commands: [SlashCommand],
    typed: String,
    limit: Int = maximumSuggestions
  ) -> [SlashCommand] {
    guard typed.hasPrefix("/"), !typed.dropFirst().contains(where: \.isWhitespace) else {
      return []
    }
    guard typed != "/" else { return Array(commands.prefix(limit)) }
    let matched = commands.filter {
      $0.name.range(of: typed, options: [.caseInsensitive, .anchored]) != nil
    }
    return Array(matched.prefix(limit))
  }

  /// The bare `/name` a command turn opens with. The parser has normalised the turn, so the
  /// first word is the command.
  private static func commandName(in text: String) -> String? {
    guard let firstWord = text.split(separator: " ", maxSplits: 1).first else { return nil }
    let name = String(firstWord)
    guard name.hasPrefix("/"), name.count > 1 else { return nil }
    return name
  }
}

/// Which suggestion row an external keyboard has highlighted.
///
/// A value so `swift test` covers the wrapping edges: down or up from nothing, the wrap at
/// each end, and an index left past the end of a list that shrank. The soft keyboard never
/// sets it, because a tap chooses a row directly.
public struct SlashSuggestionSelection: Equatable, Sendable {
  /// The highlighted row, or `nil`. Not "row 0 by default": Return with nothing highlighted
  /// sends the message, and a default would send the first command instead.
  public private(set) var index: Int?

  public init(index: Int? = nil) {
    self.index = index
  }

  /// Moves the highlight down, wrapping, or to the first row from nothing.
  public mutating func moveDown(count: Int) {
    guard count > 0 else { return reset() }
    guard let current = resolved(against: count) else { return index = 0 }
    index = (current + 1) % count
  }

  /// Moves the highlight up, wrapping, or to the last row from nothing, as Claude Code's own
  /// list does.
  public mutating func moveUp(count: Int) {
    guard count > 0 else { return reset() }
    guard let current = resolved(against: count) else { return index = count - 1 }
    index = (current - 1 + count) % count
  }

  /// Drops the highlight.
  public mutating func reset() {
    index = nil
  }

  /// The highlighted command, or `nil` when nothing is highlighted or the index is past the
  /// end of a shrunk list.
  public func highlighted(in commands: [SlashCommand]) -> SlashCommand? {
    guard let index = resolved(against: commands.count) else { return nil }
    return commands[index]
  }

  /// `index`, only when it names a row of a `count`-long list. One place decides what a
  /// stale index means, so Return and the arrow keys agree.
  private func resolved(against count: Int) -> Int? {
    guard let index, index >= 0, index < count else { return nil }
    return index
  }
}
