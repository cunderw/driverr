import Foundation

/// Every slash command a host offers, whether or not anybody has typed it.
///
/// Recents alone offer nothing on a fresh session, which is when a person most needs to see
/// what exists. This is what is installed, read off the host in one round trip and merged
/// with the recents by `SlashCommandMatcher.offerings(recents:catalog:)`. Ordering and
/// capping belong to the matcher.
public struct SlashCommandCatalog: Equatable, Sendable {
  /// The commands, already de-duplicated by name and sorted.
  public let commands: [SlashCommand]

  public init(commands: [SlashCommand] = []) {
    self.commands = commands
  }

  /// Nothing known, before anybody has asked. Distinct from `builtInsOnly`: before the round
  /// trip Driverr does not know the host runs Claude Code.
  public static let empty = SlashCommandCatalog()

  /// What Claude Code ships, and nothing from the host.
  ///
  /// Both the failure value and the "no skills installed" value. A reader cannot act
  /// differently on the two, and the built-ins are a fact about the agent, not the
  /// filesystem.
  public static let builtInsOnly = SlashCommandCatalog.installed([])

  public var isEmpty: Bool { commands.isEmpty }

  /// The built-ins plus what the host reported, de-duplicated by name, sorted. The host wins
  /// a collision: a project's `.claude/commands/review.md` overrides `/review`, and the
  /// built-in's description would describe the wrong thing.
  public static func installed(_ found: [SlashCommand]) -> SlashCommandCatalog {
    var byName: [String: SlashCommand] = [:]
    for command in builtIns { byName[command.name] = command }
    for command in found { byName[command.name] = command }
    return SlashCommandCatalog(commands: byName.values.sorted { $0.name < $1.name })
  }

  /// The commands Claude Code ships, which are on no disk.
  ///
  /// Taken from Claude Code 2.1.261, and it will drift against newer versions. `claude` is a
  /// native binary with no manifest of these, so there is no way to enumerate them from the
  /// host. Only names that are stable and fit a caption are kept. A renamed or removed one
  /// costs a round trip and a confused agent, which the reader can recover from.
  public static let builtIns: [SlashCommand] = [
    ("/add-dir", "Add another working directory to the session"),
    ("/agents", "Manage the subagents available to this session"),
    ("/clear", "Clear the conversation and start again"),
    ("/compact", "Summarise the conversation so far and keep going"),
    ("/config", "Open the settings for this session"),
    ("/context", "Show what is taking up the context window"),
    ("/cost", "Show what this session has cost so far"),
    ("/doctor", "Check the installation for problems"),
    ("/exit", "End the session"),
    ("/export", "Export the conversation"),
    ("/help", "List the commands this session understands"),
    ("/hooks", "Manage the hooks that run around tool calls"),
    ("/init", "Write a CLAUDE.md describing this codebase"),
    ("/login", "Sign in to a different account"),
    ("/logout", "Sign out of this account"),
    ("/mcp", "Manage the MCP servers this session can reach"),
    ("/memory", "Edit the memory files this session loads"),
    ("/model", "Choose which model answers"),
    ("/permissions", "Edit what this session is allowed to do"),
    ("/release-notes", "Show what changed in this version"),
    ("/resume", "Go back to an earlier conversation"),
    ("/review", "Review a pull request"),
    ("/status", "Show the version, account and connection"),
    ("/statusline", "Configure the status line"),
    ("/terminal-setup", "Configure the terminal's key bindings"),
    ("/todos", "Show the session's task list"),
    ("/usage", "Show usage against the plan's limits"),
    ("/vim", "Toggle vim key bindings in the composer"),
  ].map { SlashCommand(name: $0.0, description: $0.1, source: .builtIn) }
}

/// The `name: value` header at the top of a `SKILL.md`, and the one field the composer needs.
///
/// Here, not in `DriverrTranscript`, because this is plain YAML frontmatter rather than the
/// session file format that module isolates, and here `swift test` covers it without a host.
public enum SkillFrontmatter {
  /// The `description` a frontmatter block declares, or `nil`.
  ///
  /// Four shapes occur in real skills:
  ///
  /// - `description: one line of text`.
  /// - `description: >-` then indented lines, a folded block. Common, and joined with single
  ///   spaces, which is what folding means.
  /// - `description: |` and its variants, a literal block. Also joined with spaces, because
  ///   the row is one line high.
  /// - Quoted, `"…"` or `'…'`, stripped when the quotes match.
  ///
  /// A block ends at the first unindented line, such as a following `metadata:` key. An
  /// empty line inside a block does not end it. `nil` for no frontmatter, no `description`,
  /// or an empty value, which all mean a row with no caption.
  public static func description(inFrontmatter lines: [String]) -> String? {
    guard let start = lines.firstIndex(where: { key(of: $0) == "description" }) else {
      return nil
    }
    let head = value(of: lines[start])
    // A value on the key's line is the whole value. A block marker and a bare
    // `description:` both mean "the indented lines below".
    guard isBlockMarker(head) || head.isEmpty else {
      let single = unquoted(head).trimmingCharacters(in: .whitespacesAndNewlines)
      return single.isEmpty ? nil : single
    }
    var pieces: [String] = []
    for line in lines[lines.index(after: start)...] {
      // A blank line is a folded paragraph break, not the end of the block.
      if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
      guard line.first == " " || line.first == "\t" else { break }
      pieces.append(line.trimmingCharacters(in: .whitespaces))
    }
    let joined = unquoted(pieces.joined(separator: " "))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return joined.isEmpty ? nil : joined
  }

  /// The key a frontmatter line declares, or `nil` for a continuation, a comment or a list
  /// item. Indentation decides, because a description can contain colons.
  private static func key(of line: String) -> String? {
    guard let first = line.first, first != " ", first != "\t", first != "#", first != "-" else {
      return nil
    }
    guard let colon = line.firstIndex(of: ":") else { return nil }
    let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, !name.contains(" ") else { return nil }
    return name
  }

  /// Everything after the first colon on a key line, trimmed.
  private static func value(of line: String) -> String {
    guard let colon = line.firstIndex(of: ":") else { return "" }
    return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
  }

  /// Whether a value is a YAML block marker — `>`, `>-`, `|`, `|+`, `>2` and so on.
  private static func isBlockMarker(_ value: String) -> Bool {
    guard let first = value.first, first == ">" || first == "|" else { return false }
    return value.dropFirst().allSatisfy { $0 == "-" || $0 == "+" || $0.isNumber }
  }

  /// Strips a pair of matching quotes, and only a matching pair.
  private static func unquoted(_ value: String) -> String {
    guard value.count >= 2, let first = value.first, let last = value.last else { return value }
    guard first == last, first == "\"" || first == "'" else { return value }
    return String(value.dropFirst().dropLast())
  }
}
