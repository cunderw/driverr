import Foundation

/// One host the pane switcher could offer, as the app hands it over.
///
/// A flat value, not a connection object, so the ordering rule is testable. Built from
/// `ConnectionRegistry`'s models, whose trees the host list already polls.
public struct PaneSwitcherHost: Hashable, Sendable {
  public let id: Host.ID
  /// The host's `displayName`, resolved by the caller, so the switcher uses the same words
  /// as the host list.
  public let name: String
  /// Whether Driverr is holding this host's link right now.
  public let isConnected: Bool
  /// The tree the host list's poll last read.
  public let tree: SessionTree

  public init(id: Host.ID, name: String, isConnected: Bool, tree: SessionTree) {
    self.id = id
    self.name = name
    self.isConnected = isConnected
    self.tree = tree
  }
}

/// The pane switcher's sections for every host that is not the one on screen, so switching
/// between machines is one tap using trees already on the device.
///
/// - The host on screen is never here. Its panes are `PaneStripModel`'s, drawn before this,
///   and a second derivation would be a second opinion about one session.
/// - A disconnected host is absent. It has no tree and would need a handshake first; the host
///   list is where connecting belongs.
/// - A connected host with no panes is absent, as `showsSwitcher` hides the button there.
///
/// Ordered by name, then id. The registry is a dictionary, so its order would change between
/// openings.
public struct CrossHostPanes: Hashable, Sendable {
  /// One other host's panes, under its own name.
  public struct Section: Identifiable, Hashable, Sendable {
    public let id: Host.ID
    public let name: String
    /// In `SessionTree.allPanes` order, as the host's own tree draws them.
    public let panes: [Pane]

    public init(id: Host.ID, name: String, panes: [Pane]) {
      self.id = id
      self.name = name
      self.panes = panes
    }
  }

  public let sections: [Section]

  public var isEmpty: Bool { sections.isEmpty }

  /// - Parameter currentHostID: the host whose scene is on screen, or `nil` to offer every
  ///   connected host with panes.
  public init(currentHostID: Host.ID?, hosts: [PaneSwitcherHost]) {
    self.sections =
      hosts
      .filter { $0.isConnected && $0.id != currentHostID }
      .map { Section(id: $0.id, name: $0.name, panes: $0.tree.allPanes) }
      .filter { !$0.panes.isEmpty }
      .sorted { left, right in
        switch left.name.localizedCaseInsensitiveCompare(right.name) {
        case .orderedAscending: true
        case .orderedDescending: false
        // Two hosts can share a name (one machine saved under two addresses). The id keeps
        // their order stable, since the input order comes from a dictionary.
        case .orderedSame: left.id.uuidString < right.id.uuidString
        }
      }
  }
}
