import DriverrCore
import Testing

/// The composer's hold: an agent that has not started its session and asks on its screen
/// must not get typed text and Enter. Claude Code's folder-trust prompt picks "No, exit" on
/// Enter (#122).
@Suite("PaneComposerHold")
struct PaneComposerHoldTests {
  @Test(
    "a blocked agent waiting for its first file holds the send",
    arguments: [
      TranscriptAbsence.noSessionFiles(directory: "/home/x/project"),
      .reportedSessionMissing(sessionID: "s", directory: "/home/x/project"),
    ])
  func held(absence: TranscriptAbsence) {
    #expect(
      PaneComposerHold.reason(agentStatus: .blocked, absence: absence) == .agentAsksOnScreen)
  }

  @Test(
    "any other status with no file lets the send go",
    arguments: [AgentStatus?.none, .idle, .working, .done, .error, .unknown])
  func otherStatuses(status: AgentStatus?) {
    #expect(
      PaneComposerHold.reason(
        agentStatus: status, absence: .noSessionFiles(directory: "/home/x/project")) == nil)
    #expect(
      PaneComposerHold.reason(
        agentStatus: status,
        absence: .reportedSessionMissing(sessionID: "s", directory: "/home/x/project")) == nil)
  }

  @Test(
    "a blocked agent with a transcript, or another absence, lets the send go",
    arguments: [
      TranscriptAbsence?.none, .paneHasNoDirectory, .agentNotSupported(agent: "Gemini"),
      .paneHasNoAgent,
    ])
  func otherAbsences(absence: TranscriptAbsence?) {
    #expect(PaneComposerHold.reason(agentStatus: .blocked, absence: absence) == nil)
  }

  @Test("the held composer names Show the Screen")
  func message() {
    #expect(PaneComposerHold.agentAsksOnScreen.message.contains(TranscriptNotice.showScreenTitle))
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
