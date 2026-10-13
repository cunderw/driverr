import DriverrCore
import Foundation

/// Persists the pane each host was last opened on, so a Live Activity tap can return the
/// reader there rather than to the host's tree.
///
/// `UserDefaults`, for `UserDefaultsAnnouncedPaneStore`'s reasons: not secret, and read
/// the instant a card tap cold-launches the app. One key per host.
actor UserDefaultsLastPaneStore: LastPaneStore {
  private let defaults: UserDefaults

  /// Takes a suite name, not an instance; see `UserDefaultsHostStore.init(suiteName:)`.
  init(suiteName: String? = nil) {
    defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
  }

  /// Namespaced, because `UserDefaults.standard` is shared with the other stores and
  /// `ContentView`'s remembered selection.
  private func key(for hostID: UUID) -> String {
    "com.cunderw.driverr.lastPane.\(hostID.uuidString)"
  }

  /// **Keep this key; it is the migration.** An older build stored a bare `String` here,
  /// and `data(forKey:)` returns `nil` for a string, so the old shape reads as absent until
  /// the next write. An undecodable payload also reads as absent, which lands on the tree.
  func lastPane(forHost hostID: UUID) async -> LastPaneRecord? {
    guard let data = defaults.data(forKey: key(for: hostID)),
      let record = try? JSONDecoder().decode(LastPaneRecord.self, from: data),
      record.isResumable
    else { return nil }
    return record
  }

  func setLastPane(_ record: LastPaneRecord?, forHost hostID: UUID) async {
    guard let record, record.isResumable, let data = try? JSONEncoder().encode(record) else {
      // `nil`, an unresumable record and a failed encode all remove the key. Keeping the old
      // value would resume a pane the writer had moved off.
      defaults.removeObject(forKey: key(for: hostID))
      return
    }
    defaults.set(data, forKey: key(for: hostID))
  }
}
