import Testing

@testable import DriverrCore

/// The stack of sub-agent conversations a pane's chat has opened.
@Suite("SubagentStack")
struct SubagentStackTests {
  @Test("an empty stack shows the pane's own conversation")
  func emptyIsThePane() {
    let stack = SubagentStack<String>()
    #expect(stack.depth == 0)
    #expect(stack.isEmpty)
    #expect(stack.top == nil)
  }

  @Test("push shows the newest, pop returns to the one before it")
  func pushAndPop() {
    var stack = SubagentStack<String>()
    stack.push("analyst")
    stack.push("verifier")
    #expect(stack.depth == 2)
    #expect(stack.top == "verifier")
    #expect(stack.pop() == "verifier")
    #expect(stack.top == "analyst")
    #expect(stack.pop() == "analyst")
    #expect(stack.isEmpty)
  }

  @Test("popping the pane's own conversation does nothing")
  func popAtTheBottom() {
    var stack = SubagentStack<String>()
    #expect(stack.pop() == nil)
    #expect(stack.depth == 0)
  }

  @Test("removing everything hands back every entry, top first")
  func removeAll() {
    var stack = SubagentStack<String>()
    stack.push("a")
    stack.push("b")
    #expect(stack.removeAll() == ["b", "a"])
    #expect(stack.isEmpty)
  }
}

/// The words a sub-agent's chat says.
@Suite("Sub-agent chat copy")
struct SubagentChatCopyTests {
  @Test("a parent's prompt is labelled as the parent agent's, never as You")
  func parentPromptIsNotYou() {
    let prompt = TranscriptTurn(id: "p", speech: .human("Plan it"), isParentPrompt: true)
    let said = TranscriptTurn(id: "h", speech: .human("Plan it"))
    #expect(prompt.speaker(agentName: "Claude") == TranscriptChatCopy.parentPrompt)
    #expect(prompt.speaker(agentName: "Claude") != TranscriptChatCopy.human)
    #expect(said.speaker(agentName: "Claude") == TranscriptChatCopy.human)
  }

  @Test("a link that found no file says so, offers a retry and no screen")
  func unresolvedLinkNotice() {
    let notice = TranscriptNotice(absence: .subagentFileNotFound, agentStatus: nil)
    #expect(notice.title == "No file for this agent yet")
    #expect(notice.offersRetry)
    #expect(!notice.offersScreen)
    #expect(!TranscriptAbsence.subagentFileNotFound.isUnreadableAgentKind)
  }

  @Test("the back bar names the spawn, or its description when it has no name")
  func subagentTitle() {
    let named = TranscriptTurn.AgentEvent(
      sender: "analyst-7", summary: "Plan it", body: "", kind: .spawned)
    let unnamed = TranscriptTurn.AgentEvent(
      sender: "", summary: "Plan it", body: "", kind: .spawned)
    let bare = TranscriptTurn.AgentEvent(sender: "", summary: nil, body: "", kind: .spawned)
    #expect(named.subagentTitle == "analyst-7")
    #expect(unnamed.subagentTitle == "Plan it")
    #expect(bare.subagentTitle == "")
  }

  @Test("an event keeps its link when its task is settled")
  func linkSurvivesTask() {
    let event = TranscriptTurn.AgentEvent(
      sender: "analyst-7", summary: nil, body: "", kind: .spawned,
      link: .teammate(name: "analyst-7"))
    #expect(event.with(task: TaskProgress(state: .idle)).link == .teammate(name: "analyst-7"))
  }
}

/// `Show the Screen` is the pane's screen, so a sub-agent's chat never offers it.
@Suite("A sub-agent's notices")
struct SubagentNoticeTests {
  @Test("a failed sub-agent read offers no screen, where the pane's own failure does")
  func failureOffersNoScreenInASubagent() {
    let notice = TranscriptNotice(failure: .transcriptUnreadable(reason: "gone"))
    #expect(notice.offersScreen(inSubagentChat: false, canReadScreen: true))
    #expect(!notice.offersScreen(inSubagentChat: true, canReadScreen: true))
  }
}
