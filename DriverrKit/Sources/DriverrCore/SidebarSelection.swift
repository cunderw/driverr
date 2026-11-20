import Foundation

/// What the iPad sidebar highlights: a host, or one pane under a host.
///
/// Derived, never stored. The open pane and `ContentView.selectedHostID` are the two sources
/// of truth, and a stored copy would disagree with them the first time a notification tap,
/// the pane switcher or a Live Activity URL moved the scene. `derived(selectedHostID:open:)`
/// holds the read, and `effect(ofWrite:current:)` the write.
public enum SidebarSelection: Hashable, Sendable {
  case host(UUID)
  case pane(hostID: UUID, paneID: String)

  /// What the sidebar highlights now.
  ///
  /// The open scene wins, because it is what the detail column shows. A plain shell names no
  /// pane, so it highlights its host. With no scene, the selected host.
  public static func derived(
    selectedHostID: UUID?,
    open: (hostID: UUID, target: TerminalTarget)?
  ) -> SidebarSelection? {
    if let open {
      switch open.target {
      case .shell: return .host(open.hostID)
      case .pane(let id): return .pane(hostID: open.hostID, paneID: id)
      }
    }
    return selectedHostID.map(SidebarSelection.host)
  }

  /// What a write to the sidebar's selection asks for.
  public enum WriteEffect: Equatable, Sendable {
    /// Nothing: a tap on the pane already open.
    case none
    /// Today's host tap: leave any scene and show the host's screen, or clear the selection.
    case selectHost(UUID?)
    /// Open the pane, in the scene already on its host when there is one.
    case openPane(hostID: UUID, paneID: String)
  }

  /// What SwiftUI's write of `new` should do, given what the sidebar showed before it.
  ///
  /// A host write always applies, even onto the host already selected, because a tap on the
  /// selected host is how the iPad leaves its pane scene. A pane write onto the pane already
  /// open does nothing, so it does not reload the scene.
  public static func effect(
    ofWrite new: SidebarSelection?,
    current: SidebarSelection?
  ) -> WriteEffect {
    switch new {
    case nil: return .selectHost(nil)
    case .host(let id): return .selectHost(id)
    case .pane(let hostID, let paneID):
      if new == current { return .none }
      return .openPane(hostID: hostID, paneID: paneID)
    }
  }
}
