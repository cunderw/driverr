import Foundation
import Testing

@testable import DriverrCore

/// A unified diff, typed line by line, so a view can colour additions and removals and name
/// the file.
@Suite("Reading a unified diff")
struct TranscriptDiffTests {
  private static let gitDiff = """
    diff --git a/src/pool.rs b/src/pool.rs
    index 1a2b3c4..5d6e7f8 100644
    --- a/src/pool.rs
    +++ b/src/pool.rs
    @@ -12,7 +12,9 @@ impl Pool {
         pub fn new() -> Self {
    -        Self { conns: Vec::new() }
    +        Self {
    +            conns: Vec::with_capacity(8),
    +        }
         }
    """

  @Test("A hunk header is what makes text a diff")
  func hunkHeaderIsTheTest() {
    #expect(TranscriptDiff.looksLikeDiff(Self.gitDiff))
    #expect(TranscriptDiff.looksLikeDiff("@@ -1 +1 @@\n-a\n+b"))
  }

  /// Pros and cons, changelogs and signed numbers all put `+`/`-` in column one.
  @Test("Plus and minus lines without a hunk header are not a diff")
  func plusAndMinusAloneIsNotADiff() {
    #expect(!TranscriptDiff.looksLikeDiff("+ faster startup\n- more memory"))
    #expect(!TranscriptDiff.looksLikeDiff("-3\n+7\n-12"))
    #expect(!TranscriptDiff.looksLikeDiff("--- a/src/pool.rs\n+++ b/src/pool.rs"))
  }

  @Test("Each line is typed by the column it opens on, marker removed")
  func linesAreTyped() {
    let diff = TranscriptDiff.parse(Self.gitDiff)
    #expect(diff.lines[0] == .meta("diff --git a/src/pool.rs b/src/pool.rs"))
    #expect(diff.lines[1] == .meta("index 1a2b3c4..5d6e7f8 100644"))
    #expect(diff.lines[2] == .meta("--- a/src/pool.rs"))
    #expect(diff.lines[3] == .meta("+++ b/src/pool.rs"))
    #expect(diff.lines[4] == .hunk("@@ -12,7 +12,9 @@ impl Pool {"))
    #expect(diff.lines[5] == .context("    pub fn new() -> Self {"))
    #expect(diff.lines[6] == .removal("        Self { conns: Vec::new() }"))
    #expect(diff.lines[7] == .addition("        Self {"))
  }

  /// `--- a/x` opens with a removal's marker and is not one.
  @Test("The file headers are meta, not a removal and an addition")
  func fileHeadersAreNotChanges() {
    let diff = TranscriptDiff.parse(Self.gitDiff)
    #expect(diff.additions == 3)
    #expect(diff.removals == 1)
  }

  @Test("The file is named from the +++ header, with git's b/ prefix removed")
  func namesTheFile() {
    #expect(TranscriptDiff.parse(Self.gitDiff).filePath == "src/pool.rs")
  }

  /// A deletion's `+++` side is `/dev/null`.
  @Test("A deletion falls back to the --- header")
  func deletionNamesWhatWent() {
    let diff = TranscriptDiff.parse("--- a/old.swift\n+++ /dev/null\n@@ -1 +0,0 @@\n-gone")
    #expect(diff.filePath == "old.swift")
  }

  @Test("A bare hunk with no file header names no file rather than guessing one")
  func bareHunkNamesNothing() {
    #expect(TranscriptDiff.parse("@@ -1 +1 @@\n-a\n+b").filePath == nil)
  }

  /// `/dev/null` is a header with no usable path, not a missing header. Read as a removal it
  /// added a bogus line, a bogus count in `changeSummary`, and a bogus `accessibilityLabel`.
  @Test("A /dev/null header is meta with no path, not a removal")
  func devNullHeaderIsMetaNotARemoval() {
    let created = TranscriptDiff.parse("--- /dev/null\n+++ b/new.swift\n@@ -0,0 +1,2 @@\n+one\n+two")
    #expect(created.lines[0] == .meta("--- /dev/null"))
    #expect(created.additions == 2)
    #expect(created.removals == 0)
    #expect(created.filePath == "new.swift")

    let deleted = TranscriptDiff.parse("--- a/old.swift\n+++ /dev/null\n@@ -1 +0,0 @@\n-gone")
    #expect(deleted.lines[1] == .meta("+++ /dev/null"))
    #expect(deleted.additions == 0)
    #expect(deleted.removals == 1)
  }

  /// Swift treats `\r\n` as one `Character`, so `split(separator: "\n")` never splits it.
  @Test("A CRLF patch is still recognised and parsed as a diff")
  func crlfPatchIsStillADiff() {
    let crlf = "@@ -1 +1 @@\r\n-old\r\n+new"
    #expect(TranscriptDiff.looksLikeDiff(crlf))
    let diff = TranscriptDiff.parse(crlf)
    #expect(diff.lines == [.hunk("@@ -1 +1 @@"), .removal("old"), .addition("new")])
  }

  /// A context line whose single space was trimmed. As meta it would indent differently.
  @Test("A trimmed blank line inside a hunk is context, not meta")
  func trimmedBlankIsContext() {
    let diff = TranscriptDiff.parse("@@ -1,3 +1,3 @@\n a\n\n-b\n+c")
    #expect(diff.lines[2] == .context(""))
  }

  /// The preamble repeats the filename the card's header states, and costs most of what fits
  /// above the fold on a phone.
  @Test("The drawn body starts at the first hunk header")
  func bodySkipsThePreamble() {
    let diff = TranscriptDiff.parse(Self.gitDiff)
    #expect(diff.lines.count == diff.body.count + 4)
    #expect(diff.body.first == .hunk("@@ -12,7 +12,9 @@ impl Pool {"))
  }

  @Test("A bare hunk keeps every line in its body")
  func bareHunkKeepsEverything() {
    let diff = TranscriptDiff.parse("@@ -1 +1 @@\n-a\n+b")
    #expect(diff.body.count == diff.lines.count)
  }

  /// Without this a screen reader gets forty unlabelled monospaced rows.
  @Test("The card speaks as one sentence naming the file and the change")
  func speaksAsOneSentence() {
    #expect(
      TranscriptDiff.parse(Self.gitDiff).accessibilityLabel
        == "Diff of src/pool.rs, 3 lines added, 1 line removed"
    )
    #expect(
      TranscriptDiff.parse("@@ -1 +1 @@\n-a\n+b").accessibilityLabel
        == "Diff, 1 line added, 1 line removed"
    )
  }

  /// Git's bookkeeping line. As a removal it would draw a red `No newline at end of file`.
  @Test("The no-newline marker is meta")
  func noNewlineMarkerIsMeta() {
    let diff = TranscriptDiff.parse("@@ -1 +1 @@\n-a\n+b\n\\ No newline at end of file")
    #expect(diff.lines.last == .meta("\\ No newline at end of file"))
  }
}
