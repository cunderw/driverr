import DriverrCore
import Observation

/// Which surface each pane was last left on.
///
/// The scene ends when the reader leaves the pane, so it cannot hold this. The scene owns
/// which surface is open, and this remembers the choice across leaving and reopening.
///
/// **State, not a setting.** Driverr is not a config surface (see CLAUDE.md), and per-pane
/// memory needs nobody to set it and lets two panes differ.
///
/// Keyed by pane id, like the caches on `ConnectionModel`. Only a pane with a chat surface
/// (`TerminalSceneModel.hasChatSurface(for:)`) gets an entry. It is not rebuilt per
/// connection, because a dropped link does not change what the person chose.
///
/// `@Observable`, unlike those caches, because nothing here inserts from a view body. The
/// picker's setter is the only writer, and the segment is bound to this, so it must redraw.
@MainActor
@Observable
final class PaneSurfaceMemory {
  private var surfaces: [String: PaneSurface] = [:]

  /// The surface this pane was last left on, or `nil` if it has never been switched, in
  /// which case the caller applies the first-open rule.
  func surface(for paneID: String) -> PaneSurface? { surfaces[paneID] }

  func remember(_ surface: PaneSurface, for paneID: String) {
    surfaces[paneID] = surface
  }

  /// Drops every pane that is no longer in the session, so a pane id herdr reuses does not
  /// inherit a closed pane's choice. The poll's diff calls this.
  func forgetEverythingExcept(_ liveIDs: Set<String>) {
    surfaces = surfaces.filter { liveIDs.contains($0.key) }
  }
}
