import Foundation

/// Which levels of the iPad sidebar's pane tree are open: hosts, workspaces and tabs.
///
/// In memory only, and apart from `SessionModel`'s own expanded workspaces, so the sidebar
/// and the host screen fold separately. Every key carries its host, because two hosts'
/// herdr ids (`w1`, `w1:t1`) collide.
///
/// - Hosts and tabs start open. Few hosts connect at once, and a tab row exists only when
///   it has a name worth showing.
/// - Workspaces start from `SessionTree.defaultExpandedWorkspaceIDs`, read once per host by
///   `seed(hostID:tree:)`. A workspace that appears later starts closed, as on the host
///   screen.
/// - `reveal(paneID:hostID:tree:)` opens every level above a pane, so the highlight is
///   never inside a closed row.
public struct SidebarDisclosure: Equatable, Sendable {
  private var collapsedHosts: Set<UUID> = []
  private var collapsedTabs: [UUID: Set<String>] = [:]
  /// The workspaces the reader, or a reveal, opened or closed. They outrank the seed.
  private var openedWorkspaces: [UUID: Set<String>] = [:]
  private var closedWorkspaces: [UUID: Set<String>] = [:]
  /// Each host's first non-empty tree's default. `nil` until `seed` has run for that host.
  private var seededWorkspaces: [UUID: Set<String>] = [:]

  public init() {}

  /// Whether a workspace's tabs get rows of their own. The host screen's rule: a single tab
  /// herdr or tmux named itself has no row, and a single named tab folds into the workspace
  /// row. See `Workspace.tabHeaderStyle`.
  public static func showsTabRows(_ workspace: Workspace) -> Bool {
    workspace.tabHeaderStyle == .headers
  }

  // MARK: - Hosts

  public func isHostExpanded(_ hostID: UUID) -> Bool {
    !collapsedHosts.contains(hostID)
  }

  public mutating func setHost(_ hostID: UUID, expanded: Bool) {
    if expanded {
      collapsedHosts.remove(hostID)
    } else {
      collapsedHosts.insert(hostID)
    }
  }

  // MARK: - Workspaces

  /// Records the host's starting workspaces, once. An empty tree does not count, because it
  /// has no default to keep.
  public mutating func seed(hostID: UUID, tree: SessionTree) {
    guard seededWorkspaces[hostID] == nil, !tree.isEmpty else { return }
    seededWorkspaces[hostID] = tree.defaultExpandedWorkspaceIDs
  }

  /// Whether a workspace is open. Before the seed lands, `tree`'s default answers, so the
  /// first frame matches the frame after it.
  public func isWorkspaceExpanded(
    _ workspaceID: String, hostID: UUID, tree: SessionTree
  ) -> Bool {
    if closedWorkspaces[hostID, default: []].contains(workspaceID) { return false }
    if openedWorkspaces[hostID, default: []].contains(workspaceID) { return true }
    let defaults = seededWorkspaces[hostID] ?? tree.defaultExpandedWorkspaceIDs
    return defaults.contains(workspaceID)
  }

  public mutating func setWorkspace(_ workspaceID: String, hostID: UUID, expanded: Bool) {
    if expanded {
      openedWorkspaces[hostID, default: []].insert(workspaceID)
      closedWorkspaces[hostID, default: []].remove(workspaceID)
    } else {
      closedWorkspaces[hostID, default: []].insert(workspaceID)
      openedWorkspaces[hostID, default: []].remove(workspaceID)
    }
  }

  // MARK: - Tabs

  public func isTabExpanded(_ tabID: String, hostID: UUID) -> Bool {
    !collapsedTabs[hostID, default: []].contains(tabID)
  }

  public mutating func setTab(_ tabID: String, hostID: UUID, expanded: Bool) {
    if expanded {
      collapsedTabs[hostID, default: []].remove(tabID)
    } else {
      collapsedTabs[hostID, default: []].insert(tabID)
    }
  }

  // MARK: - Following the selection

  /// Opens the host, and the workspace and tab that hold `paneID` in `tree`. A pane the tree
  /// does not list opens only the host.
  public mutating func reveal(paneID: String, hostID: UUID, tree: SessionTree) {
    setHost(hostID, expanded: true)
    guard let pane = tree.pane(id: paneID) else { return }
    setWorkspace(pane.workspaceID, hostID: hostID, expanded: true)
    setTab(pane.tabID, hostID: hostID, expanded: true)
  }
}
