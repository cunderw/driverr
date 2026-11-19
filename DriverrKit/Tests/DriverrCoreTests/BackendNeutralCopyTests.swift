import Testing

@testable import DriverrCore

/// Sentences that a tmux pane or a tmux-only host can show must not name herdr as the thing
/// that failed. They name no backend, or they name both.
@Suite("Backend-neutral copy")
struct BackendNeutralCopyTests {
  @Test("a tmux agent nothing recognised does not blame herdr")
  func unknownAgentNamesNoBackend() {
    let agent = Agent(name: "Claude", kind: "claude", status: .unknown)
    let pane = Pane(
      id: "tmux:%3", tabID: "tmux:@1", workspaceID: "tmux:$0", title: "t", agent: agent)
    #expect(PaneComposerHeader(pane: pane).state == "Driverr can't tell what Claude is doing.")
  }

  @Test("a send with no answer and a reply still waiting name no backend")
  func composerCopyNamesNoBackend() {
    #expect(PaneComposerCopy.noAnswer == "The host did not answer.")
    #expect(PaneComposerCopy.stillWaiting("Claude") == "The pane still reports Claude as waiting.")
  }

  @Test("a set-up that stops answering names both things Driverr looks for")
  func setUpTimeoutNamesHerdrAndTmux() {
    #expect(
      AppError.herdrDidNotAnswer(host: "workbox").errorDescription
        == "Reached workbox, but it stopped answering while Driverr looked for herdr and tmux.")
  }

  @Test("an answer Driverr cannot read names no backend")
  func unreadableAnswerNamesNoBackend() {
    #expect(
      AppError.herdrResponseUnreadable.errorDescription
        == "The host answered with something this version of Driverr does not understand.")
  }

  @Test("a pane with no directory names no backend")
  func missingDirectoryNamesNoBackend() {
    let notice = TranscriptNotice(absence: .paneHasNoDirectory, agentStatus: nil)
    #expect(!notice.message.contains("herdr"))
  }
}
