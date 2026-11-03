import DriverrCore
import DriverrHerdr
import Testing

@testable import Driverr

/// The session tree's empty copy must not say a host has nothing open when another connected
/// host shows all of its terminals. The copy is chosen in `SessionTreeView` from
/// `SessionModel.emptyReason`, which is what these assert, because a hosted test cannot look
/// up an accessibility identifier.
@MainActor
@Suite("Session tree empty copy")
struct SessionTreeEmptyCopyTests {
  /// One terminal on a machine the core added, which the core `core-b` shows as its own.
  private static let onACoveredMachine = SessionTree(workspaces: [
    Workspace(
      id: "core:bee/workspace", number: 1, label: "bee",
      tabs: [
        DriverrCore.Tab(
          id: "core:bee/tab", workspaceID: "core:bee/workspace", number: 1, label: "Terminals",
          panes: [
            Pane(
              id: "core:bee/t1", tabID: "core:bee/tab", workspaceID: "core:bee/workspace",
              title: "t1")
          ])
      ],
      machineCoreID: "core-b")
  ])

  @Test("a host whose every machine another host covers says they are shown there")
  func coveredHost() async {
    let model = SessionModel(
      control: FakeControl(tree: Self.onACoveredMachine), coveringCoreIDs: { ["core-b"] })
    await model.refresh()

    #expect(model.tree.isEmpty)
    #expect(!model.reportedTree.isEmpty)
    #expect(model.emptyReason == .shownUnderAnotherHost)
  }

  @Test("a host with nothing open keeps the empty copy")
  func reallyEmptyHost() async {
    let model = SessionModel(control: FakeControl(tree: .empty), coveringCoreIDs: { ["core-b"] })
    await model.refresh()

    #expect(model.reportedTree.isEmpty)
    #expect(model.emptyReason == .nothingOpen)
  }

  @Test("the same tree with nothing covering it has rows and no empty copy")
  func uncoveredHost() async {
    let model = SessionModel(control: FakeControl(tree: Self.onACoveredMachine))
    await model.refresh()

    #expect(model.emptyReason == nil)
  }
}
