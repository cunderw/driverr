import DriverrCore
import Testing

/// A pane with an agent, not a bare shell.
private func pane(_ id: String, status: AgentStatus = .idle) -> Pane {
  Pane(id: id, tabID: "t1", workspaceID: "w1", title: id, agent: Agent(name: "Claude", status: status))
}

private func tree(_ panes: [Pane]) -> SessionTree {
  SessionTree(workspaces: [
    Workspace(
      id: "w1", number: 1, label: "one",
      tabs: [Tab(id: "t1", workspaceID: "w1", number: 1, label: "a", panes: panes)]
    )
  ])
}

/// The shortcut half of the switcher.
@Suite("PaneStripModel shortcuts")
struct PaneStripModelShortcutsTests {
  @Test("⌘1 to ⌘9 count the switcher's places, one-based")
  func indexIsOneBasedOverTargets() {
    let model = PaneStripModel(
      tree: tree([pane("a"), pane("b"), pane("c")]),
      current: .pane(id: "a"),
      openedAsShell: false
    )

    #expect(model.target(atShortcutIndex: 1) == .pane(id: "a"))
    #expect(model.target(atShortcutIndex: 2) == .pane(id: "b"))
    #expect(model.target(atShortcutIndex: 3) == .pane(id: "c"))
  }

  /// `chips` draws Needs you first, so indexing it would put every shortcut one out on the
  /// sessions that most need them.
  @Test("the Needs you entry is not a place, so it does not shift the numbering")
  func needsYouDoesNotShiftTheIndex() {
    let model = PaneStripModel(
      tree: tree([pane("a"), pane("blocked", status: .blocked), pane("c")]),
      current: .pane(id: "a"),
      openedAsShell: false
    )

    #expect(model.chips.first == .needsYou(count: 1))
    #expect(model.target(atShortcutIndex: 1) == .pane(id: "a"))
    #expect(model.target(atShortcutIndex: 2) == .pane(id: "blocked"))
  }

  @Test("a shell scene's first place is its shell")
  func shellSceneCountsTheShellFirst() {
    let model = PaneStripModel(
      tree: tree([pane("a"), pane("b")]),
      current: .shell,
      openedAsShell: true
    )

    #expect(model.target(atShortcutIndex: 1) == .shell)
    #expect(model.target(atShortcutIndex: 2) == .pane(id: "a"))
    #expect(model.target(atShortcutIndex: 3) == .pane(id: "b"))
  }

  @Test("an index past the end, or below one, goes nowhere rather than clamping")
  func indexOutOfRangeAnswersNothing() {
    let model = PaneStripModel(
      tree: tree([pane("a"), pane("b")]),
      current: .pane(id: "a"),
      openedAsShell: false
    )

    #expect(model.target(atShortcutIndex: 3) == nil)
    #expect(model.target(atShortcutIndex: 9) == nil)
    #expect(model.target(atShortcutIndex: 0) == nil)
    #expect(model.target(atShortcutIndex: -1) == nil)
  }

  @Test("next and previous step through the places in the switcher's own order")
  func neighboursStepThroughThePlaces() {
    let model = PaneStripModel(
      tree: tree([pane("a"), pane("b"), pane("c")]),
      current: .pane(id: "b"),
      openedAsShell: false
    )

    #expect(model.target(after: .pane(id: "b")) == .pane(id: "c"))
    #expect(model.target(before: .pane(id: "b")) == .pane(id: "a"))
  }

  @Test("next at the end wraps to the first place, and previous at the start to the last")
  func neighboursWrapAtBothEnds() {
    let model = PaneStripModel(
      tree: tree([pane("a"), pane("b"), pane("c")]),
      current: .pane(id: "c"),
      openedAsShell: false
    )

    #expect(model.target(after: .pane(id: "c")) == .pane(id: "a"))
    #expect(model.target(before: .pane(id: "a")) == .pane(id: "c"))
  }

  @Test("a one-place session has no neighbour to go to")
  func onePlaceSessionHasNoNeighbour() {
    let model = PaneStripModel(
      tree: tree([pane("only")]),
      current: .pane(id: "only"),
      openedAsShell: false
    )

    #expect(model.targets.count == 1)
    #expect(model.target(after: .pane(id: "only")) == nil)
    #expect(model.target(before: .pane(id: "only")) == nil)
  }

  /// A tree arriving mid-poll can drop the current pane. Answering with the first place
  /// would move the reader while the screen changes.
  @Test("a place the switcher has never heard of has no neighbour")
  func unknownCurrentHasNoNeighbour() {
    let model = PaneStripModel(
      tree: tree([pane("a"), pane("b")]),
      current: .pane(id: "a"),
      openedAsShell: false
    )

    #expect(model.target(after: .pane(id: "gone")) == nil)
    #expect(model.target(before: .pane(id: "gone")) == nil)
    // `.shell` is unknown when the scene did not open as one.
    #expect(model.target(after: .shell) == nil)
  }
}
