/// Claude Code 2.1.328's folder-trust dialog, for issue 109. A real capture, with herdr
/// `pane read --source visible --format ansi` in a 120 by 40 herdr 0.9.5 pane, while herdr
/// reported the pane `blocked`. The folder is replaced with `/home/x/project`, and the four rows
/// of the shell's prompt above the dialog are left out. One source line per terminal row.
///
/// The dialog draws no numbers, and a digit does nothing on it. Measured on the same pane:
/// `send-keys 2` left it open, `Down` then `Enter` trusted the folder, and `Up` on the top row
/// wrapped to the bottom one.
enum ClaudeTrustPromptScreenFixture {
  static let wide =
  [
    "",
    "\u{1B}[0m\u{1B}[38;2;255;193;7m───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────\u{1B}[0m",
    " \u{1B}[0m\u{1B}[1m\u{1B}[38;2;255;193;7mAccessing workspace:\u{1B}[0m",
    "",
    " \u{1B}[0m\u{1B}[1m/home/x/project\u{1B}[0m",
    "",
    " Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source",
    " project, or work from your team). If not, take a moment to review what's in this folder first.",
    "",
    " Claude Code'll be able to read, edit, and execute files here.",
    "",
    " \u{1B}[0m\u{1B}[38;2;153;153;153mSecurity guide\u{1B}[0m",
    "",
    " \u{1B}[0m\u{1B}[38;2;177;185;249m❯ No, exit\u{1B}[0m",
    "   Yes, I trust this folder",
    "",
    " \u{1B}[0m\u{1B}[38;2;153;153;153mEnter to confirm · Esc to cancel\u{1B}[0m",
  ].joined(separator: "\n")
}
