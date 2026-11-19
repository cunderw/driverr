import DriverrCore

/// Claude Code's folder-trust dialog, read from a pane's visible screen. `TmuxControl` reads it
/// only for a pane that Claude leads and whose record is missing (#122).
///
/// The rule is `DriverrCore.ClaudeTrustPrompt`'s, which the chat also reads as a question
/// (#109), so the two cannot drift. This name stays for `TmuxControl` and its tests.
enum ClaudeTrustDialog {
  static func isShowing(_ lines: [String]) -> Bool {
    ClaudeTrustPrompt.isShowing(lines)
  }
}
