import Foundation
import Testing

@testable import DriverrCore

/// Issue 109: Codex's own selection pickers (`/permissions`, `/model`) drawn on the pane's
/// screen. Measured on Codex CLI 0.170.0 under herdr 0.9.5: with the picker open herdr reports
/// the pane `idle`, the terminal title carries no `Action Required` marker, and the rollout
/// records nothing until a choice is made. The screen is the only place the picker exists.
@Suite("Codex picker on the screen")
struct CodexPickerScreenTests {
  private func screen(_ ansi: String) -> PaneScreen {
    PaneScreen.sanitised(ansi, lines: PaneScreen.maximumLines)
  }

  private let transcript = Transcript(
    turns: [
      TranscriptTurn(id: "1", speech: .human("Reply with the single word hi.")),
      TranscriptTurn(id: "2", speech: .assistant("hi")),
    ],
    window: .none
  )

  private func call(_ ansi: String) throws -> ToolCall {
    try #require(transcript.questionCall(screen: screen(ansi), agentStatus: .idle))
  }

  /// Guards the fixtures, so the failures above are about the parse and not the capture. The
  /// narrow one is tmux's `capture-pane -e`, not herdr's.
  @Test("the captures hold the picker's rows once sanitised")
  func capturesHoldThePicker() {
    for ansi in [CodexPickerScreenFixture.permissions, CodexPickerScreenFixture.permissionsNarrow] {
      let rows = screen(ansi).lines.map { $0.text.trimmingCharacters(in: .whitespaces) }
      #expect(rows.contains("enter select · esc back"))
      #expect(rows.contains("Update Model Permissions"))
      #expect(rows.contains { $0.hasPrefix("› 2. Approve for me (current)") })
    }
  }

  @Test("an open Codex picker offers its options while herdr calls the pane idle")
  func pickerWhileIdle() throws {
    let question = try #require(try call(CodexPickerScreenFixture.permissions).questions.first)
    #expect(question.question == "Update Model Permissions")
    #expect(
      question.options == ["Ask for approval", "Approve for me (current)", "Full Access", "Read Only"])
    #expect(question.optionNumbers == [1, 2, 3, 4])
    #expect(!question.allowsMultiple)
  }

  /// Measured: `pane send-keys 4` applied Read Only and closed the picker, with no Enter.
  @Test("a chip answers the Codex picker with its digit alone")
  func digitAnswers() throws {
    var selection = ReplyChipSelection(
      groups: try call(CodexPickerScreenFixture.permissions).replyChipGroups)
    let group = try #require(selection.groups.first)
    let chip = try #require(group.chips.first { $0.label == "Full Access" })
    selection.toggle(chip, in: group)
    #expect(selection.reply?.action == .key(.digit3))
  }

  @Test("a 60-column Codex picker joins its wrapped descriptions")
  func narrow() throws {
    let question = try #require(
      try call(CodexPickerScreenFixture.permissionsNarrow).questions.first)
    #expect(
      question.options == ["Ask for approval", "Approve for me (current)", "Full Access", "Read Only"])
    #expect(
      question.optionDescriptions.first
        == "Read and edit workspace files and run commands, with approval required for internet access or edits outside the workspace"
    )
  }

  @Test("an idle Codex reply that is a numbered list is not a picker")
  func numberedListIsNotAPicker() {
    #expect(
      transcript.questionCall(
        screen: screen(CodexPickerScreenFixture.idleNumberedList), agentStatus: .idle) == nil)
  }
}
