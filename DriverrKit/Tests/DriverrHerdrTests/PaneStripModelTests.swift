import DriverrCore
import Testing

@testable import DriverrHerdr

/// `FakeControl.seededTree`: `w1:p1` (working), `w1:p2` (blocked), `w1:p3` (shell),
/// `w2:p1` (idle), `w3:p1` (done), `w3:p2` (shell), in depth-first order.
@Suite("PaneStripModel")
struct PaneStripModelTests {
  @Test("chip order equals SessionTree.allPanes, with the grid chip trailing")
  func chipOrderMatchesAllPanes() {
    let tree = FakeControl.seededTree
    let model = PaneStripModel(
      tree: tree,
      current: .pane(id: "w1:p1"),
      openedAsShell: false
    )

    let paneChipIDs = model.chips.compactMap { chip -> String? in
      if case .pane(let pane, _) = chip { return pane.id }
      return nil
    }
    #expect(paneChipIDs == tree.allPanes.map(\.id))
    #expect(model.chips.last == .grid)
  }

  @Test("Needs you is absent when nothing is blocked")
  func needsYouAbsentWhenNothingBlocked() {
    // w2:p1 is idle in the seeded tree.
    let tree = FakeControl.seededTree
    let unblocked = SessionTree(
      workspaces: tree.workspaces.map { workspace in
        Workspace(
          id: workspace.id,
          number: workspace.number,
          label: workspace.label,
          isFocused: workspace.isFocused,
          status: nil,
          tabs: workspace.tabs.map { tab in
            Tab(
              id: tab.id,
              workspaceID: tab.workspaceID,
              number: tab.number,
              label: tab.label,
              isFocused: tab.isFocused,
              status: nil,
              isAutoNamed: tab.isAutoNamed,
              panes: tab.panes.map { pane in
                guard pane.agent?.status == .blocked else { return pane }
                return Pane(
                  id: pane.id,
                  tabID: pane.tabID,
                  workspaceID: pane.workspaceID,
                  title: pane.title,
                  agent: Agent(name: pane.agent!.name, status: .idle),
                  terminalID: pane.terminalID,
                  directory: pane.directory,
                  isFocused: pane.isFocused
                )
              }
            )
          }
        )
      },
      focusedPaneID: tree.focusedPaneID
    )
    let model = PaneStripModel(tree: unblocked, current: .pane(id: "w1:p1"), openedAsShell: false)

    #expect(!model.chips.contains { if case .needsYou = $0 { true } else { false } })
  }

  @Test("Needs you is absent when only the current pane is blocked")
  func needsYouAbsentWhenOnlyCurrentIsBlocked() {
    let tree = FakeControl.seededTree  // w1:p2 is the only blocked pane
    let model = PaneStripModel(tree: tree, current: .pane(id: "w1:p2"), openedAsShell: false)

    #expect(!model.chips.contains { if case .needsYou = $0 { true } else { false } })
  }

  @Test("Needs you counts blocked panes other than the current one")
  func needsYouCountsOtherBlockedPanes() {
    let tree = FakeControl.treeWithSecondBlockedPane  // w1:p2 and w2:p1 both blocked
    let model = PaneStripModel(tree: tree, current: .pane(id: "w1:p1"), openedAsShell: false)

    #expect(model.chips.first == .needsYou(count: 2))
  }

  @Test("the Shell chip appears only for a scene opened as a shell")
  func shellChipOnlyWhenOpenedAsShell() {
    let tree = FakeControl.seededTree

    let asShell = PaneStripModel(tree: tree, current: .shell, openedAsShell: true)
    #expect(asShell.chips.contains(.shell(isCurrent: true)))

    let asPane = PaneStripModel(tree: tree, current: .pane(id: "w1:p1"), openedAsShell: false)
    #expect(!asPane.chips.contains { if case .shell = $0 { true } else { false } })
  }

  @Test("the grid chip always trails the strip")
  func gridChipAlwaysTrails() {
    let tree = FakeControl.seededTree
    let model = PaneStripModel(tree: tree, current: .shell, openedAsShell: true)

    #expect(model.chips.last == .grid)
  }

  @Test("Needs you goes to the first blocked pane that is not the current one")
  func needsYouTargetsTheFirstBlockedPaneElsewhere() {
    // Both w1:p2 and w2:p1 are blocked, in that tree order.
    let tree = FakeControl.treeWithSecondBlockedPane
    let model = PaneStripModel(tree: tree, current: .pane(id: "w1:p1"), openedAsShell: false)

    #expect(model.needsYouTarget?.id == "w1:p2")
  }

  /// The count and the destination come from the same filter, or the strip offers to take
  /// you where you stand.
  @Test("Needs you skips the current pane when choosing where to go")
  func needsYouTargetSkipsTheCurrentPane() {
    let tree = FakeControl.treeWithSecondBlockedPane
    let model = PaneStripModel(tree: tree, current: .pane(id: "w1:p2"), openedAsShell: false)

    #expect(model.chips.first == .needsYou(count: 1))
    #expect(model.needsYouTarget?.id == "w2:p1")
  }

  @Test("there is nowhere to go when no other pane is blocked")
  func needsYouTargetIsNilWithNothingBlockedElsewhere() {
    let tree = FakeControl.seededTree  // w1:p2 is the only blocked pane
    let model = PaneStripModel(tree: tree, current: .pane(id: "w1:p2"), openedAsShell: false)

    #expect(model.needsYouTarget == nil)
  }

  // MARK: - Workspace boundaries

  /// The seeded tree runs w1 "driverr" (three panes), w2 "tower" (one), w3 "wiki" (two).
  @Test("the places are cut into one titled group per workspace, in the tree's order")
  func groupsFollowTheWorkspaceBoundaries() {
    let model = PaneStripModel(
      tree: FakeControl.seededTree,
      current: .pane(id: "w1:p1"),
      openedAsShell: false
    )

    #expect(model.groups.map(\.id) == ["w1", "w2", "w3"].map(PaneGroup.workspaceGroupID))
    #expect(model.groups.map(\.title) == ["driverr", "tower", "wiki"])
    #expect(model.groups.map(\.chips.count) == [3, 1, 2])
    #expect(model.showsWorkspaceHeaders)
  }

  @Test("the shell is a group of its own, first and unnamed")
  func theShellIsItsOwnUntitledGroup() {
    let model = PaneStripModel(
      tree: FakeControl.seededTree,
      current: .shell,
      openedAsShell: true
    )

    // Driverr's own pty belongs to no workspace.
    #expect(model.groups.first?.id == PaneGroup.shellID)
    #expect(model.groups.first?.title == nil)
    #expect(model.groups.first?.chips == [.shell(isCurrent: true)])
    #expect(model.groups.dropFirst().map(\.id) == ["w1", "w2", "w3"].map(PaneGroup.workspaceGroupID))
  }

  @Test("the two entries that are not places belong to no group")
  func needsYouAndTheGridAreNotGrouped() {
    // Needs you is a jump into this list, and the grid entry opens the sheet.
    let model = PaneStripModel(
      tree: FakeControl.treeWithSecondBlockedPane,
      current: .shell,
      openedAsShell: true
    )

    let grouped = model.groups.flatMap(\.chips)
    #expect(!grouped.contains { if case .needsYou = $0 { return true } else { return false } })
    #expect(!grouped.contains(.grid))
    #expect(grouped.count == model.targets.count)
  }

  @Test("one workspace draws no header, because it is a boundary against nothing")
  func headersAreHiddenForASingleWorkspace() {
    // Built here because the fixtures are deliberately three workspaces deep.
    let tree = SessionTree(
      workspaces: [
        Workspace(
          id: "w1",
          number: 1,
          label: "driverr",
          tabs: [
            Tab(
              id: "w1:t1",
              workspaceID: "w1",
              number: 1,
              label: "app",
              panes: [Pane(id: "w1:p1", tabID: "w1:t1", workspaceID: "w1", title: "swift test")]
            )
          ]
        )
      ]
    )
    let model = PaneStripModel(tree: tree, current: .shell, openedAsShell: true)

    // The untitled shell group does not count towards the boundary.
    #expect(model.groups.map(\.title) == [nil, "driverr"])
    #expect(!model.showsWorkspaceHeaders)
  }

  // MARK: - The switcher on a host with no herdr session

  @Test("a host with no panes has nothing to switch between")
  func theSwitcherIsHiddenWithNoPanes() {
    // One Shell tile and a disabled New pane cell is chrome that says nothing.
    let model = PaneStripModel(tree: .empty, current: .shell, openedAsShell: true)

    #expect(!model.showsSwitcher)
    #expect(model.groups.map(\.id) == [PaneGroup.shellID])

    let withPanes = PaneStripModel(
      tree: FakeControl.seededTree,
      current: .shell,
      openedAsShell: true
    )
    #expect(withPanes.showsSwitcher)
  }

  /// `PaneGroup.shellID` is `"shell"`, and nothing stops a herdr `workspace_id` being the
  /// same string. `PaneGroup.workspaceGroupID(_:)` namespaces workspace ids so the two can
  /// never collide.
  @Test("a workspace whose id happens to be the shell's sentinel still gets its own, distinct group")
  func aWorkspaceIDMatchingTheShellSentinelStillGetsItsOwnGroup() {
    let tree = SessionTree(
      workspaces: [
        Workspace(
          id: "shell",
          number: 1,
          label: "not the shell",
          tabs: [
            Tab(
              id: "shell:t1",
              workspaceID: "shell",
              number: 1,
              label: "app",
              panes: [Pane(id: "shell:p1", tabID: "shell:t1", workspaceID: "shell", title: "pane")]
            )
          ]
        )
      ]
    )
    let model = PaneStripModel(tree: tree, current: .shell, openedAsShell: true)

    // The shell's untitled tile, then the workspace holding only its pane.
    #expect(model.groups.count == 2)
    #expect(model.groups[0].id == PaneGroup.shellID)
    #expect(model.groups[0].title == nil)
    #expect(model.groups[0].chips == [.shell(isCurrent: true)])
    #expect(model.groups[1].id == PaneGroup.workspaceGroupID("shell"))
    #expect(model.groups[1].id != PaneGroup.shellID)
    #expect(model.groups[1].title == "not the shell")
    #expect(model.groups[1].chips.count == 1)
  }

  /// The same input, asserted only through `groups` and `PaneGroup.id`. `PaneSheetView` runs
  /// `ForEach(model.groups)`, and a duplicate id there drops or duplicates rows.
  @Test("no two groups ever share an id, however herdr has named its workspaces")
  func groupIDsAreUniqueEvenWhenAWorkspaceIsNamedAfterTheShell() {
    let tree = SessionTree(
      workspaces: [
        Workspace(
          id: "shell",
          number: 1,
          label: "not the shell",
          tabs: [
            Tab(
              id: "shell:t1",
              workspaceID: "shell",
              number: 1,
              label: "app",
              panes: [Pane(id: "shell:p1", tabID: "shell:t1", workspaceID: "shell", title: "pane")]
            )
          ]
        )
      ]
    )
    let model = PaneStripModel(tree: tree, current: .shell, openedAsShell: true)

    #expect(model.groups.count == 2)
    #expect(model.groups[0].id != model.groups[1].id)

    let ids = model.groups.map(\.id)
    #expect(Set(ids).count == ids.count)

    // The ordinary tree too, so the guarantee is about `groups`, not one adversarial name.
    let seeded = PaneStripModel(tree: FakeControl.seededTree, current: .shell, openedAsShell: true)
    let seededIDs = seeded.groups.map(\.id)
    #expect(Set(seededIDs).count == seededIDs.count)
  }

  @Test("the places the strip can send you to are its chips, minus the two that are not")
  func targetsAreThePlaces() {
    // The sheet is built from this, so "which panes, in what order" is decided once.
    let model = PaneStripModel(
      tree: FakeControl.treeWithSecondBlockedPane,
      current: .shell,
      openedAsShell: true
    )

    #expect(
      model.targets == [
        .shell,
        .pane(id: "w1:p1"),
        .pane(id: "w1:p2"),
        .pane(id: "w1:p3"),
        .pane(id: "w2:p1"),
        .pane(id: "w3:p1"),
        .pane(id: "w3:p2"),
      ]
    )
  }

  @Test("a scene that did not open as a shell offers no shell to go to")
  func targetsSkipTheShellWhenThereIsNone() {
    let model = PaneStripModel(
      tree: FakeControl.seededTree,
      current: .pane(id: "w1:p2"),
      openedAsShell: false
    )

    #expect(model.targets.first == .pane(id: "w1:p1"))
    #expect(model.targets.count == 6)
  }

  // MARK: - The toolbar button's badge

  /// Drawn from the same filter as `needsYouTarget`, so the number and destination agree.
  @Test("the blocked-elsewhere count matches the needs-you filter")
  func blockedElsewhereCountMatchesTheNeedsYouFilter() {
    let two = PaneStripModel(
      tree: FakeControl.treeWithSecondBlockedPane,
      current: .pane(id: "w1:p1"),
      openedAsShell: false
    )
    #expect(two.blockedElsewhereCount == 2)

    let one = PaneStripModel(
      tree: FakeControl.treeWithSecondBlockedPane,
      current: .pane(id: "w1:p2"),
      openedAsShell: false
    )
    #expect(one.blockedElsewhereCount == 1)
    #expect(one.needsYouTarget?.id == "w2:p1")

    let none = PaneStripModel(
      tree: FakeControl.seededTree,
      current: .pane(id: "w1:p2"),
      openedAsShell: false
    )
    #expect(none.blockedElsewhereCount == 0)
    #expect(none.needsYouTarget == nil)
  }
}
