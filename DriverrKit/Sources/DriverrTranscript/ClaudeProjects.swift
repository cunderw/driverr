import Foundation

/// Where Claude Code keeps a session's transcript. The project directory is a pure
/// function of the pane's `cwd`, so only picking the file inside it needs herdr's
/// `agent_session` integration.
enum ClaudeProjects {
  /// Claude Code's own name for a working directory: every `/` and `.` becomes `-`.
  ///
  /// A trailing slash is dropped first, so `/x/y` and `/x/y/` give one answer. Nothing else
  /// is normalised: a relative or `~` path yields a slug for a directory that does not
  /// exist, and the resolver truthfully finds no files. Expanding `~` would mean guessing
  /// the host's home directory from the phone.
  static func slug(forWorkingDirectory directory: String) -> String {
    var path = directory
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return String(path.map { $0 == "/" || $0 == "." ? "-" : $0 })
  }

  /// Where the project directories live, as a shell fragment the host expands. `$HOME`,
  /// because the login account need not be the one named in a pane's `cwd`.
  static let root = "\"$HOME/.claude/projects\""

  static let fileExtension = "jsonl"
}
