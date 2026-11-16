import Foundation
import Testing

@testable import DriverrCore

/// An `Edit`, `MultiEdit` or `Write` call's arguments, turned into the lines a diff card
/// draws, and how much of a long one the card draws.
@Suite("A file edit as a diff")
struct FileEditDiffTests {
  private func edit(_ old: String, _ new: String) -> FileEdit {
    FileEdit(filePath: "/src/pool.rs", change: .replacements([.init(old: old, new: new)]))
  }

  @Test("An Edit shows the changed line as a removal and an addition between context")
  func editIsRemovalThenAddition() {
    let diff = edit("a\nb\nc", "a\nB\nc").diff
    #expect(diff.lines == [.context("a"), .removal("b"), .addition("B"), .context("c")])
    #expect(diff.filePath == "/src/pool.rs")
    #expect(diff.changeSummary == "+1 −1")
  }

  @Test("An Edit that grows a block keeps the shared lines as context")
  func editThatGrows() {
    let diff = edit("fn a() {\n}", "fn a() {\n    go()\n}").diff
    #expect(diff.lines == [.context("fn a() {"), .addition("    go()"), .context("}")])
  }

  @Test("A MultiEdit shows each edit in order, each under its own separator")
  func multiEditIsInOrder() {
    let multi = FileEdit(
      filePath: "config.rs",
      change: .replacements([.init(old: "x", new: "y"), .init(old: "p", new: "q")]))
    #expect(
      multi.diff.lines == [
        .hunk("Edit 1 of 2"), .removal("x"), .addition("y"),
        .hunk("Edit 2 of 2"), .removal("p"), .addition("q"),
      ])
    // The first separator opens the diff, so `body`, which starts at the first hunk line,
    // still holds the first edit.
    #expect(multi.diff.body == multi.diff.lines)
  }

  @Test("A single Edit has no separator")
  func singleEditHasNoSeparator() {
    #expect(!edit("x", "y").diff.lines.contains { if case .hunk = $0 { true } else { false } })
  }

  @Test("A Write is the file's lines, all added")
  func writeIsAllAdditions() {
    let write = FileEdit(filePath: "README.md", change: .write("# Pool\n\nAsync.\n"))
    #expect(write.diff.lines == [.addition("# Pool"), .addition(""), .addition("Async.")])
    #expect(write.diff.changeSummary == "+3 −0")
  }

  /// A final newline ends the last line. Counting it as another line would add an empty
  /// `+` row under every Write and every Edit of whole lines.
  @Test("A trailing newline ends the last line rather than adding an empty one")
  func trailingNewline() {
    #expect(edit("a\n", "a\nb\n").diff.lines == [.context("a"), .addition("b")])
    #expect(FileEdit.fileLines("\n") == [""])
    #expect(FileEdit.fileLines("a\n\n") == ["a", ""])
  }

  @Test("CRLF line endings compare as the lines they are")
  func crlf() {
    #expect(
      edit("a\r\nb", "a\r\nc").diff.lines == [.context("a"), .removal("b"), .addition("c")])
  }

  /// `TranscriptDiff.parse` would read these as a hunk header and a file header. Built from
  /// the strings, they stay file content and the card keeps the call's path.
  @Test("Content that looks like a patch stays content")
  func contentThatLooksLikeAPatch() {
    let looks = edit("", "@@ -1 +1 @@\n+++ b/other.rs\n--- a/other.rs").diff
    #expect(
      looks.lines == [
        .addition("@@ -1 +1 @@"), .addition("+++ b/other.rs"), .addition("--- a/other.rs"),
      ])
    #expect(looks.filePath == "/src/pool.rs")
  }

  @Test("Empty strings give no line on their side")
  func emptyStrings() {
    #expect(edit("", "x").diff.lines == [.addition("x")])
    #expect(edit("x", "").diff.lines == [.removal("x")])
    #expect(edit("", "").diff.lines.isEmpty)
    #expect(FileEdit(filePath: "empty.txt", change: .write("")).diff.lines.isEmpty)
  }

  // MARK: - How much a card draws

  private func write(lines count: Int) -> FileEdit {
    FileEdit(
      filePath: "big.txt",
      change: .write((1...count).map { "line \($0)" }.joined(separator: "\n")))
  }

  @Test("A short edit is drawn whole and offers nothing to expand")
  func shortEditIsWhole() {
    let short = write(lines: FileEdit.collapsedLines)
    #expect(!short.isCollapsible)
    #expect(short.shownLines(isExpanded: false).count == FileEdit.collapsedLines)
    #expect(short.hiddenLineCount(isExpanded: false) == 0)
  }

  @Test("A long Write is collapsed, and expanding it draws the rest")
  func longWriteCollapses() {
    let long = write(lines: 40)
    #expect(long.isCollapsible)
    #expect(long.shownLines(isExpanded: false) == Array(long.diff.lines.prefix(12)))
    #expect(long.hiddenLineCount(isExpanded: false) == 28)
    #expect(long.shownLines(isExpanded: true) == long.diff.lines)
    #expect(long.hiddenLineCount(isExpanded: true) == 0)
  }

  /// One real Write was 1,920 lines, and every drawn line is a row in the view.
  @Test("Even expanded, a whole-file Write is cut at the cap and the rest is counted")
  func expandedIsCapped() {
    let huge = write(lines: 1_920)
    #expect(huge.shownLines(isExpanded: true).count == FileEdit.expandedLineCap)
    #expect(huge.hiddenLineCount(isExpanded: true) == 1_920 - FileEdit.expandedLineCap)
  }

  @Test("An expanded card is stored under its turn and its position in the run")
  func expansionKey() {
    #expect(FileEdit.expansionKey(turnID: "abc-4", callIndex: 2) == "abc-4.edit.2")
  }

  @Test("The card's words")
  func copy() {
    #expect(TranscriptChatCopy.editSeparator(2, of: 3) == "Edit 2 of 3")
    #expect(TranscriptChatCopy.editLinesShown(12, of: 40) == "Showing 12 of 40 lines")
    #expect(TranscriptChatCopy.editLinesNotShown(1) == "1 more line not shown")
  }

  // MARK: - The path a card shows

  @Test("A file under the pane's directory shows relative to it, whichever form each side has")
  func pathUnderThePaneDirectory() {
    let path = "/Users/dev/dev/driverr/src/pool.rs"
    #expect(FileEdit.displayPath(path, paneDirectory: "~/dev/driverr") == "src/pool.rs")
    #expect(FileEdit.displayPath(path, paneDirectory: "/Users/dev/dev/driverr") == "src/pool.rs")
    #expect(FileEdit.displayPath(path, paneDirectory: "/Users/dev/dev/driverr/") == "src/pool.rs")
    #expect(
      FileEdit.displayPath("/srv/app/main.go", paneDirectory: "/srv/app") == "main.go")
  }

  @Test("A file outside the pane's directory shows from home, or whole")
  func pathOutsideThePaneDirectory() {
    #expect(
      FileEdit.displayPath("/Users/dev/notes/todo.md", paneDirectory: "~/dev/driverr")
        == "~/notes/todo.md")
    // A sibling whose name starts with the directory's is not under it.
    #expect(
      FileEdit.displayPath("/Users/dev/dev/driverr-old/a.rs", paneDirectory: "~/dev/driverr")
        == "~/dev/driverr-old/a.rs")
    #expect(FileEdit.displayPath("/etc/hosts", paneDirectory: "~/dev/driverr") == "/etc/hosts")
  }

  @Test("A home directory is written as ~", arguments: [
    ("/Users/dev/a.rs", "~/a.rs"),
    ("/home/dev/src/a.rs", "~/src/a.rs"),
    ("/root/a.rs", "~/a.rs"),
    ("/Users/dev", "~"),
    ("/Users", "/Users"),
    ("/usr/local/bin/x", "/usr/local/bin/x"),
    ("src/a.rs", "src/a.rs"),
  ])
  func homeIsTilde(path: String, shown: String) {
    #expect(FileEdit.homeRelative(path) == shown)
  }

  @Test("With no pane directory, the path shows from home")
  func pathWithNoPaneDirectory() {
    #expect(FileEdit.displayPath("/Users/dev/dev/x.rs", paneDirectory: nil) == "~/dev/x.rs")
    #expect(FileEdit.displayPath("/Users/dev/dev/x.rs", paneDirectory: "") == "~/dev/x.rs")
    #expect(FileEdit.displayPath("/opt/x.rs", paneDirectory: nil) == "/opt/x.rs")
  }
}
