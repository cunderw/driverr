import Foundation
import Testing

@testable import DriverrCore

/// An assistant turn's markdown split into blocks. Inline styling is left to
/// `AttributedString(markdown:)` at the view.
@Suite("Splitting an assistant turn's markdown into blocks")
struct TranscriptMarkdownTests {
  @Test("Plain prose is one paragraph block")
  func plainProse() {
    let blocks = TranscriptMarkdown.blocks(from: "The pool is async now.")
    #expect(blocks == [.paragraph("The pool is async now.")])
  }

  @Test("A heading is its own block, marks and space stripped")
  func heading() {
    let blocks = TranscriptMarkdown.blocks(from: "## Summary\nThe pool is async now.")
    #expect(blocks == [.heading("Summary", level: 2), .paragraph("The pool is async now.")])
  }

  @Test("A run of more than six #s is not a heading")
  func tooManyHashes() {
    let blocks = TranscriptMarkdown.blocks(from: "####### not a heading")
    #expect(blocks == [.paragraph("####### not a heading")])
  }

  @Test("A bare # with no space is not a heading")
  func noSpaceAfterHash() {
    let blocks = TranscriptMarkdown.blocks(from: "#no-space")
    #expect(blocks == [.paragraph("#no-space")])
  }

  @Test("A fenced block is its own block, fences and language tag removed")
  func fencedCode() {
    let text = """
      Fixed in `pool.rs`:

      ```rust
      pub async fn acquire(&self) {}
      ```

      Running the tests now.
      """
    let blocks = TranscriptMarkdown.blocks(from: text)
    #expect(
      blocks == [
        .paragraph("Fixed in `pool.rs`:"),
        .code("pub async fn acquire(&self) {}", language: "rust"),
        .paragraph("Running the tests now."),
      ]
    )
  }

  @Test("A fence with no language tag carries nil")
  func fenceWithNoLanguage() {
    let blocks = TranscriptMarkdown.blocks(from: "```\nplain\n```")
    #expect(blocks == [.code("plain", language: nil)])
  }

  @Test("An unterminated fence runs to the end of the text rather than being dropped")
  func unterminatedFence() {
    let blocks = TranscriptMarkdown.blocks(from: "```swift\nlet x = 1\nstill writing")
    #expect(blocks == [.code("let x = 1\nstill writing", language: "swift")])
  }

  @Test("Consecutive paragraph lines join into one block")
  func consecutiveLinesJoin() {
    let blocks = TranscriptMarkdown.blocks(from: "Line one.\nLine two.")
    #expect(blocks == [.paragraph("Line one.\nLine two.")])
  }

  @Test("Blank text yields no blocks")
  func blank() {
    #expect(TranscriptMarkdown.blocks(from: "   \n  ") == [])
  }

  /// Carrying the boundary blank lines drew about 30 pt of dead space around every block. A
  /// blank line in the middle of a paragraph is prose spacing and stays.
  @Test("A paragraph does not carry the blank line that opened or closed it")
  func paragraphTrimsBoundaryBlankLines() {
    let blocks = TranscriptMarkdown.blocks(from: "## What changed\n\nThe pool is async now.")
    #expect(blocks == [.heading("What changed", level: 2), .paragraph("The pool is async now.")])
  }

  @Test("A blank line inside a paragraph's own prose is preserved")
  func paragraphKeepsAnInteriorBlankLine() {
    let blocks = TranscriptMarkdown.blocks(from: "First half.\n\nSecond half.")
    #expect(blocks == [.paragraph("First half.\n\nSecond half.")])
  }

  // MARK: - Lists

  @Test("A run of bullet lines is one unordered list")
  func bulletList() {
    let blocks = TranscriptMarkdown.blocks(from: "Two things:\n- the pool\n- the retry\nDone.")
    #expect(
      blocks == [
        .paragraph("Two things:"),
        .list([.init(text: "the pool"), .init(text: "the retry")], isOrdered: false),
        .paragraph("Done."),
      ]
    )
  }

  /// A list that opens at `3.` is a continuation; renumbering it rewrites what the agent said.
  @Test("A numbered list keeps the numbers the writer wrote")
  func numberedList() {
    let blocks = TranscriptMarkdown.blocks(from: "3. check the pool\n4) then the retry")
    #expect(
      blocks == [
        .list(
          [.init(text: "check the pool", number: 3), .init(text: "then the retry", number: 4)],
          isOrdered: true)
      ]
    )
  }

  @Test("Indentation becomes a depth, at two spaces a level")
  func nestedList() {
    let blocks = TranscriptMarkdown.blocks(from: "- outer\n  - inner\n    - deeper")
    #expect(
      blocks == [
        .list(
          [
            .init(text: "outer", depth: 0),
            .init(text: "inner", depth: 1),
            .init(text: "deeper", depth: 2),
          ],
          isOrdered: false)
      ]
    )
  }

  /// Without the space rule every negative number and dashed aside becomes a bullet.
  @Test("A marker with no space after it is prose")
  func markerNeedsASpace() {
    #expect(TranscriptMarkdown.blocks(from: "-5 degrees colder") == [.paragraph("-5 degrees colder")])
    #expect(TranscriptMarkdown.blocks(from: "---") == [.paragraph("---")])
  }

  /// `isOrdered` says which marker opened the run, not that every item is numbered. The view
  /// decides the glyph for a `nil` number in one place.
  @Test("A nested bullet under a numbered item carries no number")
  func nestedBulletUnderNumberedItemHasNoNumber() {
    let blocks = TranscriptMarkdown.blocks(from: "1. first\n   - nested\n2. second")
    #expect(
      blocks == [
        .list(
          [
            .init(text: "first", depth: 0, number: 1),
            .init(text: "nested", depth: 1, number: nil),
            .init(text: "second", depth: 0, number: 2),
          ],
          isOrdered: true)
      ]
    )
  }

  /// `blocks(from:)` must split on CRLF too, or the whole turn becomes one heading.
  @Test("A CRLF turn still splits into a heading and a list, not one glued block")
  func crlfTurnStillSplitsIntoBlocks() {
    let blocks = TranscriptMarkdown.blocks(from: "## Heading\r\n\r\n- alpha\r\n- beta\r\n")
    #expect(
      blocks == [
        .heading("Heading", level: 2),
        .list([.init(text: "alpha"), .init(text: "beta")], isOrdered: false),
      ]
    )
  }

  // MARK: - Diffs

  private static let patch = """
    --- a/src/pool.rs
    +++ b/src/pool.rs
    @@ -1,3 +1,3 @@
     fn main() {
    -    old()
    +    new()
     }
    """

  @Test("A fenced diff becomes a diff block, whatever the fence claimed")
  func fencedDiff() {
    for tag in ["diff", "patch", "swift", ""] {
      let blocks = TranscriptMarkdown.blocks(from: "```\(tag)\n\(Self.patch)\n```")
      guard case .diff(let diff)? = blocks.first else {
        Issue.record("Expected a diff block for a ```\(tag) fence, got \(blocks)")
        continue
      }
      #expect(diff.filePath == "src/pool.rs")
      #expect(diff.additions == 1)
      #expect(diff.removals == 1)
    }
  }

  /// A tool result pasted into an answer. As a paragraph, the `+`/`-` column wraps at phone
  /// width.
  @Test("A diff with no fence around it is still a diff")
  func unfencedDiff() {
    let blocks = TranscriptMarkdown.blocks(from: "Fixed it:\n\n\(Self.patch)\n\nRunning tests.")
    #expect(blocks.count == 3)
    #expect(blocks.first == .paragraph("Fixed it:"))
    guard case .diff(let diff) = blocks[1] else {
      Issue.record("Expected the middle block to be a diff, got \(blocks[1])")
      return
    }
    #expect(diff.filePath == "src/pool.rs")
    #expect(blocks.last == .paragraph("Running tests."))
  }

  /// A diff removal line and a bullet both start with `-`. After a blank line the diff
  /// continues only with a hunk header, preamble, or a body line `listItem(of:)` does not
  /// read as a list item.
  @Test("An unfenced diff does not swallow a bullet list that follows it")
  func unfencedDiffDoesNotSwallowATrailingList() {
    let text = "\(Self.patch)\n\n- first bullet\n- second bullet"
    let blocks = TranscriptMarkdown.blocks(from: text)
    #expect(blocks.count == 2)
    guard case .diff = blocks.first else {
      Issue.record("Expected the first block to be the diff, got \(blocks.first as Any)")
      return
    }
    #expect(
      blocks.last
        == .list([.init(text: "first bullet"), .init(text: "second bullet")], isOrdered: false)
    )
  }

  /// A blank context line arrives with its single space stripped (see
  /// `TranscriptDiffTests.trimmedBlankIsContext`) and must not end the hunk.
  @Test("An unfenced diff keeps a trimmed blank context line inside one hunk")
  func unfencedDiffKeepsATrimmedBlankContextLine() {
    let blocks = TranscriptMarkdown.blocks(from: "@@ -1,4 +1,4 @@\n a\n\n-b\n+c")
    #expect(blocks.count == 1)
    guard case .diff(let diff) = blocks.first else {
      Issue.record("Expected one diff block, got \(blocks)")
      return
    }
    #expect(diff.lines == [.hunk("@@ -1,4 +1,4 @@"), .context("a"), .context(""), .removal("b"), .addition("c")])
  }

  /// The diff branch is gated on a hunk header so this stays code.
  @Test("A fenced block with no hunk header is still code")
  func fencedCodeIsNotADiff() {
    let blocks = TranscriptMarkdown.blocks(from: "```swift\nlet delta = +1\nlet back = -1\n```")
    #expect(blocks == [.code("let delta = +1\nlet back = -1", language: "swift")])
  }

  /// The diff check runs first, or `- removed` lines become a list.
  @Test("A diff's removal lines are not read as a bullet list")
  func diffBeatsList() {
    let blocks = TranscriptMarkdown.blocks(from: Self.patch)
    #expect(blocks.count == 1)
    if case .list = blocks[0] { Issue.record("A patch was read as a list") }
  }

  // MARK: - Sharing a line budget across blocks

  @Test("Blocks take their full height until the budget runs out")
  func allowancesSpendInOrder() {
    #expect(TranscriptMarkdown.allowances(forLineCounts: [3, 4, 5], budget: 24) == [3, 4, 5])
    #expect(TranscriptMarkdown.allowances(forLineCounts: [3, 4, 5], budget: 7) == [3, 4, 0])
  }

  /// A turn that opens on one enormous paragraph is still readable while bounded.
  @Test("The block the budget runs out inside gets what is left")
  func allowancesSplitTheLastBlock() {
    #expect(TranscriptMarkdown.allowances(forLineCounts: [3, 40], budget: 24) == [3, 21])
    #expect(TranscriptMarkdown.allowances(forLineCounts: [40], budget: 24) == [24])
  }

  @Test("A budget of nothing allows nothing")
  func allowancesOfZero() {
    #expect(TranscriptMarkdown.allowances(forLineCounts: [3, 4], budget: 0) == [0, 0])
    #expect(TranscriptMarkdown.allowances(forLineCounts: [3, 4], budget: -1) == [0, 0])
  }
}
