import DriverrCore
import Testing

/// The composer's hold: a blocked Claude with no session of its own asks on its screen and
/// must not get typed text and Enter. Claude Code's folder-trust prompt picks "No, exit" on
/// Enter (#122).
@Suite("PaneComposerHold")
struct PaneComposerHoldTests {
  private static let session = AgentSession(
    agent: TranscriptAgent.claude.rawValue, kind: "id", value: "s-1",
    source: AgentSession.claudeRecordSource)

  @Test(
    "a blocked Claude with no session of its own holds the send",
    arguments: [
      Agent(name: "Claude", kind: "claude", status: .blocked),
      // No kind: the display name decides, as the reader's does.
      Agent(name: "Claude Code", status: .blocked),
    ])
  func held(agent: Agent) {
    #expect(PaneComposerHold.reason(agent: agent, screen: nil) == .agentAsksOnScreen)
  }

  @Test("a blocked Claude with a session of its own lets the send go")
  func withSession() {
    let agent = Agent(name: "Claude", kind: "claude", status: .blocked, session: Self.session)
    #expect(PaneComposerHold.reason(agent: agent, screen: nil) == nil)
  }

  @Test(
    "any other status lets the send go",
    arguments: [AgentStatus.idle, .working, .done, .error, .unknown])
  func otherStatuses(status: AgentStatus) {
    let agent = Agent(name: "Claude", kind: "claude", status: status)
    #expect(PaneComposerHold.reason(agent: agent, screen: nil) == nil)
  }

  /// herdr-core and a tmux record can say what a blocked Claude waits on. Those panes keep
  /// today's composer.
  @Test(
    "a blocked Claude that names what it waits on lets the send go",
    arguments: [AgentBlockedKind.permission, .question, .auth])
  func namedReason(kind: AgentBlockedKind) {
    let agent = Agent(name: "Claude", kind: "claude", status: .blocked, blockedKind: kind)
    #expect(PaneComposerHold.reason(agent: agent, screen: nil) == nil)
  }

  /// `TranscriptAgent(of:)`, the reader's rule: the kind is matched whole, any case.
  @Test(
    "a kind that only starts with claude is not Claude, and the kind's case does not matter")
  func claudeByTheReadersRule() {
    let helper = Agent(name: "Claude helper", kind: "claude-helper", status: .blocked)
    #expect(TranscriptAgent(of: helper) == nil)
    #expect(PaneComposerHold.reason(agent: helper, screen: nil) == nil)
    let upper = Agent(name: "Claude", kind: "CLAUDE", status: .blocked)
    #expect(TranscriptAgent(of: upper) == .claude)
    #expect(PaneComposerHold.reason(agent: upper, screen: nil) == .agentAsksOnScreen)
  }

  @Test("a blocked Codex, or no agent, lets the send go")
  func notClaude() {
    let codex = Agent(name: "Codex", kind: TranscriptAgent.codex.rawValue, status: .blocked)
    #expect(PaneComposerHold.reason(agent: codex, screen: nil) == nil)
    #expect(PaneComposerHold.reason(agent: nil, screen: nil) == nil)
  }

  @Test("the held composer's line is one short sentence that names no button")
  func lineIsShort() {
    let line = PaneComposerHold.agentAsksOnScreen.message
    #expect(line == "Sending is off while the agent asks on its screen.")
    #expect(!line.contains(TranscriptNotice.showScreenTitle))
  }

  @Test("a hold keeps the typed text and refuses to send it, and its end lets it go")
  func stateHoldsTypedText() {
    var state = PaneComposerState()
    state.text = "yes"
    state.hold = .agentAsksOnScreen

    #expect(!state.canSend)
    #expect(state.beginSending() == nil)
    #expect(state.beginSending(text: "continue") == nil)
    #expect(state.phase == .editing)
    #expect(state.text == "yes")

    state.hold = nil
    #expect(state.canSend)
    #expect(state.beginSending() == .text("yes"))
  }

  /// An attachment's hand-off types its path into the pane, which is typed text by another
  /// route: into Codex's picker it is no keys, and into the trust prompt it is noise. So a
  /// hold turns attaching off (#109).
  @Test("a hold turns attaching off, and its end turns it back on")
  func attachHeld() {
    var state = PaneComposerState()
    #expect(state.canAttach)
    state.hold = .pickerOpen
    #expect(!state.canAttach)
    state.hold = .agentAsksOnScreen
    #expect(!state.canAttach)
    state.hold = nil
    #expect(state.canAttach)
  }

  @Test("a hold lets a key press go, because a key is a deliberate answer")
  func keysGo() {
    var state = PaneComposerState()
    state.hold = .agentAsksOnScreen
    #expect(state.beginSending(.down) == .key(.down))
  }

  @Test("a failed text is not retried while held, and its Retry is not offered")
  func retryHeld() {
    var state = PaneComposerState()
    state.text = "yes"
    _ = state.beginSending()
    state.failed(.herdrCommandFailed(reason: "no such pane"))
    state.hold = .agentAsksOnScreen

    #expect(state.status?.offersRetry == false)
    #expect(state.beginRetry() == nil)

    state.hold = nil
    #expect(state.status?.offersRetry == true)
    #expect(state.beginRetry() == .text("yes"))
  }

  @Test("a failed key is still retried while held")
  func keyRetryGoes() {
    var state = PaneComposerState()
    _ = state.beginSending(.down)
    state.failed(.herdrCommandFailed(reason: "no such pane"))
    state.hold = .agentAsksOnScreen
    #expect(state.status?.offersRetry == true)
    #expect(state.beginRetry() == .key(.down))
  }

  // MARK: - An open Codex picker (#109)

  private static func screen(_ ansi: String) -> PaneScreen {
    PaneScreen.sanitised(ansi, lines: PaneScreen.maximumLines)
  }

  private static let codex = Agent(
    name: "Codex", kind: TranscriptAgent.codex.rawValue, status: .idle)

  /// herdr reports the pane idle with the picker open, and a typed send is pasted text, which
  /// the picker reads as no keys, then Enter, which picks the highlighted option.
  @Test("a Codex with its picker on the screen holds the send")
  func codexPicker() {
    #expect(
      PaneComposerHold.reason(
        agent: Self.codex, screen: Self.screen(CodexPickerScreenFixture.permissions))
        == .pickerOpen)
    #expect(
      PaneComposerHold.reason(
        agent: Self.codex, screen: Self.screen(CodexPickerScreenFixture.modelStage2))
        == .pickerOpen)
  }

  @Test("a Codex at its own prompt, or with no screen read, lets the send go")
  func codexWithoutPicker() {
    #expect(
      PaneComposerHold.reason(
        agent: Self.codex, screen: Self.screen(CodexPickerScreenFixture.idleNumberedList))
        == nil)
    #expect(PaneComposerHold.reason(agent: Self.codex, screen: nil) == nil)
  }

  /// The picker's evidence is Codex's own; the reader's rule names the agent.
  @Test("Codex's picker on a pane whose agent is not Codex does not hold")
  func pickerOnAnotherAgent() {
    let claude = Agent(name: "Claude", kind: "claude", status: .idle)
    #expect(
      PaneComposerHold.reason(
        agent: claude, screen: Self.screen(CodexPickerScreenFixture.permissions)) == nil)
  }

  @Test("the picker's line is one short sentence of its own")
  func pickerLine() {
    let line = PaneComposerHold.pickerOpen.message
    #expect(line == "Sending is off while the agent's picker is open.")
    #expect(line != PaneComposerHold.agentAsksOnScreen.message)
  }

  @Test("the folder-trust hold still comes from the agent, whatever the screen shows")
  func trustHoldIsTheAgents() {
    let claude = Agent(name: "Claude", kind: "claude", status: .blocked)
    #expect(
      PaneComposerHold.reason(
        agent: claude, screen: Self.screen(ClaudeTrustPromptScreenFixture.wide))
        == .agentAsksOnScreen)
  }
}

/// When the chat reads the pane's screen for a question: a blocked pane, or a Codex that is not
/// working, whose picker herdr reports idle (#109). One `pane read` per watch tick.
@Suite("Watching the screen for a question")
struct ScreenQuestionWatchTests {
  private static func agent(_ kind: TranscriptAgent, _ status: AgentStatus) -> Agent {
    Agent(name: kind.displayName, kind: kind.rawValue, status: status)
  }

  @Test("any blocked agent is watched", arguments: TranscriptAgent.allCases)
  func blocked(kind: TranscriptAgent) {
    #expect(PaneQuestionScreen.watches(agent: Self.agent(kind, .blocked), pendingCall: nil))
  }

  @Test(
    "a Codex that is not working is watched", arguments: [AgentStatus.idle, .done, .error, .unknown])
  func codexNotWorking(status: AgentStatus) {
    #expect(PaneQuestionScreen.watches(agent: Self.agent(.codex, status), pendingCall: nil))
  }

  @Test("a working Codex, and a Claude that is not blocked, are not watched")
  func notWatched() {
    #expect(!PaneQuestionScreen.watches(agent: Self.agent(.codex, .working), pendingCall: nil))
    for status in AgentStatus.allCases where status != .blocked {
      #expect(!PaneQuestionScreen.watches(agent: Self.agent(.claude, status), pendingCall: nil))
    }
    #expect(!PaneQuestionScreen.watches(agent: nil, pendingCall: nil))
  }

  /// A transcript question wins, so the screen is not read for one.
  @Test("a pending call that asks its own question stops the watch")
  func transcriptQuestionWins() {
    let asking = ToolCall(
      name: "AskUserQuestion", outcome: .pending,
      questions: [PendingQuestion(question: "Pick", options: ["A", "B"])])
    #expect(!PaneQuestionScreen.watches(agent: Self.agent(.claude, .blocked), pendingCall: asking))
    #expect(!PaneQuestionScreen.watches(agent: Self.agent(.codex, .idle), pendingCall: asking))
  }
}
