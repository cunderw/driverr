import Foundation
import Testing

@testable import DriverrCore

/// Claude Code's folder-trust dialog read off the screen as a question, so the chat can answer
/// it (#109). The dialog takes no digits, so a chip moves the cursor and presses Enter.
@Suite("Claude's trust dialog on the screen")
struct ClaudeTrustPromptScreenTests {
  private func screen(_ text: String) -> PaneScreen {
    PaneScreen.sanitised(text, lines: PaneScreen.maximumLines)
  }

  /// The same dialog at 40 columns, from `capture-pane -p` on #122. The question wraps and the
  /// options do not.
  private static let narrow = [
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
  ].joined(separator: "\n")

  private func read(_ text: String) throws -> PaneQuestionScreen {
    try #require(PaneQuestionScreen(screen: screen(text)))
  }

  private func reply(_ label: String, on text: String) throws -> ReplyChip.Action? {
    let call = try #require(
      Transcript.questionCall(in: nil, screen: screen(text), agentStatus: .blocked))
    var selection = ReplyChipSelection(groups: call.replyChipGroups)
    let group = try #require(selection.groups.first)
    let chip = try #require(group.chips.first { $0.label == label })
    selection.toggle(chip, in: group)
    return selection.reply?.action
  }

  @Test("the measured dialog reads as a question with its two options", arguments: [0, 1])
  func reads(width: Int) throws {
    let read = try read(width == 0 ? ClaudeTrustPromptScreenFixture.wide : Self.narrow)
    #expect(read.kind == .claudeTrust)
    #expect(
      read.question.question
        == "Quick safety check: Is this a project you created or one you trust?")
    #expect(read.question.options == ["No, exit", "Yes, I trust this folder"])
    #expect(read.question.pickerTab?.cursor == 1)
    #expect(!read.question.allowsMultiple)
  }

  @Test("Yes moves down from No and presses Enter")
  func yesFromNo() throws {
    #expect(
      try reply("Yes, I trust this folder", on: ClaudeTrustPromptScreenFixture.wide)
        == .keys([.down, .enter]))
  }

  @Test("No, under the cursor already, is Enter alone")
  func noFromNo() throws {
    #expect(try reply("No, exit", on: ClaudeTrustPromptScreenFixture.wide) == .keys([.enter]))
  }

  /// The cursor moved in the terminal. The screen says where it is.
  @Test("with the cursor on Yes, No moves up")
  func noFromYes() throws {
    let moved = Self.narrow
      .replacingOccurrences(of: " ❯ No, exit", with: "   No, exit")
      .replacingOccurrences(of: "   Yes, I trust this folder", with: " ❯ Yes, I trust this folder")
    #expect(try reply("No, exit", on: moved) == .keys([.up, .enter]))
    #expect(try reply("Yes, I trust this folder", on: moved) == .keys([.enter]))
  }

  /// Enter picks the row under the cursor, so a row with no cursor gives no keys to trust.
  @Test("the dialog with no cursor on either option is not read")
  func noCursor() {
    let bare = Self.narrow.replacingOccurrences(of: " ❯ No, exit", with: "   No, exit")
    #expect(PaneQuestionScreen(screen: screen(bare)) == nil)
  }

  /// The dialog is Claude's, which herdr reports blocked. Claude's screen questions keep that
  /// gate.
  @Test("the dialog is read only on a blocked pane")
  func onlyWhileBlocked() {
    #expect(
      Transcript.questionCall(
        in: nil, screen: screen(ClaudeTrustPromptScreenFixture.wide), agentStatus: .idle)
        == nil)
  }

  @Test("the question quoted in prose is not the dialog")
  func prose() {
    let prose = [
      "⏺ The dialog reads:",
      "",
      "  Quick safety check: Is this a project you created or one you trust?",
      "",
      "  It offers No, exit and Yes, I trust this folder.",
    ].joined(separator: "\n")
    #expect(PaneQuestionScreen(screen: screen(prose)) == nil)
    #expect(!ClaudeTrustPrompt.isShowing(prose.components(separatedBy: "\n")))
  }

  @Test("the waiting line over the dialog names no tool")
  func waitingLine() throws {
    let call = try #require(
      Transcript.questionCall(
        in: nil, screen: screen(ClaudeTrustPromptScreenFixture.wide), agentStatus: .blocked))
    #expect(call.pendingNotice(agentStatus: .blocked).label == TranscriptChatCopy.pendingQuestion)
  }
}
