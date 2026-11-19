import Testing

@testable import DriverrCore

/// A herdr session in workspace `w1` (two tabs) and a tmux session in `tmux:$0`.
private func mixedTree(focused: String? = "w1:p1") -> SessionTree {
  SessionTree(
    workspaces: [
      Workspace(
        id: "w1", number: 1, label: "work", isFocused: true, status: .blocked,
        tabs: [
          Tab(
            id: "w1:t1", workspaceID: "w1", number: 1, label: "one", isFocused: true,
            status: .blocked, isAutoNamed: false,
            panes: [
              Pane(
                id: "w1:p1", tabID: "w1:t1", workspaceID: "w1", title: "claude",
                agent: Agent(name: "Claude", status: .blocked), terminalID: "term_1",
                directory: "/home/dev", isFocused: true, viewportRows: 40),
              Pane(id: "w1:p2", tabID: "w1:t1", workspaceID: "w1", title: "tmux"),
            ]),
          Tab(
            id: "w1:t2", workspaceID: "w1", number: 2, label: "two",
            panes: [Pane(id: "w1:p3", tabID: "w1:t2", workspaceID: "w1", title: "tmux")]),
        ],
        machineCoreID: "core-x"),
      Workspace(
        id: "tmux:$0", number: 2, label: "desk",
        tabs: [
          Tab(
            id: "tmux:@0", workspaceID: "tmux:$0", number: 1, label: "herdr",
            panes: [
              Pane(id: "tmux:%0", tabID: "tmux:@0", workspaceID: "tmux:$0", title: "herdr")
            ])
        ]),
    ],
    focusedPaneID: focused,
    coreID: "core-a",
    mirrorClaims: [MirrorClaim(paneID: "tmux:%0", session: .standard)]
  )
}

@Suite("Pane mirrors")
struct PaneMirrorTests {
  @Test(
    "a socket path names its herdr session by the end of the path",
    arguments: [
      ("/home/dev/.config/herdr/sessions/work/herdr.sock", HerdrSessionKey.named("work")),
      ("~/.config/herdr/sessions/work/herdr.sock", .named("work")),
      ("/home/dev/.config/herdr/herdr.sock", .standard),
      ("/Users/dev/.config/herdr/herdr.sock", .standard),
      ("/tmp/elsewhere.sock", .socket("/tmp/elsewhere.sock")),
      ("/tmp/sessions/herdr.sock", .standard),
      ("", .standard),
    ])
  func sessionKey(path: String, key: HerdrSessionKey) {
    #expect(HerdrSessionKey(socketPath: path) == key)
  }

  @Test("no socket path is the standard session")
  func noPathIsStandard() {
    #expect(HerdrSessionKey(socketPath: nil) == .standard)
    #expect(HerdrSessionKey(socketPath: nil) != .named("default"))
  }

  @Test("marking sets isMirror on the named panes and changes nothing else")
  func marking() throws {
    let tree = mixedTree()
    let marked = tree.markingMirrors(["w1:p2", "tmux:%0"])
    #expect(marked.allPanes.filter(\.isMirror).map(\.id) == ["w1:p2", "tmux:%0"])
    #expect(marked.workspaces.map(\.id) == tree.workspaces.map(\.id))
    #expect(marked.focusedPaneID == tree.focusedPaneID)
    #expect(marked.coreID == tree.coreID)
    #expect(marked.mirrorClaims == tree.mirrorClaims)
    let original = try #require(tree.pane(id: "w1:p1"))
    #expect(marked.pane(id: "w1:p1") == original)
    #expect(marked.workspaces[0].machineCoreID == "core-x")
    #expect(marked.workspaces[0].tabs[0].status == .blocked)
    #expect(marked.workspaces[0].tabs[0].isAutoNamed == false)
    #expect(tree.markingMirrors([]) == tree)
  }

  @Test("a tree with no mirror is returned as it is")
  func noMirror() {
    let tree = mixedTree()
    #expect(tree.hidingMirrors() == tree)
    #expect(tree.hidingMirrors(keeping: "w1:p2") == tree)
  }

  @Test("a mirror goes, then a tab and a workspace it left empty, and every other field stays")
  func hiding() throws {
    let marked = mixedTree().markingMirrors(["w1:p3", "tmux:%0", "w1:p2"])
    let hidden = marked.hidingMirrors()
    #expect(hidden.allPanes.map(\.id) == ["w1:p1"])
    #expect(hidden.workspaces.map(\.id) == ["w1"])
    #expect(hidden.workspaces[0].tabs.map(\.id) == ["w1:t1"])
    let workspace = hidden.workspaces[0]
    #expect(workspace.machineCoreID == "core-x")
    #expect(workspace.status == .blocked)
    #expect(workspace.isFocused)
    #expect(workspace.tabs[0].isAutoNamed == false)
    #expect(workspace.tabs[0].isFocused)
    #expect(hidden.pane(id: "w1:p1") == marked.pane(id: "w1:p1"))
    #expect(hidden.focusedPaneID == "w1:p1")
    #expect(hidden.coreID == "core-a")
    #expect(hidden.mirrorClaims == marked.mirrorClaims)
    #expect(hidden.agentStatusCounts == AgentStatusCounts(blocked: 1))
  }

  @Test("a hidden pane that had the focus has it no longer")
  func hiddenFocus() {
    let hidden = mixedTree(focused: "tmux:%0").markingMirrors(["tmux:%0"]).hidingMirrors()
    #expect(hidden.focusedPaneID == nil)
    #expect(hidden.pane(id: "tmux:%0") == nil)
  }

  @Test("the pane a scene is open on stays, mirror or not")
  func keeping() throws {
    let marked = mixedTree(focused: "tmux:%0").markingMirrors(["tmux:%0", "w1:p2"])
    let kept = marked.hidingMirrors(keeping: "tmux:%0")
    #expect(kept.allPanes.map(\.id) == ["w1:p1", "w1:p3", "tmux:%0"])
    #expect(kept.focusedPaneID == "tmux:%0")
    #expect(try #require(kept.pane(id: "tmux:%0")).isMirror)
  }

  @Test("a tab or workspace that was empty before stays")
  func emptyAlready() {
    let tree = SessionTree(workspaces: [
      Workspace(id: "w9", number: 1, label: "empty", tabs: []),
      Workspace(
        id: "w8", number: 2, label: "tab",
        tabs: [Tab(id: "w8:t1", workspaceID: "w8", number: 1, label: "none")]),
    ])
    #expect(tree.markingMirrors(["x"]).hidingMirrors() == tree)
  }

  @Test("hiding machines keeps the claims")
  func machinesKeepClaims() {
    let tree = mixedTree()
    #expect(tree.hidingMachines(coveredBy: ["core-x"]).mirrorClaims == tree.mirrorClaims)
  }
}
