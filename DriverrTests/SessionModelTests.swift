import DriverrCore
import DriverrHerdr
import Foundation
import Testing

@testable import Driverr

/// Counts the polls that have *completed*, and hands out a wait on the next one.
///
/// A deadline is a fact about the machine; the number of polls finished is a fact about the
/// loop under test.
///
/// `refresh()` calls `SessionModel.onSessionChanged` after the new tree is stored, so awaiting
/// it means one poll finished and its result is on the model. A loop that has stopped fails on
/// the suite's `.timeLimit`, so the wait is cancellation-aware.
///
/// It fires only on a successful poll, so the error tests drive `refresh()` by hand.
@MainActor
private final class PollRecorder {
  private struct Waiter {
    let id: Int
    let threshold: Int
    let continuation: CheckedContinuation<Void, Never>
  }

  private(set) var completed = 0
  private var waiters: [Waiter] = []
  private var nextWaiterID = 0

  /// Hand this to `SessionModel.onSessionChanged`.
  var record: (SessionModel.Changes) -> Void {
    { [weak self] _ in self?.pollCompleted() }
  }

  /// Suspends until at least `count` polls have completed.
  func waitForPolls(_ count: Int) async {
    guard completed < count else { return }
    let id = nextWaiterID
    nextWaiterID += 1
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        // Cancelled before the waiter was parked: resume now, or nothing ever will.
        if Task.isCancelled {
          continuation.resume()
        } else {
          waiters.append(Waiter(id: id, threshold: count, continuation: continuation))
        }
      }
    } onCancel: {
      Task { @MainActor in self.cancel(id) }
    }
  }

  private func pollCompleted() {
    completed += 1
    var parked: [Waiter] = []
    for waiter in waiters {
      if completed >= waiter.threshold {
        waiter.continuation.resume()
      } else {
        parked.append(waiter)
      }
    }
    waiters = parked
  }

  private func cancel(_ id: Int) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    waiters.remove(at: index).continuation.resume()
  }
}

/// The polling loop. herdr has no reachable subscription API (see `SessionModel.pollInterval`),
/// so the loop has to start, repeat, stop, and never run twice over the same host.
@MainActor
@Suite("SessionModel", .timeLimit(.minutes(1)))
struct SessionModelTests {
  /// Short enough to keep the suite fast. The waits are on finished polls, so a late tick costs
  /// time, not a failure.
  private let interval = Duration.milliseconds(30)

  /// A model whose completed polls can be awaited. The recorder has to be installed before
  /// the loop starts, or the first poll is finished before anything is listening.
  private func live(
    _ control: any HerdrControl,
    pollInterval: Duration
  ) -> (SessionModel, PollRecorder) {
    let model = SessionModel(control: control, pollInterval: pollInterval)
    let polls = PollRecorder()
    model.onSessionChanged = polls.record
    return (model, polls)
  }

  /// Several ticks long, used only where the claim is that something did not happen, which a
  /// slow machine makes hold.
  private let settle = Duration.milliseconds(200)

  @Test("a first read happens immediately rather than after one interval")
  func loadsBeforeWaiting() async {
    // A screen that is blank for the length of the poll interval before its first read
    // looks broken.
    let control = FakeControl()
    let (model, polls) = live(control, pollInterval: .seconds(30))
    model.startLiveUpdates()
    defer { model.stopLiveUpdates() }

    await polls.waitForPolls(1)
    #expect(await control.snapshotCount == 1)
    #expect(!model.tree.isEmpty)
  }

  @Test("polling repeats")
  func polls() async {
    let control = FakeControl()
    let (model, polls) = live(control, pollInterval: interval)
    model.startLiveUpdates()
    defer { model.stopLiveUpdates() }

    await polls.waitForPolls(3)
    #expect(await control.snapshotCount >= 3)
  }

  @Test("stopping actually stops")
  func stops() async {
    // A phone running a command against somebody's machine every few seconds with nothing on
    // screen is a battery and a trust problem.
    let control = FakeControl()
    let (model, polls) = live(control, pollInterval: interval)
    model.startLiveUpdates()
    await polls.waitForPolls(2)

    model.stopLiveUpdates()
    let afterStop = await control.snapshotCount
    try? await Task.sleep(for: settle)

    #expect(await control.snapshotCount <= afterStop + 1, "polling continued after stop")
    #expect(!model.isLive)
  }

  @Test("starting three times does not start three loops")
  func startIsIdempotent() async {
    // A SwiftUI `.task` can re-run; two loops would double the traffic and interleave
    // two refreshes over one piece of state.
    let control = FakeControl()
    let (model, polls) = live(control, pollInterval: interval)
    model.startLiveUpdates()
    model.startLiveUpdates()
    model.startLiveUpdates()

    // Waiting for three polls rather than sleeping for roughly three.
    await polls.waitForPolls(3)
    let count = await control.snapshotCount
    model.stopLiveUpdates()
    model.stopLiveUpdates()
    model.stopLiveUpdates()
    try? await Task.sleep(for: settle)

    // Three separate loops would leave two of them running: `stopLiveUpdates` can only
    // cancel the one task it holds, so the count would keep climbing.
    #expect(await control.snapshotCount <= count + 1)
    #expect(!model.isLive)
  }

  @Test("polling runs while any consumer holds it and stops when the last one leaves")
  func retainsWhileAnyConsumerIsOnScreen() async {
    // The session outlives the host screen, so it has two consumers, the host screen and the
    // terminal scene. Whichever leaves first must not take the other's live updates with it.
    let control = FakeControl()
    let (model, polls) = live(control, pollInterval: interval)
    model.startLiveUpdates()
    model.startLiveUpdates()
    await polls.waitForPolls(2)

    model.stopLiveUpdates()
    let afterFirstLeft = await control.snapshotCount
    #expect(model.isLive, "the second consumer is still on screen")
    await polls.waitForPolls(polls.completed + 1)
    #expect(await control.snapshotCount > afterFirstLeft, "polling stopped too early")

    model.stopLiveUpdates()
    let afterBothLeft = await control.snapshotCount
    try? await Task.sleep(for: settle)

    #expect(await control.snapshotCount <= afterBothLeft + 1, "polling continued after stop")
    #expect(!model.isLive)
  }

  @Test("a scripted session is picked up without anyone asking")
  func picksUpChanges() async throws {
    let control = FakeControl(script: FakeControl.blockingScript)
    let (model, polls) = live(control, pollInterval: interval)
    model.startLiveUpdates()
    defer { model.stopLiveUpdates() }

    // The script's second tree is the one that blocks, so two completed polls is when it is on
    // the model. `w2:p1` has an agent; an agentless blocked pane is an illegal state.
    await polls.waitForPolls(2)
    #expect(model.tree.pane(id: "w2:p1")?.agent?.status == .blocked)
  }

  @Test("a failed poll keeps the tree already on screen")
  func failureKeepsTheTree() async {
    // Blanking the sidebar because one refresh failed throws away what the user was
    // reading; the stale tree stays and the screen says so.
    let control = FakeControl()
    let model = SessionModel(control: control, pollInterval: interval)
    await model.refresh()
    #expect(!model.tree.isEmpty)

    let failing = SessionModel(control: FakeControl.failing(.herdrNotInstalled))
    await failing.refresh()
    #expect(failing.failure == .herdrNotInstalled)
    #expect(failing.tree.isEmpty, "nothing was ever loaded, so there is nothing to keep")
  }

  @Test("an empty session is loaded, not idle, and not a failure")
  func emptyIsLoaded() async {
    let model = SessionModel(control: FakeControl(tree: .empty))
    await model.refresh()

    #expect(model.isEmptySession)
    #expect(model.failure == nil)
  }

  // MARK: - Renaming a workspace or a tab

  @Test("the rename row opens with the name the row has now already in it")
  func renameOpensWithTheCurrentName() async {
    let model = SessionModel(control: FakeControl())
    await model.refresh()

    model.startRenaming(.workspace(id: "w1"), currentLabel: "driverr")

    #expect(model.renameDraft == "driverr")
    #expect(model.renamePrompt == .editing(.workspace(id: "w1"), currentLabel: "driverr"))
    #expect(model.pendingRename(for: .workspace(id: "w1")) != nil)
    #expect(model.pendingRename(for: .workspace(id: "w2")) == nil, "one row at a time")
    #expect(model.pendingRename(for: .tab(id: "w1")) == nil, "a tab is not a workspace")
  }

  @Test("committing sends the rename and the tree shows the new name without a poll")
  func commitRenamesAndRefreshes() async {
    // A row that keeps its old name until the next poll reads as a failed tap.
    let control = FakeControl()
    let model = SessionModel(control: control, pollInterval: .seconds(600))
    await model.refresh()

    model.startRenaming(.workspace(id: "w1"), currentLabel: "driverr")
    model.renameDraft = "shipping"
    await model.commitRename()

    let renamed = await control.renamed
    #expect(renamed.map(\.target) == [.workspace(id: "w1")])
    #expect(renamed.map(\.label) == ["shipping"])
    #expect(model.tree.workspaces.first?.label == "shipping")
    #expect(model.renamePrompt == nil)
  }

  @Test("a tab rename sends the tab's own id, not its workspace's")
  func commitRenamesATab() async {
    let control = FakeControl()
    let model = SessionModel(control: control, pollInterval: .seconds(600))
    await model.refresh()

    model.startRenaming(.tab(id: "w1:t2"), currentLabel: "tests")
    model.renameDraft = "build logs"
    await model.commitRename()

    #expect(await control.renamed.map(\.target) == [.tab(id: "w1:t2")])
    #expect(model.tree.workspaces.first?.tabs.map(\.label) == ["app", "build logs"])
  }

  @Test(
    "a label with nothing in it is a cancel, and nothing reaches herdr",
    arguments: ["", "   ", "\n\t "]
  )
  func blankLabelsAreRefused(draft: String) async {
    let control = FakeControl()
    let model = SessionModel(control: control, pollInterval: .seconds(600))
    await model.refresh()

    model.startRenaming(.workspace(id: "w1"), currentLabel: "driverr")
    model.renameDraft = draft
    await model.commitRename()

    #expect(await control.renamed.isEmpty, "an empty label must never reach herdr")
    #expect(model.renamePrompt == nil, "the row closes rather than sitting there refusing")
    #expect(model.tree.workspaces.first?.label == "driverr")
  }

  @Test("an unchanged label sends nothing, whitespace or not")
  func unchangedLabelsSendNothing() async {
    let control = FakeControl()
    let model = SessionModel(control: control, pollInterval: .seconds(600))
    await model.refresh()

    model.startRenaming(.workspace(id: "w1"), currentLabel: "driverr")
    model.renameDraft = "  driverr  "
    await model.commitRename()

    #expect(await control.renamed.isEmpty)
  }

  @Test("the label that goes over is trimmed at the ends and left alone in the middle")
  func trimsTheLabelItSends() async {
    let control = FakeControl()
    let model = SessionModel(control: control, pollInterval: .seconds(600))
    await model.refresh()

    model.startRenaming(.workspace(id: "w1"), currentLabel: "driverr")
    model.renameDraft = "  build  logs  "
    await model.commitRename()

    #expect(await control.renamed.map(\.label) == ["build  logs"])
  }

  @Test("cancelling closes the row and sends nothing")
  func cancelSendsNothing() async {
    let control = FakeControl()
    let model = SessionModel(control: control, pollInterval: .seconds(600))
    await model.refresh()

    model.startRenaming(.workspace(id: "w1"), currentLabel: "driverr")
    model.renameDraft = "shipping"
    model.cancelRenaming()
    await model.commitRename()

    #expect(await control.renamed.isEmpty)
    #expect(model.renamePrompt == nil)
  }

  @Test("a refused rename says what herdr said, under the row it was asked about")
  func aRefusedRenameReportsIt() async {
    let control = FakeControl.failing(.herdrCommandFailed(reason: "no such workspace: w1"))
    let model = SessionModel(control: control, pollInterval: .seconds(600))

    model.startRenaming(.workspace(id: "w1"), currentLabel: "driverr")
    model.renameDraft = "shipping"
    await model.commitRename()

    #expect(
      model.renamePrompt
        == .failed(.workspace(id: "w1"), .herdrCommandFailed(reason: "no such workspace: w1"))
    )
    #expect(model.pendingRename(for: .workspace(id: "w1")) != nil, "under that row, not another")
    #expect(model.isRenameInFlight == false)

    model.dismissRenameFailure()
    #expect(model.renamePrompt == nil)
  }

  @Test("opening a second row replaces the first, so there is only ever one draft")
  func oneRowAtATime() async {
    let model = SessionModel(control: FakeControl())
    await model.refresh()

    model.startRenaming(.workspace(id: "w1"), currentLabel: "driverr")
    model.renameDraft = "half typed"
    model.startRenaming(.tab(id: "w1:t1"), currentLabel: "app")

    #expect(model.renamePrompt == .editing(.tab(id: "w1:t1"), currentLabel: "app"))
    #expect(model.renameDraft == "app", "the new row's own name, not the abandoned draft")
    #expect(model.pendingRename(for: .workspace(id: "w1")) == nil)
  }

  // MARK: - What moved between two polls

  private func tree(_ panes: [Pane]) -> SessionTree {
    SessionTree(workspaces: [
      Workspace(
        id: "w1",
        number: 1,
        label: "main",
        tabs: [Tab(id: "w1:t1", workspaceID: "w1", number: 1, label: "main", panes: panes)]
      )
    ])
  }

  private func pane(
    _ id: String,
    status: AgentStatus? = .blocked,
    session: String? = nil,
    kind: String? = "claude",
    directory: String? = "/Users/x/Dev/driverr",
    title: String = "needs a decision"
  ) -> Pane {
    Pane(
      id: id,
      tabID: "w1:t1",
      workspaceID: "w1",
      title: title,
      agent: status.map {
        Agent(
          name: "Claude",
          kind: kind,
          status: $0,
          session: session.map { AgentSession(agent: "claude", kind: "id", value: $0) }
        )
      },
      directory: directory
    )
  }

  /// Blocked, then working, then blocked on one pane is a new question. Unnoticed, the chat
  /// would show the previous question and the Needs you row would quote it with the old age.
  @Test("a pane whose status changed has moved")
  func aStatusChangeMoves() {
    let changes = SessionModel.changes(
      from: tree([pane("w1:p1", status: .working)]),
      to: tree([pane("w1:p1", status: .blocked)])
    )

    #expect(changes.moved.map(\.id) == ["w1:p1"])
    #expect(changes.liveIDs == ["w1:p1"])
  }

  /// A `/clear` or a restart gives the same pane a new session file, and the old one is
  /// another conversation.
  @Test("a pane whose reported session changed has moved")
  func aNewSessionMoves() {
    let changes = SessionModel.changes(
      from: tree([pane("w1:p1", session: "old")]),
      to: tree([pane("w1:p1", session: "new")])
    )

    #expect(changes.moved.map(\.id) == ["w1:p1"])
  }

  @Test("a pane whose agent kind or directory changed has moved")
  func aNewResolverInputMoves() {
    #expect(
      SessionModel.changes(
        from: tree([pane("w1:p1", kind: "claude")]),
        to: tree([pane("w1:p1", kind: "codex")])
      ).moved.count == 1)
    #expect(
      SessionModel.changes(
        from: tree([pane("w1:p1", directory: "/a")]),
        to: tree([pane("w1:p1", directory: "/b")])
      ).moved.count == 1)
  }

  /// The title is left out on purpose. `terminal_title_stripped` does not strip Claude Code's
  /// spinner frames (`◐◑◒◓`), so comparing whole `Pane` values would report every agent pane
  /// as changed on every poll and re-read its transcript.
  @Test("a pane whose title merely cycled has not moved")
  func aSpinningTitleIsNotAMove() {
    let changes = SessionModel.changes(
      from: tree([pane("w1:p1", title: "◐ driverr")]),
      to: tree([pane("w1:p1", title: "◑ driverr")])
    )

    #expect(changes.moved.isEmpty)
    #expect(changes.isEmpty)
  }

  /// A pane that has appeared has no page yet, so counting it throws nothing away, and one
  /// that arrives blocked is about to be wanted.
  @Test("a pane that has just appeared counts as moved")
  func aNewPaneMoves() {
    let changes = SessionModel.changes(
      from: tree([pane("w1:p1")]),
      to: tree([pane("w1:p1"), pane("w1:p2")])
    )

    #expect(changes.moved.map(\.id) == ["w1:p2"])
  }

  /// What is still there, so state held for the rest can be let go. A pane id herdr reuses
  /// after a close must not get the closed pane's conversation.
  @Test("a pane that has left the session is not in the live set")
  func aClosedPaneLeavesTheLiveSet() {
    let changes = SessionModel.changes(
      from: tree([pane("w1:p1"), pane("w1:p2")]),
      to: tree([pane("w1:p1")])
    )

    #expect(changes.liveIDs == ["w1:p1"])
    #expect(changes.moved.isEmpty)
  }

  @Test("a successful poll tells whoever is listening what moved")
  func refreshReportsChanges() async {
    let control = FakeControl(script: [
      tree([pane("w1:p1", status: .working)]),
      tree([pane("w1:p1", status: .blocked)]),
    ])
    let model = SessionModel(control: control)
    var reported: [SessionModel.Changes] = []
    model.onSessionChanged = { reported.append($0) }

    await model.refresh()
    await model.refresh()

    #expect(reported.count == 2)
    #expect(reported.last?.moved.map(\.id) == ["w1:p1"])
  }

  @Test("a poll that failed reports nothing, because nothing is known to have moved")
  func aFailedPollReportsNothing() async {
    let model = SessionModel(control: FakeControl.failing(.herdrNotInstalled))
    var reported = 0
    model.onSessionChanged = { _ in reported += 1 }

    await model.refresh()

    #expect(reported == 0)
  }

  // MARK: - How long a pane has been blocked, and where the open workspaces live

  /// A pane that just blocked and one that has waited an hour must not look the same, even for
  /// an agent with no reader and so no transcript. The session sees every snapshot, so it can
  /// record this without a view inventing it.
  @Test("a pane is stamped when it enters blocked, and keeps that stamp while it stays")
  func blockedSinceIsRecordedOnce() async {
    let control = FakeControl(script: [
      tree([pane("w1:p1", status: .working)]),
      tree([pane("w1:p1", status: .blocked)]),
      tree([pane("w1:p1", status: .blocked)]),
    ])
    let model = SessionModel(control: control)
    let blocked = pane("w1:p1", status: .blocked)

    await model.refresh()
    #expect(model.blockedSince(for: blocked) == nil, "not blocked yet")

    await model.refresh()
    let stamped = model.blockedSince(for: blocked)
    #expect(stamped != nil)

    // A poll that finds it still blocked must not restamp it, or the age resets every poll.
    await model.refresh()
    #expect(model.blockedSince(for: blocked) == stamped)
  }

  /// A pane that answers and blocks again is asking a new question, so its age starts over,
  /// as `changes(from:to:)` treats it as a move.
  @Test("blocking a second time restamps the pane")
  func blockedSinceRestartsAfterUnblocking() async {
    let control = FakeControl(script: [
      tree([pane("w1:p1", status: .blocked)]),
      tree([pane("w1:p1", status: .working)]),
      tree([pane("w1:p1", status: .blocked)]),
    ])
    let model = SessionModel(control: control)
    let blocked = pane("w1:p1", status: .blocked)

    await model.refresh()
    let first = model.blockedSince(for: blocked)

    await model.refresh()
    #expect(model.blockedSince(for: blocked) == nil, "an unblocked pane has no age to show")

    await model.refresh()
    #expect(model.blockedSince(for: blocked) != first)
  }

  /// A pane that has gone must not leave its stamp. The map lives as long as the connection.
  @Test("a pane that leaves the tree drops its stamp")
  func blockedSinceIsForgottenWithThePane() async {
    let control = FakeControl(script: [
      tree([pane("w1:p1", status: .blocked), pane("w1:p2", status: .blocked)]),
      tree([pane("w1:p1", status: .blocked)]),
    ])
    let model = SessionModel(control: control)

    await model.refresh()
    #expect(model.blockedSince(for: pane("w1:p2", status: .blocked)) != nil)

    await model.refresh()
    #expect(model.blockedSince(for: pane("w1:p2", status: .blocked)) == nil)
  }

  /// Newest first, because the pane that just asked is the one worth answering.
  @Test("Needs you puts the most recently blocked pane first")
  func needsYouIsNewestFirst() async {
    let control = FakeControl(script: [
      tree([pane("w1:p1", status: .blocked), pane("w1:p2", status: .working)]),
      tree([pane("w1:p1", status: .blocked), pane("w1:p2", status: .blocked)]),
    ])
    let model = SessionModel(control: control)

    await model.refresh()
    await model.refresh()

    // p2 blocked on the second poll, p1 on the first, so p2 leads despite the tree's own
    // order putting p1 there.
    #expect(model.blockedPanesNewestFirst.map(\.id) == ["w1:p2", "w1:p1"])
  }

  /// Panes with no stamp — already blocked when this connection opened — must hold the
  /// tree's own order rather than shuffling on every poll.
  @Test("panes with no recorded age keep the tree's order")
  func unstampedPanesKeepTheirOrder() async {
    let control = FakeControl(script: [
      tree([pane("w1:p1", status: .blocked), pane("w1:p2", status: .blocked)])
    ])
    let model = SessionModel(control: control)
    await model.refresh()

    // Both were stamped by the same poll, so the tie-break is what orders them.
    #expect(model.blockedPanesNewestFirst.map(\.id) == ["w1:p1", "w1:p2"])
  }

  /// Expansion seeds once from herdr's desk focus and then belongs to the person looking, or a
  /// closed workspace would reopen on the next poll.
  @Test("the open workspaces follow the desk only on the first snapshot")
  func expansionSeedsOnceAndThenBelongsToTheReader() async {
    let control = FakeControl()
    let model = SessionModel(control: control)
    await model.refresh()

    guard let workspace = model.tree.workspaces.first else {
      Issue.record("expected the fake to have a workspace")
      return
    }
    let seeded = model.isWorkspaceExpanded(workspace)

    model.setWorkspace(workspace, expanded: !seeded)
    #expect(model.isWorkspaceExpanded(workspace) == !seeded)

    // The poll that follows must not undo it.
    await model.refresh()
    #expect(model.isWorkspaceExpanded(workspace) == !seeded)
  }

  /// Held on the session, not the view's `@State`, so popping the host screen and returning
  /// does not spring the tree back open.
  @Test("expansion survives the view that set it")
  func expansionOutlivesAView() async {
    let model = SessionModel(control: FakeControl())
    await model.refresh()
    guard let workspace = model.tree.workspaces.first else {
      Issue.record("expected the fake to have a workspace")
      return
    }

    model.setWorkspace(workspace, expanded: false)
    #expect(!model.isWorkspaceExpanded(workspace))
    #expect(model.expandedWorkspaceIDs?.contains(workspace.id) == false)
  }
}
