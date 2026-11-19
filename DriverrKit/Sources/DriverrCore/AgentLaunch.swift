import Foundation

/// A request to start a coding agent in a folder on a host, with an optional first message.
///
/// Every backend starts the agent the same way: it opens a new interactive shell in the
/// folder and the agent's command runs there. So the agent finds the login shell's `PATH`,
/// and the shell stays when the agent exits.
///
/// **The first message goes as an argument, never as typed input after the start.** The agent
/// can stop at a startup question, such as Claude Code's folder trust check. Text typed then
/// answers the question. An argument stays in the agent's argv through the question.
///
/// **A backend does not trust the folder.** herdr, tmux and herdr-core each open a missing
/// folder in the home folder and exit 0, or refuse it with no useful message. So the folder is
/// resolved first, with `resolveCommand(for:)`, and the backend gets the absolute path.
public struct AgentLaunch: Hashable, Sendable {
  /// The agents Driverr can start. No free-form command, by the owner's decision on #97.
  public enum Kind: String, CaseIterable, Hashable, Sendable {
    case claude
    case codex

    /// The program to run, which is also herdr's `agent start --kind`.
    public var command: String { rawValue }
  }

  public let kind: Kind
  /// The folder as the person typed or picked it. `~` and `~/…` are the login account's home.
  public let directory: String
  /// The first message, or `nil` for none. A message of only white space is `nil`.
  public let prompt: String?

  public init(kind: Kind, directory: String, prompt: String? = nil) {
    self.kind = kind
    self.directory = directory
    let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.prompt = trimmed.isEmpty ? nil : trimmed
  }

  // MARK: The typed line

  /// The longest launch line, in bytes, that a new shell is sure to read.
  ///
  /// A shell that has not started reading yet leaves the terminal in canonical mode, and on
  /// macOS a canonical line holds 1024 bytes, the newline included. Measured on #97: tmux ran
  /// a 1008-byte line typed into a new window and silently dropped a 1118-byte one. herdr
  /// refuses a longer line with `agent_start_input_failed`.
  public static let typedLineLimit = 1023

  /// The line a backend types into the new shell, such as `claude -- 'fix the build'`.
  ///
  /// `--` keeps a message that starts with `-` from reading as a flag. The message is one word
  /// that bash, zsh, dash and fish all read back as typed. See
  /// `HookInstallCommands.loginShellQuoted`.
  public var typedLine: String {
    guard let typedPrompt else { return kind.command }
    return "\(kind.command) -- \(HookInstallCommands.loginShellQuoted(typedPrompt))"
  }

  /// The message as every backend sends it: one line, with each control character (Unicode
  /// category Cc, C0, DEL and C1) and each line break a space.
  ///
  /// A typed tab starts completion in an interactive shell, and a typed line break ends a
  /// canonical line and puts the shell at a continuation prompt. herdr refuses any argument
  /// that holds a control character with `invalid_agent_argument`, after the workspace exists.
  ///
  /// herdr's TUI gets this text but types it with its own POSIX quoting (`shell_quote` in
  /// herdr's `src/app/agent_resume.rs`, v0.9.5), not `typedLine`'s. A fish shell reads `\\`,
  /// `\'` and a trailing `\` in that quoting differently, so on a herdr pane whose shell is
  /// fish, a message with backslashes can arrive changed.
  public var typedPrompt: String? {
    prompt.map { prompt in
      String(
        prompt.map { character in
          character.unicodeScalars.contains { $0.properties.generalCategory == .control }
            ? " " : character
        })
    }
  }

  /// Whether `typedLine` is too long for a new shell to read. A start refuses it before it
  /// opens anything.
  public var isTooLong: Bool {
    typedLine.utf8.count > Self.typedLineLimit
  }

  /// - Throws: `AppError.agentPromptTooLong` when `isTooLong`.
  public func checkLength() throws {
    if isTooLong { throw AppError.agentPromptTooLong }
  }

  // MARK: The folder

  /// The line that comes before the resolved path in `resolveCommand(for:)`'s output.
  static let resolveMarker = "driverr-agent-folder"

  /// One POSIX script that prints the folder's absolute path, with symlinks resolved, after a
  /// marker line. The same `cd` as `DirectoryListing.command(for:)`. The marker is there
  /// because an rc file can print first.
  ///
  /// **Not wrapped here.** An exec channel's runner already sends every command through
  /// `LoginShell.posix` at the app's joins, so a fish login shell reads it as `sh` does. A
  /// caller that bypasses those joins, such as a core's `machine.exec`, wraps it itself.
  public static func resolveCommand(for directory: String) -> String {
    "cd -- \(DirectoryListing.cdArgument(directory)) >/dev/null && printf '\\n%s\\n' "
      + "\(resolveMarker) && pwd -P"
  }

  /// The absolute path `resolveCommand(for:)` printed.
  ///
  /// - Throws: `AppError.directoryUnavailable`, named after what was asked for, when no path
  ///   follows the marker: the `cd` failed.
  public static func resolvedDirectory(from result: CommandResult, requested: String) throws
    -> String
  {
    let output = result.standardOutput
    guard let marker = output.range(of: "\n\(resolveMarker)\n") else {
      throw AppError.directoryUnavailable(path: requested)
    }
    var path = output[marker.upperBound...]
    // `pwd` ends its line. Everything before that is the path, line breaks in a name included.
    if path.hasSuffix("\n") { path = path.dropLast() }
    guard path.hasPrefix("/") else { throw AppError.directoryUnavailable(path: requested) }
    return String(path)
  }

  /// The folder's own name, which names the new workspace, window or space. `/` for the root.
  public static func folderName(of path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? "/"
  }
}
