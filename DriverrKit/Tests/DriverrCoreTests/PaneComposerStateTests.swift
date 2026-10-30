import DriverrCore
import Foundation
import Testing

/// The composer's three send states, as transitions on a value, so re-entry, the sent
/// notice and a failure's Retry are asserted without herdr or a simulator.
@Suite("PaneComposerState")
struct PaneComposerStateTests {
  @Test("nothing typed is a disabled button, not an error")
  func blankIsNotSent() {
    var state = PaneComposerState()
    state.text = "   \n  "

    #expect(!state.canSend)
    #expect(state.beginSending() == nil)
    #expect(state.phase == .editing)
  }

  @Test("a send stages the typed text and moves to sending")
  func sendingStagesTheText() {
    var state = PaneComposerState()
    state.text = "yes, go ahead"

    #expect(state.beginSending() == .text("yes, go ahead"))
    #expect(state.phase == .sending)
    #expect(state.isSending)
  }

  @Test("a second send while one is in flight is refused")
  func sendingCannotBeReEntered() {
    // A disabled button is a rendering, and a tap can land in the frame before the redraw.
    var state = PaneComposerState()
    state.text = "y"
    #expect(state.beginSending() != nil)

    #expect(state.beginSending() == nil)
    #expect(state.beginSending(.enter) == nil)
    #expect(state.beginRetry() == nil)
    #expect(state.phase == .sending)
  }

  @Test("a key press can be sent with nothing typed")
  func keysNeedNoText() {
    var state = PaneComposerState()

    #expect(state.beginSending(.interrupt) == .key(.interrupt))
    #expect(state.phase == .sending)
  }

  @Test("herdr taking the reply is not the agent answering it")
  func sentIsItsOwnState() {
    // `sent` says herdr took it and nothing about whether the agent has spoken.
    var state = PaneComposerState()
    state.text = "y"
    _ = state.beginSending()

    state.succeeded()

    #expect(state.phase == .sent)
    #expect(state.status?.message == PaneComposerCopy.sent)
    #expect(state.status?.tone == .success)
    #expect(state.status?.offersRetry == false)
  }

  @Test("the field empties on a successful send")
  func clearsAfterSending() {
    var state = PaneComposerState()
    state.text = "y"
    _ = state.beginSending()

    state.succeeded()

    #expect(state.text.isEmpty)
  }

  @Test("the composer's own clearing of the field does not erase the verdict")
  func clearingIsNotAnEdit() {
    // The model emptying the field must not look like a keystroke, or it clears the fresh
    // verdict and "Sent" never appears.
    var state = PaneComposerState()
    state.text = "yes"
    _ = state.beginSending()

    state.succeeded()

    #expect(state.phase == .sent)
  }

  @Test("a key press leaves a half-written reply staged")
  func keySendKeepsTheDraft() {
    var state = PaneComposerState()
    state.text = "half written"
    _ = state.beginSending(.esc)

    state.succeeded()

    #expect(state.text == "half written")
    #expect(state.phase == .sent)
  }

  @Test("the sent notice clears itself")
  func sentClearsItself() {
    var state = PaneComposerState()
    state.text = "y"
    _ = state.beginSending()
    state.succeeded()

    state.clearSentNotice()

    #expect(state.phase == .editing)
    #expect(state.status == nil)
  }

  @Test("clearing the sent notice cannot wipe a newer verdict")
  func clearingOnlyClearsSent() {
    // A second send can have failed before the first send's notice clears.
    var state = PaneComposerState()
    state.failed(.herdrCommandFailed(reason: "no such pane"))

    state.clearSentNotice()

    #expect(state.phase == .failed(.herdrCommandFailed(reason: "no such pane")))
  }

  @Test("a failure keeps the staged text and offers a retry")
  func failureKeepsTheText() {
    var state = PaneComposerState()
    state.text = "retry me"
    _ = state.beginSending()

    state.failed(.herdrCommandFailed(reason: "no such pane"))

    #expect(state.text == "retry me")
    #expect(state.failure == .herdrCommandFailed(reason: "no such pane"))
    #expect(state.status?.offersRetry == true)
    #expect(state.status?.tone == .failure)
  }

  @Test("a failure says herdr's own words under the headline")
  func failureSaysWhatHerdrSaid() {
    // The headline is true whether or not herdr answered; herdr's own sentence goes under it.
    var state = PaneComposerState()
    state.failed(.herdrCommandFailed(reason: "no such pane"))

    #expect(state.status?.message == PaneComposerCopy.failed)
    #expect(state.status?.detail == "no such pane")
  }

  @Test("a retry repeats what failed, without it being retyped")
  func retryRepeatsTheAttempt() {
    var state = PaneComposerState()
    state.text = "retry me"
    _ = state.beginSending()
    state.failed(.herdrCommandFailed(reason: "no such pane"))

    #expect(state.beginRetry() == .text("retry me"))
    #expect(state.phase == .sending)
  }

  @Test("a retry repeats a key press as a key press")
  func retryRepeatsAKey() {
    var state = PaneComposerState()
    _ = state.beginSending(.interrupt)
    state.failed(.herdrCommandFailed(reason: "no such pane"))

    #expect(state.beginRetry() == .key(.interrupt))
  }

  /// An `AskUserQuestion` answer is several keys.
  @Test("a retry repeats a key sequence whole, and it earns the reply's sentence")
  func retryRepeatsAKeySequence() {
    var state = PaneComposerState()
    #expect(state.beginSending([PaneKey]()) == nil, "no keys is nothing to send")
    _ = state.beginSending([.digit2, .digit3, .digit1])
    state.failed(.herdrCommandFailed(reason: "no such pane"))

    #expect(state.beginRetry() == .keys([.digit2, .digit3, .digit1]))
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    state.succeeded(at: now)
    #expect(state.status(asOf: now)?.message == PaneComposerCopy.sent)
  }

  @Test("there is nothing to retry until something has failed")
  func retryNeedsAFailure() {
    var state = PaneComposerState()
    state.text = "y"
    #expect(state.beginRetry() == nil)

    _ = state.beginSending()
    state.succeeded()

    #expect(state.beginRetry() == nil)
  }

  @Test("typing again clears the last verdict")
  func typingResumes() {
    var state = PaneComposerState()
    state.text = "one"
    _ = state.beginSending()
    state.succeeded()

    state.text = "two"

    #expect(state.phase == .editing)
    #expect(state.status == nil)
  }

  @Test("editing a failed reply retires its retry")
  func typingRetiresTheRetry() {
    // Once the text changes, Retry would send something else.
    var state = PaneComposerState()
    state.text = "retry me"
    _ = state.beginSending()
    state.failed(.herdrCommandFailed(reason: "no such pane"))

    state.text = "retry me, differently"

    #expect(state.phase == .editing)
    #expect(state.beginRetry() == nil)
  }

  @Test("the field being set to what it already holds is not typing")
  func idempotentWritesAreNotEdits() {
    // A `TextField` binding writes on every redraw, not only on a keystroke.
    var state = PaneComposerState()
    state.text = "y"
    _ = state.beginSending()
    state.succeeded()

    state.text = ""

    #expect(state.phase == .sent)
  }

  @Test("sending says so, and offers nothing to press")
  func sendingStatus() {
    var state = PaneComposerState()
    state.text = "y"
    _ = state.beginSending()

    #expect(state.status?.message == PaneComposerCopy.sending)
    #expect(state.status?.tone == .progress)
    #expect(state.status?.offersRetry == false)
  }

  @Test("an untouched composer says nothing about a send")
  func editingHasNoStatus() {
    #expect(PaneComposerState().status == nil)
  }

  // MARK: - Holding "Sent" until it is true

  private func blocked(_ status: AgentStatus = .blocked) -> Pane {
    Pane(
      id: "w1:p2",
      tabID: "w1:t1",
      workspaceID: "w1",
      title: "needs a decision",
      agent: Agent(name: "Claude", kind: "claude", status: status)
    )
  }

  private func sent(at now: Date, pane: Pane?) -> PaneComposerState {
    var state = PaneComposerState()
    state.text = "y"
    _ = state.beginSending()
    state.succeeded(at: now, pane: pane)
    return state
  }

  /// A clock is not evidence the agent answered. Retiring the notice on a timer showed the
  /// question again over an empty field, which invites sending the same answer twice.
  @Test("Sent does not expire on a clock while the pane is still blocked")
  func sentDoesNotExpireOnAClock() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var state = sent(at: now, pane: blocked())

    state.paneChanged(to: blocked())

    #expect(state.phase == .sent)
    #expect(state.status(asOf: now.addingTimeInterval(3))?.message == PaneComposerCopy.sent)
  }

  @Test("Sent clears the moment the pane stops being blocked")
  func sentClearsWhenTheStatusMoves() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var state = sent(at: now, pane: blocked())

    state.paneChanged(to: blocked(.working))

    #expect(state.phase == .editing)
    #expect(state.status(asOf: now) == nil)
  }

  @Test("Sent clears when the conversation gains a turn")
  func sentClearsWhenTheTranscriptMoves() {
    // The agent may answer without leaving `blocked`, as when one permission prompt follows
    // another.
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var state = sent(at: now, pane: blocked())

    state.transcriptAdvanced()

    #expect(state.phase == .editing)
  }

  @Test("a send nothing has confirmed ages instead of quietly disappearing")
  func sentAges() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let state = sent(at: now, pane: blocked())

    let status = state.status(asOf: now.addingTimeInterval(40))

    #expect(status?.message == "Sent 40s ago")
    #expect(status?.detail == "herdr still reports Claude as waiting.")
    #expect(status?.tone == .progress)
    #expect(status?.offersRetry == false)
    #expect(state.phase == .sent, "ageing is a sentence, not a state change")
  }

  @Test("the notice only starts ageing once it has waited long enough to be worth saying")
  func sentAgesOnlyAfterTheThreshold() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let state = sent(at: now, pane: blocked())

    #expect(state.status(asOf: now.addingTimeInterval(29))?.message == PaneComposerCopy.sent)
    #expect(state.status(asOf: now.addingTimeInterval(30))?.message == "Sent 30s ago")
  }

  @Test("a send to a pane that was not blocked ages without inventing a herdr report")
  func agedSendDoesNotInventAReport() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let state = sent(at: now, pane: blocked(.working))

    let status = state.status(asOf: now.addingTimeInterval(45))

    #expect(status?.message == "Sent 45s ago")
    #expect(status?.detail == nil)
  }

  @Test("a pane that has not changed leaves Sent alone")
  func unchangedPaneHoldsSent() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var state = sent(at: now, pane: blocked())

    state.paneChanged(to: blocked())
    state.paneChanged(to: nil)

    #expect(state.phase == .sent, "a pane that fell out of the tree is not an answer")
  }

  /// A key's verdict is already a finished statement, so it does not age.
  @Test("a key's own verdict is kept, and only a reply awaiting an answer ages")
  func aKeyKeepsItsOwnVerdict() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var interrupt = PaneComposerState()
    _ = interrupt.beginSending(.interrupt)
    interrupt.succeeded(at: now, pane: blocked())

    #expect(interrupt.status(asOf: now)?.message == "Sent Ctrl-C · Claude was interrupted")
    #expect(
      interrupt.status(asOf: now.addingTimeInterval(90))?.message
        == "Sent Ctrl-C · Claude was interrupted",
      "an interrupt already said what happened; there is no wait to report")

    // Enter answers whatever was on screen, so it gets the reply's sentence and the ageing.
    var enter = PaneComposerState()
    _ = enter.beginSending(.enter)
    enter.succeeded(at: now, pane: blocked())

    #expect(enter.status(asOf: now)?.message == PaneComposerCopy.sent)
    #expect(enter.status(asOf: now.addingTimeInterval(40))?.message == "Sent 40s ago")
  }

  @Test("neither piece of evidence can wipe a newer verdict")
  func evidenceOnlyClearsSent() {
    // A second send can have failed while the first was waiting.
    var state = PaneComposerState()
    state.failed(.herdrCommandFailed(reason: "no such pane"))

    state.paneChanged(to: blocked(.idle))
    state.transcriptAdvanced()

    #expect(state.phase == .failed(.herdrCommandFailed(reason: "no such pane")))
  }
}

/// What the composer says about its pane. The composer stays for a pane that is not
/// blocked; only the sentence above it changes.
@Suite("PaneComposerHeader")
struct PaneComposerHeaderTests {
  private func pane(_ status: AgentStatus?) -> Pane {
    Pane(
      id: "w1:p2",
      tabID: "w1:t1",
      workspaceID: "w1",
      title: "needs a decision",
      agent: status.map { Agent(name: "Claude", kind: "claude", status: $0) }
    )
  }

  @Test("a blocked pane is told it is being waited on, and nothing else")
  func blocked() {
    let header = PaneComposerHeader(pane: pane(.blocked))

    #expect(header.state == "Claude is waiting for you.")
    #expect(header.invitation == nil)
  }

  @Test(
    "a blocked agent that said why is worded for it",
    arguments: [
      (AgentBlockedKind?.none, "Claude is waiting for you."),
      (.permission, "Claude is waiting for permission."),
      (.question, "Claude is waiting for your answer."),
      (.auth, "Claude is waiting for you to sign in."),
    ])
  func blockedKinds(kind: AgentBlockedKind?, state: String) {
    let agent = Agent(name: "Claude", kind: "claude", status: .blocked, blockedKind: kind)
    let pane = Pane(id: "w1:p2", tabID: "w1:t1", workspaceID: "w1", title: "t", agent: agent)
    let header = PaneComposerHeader(pane: pane)
    #expect(header.state == state)
    #expect(header.invitation == nil)
  }

  @Test("every other state keeps the composer and changes the sentence")
  func notBlocked() {
    for status in AgentStatus.allCases where status != .blocked {
      let header = PaneComposerHeader(pane: pane(status))
      #expect(header.state.contains("Claude"), "\(status) should name the agent")
      #expect(
        header.invitation != nil,
        "\(status) should say the composer still works"
      )
    }
  }

  @Test("each state gets its own sentence")
  func sentencesAreDistinct() {
    let sentences = AgentStatus.allCases.map { PaneComposerHeader(pane: pane($0)).state }
    #expect(Set(sentences).count == AgentStatus.allCases.count)
  }

  @Test("a pane with no agent is not told an agent is doing something")
  func noAgent() {
    let header = PaneComposerHeader(pane: pane(nil))

    #expect(!header.state.contains("Claude"))
    #expect(header.accessibilityLabel == header.state)
  }

  @Test("what is spoken is both halves, as one sentence")
  func spoken() {
    let header = PaneComposerHeader(pane: pane(.working))

    #expect(header.accessibilityLabel == "\(header.state) \(header.invitation ?? "")")
  }

  @Test("only .working has anything to interrupt")
  func onlyWorkingIsInterruptible() {
    #expect(PaneComposerHeader(pane: pane(.working)).isWorking)
    for status in AgentStatus.allCases where status != .working {
      #expect(!PaneComposerHeader(pane: pane(status)).isWorking, "\(status) has nothing running")
    }
    #expect(!PaneComposerHeader(pane: pane(nil)).isWorking, "a shell has no agent to be working")
  }
}

/// A pending call's options, turned into something a tap can send.
@Suite("ToolCall.replyChips")
struct ReplyChipTests {
  @Test("a raw prompt with no options gets a generic Approve/Deny pair")
  func genericPairForNoOptions() {
    let call = ToolCall(name: "Bash", target: "cargo test", outcome: .pending)

    #expect(
      call.replyChips == [
        ReplyChip(label: "Approve", action: .key(.yes)),
        ReplyChip(label: "Deny", action: .key(.no)),
      ]
    )
  }

  @Test("AskUserQuestion's own option labels become chips, in the order the agent listed them")
  func labelsBecomeChips() {
    let call = ToolCall(
      name: "AskUserQuestion",
      outcome: .pending,
      questions: [
        PendingQuestion(question: "What next?", options: ["Add tests", "Skip", "Ask again later"])
      ]
    )

    #expect(
      call.replyChips == [
        ReplyChip(label: "Add tests", action: .key(.digit1)),
        ReplyChip(label: "Skip", action: .key(.digit2)),
        ReplyChip(label: "Ask again later", action: .key(.digit3)),
      ]
    )
  }

  /// The terminal picker shows each question's header and each option's description.
  @Test("a question's header and its options' descriptions reach the chips")
  func headerAndDescriptionsReachTheChips() throws {
    let call = ToolCall(
      name: "AskUserQuestion",
      outcome: .pending,
      questions: [
        PendingQuestion(
          question: "Which fruit do you pick?",
          options: ["Apple", "Banana", "Cherry"],
          header: "Fruit",
          optionDescriptions: ["Crisp", nil, "A small stone fruit"]
        )
      ]
    )

    let group = try #require(call.replyChipGroups.first)
    #expect(group.header == "Fruit")
    #expect(group.question == "Which fruit do you pick?")
    #expect(group.chips.map(\.detail) == ["Crisp", nil, "A small stone fruit"])
    #expect(group.chips.map(\.action) == [.key(.digit1), .key(.digit2), .key(.digit3)])
    #expect(group.describesItsOptions)
  }

  @Test("the generic pair has no header and no descriptions")
  func theGenericPairDescribesNothing() throws {
    let group = try #require(ToolCall(name: "Bash", outcome: .pending).replyChipGroups.first)
    #expect(group.header == nil)
    #expect(group.describesItsOptions == false)
  }

  /// The picker answers by number, 1 to 9. Typed text would record the highlighted option,
  /// so a call with a tenth option gets no chips and is answered in the terminal.
  @Test("an option past the ninth takes every chip off the call")
  func aTenthOptionOffersNoChips() {
    let nine = ToolCall(
      name: "AskUserQuestion",
      outcome: .pending,
      questions: [PendingQuestion(question: "Which?", options: (1...9).map { "o\($0)" })]
    )
    #expect(nine.replyChips.last?.action == .key(.digit9))

    let ten = ToolCall(
      name: "AskUserQuestion",
      outcome: .pending,
      questions: [PendingQuestion(question: "Which?", options: (1...10).map { "o\($0)" })]
    )
    #expect(ten.replyChipGroups.isEmpty)
    #expect(ten.asksItsOwnQuestions, "the call is still a question waiting on the reader")
  }

  /// The chat rests at the band's top and the turn above scrolls off, so one question also
  /// carries its heading.
  @Test("one question makes one group headed by its question")
  func oneQuestionOneGroup() throws {
    let call = ToolCall(
      name: "AskUserQuestion",
      outcome: .pending,
      questions: [PendingQuestion(question: "Proceed?", options: ["Yes", "No"])]
    )

    let groups = call.replyChipGroups
    try #require(groups.count == 1)
    #expect(groups[0].question == "Proceed?")
    #expect(groups[0].chips.map(\.label) == ["Yes", "No"])
    #expect(groups[0].allowsMultiple == false)
  }

  @Test("each question gets its own labelled group, its own chips and its own multiSelect")
  func aGroupPerQuestion() throws {
    let call = ToolCall(
      name: "AskUserQuestion",
      outcome: .pending,
      questions: [
        PendingQuestion(question: "Which branch?", options: ["main", "release"]),
        PendingQuestion(question: "Which reviewers?", options: ["Ann", "Bo"], allowsMultiple: true),
      ]
    )

    let groups = call.replyChipGroups
    try #require(groups.count == 2)
    #expect(groups.map(\.question) == ["Which branch?", "Which reviewers?"])
    #expect(groups.map { $0.chips.map(\.label) } == [["main", "release"], ["Ann", "Bo"]])
    #expect(groups.map(\.allowsMultiple) == [false, true])
    #expect(Set(groups.map(\.id)).count == 2)
  }

  @Test("chips are identified by their own label")
  func chipIdentity() {
    let chip = ReplyChip(label: "Approve", action: .key(.yes))
    #expect(chip.id == "Approve")
  }
}

/// Nothing is sent until every question has an answer.
@Suite("ReplyChipSelection")
struct ReplyChipSelectionTests {
  private let branch = ReplyChipGroup(
    index: 0,
    question: "Which branch?",
    chips: [
      ReplyChip(label: "main", action: .key(.digit1)),
      ReplyChip(label: "release", action: .key(.digit2)),
    ]
  )
  private let tests = ReplyChipGroup(
    index: 1,
    question: "Run the tests?",
    chips: [
      ReplyChip(label: "Yes", action: .key(.digit1)),
      ReplyChip(label: "No", action: .key(.digit2)),
    ]
  )
  private let reviewers = ReplyChipGroup(
    index: 2,
    question: "Which reviewers?",
    chips: [
      ReplyChip(label: "Ann", action: .key(.digit1)),
      ReplyChip(label: "Bo", action: .key(.digit2)),
    ],
    allowsMultiple: true
  )

  @Test("two of three questions answered sends nothing")
  func incompleteSendsNothing() {
    var selection = ReplyChipSelection(groups: [branch, tests, reviewers])

    #expect(selection.reply == nil)
    selection.toggle(branch.chips[0], in: branch)
    #expect(selection.isComplete == false)
    #expect(selection.reply == nil)
    selection.toggle(tests.chips[0], in: tests)
    #expect(selection.isComplete == false)
    #expect(selection.reply == nil)

    // The call has a multi-select question, so it waits for Send.
    selection.toggle(reviewers.chips[0], in: reviewers)
    #expect(selection.isComplete)
    #expect(selection.reply == nil)
    selection.confirm()
    #expect(selection.reply != nil)
  }

  /// Each question's digits in order, `right` after the multi-select one, and `1` for the
  /// review's Submit.
  @Test("a complete multi-question selection sends one key sequence")
  func completeSelectionComposesOneSequence() throws {
    var selection = ReplyChipSelection(groups: [branch, tests, reviewers])
    selection.toggle(branch.chips[1], in: branch)
    selection.toggle(tests.chips[0], in: tests)
    selection.toggle(reviewers.chips[0], in: reviewers)
    selection.toggle(reviewers.chips[1], in: reviewers)
    selection.confirm()

    let reply = try #require(selection.reply)
    #expect(reply.action == .keys([.digit2, .digit1, .digit1, .digit2, .right, .digit1]))
    #expect(reply.label == "release\nYes\nAnn, Bo")
  }

  /// Sending on the completing tap would stop a multi-select question from taking a second
  /// answer.
  @Test("a multi-select answer is not cut short by the tap that completes the set")
  func aMultiSelectAnswerSurvivesTheCompletingTap() {
    var selection = ReplyChipSelection(groups: [branch, reviewers])

    selection.toggle(branch.chips[0], in: branch)
    selection.toggle(reviewers.chips[0], in: reviewers)

    #expect(selection.isComplete)
    #expect(selection.reply == nil)

    selection.toggle(reviewers.chips[1], in: reviewers)
    #expect(selection.isChosen(reviewers.chips[0], in: reviewers))
    #expect(selection.isChosen(reviewers.chips[1], in: reviewers))

    selection.confirm()
    #expect(selection.reply?.action == .keys([.digit1, .digit1, .digit2, .right, .digit1]))
  }

  /// Confirmation belongs to the call. Keyed to the completing group, it would depend on tap
  /// order.
  @Test("any multi-select question makes the whole call need a Send")
  func anyMultiSelectGroupNeedsConfirmation() {
    #expect(ReplyChipSelection(groups: [branch, tests]).needsConfirmation == false)
    #expect(ReplyChipSelection(groups: [branch, reviewers]).needsConfirmation)
    #expect(ReplyChipSelection(groups: [reviewers]).needsConfirmation)
    #expect(ReplyChipSelection().needsConfirmation == false)
  }

  @Test("a call with no multi-select question still sends on the completing tap")
  func singleAnswerQuestionsStillSendOnCompletion() {
    var selection = ReplyChipSelection(groups: [branch, tests])
    #expect(selection.awaitsConfirmation == false)

    selection.toggle(branch.chips[0], in: branch)
    #expect(selection.reply == nil)
    selection.toggle(tests.chips[0], in: tests)

    #expect(selection.reply?.action == .keys([.digit1, .digit1, .digit1]))
  }

  @Test("a single multi-select question waits for Send too")
  func oneMultiSelectQuestionWaitsForSend() {
    var selection = ReplyChipSelection(groups: [reviewers])

    selection.toggle(reviewers.chips[0], in: reviewers)
    #expect(selection.isComplete)
    #expect(selection.awaitsConfirmation)
    #expect(selection.reply == nil)

    selection.toggle(reviewers.chips[1], in: reviewers)
    selection.confirm()

    #expect(selection.reply?.action == .keys([.digit1, .digit2, .right, .digit1]))
    #expect(selection.reply?.label == "Ann, Bo")
  }

  /// Send is drawn disabled until the set is complete; this covers a press that reaches it.
  @Test("confirming an incomplete selection does nothing")
  func confirmingIncompleteDoesNothing() {
    var selection = ReplyChipSelection(groups: [branch, reviewers])
    selection.toggle(reviewers.chips[0], in: reviewers)

    selection.confirm()

    #expect(selection.isConfirmed == false)
    #expect(selection.reply == nil)

    selection.toggle(branch.chips[0], in: branch)
    #expect(selection.reply == nil)
    selection.confirm()
    #expect(selection.isConfirmed)
    #expect(selection.reply != nil)
  }

  /// `PaneChatView` reseeds the selection on every change of the pending groups.
  @Test("a selection built for new groups has not been confirmed")
  func aFreshSelectionIsUnconfirmed() {
    #expect(ReplyChipSelection(groups: [reviewers]).isConfirmed == false)
    #expect(ReplyChipSelection(groups: [reviewers]).awaitsConfirmation)
  }

  /// The chip's own action goes over, so a generic Approve stays a `y` key press.
  @Test("one question sends its own chip on the first tap")
  func oneQuestionSendsItsOwnChip() throws {
    let generic = ReplyChipGroup(
      index: 0,
      question: nil,
      chips: [
        ReplyChip(label: "Approve", action: .key(.yes)),
        ReplyChip(label: "Deny", action: .key(.no)),
      ]
    )
    var selection = ReplyChipSelection(groups: [generic])

    selection.toggle(generic.chips[0], in: generic)

    #expect(selection.reply == ReplyChip(label: "Approve", action: .key(.yes)))
  }

  private func pickerGroups(_ questions: [PendingQuestion]) -> [ReplyChipGroup] {
    ToolCall(name: "AskUserQuestion", outcome: .pending, questions: questions).replyChipGroups
  }

  private let fruit = PendingQuestion(question: "Pick a fruit", options: ["Apple", "Banana", "Cherry"])
  private let fruits = PendingQuestion(
    question: "Pick fruits", options: ["Apple", "Banana", "Cherry"], allowsMultiple: true)
  private let color = PendingQuestion(question: "Pick a color", options: ["Red", "Green", "Blue"])

  /// Verified on a live picker: `2` recorded `{"Pick a fruit":"Banana"}`. A lone
  /// single-select question has no review screen.
  @Test("one single-select question answers with its option's digit alone")
  func oneSingleSelectIsItsDigit() throws {
    let groups = pickerGroups([fruit])
    var selection = ReplyChipSelection(groups: groups)
    selection.toggle(groups[0].chips[1], in: groups[0])

    #expect(selection.reply == ReplyChip(label: "Banana", action: .key(.digit2)))
  }

  /// Verified on a live picker: `1 3 right 1` recorded `{"Pick fruits":"Apple, Cherry"}`.
  /// Each digit toggles, `right` leaves the question, and `1` is the review's Submit.
  @Test("one multi-select question toggles each choice, moves on, and submits")
  func oneMultiSelectTogglesAndSubmits() throws {
    let groups = pickerGroups([fruits])
    var selection = ReplyChipSelection(groups: groups)
    selection.toggle(groups[0].chips[0], in: groups[0])
    selection.toggle(groups[0].chips[2], in: groups[0])
    selection.confirm()

    let reply = try #require(selection.reply)
    #expect(reply.action == .keys([.digit1, .digit3, .right, .digit1]))
    #expect(reply.label == "Apple, Cherry")
  }

  /// The chip's own `.key` would press one digit and leave the picker waiting.
  @Test("one multi-select question with a single choice still moves on and submits")
  func oneMultiSelectWithOneChoiceSubmits() throws {
    let groups = pickerGroups([fruits])
    var selection = ReplyChipSelection(groups: groups)
    selection.toggle(groups[0].chips[1], in: groups[0])
    selection.confirm()

    #expect(selection.reply?.action == .keys([.digit2, .right, .digit1]))
  }

  @Test("a multi-select choice taken back is not sent")
  func aDeselectedChoiceIsNotSent() throws {
    let groups = pickerGroups([fruits])
    var selection = ReplyChipSelection(groups: groups)
    selection.toggle(groups[0].chips[0], in: groups[0])
    selection.toggle(groups[0].chips[2], in: groups[0])
    selection.toggle(groups[0].chips[0], in: groups[0])
    selection.confirm()

    #expect(selection.reply?.action == .keys([.digit3, .right, .digit1]))
  }

  /// Verified on a live picker: `2 3 1` recorded `{"Pick a fruit":"Banana","Pick a color":"Blue"}`.
  @Test("two single-select questions answer with a digit each and submit")
  func twoSingleSelectsSubmit() throws {
    let groups = pickerGroups([fruit, color])
    var selection = ReplyChipSelection(groups: groups)
    selection.toggle(groups[0].chips[1], in: groups[0])
    selection.toggle(groups[1].chips[2], in: groups[1])

    let reply = try #require(selection.reply)
    #expect(reply.action == .keys([.digit2, .digit3, .digit1]))
    #expect(reply.label == "Banana\nBlue")
  }

  /// Verified on a live picker: `1 right 3 1` recorded `{"Pick fruits":"Apple","Pick a color":"Blue"}`.
  @Test("a multi-select question then a single-select one moves on between them")
  func mixedQuestionsMoveOnBetweenThem() throws {
    let groups = pickerGroups([fruits, color])
    var selection = ReplyChipSelection(groups: groups)
    selection.toggle(groups[1].chips[2], in: groups[1])
    selection.toggle(groups[0].chips[0], in: groups[0])
    selection.confirm()

    #expect(selection.reply?.action == .keys([.digit1, .right, .digit3, .digit1]))
  }

  @Test("a single-answer question replaces its choice, and a multi-select one adds to it")
  func singleReplacesMultiAdds() {
    var selection = ReplyChipSelection(groups: [branch, reviewers])

    selection.toggle(branch.chips[0], in: branch)
    selection.toggle(branch.chips[1], in: branch)
    #expect(selection.isChosen(branch.chips[0], in: branch) == false)
    #expect(selection.isChosen(branch.chips[1], in: branch))

    selection.toggle(reviewers.chips[0], in: reviewers)
    selection.toggle(reviewers.chips[1], in: reviewers)
    #expect(selection.isChosen(reviewers.chips[0], in: reviewers))
    #expect(selection.isChosen(reviewers.chips[1], in: reviewers))
  }

  /// A heading of no words would be a blank line above the chips.
  @Test("a question with no words has no heading and still answers with its digit")
  func anEmptyQuestionHasNoHeading() throws {
    let call = ToolCall(
      name: "AskUserQuestion",
      outcome: .pending,
      questions: [
        PendingQuestion(question: "Which branch?", options: ["main"]),
        PendingQuestion(question: "", options: ["Yes"]),
      ]
    )
    let groups = call.replyChipGroups
    try #require(groups.count == 2)
    #expect(groups[1].question == nil)

    var selection = ReplyChipSelection(groups: groups)
    selection.toggle(groups[0].chips[0], in: groups[0])
    selection.toggle(groups[1].chips[0], in: groups[1])

    #expect(selection.reply?.action == .keys([.digit1, .digit1, .digit1]))
  }

  /// No chip sends typed text, so only digits compose a sequence.
  @Test("several questions answered by a chip that is not a digit compose nothing")
  func aNonDigitChipInASequenceComposesNothing() {
    let generic = ReplyChipGroup(
      index: 1, question: "Go?", chips: [ReplyChip(label: "Approve", action: .key(.yes))])
    var selection = ReplyChipSelection(groups: [branch, generic])
    selection.toggle(branch.chips[0], in: branch)
    selection.toggle(generic.chips[0], in: generic)

    #expect(selection.isComplete)
    #expect(selection.reply == nil)
  }

  /// The chip itself is the only control that corrects a mis-tap.
  @Test("tapping a chosen chip again takes it back off")
  func tappingAgainDeselects() {
    var selection = ReplyChipSelection(groups: [branch])

    selection.toggle(branch.chips[0], in: branch)
    selection.toggle(branch.chips[0], in: branch)

    #expect(selection.isChosen(branch.chips[0], in: branch) == false)
    #expect(selection.isComplete == false)
    #expect(selection.reply == nil)
  }

  /// A multi-select question with two answers is one question answered.
  @Test("the answered count counts questions rather than chips")
  func answeredCountsQuestions() {
    var selection = ReplyChipSelection(groups: [branch, tests, reviewers])
    #expect(selection.answeredCount == 0)

    selection.toggle(branch.chips[0], in: branch)
    #expect(selection.answeredCount == 1)

    selection.toggle(reviewers.chips[0], in: reviewers)
    selection.toggle(reviewers.chips[1], in: reviewers)
    #expect(selection.answeredCount == 2)

    selection.toggle(branch.chips[0], in: branch)
    #expect(selection.answeredCount == 1)
  }

  @Test("a sent selection keeps what was chosen and takes no more taps")
  func aSentSelectionIsAnInertRecord() throws {
    var selection = ReplyChipSelection(groups: [branch, tests])
    selection.toggle(branch.chips[0], in: branch)
    selection.toggle(tests.chips[0], in: tests)
    try #require(selection.reply != nil)

    selection.markSent()

    #expect(selection.hasSent)
    #expect(selection.reply == nil)
    selection.toggle(branch.chips[1], in: branch)
    selection.toggle(tests.chips[1], in: tests)
    #expect(selection.reply == nil)
    #expect(selection.isChosen(branch.chips[0], in: branch))
    #expect(selection.isChosen(tests.chips[0], in: tests))
    #expect(selection.isChosen(branch.chips[1], in: branch) == false)
    #expect(selection.answeredCount == 2)
  }

  @Test("a selection built for new groups has not sent")
  func aFreshSelectionHasNotSent() {
    #expect(ReplyChipSelection(groups: [branch]).hasSent == false)
  }

  /// `allSatisfy` on an empty list is `true`.
  @Test("no groups is never complete")
  func noGroupsIsNeverComplete() {
    let selection = ReplyChipSelection()
    #expect(selection.isComplete == false)
    #expect(selection.reply == nil)
  }
}

/// What a successful send says, per what was sent.
@Suite("PaneComposerCopy.sentVerdict")
struct PaneComposerCopySentVerdictTests {
  @Test("typed text and Enter share the ordinary sentence")
  func textAndEnterShareTheOrdinarySentence() {
    #expect(PaneComposerCopy.sentVerdict(for: nil) == PaneComposerCopy.sent)
    #expect(PaneComposerCopy.sentVerdict(for: .enter) == PaneComposerCopy.sent)
  }

  @Test("an option digit reads as an ordinary answer")
  func aDigitReadsAsAnAnswer() {
    for number in 1...9 {
      #expect(PaneComposerCopy.sentVerdict(for: PaneKey.digit(number)) == PaneComposerCopy.sent)
    }
  }

  @Test("Ctrl-C says what it did, not just that it went")
  func ctrlCSaysWhatHappened() {
    #expect(PaneComposerCopy.sentVerdict(for: .interrupt) == "Sent Ctrl-C · Claude was interrupted")
  }

  @Test("every other key names itself")
  func everyOtherKeyNamesItself() {
    #expect(PaneComposerCopy.sentVerdict(for: .esc) == "Sent Esc")
    #expect(PaneComposerCopy.sentVerdict(for: .up) == "Sent Up")
    #expect(PaneComposerCopy.sentVerdict(for: .down) == "Sent Down")
    #expect(PaneComposerCopy.sentVerdict(for: .tab) == "Sent Tab")
    #expect(PaneComposerCopy.sentVerdict(for: .yes) == "Sent y")
    #expect(PaneComposerCopy.sentVerdict(for: .no) == "Sent n")
  }

  @Test("no two keys share a sentence, except Enter sharing text's")
  func sentencesAreDistinctPerKey() {
    let verdicts = PaneKey.allCases.map { PaneComposerCopy.sentVerdict(for: $0) }
    let nonEnter = verdicts.filter { $0 != PaneComposerCopy.sent }
    #expect(Set(nonEnter).count == nonEnter.count)
  }
}
