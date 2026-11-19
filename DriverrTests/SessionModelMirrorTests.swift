import DriverrCore
import DriverrHerdr
import Testing

@testable import Driverr

/// What a host with a mirror pane lists, and what it keeps. #102 S5.
@MainActor
@Suite("SessionModel mirrors")
struct SessionModelMirrorTests {
  /// `w1:p2` runs a tmux client, so the tmux panes are its content and it is a mirror.
  private let reported = SessionTree(
    workspaces: [
      Workspace(
        id: "w1", number: 1, label: "herdr",
        tabs: [
          DriverrCore.Tab(
            id: "w1:t1", workspaceID: "w1", number: 1, label: "one",
            panes: [
              Pane(id: "w1:p1", tabID: "w1:t1", workspaceID: "w1", title: "zsh"),
              Pane(
                id: "w1:p2", tabID: "w1:t1", workspaceID: "w1", title: "tmux",
                agent: Agent(name: "Claude", status: .blocked), isMirror: true),
            ])
        ])
    ],
    focusedPaneID: "w1:p2")

  @Test("the tree lists no mirror and counts none, and the reported tree keeps it")
  func listsNoMirror() async {
    let model = SessionModel(control: FakeControl(tree: reported))
    await model.refresh()
    #expect(model.reportedTree.allPanes.map(\.id) == ["w1:p1", "w1:p2"])
    #expect(model.tree.allPanes.map(\.id) == ["w1:p1"])
    #expect(model.tree.blockedPanes.isEmpty)
    #expect(model.tree.focusedPaneID == nil)
  }

  @Test("a scene open on a mirror keeps it in the tree it reads")
  func keepsAnOpenMirror() async {
    let model = SessionModel(control: FakeControl(tree: reported))
    await model.refresh()
    #expect(model.tree(keeping: "w1:p2").allPanes.map(\.id) == ["w1:p1", "w1:p2"])
    #expect(model.tree(keeping: "w1:p1").allPanes.map(\.id) == ["w1:p1"])
  }
}
