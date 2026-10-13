import Testing

@testable import DriverrCore

/// What the foot of the conversation says, and more often what it does not.
@Suite("ChatActivity")
struct ChatActivityTests {
  private func pane(_ status: AgentStatus) -> Pane {
    Pane(
      id: "w1:p1",
      tabID: "w1:t1",
      workspaceID: "w1",
      title: "needs a decision",
      agent: Agent(name: "Claude", kind: "claude", status: status)
    )
  }

  private func header(_ status: AgentStatus) -> PaneComposerHeader {
    PaneComposerHeader(pane: pane(status))
  }

  @Test("a working pane reports that it is working")
  func workingReports() throws {
    let activity = try #require(ChatActivity(header: header(.working), status: nil))
    #expect(activity.message == "Claude is working.")
    #expect(activity.tone == .progress)
    #expect(activity.showsSpinner)
    #expect(!activity.offersRetry)
  }

  /// The conversation already shows a blocked pane: the turn is emphasised and carries its
  /// chips. A caption would repeat it.
  @Test("a pane with nothing in flight says nothing at all", arguments: [
    AgentStatus.blocked, .idle, .done, .unknown,
  ])
  func quietStatesAreSilent(status: AgentStatus) {
    #expect(ChatActivity(header: header(status), status: nil) == nil)
  }

  @Test("a pane with no agent says nothing")
  func shellIsSilent() {
    let shell = Pane(id: "w1:p2", tabID: "w1:t1", workspaceID: "w1", title: "shell")
    #expect(ChatActivity(header: PaneComposerHeader(pane: shell), status: nil) == nil)
  }

  /// The two must not stack, or the foot grows and shrinks on the way to the field.
  @Test("a send verdict outranks the agent's own state")
  func verdictWins() throws {
    let status = PaneComposerStatus(
      message: "Sent · waiting for the agent",
      detail: nil,
      tone: .success,
      offersRetry: false
    )
    let activity = try #require(ChatActivity(header: header(.working), status: status))
    #expect(activity.message == "Sent · waiting for the agent")
    #expect(activity.tone == .success)
    #expect(!activity.showsSpinner)
  }

  /// Answering a blocked agent is the most common send.
  @Test("a verdict shows on a pane that is not working")
  func verdictOnAQuietPane() throws {
    let status = PaneComposerStatus(
      message: "Couldn't send", detail: "no such pane", tone: .failure, offersRetry: true)
    let activity = try #require(ChatActivity(header: header(.blocked), status: status))
    #expect(activity.message == "Couldn't send")
    #expect(activity.detail == "no such pane")
    #expect(activity.offersRetry)
    #expect(activity.tone == .failure)
  }

  /// Two lines would be two swipes for a sentence and its cause.
  @Test("a headline and its cause are one sentence to a screen reader")
  func speaksAsOneSentence() throws {
    let status = PaneComposerStatus(
      message: "Couldn't send", detail: "no such pane", tone: .failure, offersRetry: true)
    let activity = try #require(ChatActivity(header: header(.idle), status: status))
    #expect(activity.accessibilityLabel == "Couldn't send. no such pane")

    let working = try #require(ChatActivity(header: header(.working), status: nil))
    #expect(working.accessibilityLabel == "Claude is working.")
  }

  /// Only a failure offers a retry; retrying a send that worked would send it twice.
  @Test("a spinner belongs to progress and to nothing else")
  func spinnerOnlyOnProgress() throws {
    for tone in [PaneComposerStatus.Tone.success, .failure] {
      let status = PaneComposerStatus(
        message: "m", detail: nil, tone: tone, offersRetry: false)
      let activity = try #require(ChatActivity(header: header(.idle), status: status))
      #expect(!activity.showsSpinner)
    }
    let sending = PaneComposerStatus(
      message: "Sending…", detail: nil, tone: .progress, offersRetry: false)
    let activity = try #require(ChatActivity(header: header(.idle), status: sending))
    #expect(activity.showsSpinner)
  }
}

/// The count under a part-answered multi-question call.
@Suite("ChatActivity.answering")
struct ChatActivityAnsweringTests {
  @Test("the count says how many questions of how many have an answer")
  func countsAnsweredQuestions() throws {
    let none = try #require(ChatActivity.answering(chosen: 0, of: 2))
    let one = try #require(ChatActivity.answering(chosen: 1, of: 2))

    #expect(none.message == "0 of 2 answered")
    #expect(one.message == "1 of 2 answered")
  }

  /// Shown from rest, so the row does not appear and disappear while questions are answered.
  @Test("zero answered still says something")
  func zeroIsStillARow() {
    #expect(ChatActivity.answering(chosen: 0, of: 4) != nil)
  }

  /// One question is answered by the tap that chooses it.
  @Test("a single question gets no count")
  func oneQuestionIsSilent() {
    #expect(ChatActivity.answering(chosen: 0, of: 1) == nil)
    #expect(ChatActivity.answering(chosen: 0, of: 0) == nil)
  }

  /// Nothing is running while the reader answers.
  @Test("the count carries no spinner and no retry")
  func noSpinner() throws {
    let counting = try #require(ChatActivity.answering(chosen: 1, of: 3))

    #expect(counting.tone == .prompt)
    #expect(counting.showsSpinner == false)
    #expect(counting.offersRetry == false)
    #expect(counting.detail == nil)
  }
}

/// Which of the two rows the foot shows. A question herdr has not called `blocked` would
/// otherwise show "Claude is working." over its own unanswered chips.
@Suite("ChatActivity.foot")
struct ChatActivityFootTests {
  private func working() -> ChatActivity {
    ChatActivity(message: "Claude is working.", detail: nil, tone: .progress, offersRetry: false)
  }

  private func verdict() -> ChatActivity? {
    ChatActivity(
      header: PaneComposerHeader(
        pane: Pane(
          id: "p", tabID: "t", workspaceID: "w", title: "pane",
          agent: Agent(name: "Claude", kind: "claude", status: .working)
        )
      ),
      status: PaneComposerStatus(
        message: "Sent · waiting for the agent", detail: nil, tone: .success, offersRetry: false
      )
    )
  }

  @Test("the count outranks what the pane is doing")
  func countBeatsTheStatus() throws {
    let counting = try #require(ChatActivity.answering(chosen: 0, of: 2))
    #expect(ChatActivity.foot(reporting: working(), answering: counting) == counting)
  }

  @Test("a send verdict outranks the count")
  func verdictBeatsTheCount() throws {
    let sent = try #require(verdict())
    #expect(sent.isVerdict)
    #expect(ChatActivity.foot(reporting: sent, answering: ChatActivity.answering(chosen: 1, of: 2))
      == sent)
  }

  /// A working row and a verdict are both `.progress`, so the tone cannot tell them apart;
  /// the flag does.
  @Test("what the pane is doing is not a verdict")
  func aStatusRowIsNotAVerdict() throws {
    let pane = Pane(
      id: "p", tabID: "t", workspaceID: "w", title: "pane",
      agent: Agent(name: "Claude", kind: "claude", status: .working)
    )
    let reported = try #require(
      ChatActivity(header: PaneComposerHeader(pane: pane), status: nil))
    #expect(reported.isVerdict == false)
    #expect(reported.tone == .progress)
  }

  @Test("with no count the pane's own row stands")
  func statusStandsAlone() {
    #expect(ChatActivity.foot(reporting: working(), answering: nil) == working())
    #expect(ChatActivity.foot(reporting: nil, answering: nil) == nil)
  }
}
