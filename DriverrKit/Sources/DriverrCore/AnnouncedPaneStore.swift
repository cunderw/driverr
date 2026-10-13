import Foundation

/// Which panes a host has already been told about, stored so it outlives the process.
///
/// A background refresh launches the app cold. With an empty set, every blocked pane reads
/// as newly blocked, and each refresh re-alerts the same questions. Keyed by host id, as
/// `BlockedPaneAlerts` is one per host, because pane ids repeat across hosts.
public protocol AnnouncedPaneStore: Sendable {
  func announcedPanes(forHost hostID: UUID) async -> Set<String>
  func setAnnouncedPanes(_ paneIDs: Set<String>, forHost hostID: UUID) async
}

#if DEBUG
/// A non-persistent `AnnouncedPaneStore` for tests, previews and UI runs.
///
/// No UI run may carry one test's announced set into the next launch, and previews must not
/// write to `UserDefaults`.
public actor InMemoryAnnouncedPaneStore: AnnouncedPaneStore {
  private var panes: [UUID: Set<String>]

  public init(seeded: [UUID: Set<String>] = [:]) {
    panes = seeded
  }

  public func announcedPanes(forHost hostID: UUID) async -> Set<String> {
    panes[hostID] ?? []
  }

  public func setAnnouncedPanes(_ paneIDs: Set<String>, forHost hostID: UUID) async {
    panes[hostID] = paneIDs
  }
}
#endif
