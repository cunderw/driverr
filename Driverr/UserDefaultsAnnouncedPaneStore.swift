import DriverrCore
import Foundation

/// Persists the panes each host has already been announced, so a background refresh does
/// not alert them again.
///
/// `UserDefaults`, not the Keychain: pane ids are not secret, and a `BGAppRefreshTask`
/// launched from cold on a locked phone must read them without a lock-state failure mode.
///
/// One key per host, so two hosts' refreshes cannot overwrite each other.
actor UserDefaultsAnnouncedPaneStore: AnnouncedPaneStore {
  private let defaults: UserDefaults

  /// Takes a suite name, not an instance; see `UserDefaultsHostStore.init(suiteName:)`.
  init(suiteName: String? = nil) {
    defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
  }

  /// Namespaced, because `UserDefaults.standard` is shared with the other stores and
  /// `ContentView`'s remembered selection.
  private func key(for hostID: UUID) -> String {
    "com.cunderw.driverr.announcedPanes.\(hostID.uuidString)"
  }

  func announcedPanes(forHost hostID: UUID) async -> Set<String> {
    Set(defaults.stringArray(forKey: key(for: hostID)) ?? [])
  }

  func setAnnouncedPanes(_ paneIDs: Set<String>, forHost hostID: UUID) async {
    guard !paneIDs.isEmpty else {
      // Removed, not stored empty, so no key lingers for every host ever connected.
      defaults.removeObject(forKey: key(for: hostID))
      return
    }
    // Sorted, so the stored value is stable for diagnosis on a device.
    defaults.set(paneIDs.sorted(), forKey: key(for: hostID))
  }
}
