import DriverrCore
import Foundation

/// What Codex's terminal title says it is doing.
///
/// Codex keeps no record of a running process's state, and its rollout files never hold an
/// approval or a question, so the title is the only signal. Codex sets it with OSC 0, and tmux
/// hands it back as `#{pane_title}`. Without `-u` the non-ASCII frames read as `_`.
///
/// Read from codex 0.164.0's own strings:
/// - **Blocked**: `[ ! ] Action Required`, alternating each second with `[ . ] Action Required`.
///   Both frames are blocked, or a poll that lands on the second would clear the request and the
///   next would announce it again.
/// - **Working**: a braille spinner frame (U+2800 to U+28FF) first.
/// - **Idle**: anything else.
///
/// A title the user set with `/title`, or one drawn with animations off, carries no marker and
/// reads as idle. What the agent waits for is not in the title, so a blocked Codex has no
/// `AgentBlockedKind`.
enum CodexTitle {
  /// The two frames of the blink. Both are followed by `Action Required`.
  private static let markers = ["[ ! ] ", "[ . ] "]
  private static let actionRequired = "Action Required"
  /// What Codex may draw in front of the marker.
  private static let attentionDot = "● "
  private static let spinner: ClosedRange<Unicode.Scalar> = "\u{2800}"..."\u{28FF}"

  static func status(of title: String) -> AgentStatus {
    if blockedRest(of: title) != nil { return .blocked }
    if let first = title.unicodeScalars.first, spinner.contains(first) { return .working }
    return .idle
  }

  /// The title without its state, so a pane's label is the same while Codex blinks, works and
  /// waits. Empty when nothing follows the marker.
  static func display(_ title: String) -> String {
    if let rest = blockedRest(of: title) {
      // `[ ! ] Action Required | driverr` names the folder after the separator.
      let trimmed = rest.drop(while: \.isWhitespace)
      let afterSeparator = trimmed.first == "|" ? trimmed.dropFirst() : trimmed
      return String(afterSeparator.drop(while: \.isWhitespace))
    }
    if let first = title.unicodeScalars.first, spinner.contains(first) {
      return String(title.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
    // An idle title can carry the dot too, and the label must not change when it comes and goes.
    return title.hasPrefix(attentionDot) ? String(title.dropFirst(attentionDot.count)) : title
  }

  /// What follows `Action Required`, or `nil` when the title is not a blocked one.
  private static func blockedRest(of title: String) -> Substring? {
    var rest = Substring(title)
    if rest.hasPrefix(attentionDot) { rest = rest.dropFirst(attentionDot.count) }
    guard let marker = markers.first(where: { rest.hasPrefix($0) }) else { return nil }
    rest = rest.dropFirst(marker.count)
    guard rest.hasPrefix(actionRequired) else { return nil }
    return rest.dropFirst(actionRequired.count)
  }
}
