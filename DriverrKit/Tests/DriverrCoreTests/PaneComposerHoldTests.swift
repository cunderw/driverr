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
    #expect(PaneComposerHold.reason(agent: agent) == .agentAsksOnScreen)
  }

  @Test("a blocked Claude with a session of its own lets the send go")
  func withSession() {
    let agent = Agent(name: "Claude", kind: "claude", status: .blocked, session: Self.session)
    #expect(PaneComposerHold.reason(agent: agent) == nil)
  }

  @Test(
    "any other status lets the send go",
    arguments: [AgentStatus.idle, .working, .done, .error, .unknown])
  func otherStatuses(status: AgentStatus) {
    let agent = Agent(name: "Claude", kind: "claude", status: status)
    #expect(PaneComposerHold.reason(agent: agent) == nil)
  }

  /// herdr-core and a tmux record can say what a blocked Claude waits on. Those panes keep
  /// today's composer.
  @Test(
    "a blocked Claude that names what it waits on lets the send go",
    arguments: [AgentBlockedKind.permission, .question, .auth])
  func namedReason(kind: AgentBlockedKind) {
    let agent = Agent(name: "Claude", kind: "claude", status: .blocked, blockedKind: kind)
    #expect(PaneComposerHold.reason(agent: agent) == nil)
  }

  /// `TranscriptAgent(of:)`, the reader's rule: the kind is matched whole, any case.
  @Test(
    "a kind that only starts with claude is not Claude, and the kind's case does not matter")
  func claudeByTheReadersRule() {
    let helper = Agent(name: "Claude helper", kind: "claude-helper", status: .blocked)
    #expect(TranscriptAgent(of: helper) == nil)
    #expect(PaneComposerHold.reason(agent: helper) == nil)
    let upper = Agent(name: "Claude", kind: "CLAUDE", status: .blocked)
    #expect(TranscriptAgent(of: upper) == .claude)
    #expect(PaneComposerHold.reason(agent: upper) == .agentAsksOnScreen)
  }

  @Test("a blocked Codex, or no agent, lets the send go")
  func notClaude() {
    let codex = Agent(name: "Codex", kind: TranscriptAgent.codex.rawValue, status: .blocked)
    #expect(PaneComposerHold.reason(agent: codex) == nil)
    #expect(PaneComposerHold.reason(agent: nil) == nil)
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
}
