import DriverrCore
import Testing

@testable import DriverrHerdr

@Suite("FakeControl")
struct FakeControlTests {
  @Test("the seeded tree is the same every time it is asked for")
  func isDeterministic() async throws {
    // UI tests assert on fixed rows, so a varying fake would look like an app bug.
    let first = try await FakeControl().snapshot()
    let second = try await FakeControl().snapshot()
    #expect(first == second)

    let control = FakeControl()
    #expect(try await control.snapshot() == (try await control.snapshot()))
  }

  @Test("the seed exercises what is easy to get wrong")
  func seedIsRealistic() async throws {
    let tree = try await FakeControl().snapshot()

    #expect(tree.workspaces.count == 3, "two workspaces would not exercise collapsing")
    #expect(tree.allPanes.count == 6)
    #expect(
      Set(tree.allPanes.compactMap { $0.agent?.status }) == [.working, .blocked, .idle, .done]
    )
    #expect(tree.focusedPaneID == "w1:p1")
  }

  @Test("the seed has shell panes, because most panes are shells")
  func seedHasShellPanes() async throws {
    // Most panes on a real session are shells, and shell-only bugs need shells in the seed.
    let tree = try await FakeControl().snapshot()
    let shells = tree.allPanes.filter { $0.agent == nil }

    #expect(shells.count == 2)
    #expect(shells.allSatisfy { $0.directory != nil }, "a shell has a directory to show")
    #expect(tree.allPanes.allSatisfy { $0.terminalID != nil }, "every pane can be attached")
  }

  /// The store tour's Needs You list and every capture before the switcher are the seed's,
  /// so the larger session may only add panes, never change or block one.
  @Test("the store tour's session is the seed plus panes that cannot block")
  func storeTourTreeExtendsTheSeed() {
    let seed = FakeControl.seededTree.allPanes
    let tour = FakeControl.storeTourTree.allPanes
    let blocked = FakeControl.storeTourScript.last?.allPanes.filter {
      $0.agent?.status == .blocked
    }

    #expect(tour.count == 14)
    #expect(
      FakeControl.storeTourTree.workspaces.map(\.label) == ["driverr", "tower", "wiki", "docs"])
    #expect(
      FakeControl.storeTourTree.workspaces.map { $0.tabs.flatMap(\.panes).count } == [4, 4, 3, 3])
    #expect(seed.allSatisfy { tour.contains($0) }, "a seed pane changed")
    #expect(Set(tour.map(\.id)).count == tour.count, "pane ids repeat")
    #expect(tour.filter { $0.agent?.status == .blocked }.map(\.id) == ["w1:p2"])
    #expect(blocked?.map(\.id) == ["w1:p2", "w2:p1"])
    // Roll-ups are recomputed for the new panes, as herdr's are.
    #expect(FakeControl.storeTourScript.last?.workspaces.map(\.status) == [
      .blocked, .blocked, .done, .done,
    ])
  }

  @Test("the seed has a done agent")
  func seedHasADoneAgent() async throws {
    let tree = try await FakeControl().snapshot()
    #expect(tree.allPanes.contains { $0.agent?.status == .done })
  }

  @Test("a tab of nothing but shells carries no roll-up status")
  func seedRollsUpLikeHerdr() async throws {
    let tree = try await FakeControl().snapshot()

    #expect(tree.workspaces[0].status == .blocked)
    let shellOnlyTab = tree.workspaces[0].tabs[1]
    #expect(shellOnlyTab.panes.allSatisfy { $0.agent == nil })
    #expect(shellOnlyTab.status == nil)
  }

  @Test("the blocked pane is not already first, so sorting has something to do")
  func blockedIsNotTriviallyFirst() async throws {
    let tree = try await FakeControl().snapshot()

    // The seed has to be able to fail the test it supports.
    #expect(tree.allPanes.first?.agent?.status != .blocked)
    #expect(tree.panesByUrgency.first?.agent?.status == .blocked)
  }

  @Test("snapshot requests are counted, so a store's refreshes can be asserted")
  func countsRequests() async throws {
    let control = FakeControl()
    #expect(await control.snapshotCount == 0)
    _ = try await control.snapshot()
    _ = try await control.snapshot()
    #expect(await control.snapshotCount == 2)
  }

  @Test("a failing fake throws the error it was given")
  func failingFake() async {
    let control = FakeControl.failing(.herdrNotInstalled)
    await #expect(throws: AppError.herdrNotInstalled) {
      _ = try await control.snapshot()
    }
  }

  @Test("the tree can be replaced, so a test can show the UI reacting")
  func updatesTree() async throws {
    let control = FakeControl()
    await control.update(to: .empty)
    #expect(try await control.snapshot().isEmpty)
  }

  @Test("closing a pane actually removes it from the fake's session")
  func closeRemovesThePane() async throws {
    // A fake that only recorded the close would let the UI claim success while the pane stayed.
    let control = FakeControl()
    #expect(try await control.snapshot().pane(id: "w1:p2") != nil)

    try await control.perform(.close, on: "w1:p2")

    let after = try await control.snapshot()
    #expect(after.pane(id: "w1:p2") == nil)
    #expect(after.allPanes.count == 5, "only the named pane goes")
  }

  @Test("renaming a pane changes the title the sidebar shows")
  func renameChangesTheTitle() async throws {
    let control = FakeControl()

    try await control.perform(.rename("build logs"), on: "w1:p2")

    let pane = try await control.snapshot().pane(id: "w1:p2")
    #expect(pane?.title == "build logs")
    #expect(pane?.agent?.name == "Claude", "a rename changes the label, not the pane")
  }

  @Test("renaming a workspace changes the label the tree shows, and nothing else")
  func renameChangesTheWorkspaceLabel() async throws {
    let control = FakeControl()

    try await control.rename(.workspace(id: "w1"), to: "shipping")

    let tree = try await control.snapshot()
    #expect(tree.workspaces.first?.label == "shipping")
    #expect(tree.workspaces.map(\.label) == ["shipping", "tower", "wiki"])
    #expect(tree.workspaces.first?.tabs.map(\.label) == ["app", "tests"], "tabs are untouched")
    #expect(tree.allPanes.count == 6, "a rename moves no panes")
  }

  @Test("renaming a tab changes that tab and leaves its siblings alone")
  func renameChangesTheTabLabel() async throws {
    let control = FakeControl()

    try await control.rename(.tab(id: "w1:t2"), to: "build logs")

    let tree = try await control.snapshot()
    #expect(tree.workspaces.first?.tabs.map(\.label) == ["app", "build logs"])
    #expect(tree.workspaces.first?.label == "driverr", "the workspace is untouched")
  }

  @Test("a renamed tab is no longer auto-named, so its row stops being elided")
  func renamingATabClearsAutoNaming() async throws {
    // `Workspace.tabHeaderStyle` hides a lone auto-named tab, so a fake that kept the flag
    // would show the new name nowhere.
    let control = FakeControl(tree: SessionTree(workspaces: [
      Workspace(
        id: "w9",
        number: 9,
        label: "scratch",
        tabs: [Tab(id: "w9:t1", workspaceID: "w9", number: 1, label: "Tab 1", isAutoNamed: true)]
      )
    ]))
    #expect(try await control.snapshot().workspaces.first?.tabHeaderStyle == TabHeaderStyle.none)

    try await control.rename(.tab(id: "w9:t1"), to: "notes")

    let workspace = try #require(try await control.snapshot().workspaces.first)
    #expect(workspace.tabs.first?.isAutoNamed == false)
    #expect(workspace.tabHeaderStyle == .inline)
  }

  @Test("an id that matches nothing renames nothing, and does not fail")
  func renamingSomethingAbsentIsQuiet() async throws {
    let control = FakeControl()
    let before = try await control.snapshot()

    try await control.rename(.workspace(id: "w9"), to: "nowhere")

    #expect(try await control.snapshot() == before)
  }

  @Test("a workspace id and a tab id do not cross over")
  func targetsDoNotCrossOver() async throws {
    // `w1` is a workspace and `w1:t1` a tab; matching on id alone would cross them.
    let control = FakeControl()

    try await control.rename(.tab(id: "w1"), to: "wrong")

    #expect(try await control.snapshot().workspaces.first?.label == "driverr")
  }

  @Test("container renames are recorded, in the order they were asked for")
  func renamesAreRecorded() async throws {
    let control = FakeControl()

    try await control.rename(.workspace(id: "w1"), to: "shipping")
    try await control.rename(.tab(id: "w1:t1"), to: "build logs")

    let renamed = await control.renamed
    #expect(renamed.map(\.target) == [.workspace(id: "w1"), .tab(id: "w1:t1")])
    #expect(renamed.map(\.label) == ["shipping", "build logs"])
  }

  @Test("a refused container rename is recorded and then not acted on")
  func aRefusedRenameIsRecorded() async throws {
    // Every list counts attempts, not successes (see `FakeControl`), because a recorder that
    // drops failures fails silently.
    let control = FakeControl.failing(.herdrCommandFailed(reason: "no such workspace"))

    await #expect(throws: AppError.self) {
      try await control.rename(.workspace(id: "w1"), to: "shipping")
    }

    let renamed = await control.renamed
    #expect(renamed.map(\.target) == [.workspace(id: "w1")])
    #expect(renamed.map(\.label) == ["shipping"])
  }

  @Test("a scripted session stops overwriting the tree once a rename has changed it")
  func aRenameOverridesTheScript() async throws {
    let control = FakeControl(script: FakeControl.blockingScript)
    _ = try await control.snapshot()

    try await control.rename(.workspace(id: "w1"), to: "shipping")

    #expect(try await control.snapshot().workspaces.first?.label == "shipping")
    #expect(try await control.snapshot().workspaces.first?.label == "shipping")
  }

  @Test("actions are recorded, in the order they were asked for")
  func recordsActions() async throws {
    // `PaneActionsModelTests` reads this list for every action it drives.
    let control = FakeControl()

    try await control.perform(.rename("build logs"), on: "w1:p1")
    try await control.perform(.split(.right), on: "w1:p1")

    let performed = await control.performed
    #expect(performed.map(\.action) == [.rename("build logs"), .split(.right)])
    #expect(performed.allSatisfy { $0.paneID == "w1:p1" })
  }

  @Test("splitting puts a new pane beside the one it split")
  func splitAddsAPane() async throws {
    // The scene switches to the new pane as soon as a snapshot lists it, so the fake must add
    // one.
    let control = FakeControl()

    try await control.perform(.split(.right), on: "w1:p1")

    let tree = try await control.snapshot()
    let ids = tree.allPanes.map(\.id)
    #expect(ids == ["w1:p1", "w1:p7", "w1:p2", "w1:p3", "w2:p1", "w3:p1", "w3:p2"])
    let new = try #require(tree.pane(id: "w1:p7"))
    #expect(new.tabID == "w1:t1", "a split stays in the tab it split")
    #expect(new.agent == nil, "a fresh pane has no agent in it yet")
    // A pane with no terminal id takes a different attach path.
    #expect(new.terminalID == "term_w1p7")
  }

  @Test("splitting twice invents two ids, and the same two every run")
  func splitIsDeterministic() async throws {
    let control = FakeControl()

    try await control.perform(.split(.right), on: "w1:p1")
    try await control.perform(.split(.right), on: "w1:p1")

    #expect(try await control.snapshot().allPanes.map(\.id).prefix(3) == ["w1:p1", "w1:p8", "w1:p7"])
  }

  @Test("a batch of reads answers every pane it was asked for, and remembers which")
  func readsPanes() async throws {
    // A warm pane's thumbnail comes from its own emulator and must never be read over the wire.
    let control = FakeControl()

    let panes = try await control.readPanes(ids: ["w1:p2", "w3:p2"], lines: 6)

    #expect(Set(panes.keys) == ["w1:p2", "w3:p2"])
    #expect(panes["w1:p2"] == ["$ cd ~/dev/driverr", "$ herdr pane w1:p2", "Claude is blocked"])
    #expect(
      panes["w3:p2"] == ["$ cd ~/wiki/site", "$ herdr pane w3:p2", "$"],
      "a shell pane has no agent line to draw"
    )
    #expect(await control.reads == [["w1:p2", "w3:p2"]])
  }

  @Test("a read asks for no more lines than it was told to")
  func readsHonourTheLineCount() async throws {
    let control = FakeControl()

    let panes = try await control.readPanes(ids: ["w1:p2"], lines: 2)

    #expect(panes["w1:p2"] == ["$ herdr pane w1:p2", "Claude is blocked"])
  }

  @Test("a pane the fake has never heard of reads as nothing, not as a failure")
  func readsAnUnknownPane() async throws {
    let control = FakeControl()

    let panes = try await control.readPanes(ids: ["w9:p9"], lines: 6)

    #expect(panes == ["w9:p9": []])
  }

  /// The fake must follow the same marker rules as a real pane, or demo mode proves nothing.
  @Test("a single-pane read answers a screen with the agent's message marked in it")
  func readsOnePaneScreen() async throws {
    let control = FakeControl()
    let pane = try #require(FakeControl.seededTree.pane(id: "w1:p2"))

    let screen = try await control.readScreen(of: pane, lines: 20)

    let message = try #require(screen.agentMessage, "a blocked agent has said something")
    #expect(screen.lines[message].first?.text.hasPrefix("⏺ ") == true)
    #expect(screen.lines[message].first?.text.contains("Should I hold the second one?") == true)
    #expect(!screen.text.unicodeScalars.contains { $0.value == 0x1B })
    #expect(await control.screenReads.map(\.paneID) == ["w1:p2"])
    #expect(await control.screenReads.map(\.lines) == [20])
  }

  /// A shell pane has no speaker, so its screen must carry no marker.
  @Test("a shell pane's screen carries no marker")
  func readsAShellPaneScreen() async throws {
    let control = FakeControl()
    let pane = try #require(FakeControl.seededTree.pane(id: "w1:p3"))

    let screen = try await control.readScreen(of: pane, lines: 20)

    #expect(!screen.isEmpty)
    #expect(screen.agentMessage == nil)
    #expect(screen.lines.allSatisfy { $0.marker == nil })
  }

  @Test("a single-pane read honours the line count it was given")
  func screenReadHonoursTheLineCount() async throws {
    let control = FakeControl()
    let pane = try #require(FakeControl.seededTree.pane(id: "w1:p2"))

    #expect(try await control.readScreen(of: pane, lines: 3).lines.count == 3)
  }

  /// `AppEnvironment.seededLastPanes` takes the witness from this tree for
  /// `-uiTestingLastPane`, so an unwitnessed fixture pane would silently test the fallback.
  /// `DriverrCoreTests` cannot see `FakeControl`.
  @Test("every pane the fake reports carries a session witness")
  func everyFixturePaneIsWitnessed() {
    let unwitnessed = FakeControl.seededTree.allPanes.filter { $0.sessionWitness == nil }
    #expect(
      unwitnessed.isEmpty,
      "these fixture panes cannot be remembered: \(unwitnessed.map(\.id))")
    #expect(FakeControl.seededTree.pane(id: "w1:p1")?.sessionWitness == "term_w1p1")
  }

  /// Every published tree on `FakeControl`, not a sample. Add any new fixture tree here.
  @Test("every pane in the fake's other trees carries a witness too")
  func everyScriptedPaneIsWitnessed() {
    let trees =
      FakeControl.blockingScript + FakeControl.vanishingPaneScript
      + FakeControl.storeTourScript + [
        FakeControl.treeWithoutTheBlockedPane,
        FakeControl.treeWithAFailedAgent,
        FakeControl.treeWithSecondBlockedPane,
        FakeControl.treeWithIdleAgent,
        FakeControl.treeWithAWorkingAsker,
        FakeControl.treeWithUnstartedAgent,
        FakeControl.crowdedTree,
      ]
    let unwitnessed = trees.flatMap(\.allPanes).filter { $0.sessionWitness == nil }
    #expect(
      unwitnessed.isEmpty,
      "these fixture panes cannot be remembered: \(unwitnessed.map(\.id))")
  }

  /// "The read failed" and "the pane shows nothing" must never collapse.
  @Test("a failing fake refuses a screen read rather than answering an empty one")
  func failingFakeRefusesAScreenRead() async {
    let control = FakeControl.failing(.herdrCommandFailed(reason: "herdr refused the request."))
    let pane = FakeControl.seededTree.pane(id: "w1:p2")!

    await #expect(throws: AppError.herdrCommandFailed(reason: "herdr refused the request.")) {
      _ = try await control.readScreen(of: pane, lines: 9)
    }
  }

  @Test("a batch of nothing is not a request")
  func readsNothing() async throws {
    let control = FakeControl()

    #expect(try await control.readPanes(ids: [], lines: 6).isEmpty)
    #expect(await control.reads.isEmpty)
  }

  @Test("a scripted session stops overwriting the tree once an action has changed it")
  func actionsSurviveTheScript() async throws {
    // If the script kept overwriting, the next poll would undo what the user just did.
    let control = FakeControl(script: FakeControl.blockingScript)
    _ = try await control.snapshot()

    try await control.perform(.close, on: "w1:p3")

    #expect(try await control.snapshot().pane(id: "w1:p3") == nil)
    #expect(try await control.snapshot().pane(id: "w1:p3") == nil, "still gone next poll")
  }

  @Test("a failing fake refuses actions too")
  func failingFakeRefusesActions() async {
    let control = FakeControl.failing(.herdrCommandFailed(reason: "nope"))
    await #expect(throws: AppError.herdrCommandFailed(reason: "nope")) {
      try await control.perform(.close, on: "w1:p2")
    }
  }

  // MARK: - A refused call is still a call the fake was asked for

  /// A refusal appends to the same list a delivered call does, then throws. Otherwise a retry
  /// test reads a missing record as the retry not firing, blaming the code under test.
  @Test("a refused screen read is recorded, with the pane and the line count asked for")
  func aRefusedScreenReadIsRecorded() async {
    let control = FakeControl.failing(.herdrCommandFailed(reason: "agent_not_idle"))
    let pane = FakeControl.seededTree.pane(id: "w1:p2")!

    await #expect(throws: AppError.herdrCommandFailed(reason: "agent_not_idle")) {
      _ = try await control.readScreen(of: pane, lines: 9)
    }

    #expect(await control.screenReads.map(\.paneID) == ["w1:p2"])
    #expect(await control.screenReads.map(\.lines) == [9])
  }

  @Test("a refused batched read is recorded, with the ids exactly as asked")
  func aRefusedBatchIsRecorded() async {
    let control = FakeControl.failing(.herdrCommandFailed(reason: "herdr went away"))

    await #expect(throws: AppError.herdrCommandFailed(reason: "herdr went away")) {
      _ = try await control.readPanes(ids: ["w1:p2", "w1:p3"], lines: 6)
    }

    // `waitForReads(_:)` is reached by a refusal too, so tests wait on a count, not a clock.
    #expect(await control.reads == [["w1:p2", "w1:p3"]])
  }

  @Test("a refused action is recorded")
  func aRefusedActionIsRecorded() async throws {
    let control = FakeControl.failing(.herdrCommandFailed(reason: "pane is the last one"))

    await #expect(throws: AppError.herdrCommandFailed(reason: "pane is the last one")) {
      try await control.perform(.close, on: "w1:p2")
    }

    let performed = await control.performed
    #expect(performed.map(\.action) == [.close])
    #expect(performed.map(\.paneID) == ["w1:p2"])
  }

  @Test("a refused send is recorded, for every one of the three steering calls")
  func aRefusedSendIsRecorded() async {
    let refusal = AppError.herdrCommandFailed(reason: "no such pane")
    let control = FakeControl()
    await control.failNextSends(3, with: refusal)

    await #expect(throws: refusal) {
      try await control.sendText(paneID: "w1:p2", text: "hello")
    }
    await #expect(throws: refusal) {
      try await control.submitText(paneID: "w1:p2", text: "go ahead\n")
    }
    await #expect(throws: refusal) {
      try await control.sendKeys(paneID: "w1:p2", keys: [.esc])
    }

    #expect(
      await control.sent == [
        .text(paneID: "w1:p2", text: "hello"),
        // Trimmed on the way in: what `pane run` would have been handed, which a retry resends.
        .submit(paneID: "w1:p2", text: "go ahead"),
        .keys(paneID: "w1:p2", keys: [.esc]),
      ]
    )
  }

  /// `snapshotCount` is the anchor the other lists follow.
  @Test("a refused snapshot is counted, which is the convention the rest now follow")
  func aRefusedSnapshotIsCounted() async {
    let control = FakeControl.failing(.herdrNotInstalled)

    await #expect(throws: AppError.herdrNotInstalled) { _ = try await control.snapshot() }
    await #expect(throws: AppError.herdrNotInstalled) { _ = try await control.snapshot() }

    #expect(await control.snapshotCount == 2)
  }

  @Test("an empty session is a session, not a failure")
  func emptyIsNotAnError() async throws {
    // No workspaces is a different state from herdr missing, with its own empty view.
    let control = FakeControl(tree: FakeControl.emptyTree)
    let tree = try await control.snapshot()
    #expect(tree.isEmpty)
  }
}
