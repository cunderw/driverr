import DriverrCore
import Testing

@testable import DriverrHerdr

@Suite("SessionTree.agentFolders")
struct AgentFoldersTests {
  private func pane(_ id: String, _ directory: String?, machine: String? = nil) -> Pane {
    Pane(
      id: id, tabID: "t", workspaceID: "w", title: id,
      agent: machine.map { Agent(name: "claude", status: .idle, machine: $0) },
      directory: directory)
  }

  private func tree(_ panes: [Pane]) -> SessionTree {
    SessionTree(workspaces: [
      Workspace(id: "w", number: 1, label: "w", tabs: [
        DriverrCore.Tab(id: "t", workspaceID: "w", number: 1, label: "t", panes: panes)
      ])
    ])
  }

  @Test("each folder once, in the tree's order")
  func distinct() {
    let folders = tree([
      pane("w1:p1", "~/dev/app"), pane("w1:p2", "~/dev/site"), pane("w1:p3", "~/dev/app"),
      pane("w1:p4", "/srv"),
    ]).agentFolders()
    #expect(folders == ["~/dev/app", "~/dev/site", "/srv"])
  }

  @Test("a pane with no folder, or an empty one, offers nothing")
  func missing() {
    #expect(tree([pane("w1:p1", nil), pane("w1:p2", "")]).agentFolders().isEmpty)
  }

  /// An agent starts on the connected computer. A machine a core added has its own disk.
  @Test("a pane on a machine a core added is left out, by its id and by its agent")
  func otherMachines() {
    let folders = tree([
      pane("core:box/t1", "/data/box"),
      pane("w1:p1", "/data/agent", machine: "box"),
      pane("core:t2", "~/core-home"),
      pane("tmux:%3", "~/tmux"),
    ]).agentFolders()
    #expect(folders == ["~/core-home", "~/tmux"])
  }

  @Test("no more than the limit")
  func limited() {
    let panes = (1...9).map { pane("w1:p\($0)", "/f\($0)") }
    #expect(tree(panes).agentFolders(limit: 3) == ["/f1", "/f2", "/f3"])
    #expect(tree(panes).agentFolders().count == 6)
  }
}
