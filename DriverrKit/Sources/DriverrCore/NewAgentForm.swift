import Foundation

/// What the New Agent sheet holds before a start: the agent, the folder and the first message,
/// as the person typed or picked them.
///
/// The rules live here, not in the view, so the kit tier tests them. The length check asks
/// `AgentLaunch` itself, because the limit is on the typed line, which depends on the agent
/// and on the quoting of the message.
public struct NewAgentForm: Hashable, Sendable {
  public var kind: AgentLaunch.Kind
  /// The folder as typed or picked. White space at either end is not part of it.
  public var directory: String
  /// The first message. Empty means none.
  public var prompt: String

  public init(kind: AgentLaunch.Kind = .claude, directory: String = "", prompt: String = "") {
    self.kind = kind
    self.directory = directory
    self.prompt = prompt
  }

  /// The folder without white space at either end.
  public var trimmedDirectory: String { directory.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// The start this form asks for, or `nil` with no folder.
  public var launch: AgentLaunch? {
    let folder = trimmedDirectory
    guard !folder.isEmpty else { return nil }
    return AgentLaunch(kind: kind, directory: folder, prompt: prompt)
  }

  /// Whether the first message makes the line too long to type. Asked with any folder,
  /// because the folder is not part of the typed line.
  public var isPromptTooLong: Bool {
    AgentLaunch(kind: kind, directory: trimmedDirectory, prompt: prompt).isTooLong
  }

  /// Whether Start can be tapped: a folder, and a line short enough to type.
  public var canStart: Bool { launch != nil && !isPromptTooLong }
}

extension AgentLaunch.Kind {
  /// The agent's product name, as the picker and the Start button show it.
  public var displayName: String {
    switch self {
    case .claude: "Claude Code"
    case .codex: "Codex"
    }
  }
}
