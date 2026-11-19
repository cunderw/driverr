import Testing

@testable import DriverrTmux

/// Claude Code 2.1.328's folder-trust dialog, as `capture-pane -p` printed it in a 100x30 tmux
/// window and again after `resize-window -x 40`. Measured on #122; only the folder is changed.
enum TrustDialogScreens {
  static let wide: [String] = [
    "",
    String(repeating: "─", count: 100),
    " Accessing workspace:",
    "",
    " /home/x/project",
    "",
    " Quick safety check: Is this a project you created or one you trust? (Like your own code, a",
    " well-known open source project, or work from your team). If not, take a moment to review what's in",
    " this folder first.",
    "",
    " Claude Code'll be able to read, edit, and execute files here.",
    "",
    " Security guide",
    "",
    " ❯ No, exit",
    "   Yes, I trust this folder",
    "",
    " Enter to confirm · Esc to cancel",
  ]

  static let narrow: [String] = [
    "",
    String(repeating: "─", count: 40),
    " Accessing workspace:",
    "",
    " /home/x/project",
    "",
    " Quick safety check: Is this a project",
    " you created or one you trust? (Like",
    " your own code, a well-known open",
    " source project, or work from your",
    " team). If not, take a moment to review",
    " what's in this folder first.",
    "",
    " Claude Code'll be able to read, edit,",
    " and execute files here.",
    "",
    " Security guide",
    "",
    " ❯ No, exit",
    "   Yes, I trust this folder",
    "",
    " Enter to confirm · Esc to cancel",
  ]

  /// The dialog's question quoted in a conversation, with its options in a sentence.
  static let prose: [String] = [
    "⏺ The dialog reads:",
    "",
    "  Quick safety check: Is this a project you created or one you trust?",
    "",
    "  It offers No, exit and Yes, I trust this folder.",
  ]
}

@Suite("Claude's trust dialog")
struct ClaudeTrustDialogTests {
  @Test("the measured dialog shows at 100 columns and wrapped at 40")
  func measured() {
    #expect(ClaudeTrustDialog.isShowing(TrustDialogScreens.wide))
    #expect(ClaudeTrustDialog.isShowing(TrustDialogScreens.narrow))
  }

  @Test("the cursor on the other option is still the dialog")
  func cursorMoved() {
    let moved = TrustDialogScreens.wide.map { line in
      switch line {
      case " ❯ No, exit": return "   No, exit"
      case "   Yes, I trust this folder": return " ❯ Yes, I trust this folder"
      default: return line
      }
    }
    #expect(ClaudeTrustDialog.isShowing(moved))
  }

  @Test("the question in prose, with the options in a sentence, is not the dialog")
  func prose() {
    #expect(!ClaudeTrustDialog.isShowing(TrustDialogScreens.prose))
  }

  @Test("the question alone, or the options alone, is not the dialog")
  func halves() {
    let wide = TrustDialogScreens.wide
    #expect(!ClaudeTrustDialog.isShowing(wide.filter { !$0.contains("No, exit") }))
    #expect(!ClaudeTrustDialog.isShowing(wide.filter { !$0.contains("Yes, I trust") }))
    #expect(!ClaudeTrustDialog.isShowing(wide.filter { !$0.contains("Quick safety check:") }))
    #expect(!ClaudeTrustDialog.isShowing([]))
  }

  @Test("options above the question, or apart from each other, are not the dialog")
  func order() {
    #expect(
      !ClaudeTrustDialog.isShowing([
        " ❯ No, exit", "   Yes, I trust this folder", " Quick safety check: Is this a project",
      ]))
    #expect(
      !ClaudeTrustDialog.isShowing([
        " Quick safety check: Is this a project", " ❯ No, exit", "", "   Yes, I trust this folder",
      ]))
  }

  @Test("an option line with more text on it is not the option")
  func optionWithMore() {
    #expect(
      !ClaudeTrustDialog.isShowing([
        " Quick safety check: Is this a project", " ❯ No, exit now", "   Yes, I trust this folder",
      ]))
  }
}
