import Foundation
import Testing

@testable import DriverrCore

/// An `AskUserQuestion` read off the pane's screen, and the keys that answer it. Every
/// screen is a real capture; see `PaneQuestionScreenFixture`.
@Suite("PaneQuestionScreen")
struct PaneQuestionScreenTests {
  private func read(_ ansi: String) -> PaneQuestionScreen? {
    PaneQuestionScreen(screen: PaneScreen.sanitised(ansi, lines: PaneScreen.maximumLines))
  }

  private func question(_ ansi: String) throws -> PendingQuestion {
    try #require(read(ansi)).question
  }

  // MARK: - What the screen says

  @Test("a single-select question reads with its header, options and descriptions")
  func singleSelect() throws {
    let question = try question(PaneQuestionScreenFixture.singleSelect)
    #expect(question.question == "Pick a fruit")
    #expect(question.header == "Fruit")
    #expect(question.options == ["Apple", "Banana", "Cherry"])
    #expect(question.optionNumbers == [1, 2, 3])
    #expect(
      question.optionDescriptions == [
        "A crisp, sweet red or green fruit",
        "A soft, creamy yellow tropical fruit",
        "A small, tart red stone fruit",
      ])
    #expect(!question.allowsMultiple)
    #expect(question.pickerTab == PickerTab(index: 0, count: 1, submitsAfter: false))
  }

  /// The answered call above it on the screen is not part of it.
  @Test("a multi-select question reads its boxes, and goes on to the review screen")
  func multiSelect() throws {
    let question = try question(PaneQuestionScreenFixture.multiSelect)
    #expect(question.question == "Pick any fruits")
    #expect(question.header == "Fruits")
    #expect(question.options == ["Apple", "Banana", "Cherry"])
    #expect(question.optionDescriptions.count == 3)
    #expect(question.allowsMultiple)
    #expect(question.pickerTab == PickerTab(index: 0, count: 1, submitsAfter: true))
  }

  @Test("a box checked in the terminal reads as checked")
  func checkedInTheTerminal() throws {
    let question = try question(PaneQuestionScreenFixture.multiSelectBananaChecked)
    #expect(question.pickerTab?.checked == [2])
  }

  @Test("the first of two questions is the active tab and does not submit")
  func firstOfTwo() throws {
    let question = try question(PaneQuestionScreenFixture.twoQuestionsFirstTab)
    #expect(question.question == "Pick a fruit")
    #expect(question.header == "Fruit")
    #expect(question.pickerTab == PickerTab(index: 0, count: 2, submitsAfter: false))
  }

  /// The active tab is the one on a background colour, and Fruit is already `☒`.
  @Test("the second of two questions is read from the active tab, and submits")
  func secondOfTwo() throws {
    let question = try question(PaneQuestionScreenFixture.twoQuestionsSecondTab)
    #expect(question.question == "Pick a color")
    #expect(question.header == "Color")
    #expect(question.options == ["Red", "Blue", "Green"])
    #expect(question.pickerTab == PickerTab(index: 1, count: 2, submitsAfter: true))
  }

  @Test("a phone-width pane joins the wrapped question and descriptions")
  func wrapped() throws {
    let question = try question(PaneQuestionScreenFixture.narrowWrapped)
    #expect(
      question.question == "Which fruit should go into the smoothie we are making this afternoon?")
    #expect(question.options == ["Apple", "Banana", "Cherry", "Mango"])
    #expect(
      question.optionDescriptions[0]
        == "Adds natural sweetness and fiber content, creates a crisp texture, blends smoothly into creamy beverages."
    )
  }

  /// Every other header is shortened to `B…`, so the row is whole at phone width.
  @Test("the last of four questions at 46 columns reads, and submits")
  func lastOfFour() throws {
    let question = try question(PaneQuestionScreenFixture.fourQuestionsLastTab)
    #expect(question.question == "Pick a delivery")
    #expect(question.header == "Deliveries")
    #expect(question.pickerTab == PickerTab(index: 3, count: 4, submitsAfter: true))
  }

  // MARK: - What it refuses

  /// A wrong tab count would send `1` into the next question as its answer.
  @Test("a tab row that wraps is not read")
  func wrappedTabRow() {
    #expect(read(PaneQuestionScreenFixture.fourQuestionsWrapped) == nil)
  }

  @Test("a permission prompt is not a question")
  func permission() {
    #expect(read(PaneQuestionScreenFixture.permission) == nil)
  }

  @Test("the review screen is not a question")
  func review() {
    #expect(read(PaneQuestionScreenFixture.twoQuestionsReview) == nil)
  }

  /// Options 1 and 2 and the question have scrolled off, so no digit is certain.
  @Test("a pane too short to show every option is not read")
  func shortPane() {
    #expect(read(PaneQuestionScreenFixture.shortPane) == nil)
  }

  // MARK: - The keys that answer it

  private func selection(_ ansi: String) throws -> ReplyChipSelection {
    let call = try #require(read(ansi)).call
    return ReplyChipSelection(groups: call.replyChipGroups)
  }

  private func tap(_ label: String, in selection: inout ReplyChipSelection) throws {
    let group = try #require(selection.groups.first)
    let chip = try #require(group.chips.first { $0.label == label })
    selection.toggle(chip, in: group)
  }

  @Test("a lone single-select question answers with its digit alone")
  func singleSelectKeys() throws {
    var selection = try selection(PaneQuestionScreenFixture.singleSelect)
    try tap("Banana", in: &selection)
    #expect(selection.reply?.action == .key(.digit2))
  }

  @Test("a multi-select question toggles, moves on and submits")
  func multiSelectKeys() throws {
    var selection = try selection(PaneQuestionScreenFixture.multiSelect)
    try tap("Apple", in: &selection)
    try tap("Cherry", in: &selection)
    selection.confirm()
    #expect(selection.reply?.action == .keys([.digit1, .digit3, .right, .digit1]))
  }

  /// Banana is checked in the terminal. Pressing `2` again would uncheck it.
  @Test("a box already checked on screen starts chosen, and only changes are sent")
  func checkedKeys() throws {
    var selection = try selection(PaneQuestionScreenFixture.multiSelectBananaChecked)
    let group = try #require(selection.groups.first)
    #expect(selection.isChosen(try #require(group.chips.first { $0.label == "Banana" }), in: group))
    try tap("Apple", in: &selection)
    selection.confirm()
    #expect(selection.reply?.action == .keys([.digit1, .right, .digit1]))
  }

  @Test("unchecking a box checked on screen sends its digit")
  func uncheckKeys() throws {
    var selection = try selection(PaneQuestionScreenFixture.multiSelectBananaChecked)
    try tap("Banana", in: &selection)
    try tap("Cherry", in: &selection)
    selection.confirm()
    #expect(selection.reply?.action == .keys([.digit2, .digit3, .right, .digit1]))
  }

  /// The picker moves to the next tab, and the next read shows it.
  @Test("the first of two questions answers its own tab and nothing more")
  func firstOfTwoKeys() throws {
    var selection = try selection(PaneQuestionScreenFixture.twoQuestionsFirstTab)
    try tap("Banana", in: &selection)
    #expect(selection.reply?.action == .key(.digit2))
  }

  @Test("the last of two questions answers its tab and submits")
  func secondOfTwoKeys() throws {
    var selection = try selection(PaneQuestionScreenFixture.twoQuestionsSecondTab)
    try tap("Blue", in: &selection)
    #expect(selection.reply?.action == .keys([.digit2, .digit1]))
  }

  // MARK: - The next tab

  @Test("the next tab appearing on the screen is the screen advancing")
  func nextTabAdvances() throws {
    let first = try #require(read(PaneQuestionScreenFixture.twoQuestionsFirstTab)).call
    let second = try #require(read(PaneQuestionScreenFixture.twoQuestionsSecondTab)).call
    #expect(
      ReplyChipGroup.screenQuestionAdvanced(
        from: first.replyChipGroups, to: second.replyChipGroups))
    #expect(
      !ReplyChipGroup.screenQuestionAdvanced(
        from: first.replyChipGroups, to: first.replyChipGroups))
  }

  @Test("a handover or an answered band is not the screen advancing")
  func handoverDoesNotAdvance() throws {
    let screen = try #require(read(PaneQuestionScreenFixture.singleSelect)).call
    let transcript = ToolCall(
      name: "AskUserQuestion", outcome: .pending,
      questions: [PendingQuestion(question: "Pick a fruit", options: ["Apple", "Banana"])])
    #expect(
      !ReplyChipGroup.screenQuestionAdvanced(
        from: screen.replyChipGroups, to: transcript.replyChipGroups))
    #expect(!ReplyChipGroup.screenQuestionAdvanced(from: screen.replyChipGroups, to: []))
  }

  // MARK: - Which call the chips answer

  private let screen = PaneScreen.sanitised(
    PaneQuestionScreenFixture.singleSelect, lines: PaneScreen.maximumLines)

  private func transcript(_ turns: [TranscriptTurn]) -> Transcript {
    Transcript(turns: turns, window: .none)
  }

  @Test("a blocked pane whose transcript has no question takes the screen's")
  func screenIsTheFallback() throws {
    let transcript = transcript([TranscriptTurn(id: "1", speech: .human("ask me"))])
    let call = try #require(transcript.questionCall(screen: screen, agentStatus: .blocked))
    #expect(call.questions.map(\.question) == ["Pick a fruit"])
    #expect(call.outcome == .pending)
  }

  @Test("a pane herdr does not call blocked takes nothing from the screen")
  func onlyWhileBlocked() {
    let transcript = transcript([TranscriptTurn(id: "1", speech: .human("ask me"))])
    #expect(transcript.questionCall(screen: screen, agentStatus: .working) == nil)
  }

  @Test("the transcript's own question wins over the screen's")
  func transcriptWins() throws {
    let asked = ToolCall(
      name: "AskUserQuestion", outcome: .pending,
      questions: [PendingQuestion(question: "Pick a fruit", options: ["Apple", "Banana"])])
    let transcript = transcript([
      TranscriptTurn(id: "1", speech: .human("ask me")),
      TranscriptTurn(id: "2", speech: .tools(ToolRun(calls: [asked]))),
    ])
    let call = try #require(transcript.questionCall(screen: screen, agentStatus: .blocked))
    #expect(call == asked)
    #expect(call.questions.first?.pickerTab == nil)
  }

  /// The screen and herdr's status can lag the transcript by a poll after an answer.
  @Test("a question the transcript already records as answered is not drawn again")
  func answeredIsNotDrawnTwice() {
    let answered = ToolCall(
      name: "AskUserQuestion", outcome: .succeeded,
      questions: [
        PendingQuestion(question: "Pick a fruit", options: ["Apple", "Banana"], answer: "Banana")
      ])
    let transcript = transcript([
      TranscriptTurn(id: "1", speech: .human("ask me")),
      TranscriptTurn(id: "2", speech: .tools(ToolRun(calls: [answered]))),
      TranscriptTurn(id: "3", speech: .assistant("You picked Banana.")),
    ])
    #expect(transcript.questionCall(screen: screen, agentStatus: .blocked) == nil)
  }

  /// This parse joins wrapped rows with one space, so a newline, double space or broken word
  /// must not make a different question.
  @Test("an answered question matches the screen's whatever its line breaks")
  func answeredMatchesAcrossWraps() {
    let answered = ToolCall(
      name: "AskUserQuestion", outcome: .succeeded,
      questions: [
        PendingQuestion(
          question: "Pick a  fruit\n", options: ["Apple", "Banana"], answer: "Banana")
      ])
    let transcript = transcript([
      TranscriptTurn(id: "1", speech: .human("ask me")),
      TranscriptTurn(id: "2", speech: .tools(ToolRun(calls: [answered]))),
    ])
    #expect(transcript.questionCall(screen: screen, agentStatus: .blocked) == nil)
    #expect(PaneQuestionScreen.comparable("Pick a fr uit") == PaneQuestionScreen.comparable("Pick a fruit"))
  }

  /// A new human turn starts a new exchange, so an older answer does not hide the question.
  @Test("the same question asked again after a new prompt is drawn")
  func askedAgain() throws {
    let answered = ToolCall(
      name: "AskUserQuestion", outcome: .succeeded,
      questions: [
        PendingQuestion(question: "Pick a fruit", options: ["Apple", "Banana"], answer: "Banana")
      ])
    let transcript = transcript([
      TranscriptTurn(id: "1", speech: .human("ask me")),
      TranscriptTurn(id: "2", speech: .tools(ToolRun(calls: [answered]))),
      TranscriptTurn(id: "3", speech: .human("ask me again")),
    ])
    #expect(transcript.questionCall(screen: screen, agentStatus: .blocked) != nil)
  }

  @Test("a permission prompt leaves the transcript's pending call in place")
  func permissionKeepsThePendingCall() {
    let bash = ToolCall(name: "Bash", target: "curl -sI https://example.com", outcome: .pending)
    let transcript = transcript([
      TranscriptTurn(id: "1", speech: .human("run it")),
      TranscriptTurn(id: "2", speech: .tools(ToolRun(calls: [bash]))),
    ])
    let permission = PaneScreen.sanitised(
      PaneQuestionScreenFixture.permission, lines: PaneScreen.maximumLines)
    #expect(transcript.questionCall(screen: permission, agentStatus: .blocked) == bash)
  }
}
