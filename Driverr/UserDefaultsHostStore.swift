import DriverrCore
import Foundation

/// Persists the host list in `UserDefaults`.
///
/// Hosts carry no secrets (passwords and keys are in the Keychain, by host id). Order is
/// kept as written, so editing an entry does not reshuffle the list.
///
/// `StoredHostList` reads the list one host at a time. A host this build cannot read, for
/// example one a newer build saved with a new auth method, is left out of `hosts()` and is
/// written back unchanged on every save and delete.
actor UserDefaultsHostStore: HostStore {
  private let defaults: UserDefaults
  private let key = "com.cunderw.driverr.hosts"
  /// Where stored data that is not a JSON array goes before the first write replaces it.
  /// Written once and never overwritten, so a second corruption cannot replace the first.
  private let unreadableKey = "com.cunderw.driverr.hosts.unreadable"

  /// Takes a suite name, not an instance, so the instance is made inside the actor.
  /// `UserDefaults` is not `Sendable`, and passing one across the boundary is a data race.
  init(suiteName: String? = nil) {
    defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
  }

  func hosts() async throws -> [DriverrCore.Host] {
    // Data that is not an array reads as empty: a throw would break launch.
    stored().hosts
  }

  func save(_ host: DriverrCore.Host) async throws {
    var list = stored()
    list.save(host)
    try persist(list)
  }

  func delete(_ id: UUID) async throws {
    var list = stored()
    list.delete(id)
    try persist(list)
  }

  private func stored() -> StoredHostList {
    StoredHostList(data: defaults.data(forKey: key))
  }

  private func persist(_ list: StoredHostList) throws {
    let data = try list.encoded()
    if list.storedDataIsUnreadable, defaults.object(forKey: unreadableKey) == nil,
      let original = defaults.data(forKey: key)
    {
      defaults.set(original, forKey: unreadableKey)
    }
    defaults.set(data, forKey: key)
  }
}
