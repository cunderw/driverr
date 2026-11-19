import Foundation

/// Claude Code's folder-trust dialog, read from a pane's visible screen.
///
/// Claude asks whether to trust a folder it has not opened before, and it writes no session
/// record until the user answers. Its title is not set either, so tmux shows its default, the
/// host's name, which a shell pane shows too. The screen is the only signal. `TmuxControl`
/// reads it only for a pane that Claude leads and whose record is missing. See #122.
///
/// Measured on Claude Code 2.1.328 in tmux 3.7c, at 100 and at 40 columns:
///
/// ```
///  Quick safety check: Is this a project you created or one you trust? (Like your own code, a
///  ...
///  ❯ No, exit
///    Yes, I trust this folder
/// ```
///
/// The question wraps at 40 columns and the option lines do not. So the match is three whole
/// lines: one that starts with the question's opening words, then the two options on adjacent
/// lines below it. Each is trimmed, and the cursor may be on either option. A conversation that
/// quotes the question, or names the options in a sentence, does not match.
enum ClaudeTrustDialog {
  static let question = "Quick safety check:"
  static let options = ("No, exit", "Yes, I trust this folder")

  static func isShowing(_ lines: [String]) -> Bool {
    let lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }
    guard let asked = lines.firstIndex(where: { $0.hasPrefix(question) }) else { return false }
    let below = lines[(asked + 1)...]
    return zip(below, below.dropFirst()).contains { first, second in
      option(first) == options.0 && option(second) == options.1
    }
  }

  /// An option line without the cursor in front of it.
  private static func option(_ line: String) -> Substring {
    guard line.hasPrefix("❯") else { return Substring(line) }
    return line.dropFirst().drop(while: \.isWhitespace)
  }
}
