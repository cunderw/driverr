import DriverrCore
import Foundation

/// What Codex's terminal title says it is doing.
///
/// Codex keeps no record of a running process's state, and its rollout files never hold an
/// approval or a question, so the title is the only signal. Codex sets it with OSC 0, and tmux
/// returns it as `#{pane_title}` (with `-u`, or the non-ASCII frames read as `_`).
enum CodexTitle {
  static func status(of title: String) -> AgentStatus {
    .unknown
  }

  static func display(_ title: String) -> String {
    title
  }
}
