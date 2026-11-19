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

  // MARK: - The other measured pickers

  @Test("the first stage of /model reads with no transcript at all")
  func modelStage1WithNoTranscript() throws {
    let call = try #require(
      Transcript.questionCall(
        in: nil, screen: screen(CodexPickerScreenFixture.modelStage1), agentStatus: .idle))
    let question = try #require(call.questions.first)
    #expect(question.question == "Select Model and Effort")
    #expect(question.options == ["GPT-6-Luna", "GPT-5.6-Terra (current)", "GPT-5.6-Luna"])
    #expect(
      question.optionDescriptions == [
        "Fast and affordable model for easier tasks.",
        "Legacy balanced model for agentic coding.",
        "Legacy fast model for simpler tasks.",
      ])
    #expect(
      question.pickerTab
        == PickerTab(index: 0, count: 1, submitsAfter: false, leavesNoRecord: true))
  }

  /// Its footer is `enter default · s session · esc back`, not the first stage's.
  @Test("the second stage of /model reads under its own footer")
  func modelStage2() throws {
    let question = try #require(try call(CodexPickerScreenFixture.modelStage2).questions.first)
    #expect(question.question == "Select Reasoning Level for GPT-5.6-Terra")
    #expect(
      question.options == [
        "Low", "Medium (default) (current)", "High", "Extra high", "More reasoning…",
      ])
    #expect(question.optionNumbers == [1, 2, 3, 4, 5])
  }

  /// A digit on the first stage opens the second. The chat reseeds its chips and retires the
  /// `Sent` notice on that, as it does for Claude's next tab.
  @Test("the second stage of /model is a new question")
  func modelAdvances() throws {
    let first = try call(CodexPickerScreenFixture.modelStage1).replyChipGroups
    let second = try call(CodexPickerScreenFixture.modelStage2).replyChipGroups
    #expect(ReplyChipGroup.screenQuestionAdvanced(from: first, to: second))
  }

  /// Codex records nothing for the answer and herdr keeps the pane idle, so the picker going
  /// is the only sign. Claude's picker keeps waiting for the transcript;
  /// `PaneQuestionScreenTests` holds that.
  @Test("a Codex picker leaving the screen is its answer landing")
  func pickerGoing() throws {
    let open = try call(CodexPickerScreenFixture.permissions).replyChipGroups
    #expect(ReplyChipGroup.screenQuestionAdvanced(from: open, to: []))
  }

  @Test("a picker under a numbered reply reads only the picker's options")
  func pickerUnderNumberedList() throws {
    let question = try #require(
      try call(CodexPickerScreenFixture.permissionsUnderNumberedList).questions.first)
    #expect(question.question == "Update Model Permissions")
    #expect(question.options == ["Ask for approval", "Approve for me", "Full Access", "Read Only"])
  }

  /// herdr reports a Codex picker `idle`, and the screen is read on any status for it. Claude's
  /// picker is read only on a `blocked` pane; `PaneQuestionScreenTests` keeps that rule.
  @Test(
    "a Codex picker reads whatever herdr says",
    arguments: [AgentStatus.idle, .done, .unknown, .blocked, .working])
  func anyStatus(status: AgentStatus) {
    #expect(
      Transcript.questionCall(
        in: nil, screen: screen(CodexPickerScreenFixture.permissions), agentStatus: status)
        != nil)
  }

  @Test("the screen read says which picker it found")
  func kind() throws {
    let read = try #require(
      PaneQuestionScreen(screen: screen(CodexPickerScreenFixture.permissions)))
    #expect(read.kind == .codexPicker)
  }

  /// The chat's waiting line names the call. Claude's picker is `AskUserQuestion`; Codex's has
  /// no tool name, so the line is the plain sentence.
  @Test("the waiting line over a Codex picker names no tool")
  func waitingLine() throws {
    let notice = try call(CodexPickerScreenFixture.permissions).pendingNotice(agentStatus: .idle)
    #expect(notice.label == TranscriptChatCopy.pendingQuestion)
  }
}
