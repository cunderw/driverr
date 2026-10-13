import Foundation

/// One hook Driverr asks an agent on the host to run.
///
/// Claude Code writes a pending `AskUserQuestion` to its transcript only once it is
/// answered, unless a `PreToolUse` hook matches the tool; with one, the call lands as the
/// picker appears (tested on Claude Code 2.1.282, with no delay to the picker). The hook
/// itself does nothing but read its input.
///
/// Hooks are data, so a second one is a catalog entry, not new UI.
public struct AgentHook: Hashable, Sendable, Identifiable {
  /// Stable across versions, and the text Driverr looks for on the host: see ``marker``.
  public let id: String
  /// Raised whenever ``command``, ``event`` or ``matcher`` changes. A host with an older
  /// version is offered the update once.
  public let version: Int
  /// What the overview calls it.
  public let title: String
  /// What it does and why, in a sentence the overview shows as it is.
  public let purpose: String
  /// The agent's hook event, e.g. Claude Code's `PreToolUse`.
  public let event: String
  /// The event's matcher, e.g. the tool name.
  public let matcher: String
  /// The shell command, ending in a comment that carries ``marker`` and the version.
  ///
  /// The marker is a shell comment, so it costs nothing at run time and survives in the
  /// settings file as the string Driverr recognises as its own without keeping records.
  public let command: String

  /// - Parameter run: the command's working part. ``command`` appends the marker comment.
  public init(
    id: String,
    version: Int,
    title: String,
    purpose: String,
    event: String,
    matcher: String,
    run: String
  ) {
    self.id = id
    self.version = version
    self.title = title
    self.purpose = purpose
    self.event = event
    self.matcher = matcher
    self.command = "\(run) # \(Self.marker(id: id))\(version)"
  }

  /// `driverr:<id>:v`, which the version number follows. The `:v` after the id keeps one
  /// hook's id from matching as the prefix of another's.
  public var marker: String { Self.marker(id: id) }

  static func marker(id: String) -> String { "driverr:\(id):v" }
}

/// How an agent's settings file is written, which decides the editor that merges hooks
/// into it. One case today; a second agent with another format adds a case and an editor.
public enum AgentSettingsFormat: String, Hashable, Sendable {
  /// Claude Code's `settings.json`: `hooks.<event>` is an array of
  /// `{"matcher", "hooks": [{"type": "command", "command"}]}` groups.
  case claudeCodeJSON
}

/// Everything Driverr installs into one agent's configuration on a host. Generic over
/// agents; the catalog holds Claude Code alone today.
public struct AgentIntegration: Hashable, Sendable, Identifiable {
  /// herdr's agent token, the same string `TranscriptAgent`'s raw values use.
  public let agent: String
  /// What the overview names the agent.
  public let displayName: String
  /// The settings file's directory, as a shell word that expands on the host. Its absence is
  /// reported separately, because it means the agent has never run there.
  public let configDirectory: String
  /// The settings file's name inside ``configDirectory``.
  public let settingsFileName: String
  /// The path as a person reads it, for the overview and the command view.
  public let displayPath: String
  public let format: AgentSettingsFormat
  public let hooks: [AgentHook]
  /// The hook set's version. Raise it with any hook's ``AgentHook/version`` and when a hook
  /// is added or removed. `HookOfferPolicy` compares it to decide whether to offer an update.
  public let version: Int

  public var id: String { agent }

  public init(
    agent: String,
    displayName: String,
    configDirectory: String,
    settingsFileName: String,
    displayPath: String,
    format: AgentSettingsFormat,
    hooks: [AgentHook],
    version: Int
  ) {
    self.agent = agent
    self.displayName = displayName
    self.configDirectory = configDirectory
    self.settingsFileName = settingsFileName
    self.displayPath = displayPath
    self.format = format
    self.hooks = hooks
    self.version = version
  }
}

extension AgentHook {
  /// Without this hook a pending `AskUserQuestion` cannot reach the chat.
  ///
  /// `cat >/dev/null` reads the hook's JSON input and exits 0, letting the tool run. It
  /// cannot block, because Claude Code closes the hook's stdin after writing the input.
  public static let claudeAskUserQuestion = AgentHook(
    id: "claude.ask-user-question",
    version: 1,
    title: "Show Claude’s questions in the chat",
    purpose:
      "Claude Code saves a question it asks you only after you answer it. This hook makes it save the question as soon as it appears, so Driverr can show the question and its choices in the chat. The hook reads its input and does nothing else.",
    event: "PreToolUse",
    matcher: "AskUserQuestion",
    run: "cat >/dev/null"
  )
}

extension AgentIntegration {
  public static let claudeCode = AgentIntegration(
    agent: TranscriptAgent.claude.rawValue,
    displayName: TranscriptAgent.claude.displayName,
    // Claude Code's own override, when a non-interactive shell has it.
    configDirectory: "\"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\"",
    settingsFileName: "settings.json",
    displayPath: "~/.claude/settings.json",
    format: .claudeCodeJSON,
    hooks: [.claudeAskUserQuestion],
    version: 1
  )

  /// Every integration this build can install, in the order the app offers them.
  public static let catalog: [AgentIntegration] = [.claudeCode]

  /// The integration for herdr's agent token, or `nil` for an agent Driverr has no hooks for.
  public static func forAgent(_ token: String) -> AgentIntegration? {
    catalog.first { $0.agent == token.lowercased() }
  }
}
