import DriverrCore
import DriverrHerdr
import DriverrSSH
import DriverrTranscript
import Foundation
import Observation
import Testing

@testable import Driverr

/// When a pane's `agent_session` changes while its chat is open, `ConnectionModel.apply(_:)`
/// invalidates the transcript model and has to restart the fetch. `PaneChatView`'s
/// `.task(id: model.pane.id)` does not re-run, because the pane id is unchanged, so the chat
/// would otherwise sit on "Reading the session file…" for ever.
///
/// `PaneChatUITests.testSendingTheFirstMessageAnswersTheNoSessionFileNotice` reaches this only
/// when the poll and the post-send re-read land in one order. Calling `apply(_:)` with scripted
/// `SessionModel.Changes` makes it deterministic.
@MainActor
@Suite("A pane whose session changes while its chat is open", .timeLimit(.minutes(1)))
struct ConnectionModelPaneMovedTests {
  private let workbox = DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson")

  /// The shared `waitUntil` in `TestWaker.swift`, on a private waker. Keep the
  /// `Task.isCancelled` check; see `Waker`.
  private func waitUntil(
    _ condition: @MainActor () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    let waker = Waker()
    while true {
      let seen = waker.generation
      var satisfied = false
      withObservationTracking {
        satisfied = condition()
      } onChange: {
        waker.signalFromAnywhere()
      }
      if satisfied { return }
      await waker.next(after: seen)
      if Task.isCancelled {
        Issue.record(
          "waitUntil was cancelled before its condition ever held",
          sourceLocation: sourceLocation
        )
        return
      }
    }
  }

  private func environment(control: FakeControl) -> AppEnvironment {
    var environment = AppEnvironment.ephemeral
    environment.knownHostsStore = InMemoryKnownHostsStore(
      seeded: [workbox.hostname: FakeSSHTransport.defaultHostKey]
    )
    environment.makeTransport = { FakeSSHTransport() }
    environment.makeHerdrControl = { _ in control }
    // The reader's answer does not matter: the assertion is about `state` leaving `.idle`
    // synchronously.
    environment.makeTranscriptReader = { _ in
      TranscriptReader(run: { _ in CommandResult(standardOutput: "", standardError: "", exitStatus: 1) })
    }
    return environment
  }

  @Test("apply(_:) restarts the fetch rather than leaving the model in .idle")
  func hasMovedOnRestartsTheFetch() async throws {
    let control = FakeControl(tree: FakeControl.treeWithUnstartedAgent)
    let model = ConnectionModel(host: workbox, environment: environment(control: control))
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    #expect(model.phase == .connected)

    let pane = try #require(
      FakeControl.treeWithUnstartedAgent.pane(id: "w1:p2"),
      "the fixture must still hold this pane"
    )
    #expect(pane.agent?.session == nil, "the fixture's whole point is starting with no session")

    // Let the first fetch settle. `hasMovedOn` compares against `resolvedFrom`, which only a
    // completed fetch sets, so before it `hasMovedOn` is `false` and the branch under test is
    // never reached.
    let transcript = try #require(model.transcripts?.model(for: pane))
    transcript.loadIfNeeded()
    await waitUntil { transcript.state != .loading }
    #expect(transcript.state != .idle, "loadIfNeeded() must leave .idle immediately")

    // A first message makes herdr report a session for the same pane id.
    let movedAgent = Agent(
      name: pane.agent?.name ?? "Claude",
      kind: pane.agent?.kind,
      status: pane.agent?.status ?? .working,
      session: AgentSession(agent: "claude", kind: "id", value: "3f8c1d20-0000-4000-8000-000000000099")
    )
    let movedPane = Pane(
      id: pane.id,
      tabID: pane.tabID,
      workspaceID: pane.workspaceID,
      title: pane.title,
      agent: movedAgent,
      terminalID: pane.terminalID,
      directory: pane.directory,
      isFocused: pane.isFocused,
      viewportRows: pane.viewportRows
    )

    model.apply(SessionModel.Changes(moved: [movedPane], liveIDs: [pane.id]))

    // `invalidate()` alone leaves `.idle` with nothing to bring it back. `loadIfNeeded()`
    // after it sets `.loading` synchronously, so this needs no wait.
    #expect(
      transcript.state != .idle,
      "a pane whose session just appeared must not be stranded on the loading spinner"
    )
  }

  /// A model made from a view's older `Pane` is corrected by the next poll, even one that moved
  /// nothing. Otherwise the stale value stays until the pane's next status or session change.
  @Test("apply(_:) records the live pane on a cached model the poll did not move")
  func applyRecordsTheLivePaneOnEveryModel() async throws {
    let control = FakeControl(tree: FakeControl.treeWithUnstartedAgent)
    let model = ConnectionModel(host: workbox, environment: environment(control: control))
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    let live = try #require(FakeControl.treeWithUnstartedAgent.pane(id: "w1:p2"))
    let stale = Pane(
      id: live.id,
      tabID: live.tabID,
      workspaceID: live.workspaceID,
      title: live.title,
      agent: Agent(
        name: "Claude", kind: "claude", status: .blocked,
        session: AgentSession(agent: "claude", kind: "id", value: "an-older-session")),
      terminalID: live.terminalID,
      directory: live.directory
    )
    let transcript = try #require(model.transcripts?.model(for: stale))

    model.apply(SessionModel.Changes(moved: [], liveIDs: [live.id], livePanes: [live]))

    #expect(
      transcript.pane.agent?.session?.identifier == live.agent?.session?.identifier,
      "the model still holds the session a view handed it")
  }
}
