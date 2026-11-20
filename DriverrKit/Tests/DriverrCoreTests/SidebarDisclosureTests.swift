import Foundation
import Testing

@testable import DriverrCore

/// Which levels of the iPad sidebar's pane tree are open.
@Suite("SidebarDisclosure")
struct SidebarDisclosureTests {
  private let host = UUID()
  private let other = UUID()

  private static func pane(_ id: String, tab: String, workspace: String) -> Pane {
    Pane(id: id, tabID: tab, workspaceID: workspace, title: id)
  }

  /// Two workspaces, `w2` focused. `w2` has two tabs, so its tabs have rows.
  private static let tree = SessionTree(workspaces: [
    Workspace(
      id: "w1", number: 1, label: "one",
      tabs: [
        Tab(
          id: "w1:t1", workspaceID: "w1", number: 1, label: "1", isAutoNamed: true,
          panes: [pane("w1:p1", tab: "w1:t1", workspace: "w1")])
      ]),
    Workspace(
      id: "w2", number: 2, label: "two", isFocused: true,
      tabs: [
        Tab(
          id: "w2:t1", workspaceID: "w2", number: 1, label: "app",
          panes: [pane("w2:p1", tab: "w2:t1", workspace: "w2")]),
        Tab(
          id: "w2:t2", workspaceID: "w2", number: 2, label: "logs",
          panes: [pane("w2:p2", tab: "w2:t2", workspace: "w2")]),
      ]),
  ])

  /// The same ids with `w1` focused instead, as a later poll might report.
  private static let refocused = SessionTree(workspaces: [
    Workspace(id: "w1", number: 1, label: "one", isFocused: true, tabs: tree.workspaces[0].tabs),
    Workspace(id: "w2", number: 2, label: "two", tabs: tree.workspaces[1].tabs),
    Workspace(id: "w3", number: 3, label: "three"),
  ])

  @Test("hosts and tabs start open, and workspaces start from the tree's default")
  func defaults() {
    let disclosure = SidebarDisclosure()
    #expect(disclosure.isHostExpanded(host))
    #expect(disclosure.isTabExpanded("w2:t1", hostID: host))
    #expect(disclosure.isWorkspaceExpanded("w2", hostID: host, tree: Self.tree))
    #expect(!disclosure.isWorkspaceExpanded("w1", hostID: host, tree: Self.tree))
  }

  /// A later focus change must not reopen a workspace, and a new one starts closed.
  @Test("the seed is read once per host, so later trees do not move it")
  func seededOnce() {
    var disclosure = SidebarDisclosure()
    disclosure.seed(hostID: host, tree: Self.tree)
    disclosure.seed(hostID: host, tree: Self.refocused)
    #expect(disclosure.isWorkspaceExpanded("w2", hostID: host, tree: Self.refocused))
    #expect(!disclosure.isWorkspaceExpanded("w1", hostID: host, tree: Self.refocused))
    #expect(!disclosure.isWorkspaceExpanded("w3", hostID: host, tree: Self.refocused))
  }

  @Test("an empty tree does not count as the seed")
  func emptyTreeIsNoSeed() {
    var disclosure = SidebarDisclosure()
    disclosure.seed(hostID: host, tree: .empty)
    disclosure.seed(hostID: host, tree: Self.refocused)
    #expect(disclosure.isWorkspaceExpanded("w1", hostID: host, tree: Self.tree))
  }

  /// Two hosts' herdr ids collide, so a key without its host would fold both.
  @Test("every level is kept per host")
  func perHost() {
    var disclosure = SidebarDisclosure()
    disclosure.seed(hostID: host, tree: Self.tree)
    disclosure.seed(hostID: other, tree: Self.refocused)
    #expect(disclosure.isWorkspaceExpanded("w2", hostID: host, tree: Self.tree))
    #expect(!disclosure.isWorkspaceExpanded("w2", hostID: other, tree: Self.tree))

    disclosure.setTab("w2:t1", hostID: host, expanded: false)
    disclosure.setHost(host, expanded: false)
    #expect(disclosure.isTabExpanded("w2:t1", hostID: other))
    #expect(disclosure.isHostExpanded(other))
  }

  @Test("a toggle closes and reopens each level")
  func toggle() {
    var disclosure = SidebarDisclosure()
    disclosure.seed(hostID: host, tree: Self.tree)

    disclosure.setHost(host, expanded: false)
    #expect(!disclosure.isHostExpanded(host))
    disclosure.setHost(host, expanded: true)
    #expect(disclosure.isHostExpanded(host))

    disclosure.setWorkspace("w2", hostID: host, expanded: false)
    #expect(!disclosure.isWorkspaceExpanded("w2", hostID: host, tree: Self.tree))
    disclosure.setWorkspace("w1", hostID: host, expanded: true)
    #expect(disclosure.isWorkspaceExpanded("w1", hostID: host, tree: Self.tree))
    disclosure.setWorkspace("w1", hostID: host, expanded: false)
    #expect(!disclosure.isWorkspaceExpanded("w1", hostID: host, tree: Self.tree))

    disclosure.setTab("w2:t2", hostID: host, expanded: false)
    #expect(!disclosure.isTabExpanded("w2:t2", hostID: host))
    disclosure.setTab("w2:t2", hostID: host, expanded: true)
    #expect(disclosure.isTabExpanded("w2:t2", hostID: host))
  }

  @Test("a reveal opens the host, workspace and tab above the pane")
  func reveal() {
    var disclosure = SidebarDisclosure()
    disclosure.seed(hostID: host, tree: Self.tree)
    disclosure.setHost(host, expanded: false)
    disclosure.setWorkspace("w2", hostID: host, expanded: false)
    disclosure.setTab("w2:t2", hostID: host, expanded: false)

    disclosure.reveal(paneID: "w2:p2", hostID: host, tree: Self.tree)
    #expect(disclosure.isHostExpanded(host))
    #expect(disclosure.isWorkspaceExpanded("w2", hostID: host, tree: Self.tree))
    #expect(disclosure.isTabExpanded("w2:t2", hostID: host))
    // Nothing else moved.
    #expect(!disclosure.isWorkspaceExpanded("w1", hostID: host, tree: Self.tree))
  }

  /// A pane opened before the sidebar drew its host, from a URL or a notification at launch.
  @Test("a reveal before the seed survives the seed, and is not taken as it")
  func revealBeforeSeed() {
    var disclosure = SidebarDisclosure()
    disclosure.reveal(paneID: "w1:p1", hostID: host, tree: Self.tree)
    disclosure.seed(hostID: host, tree: Self.tree)
    #expect(disclosure.isWorkspaceExpanded("w1", hostID: host, tree: Self.tree))
    // The seed still landed: the focused workspace is open, and a later focus change does
    // not open another.
    #expect(disclosure.isWorkspaceExpanded("w2", hostID: host, tree: Self.refocused))
    #expect(!disclosure.isWorkspaceExpanded("w3", hostID: host, tree: Self.refocused))
  }

  @Test("a pane the tree does not list opens only its host")
  func revealMissingPane() {
    var disclosure = SidebarDisclosure()
    disclosure.seed(hostID: host, tree: Self.tree)
    disclosure.setHost(host, expanded: false)
    disclosure.reveal(paneID: "gone", hostID: host, tree: Self.tree)
    #expect(disclosure.isHostExpanded(host))
    #expect(!disclosure.isWorkspaceExpanded("w1", hostID: host, tree: Self.tree))
  }

  /// The host screen's tab rule. See `Workspace.tabHeaderStyle`.
  @Test("only a workspace of several tabs gives its tabs rows")
  func tabRule() {
    let autoNamed = Self.tree.workspaces[0]
    let named = Workspace(
      id: "w4", number: 4, label: "four",
      tabs: [Tab(id: "w4:t1", workspaceID: "w4", number: 1, label: "app")])
    #expect(!SidebarDisclosure.showsTabRows(autoNamed))
    #expect(named.tabHeaderStyle == .inline)
    #expect(!SidebarDisclosure.showsTabRows(named))
    #expect(SidebarDisclosure.showsTabRows(Self.tree.workspaces[1]))
  }
}
