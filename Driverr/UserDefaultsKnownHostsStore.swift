import DriverrCore
import Foundation

/// Persists accepted host keys in `UserDefaults`.
///
/// Not the Keychain: a host key is public, and the property that matters is durability. A
/// store that forgot would re-prompt on every connection, training the user to tap "Trust"
/// without reading, including on the day the key really changes. An attacker who can
/// rewrite this file can already rewrite the app.
actor UserDefaultsKnownHostsStore: KnownHostsStore {
  private let defaults: UserDefaults
  private let key = "com.cunderw.driverr.knownHosts"

  /// Takes a suite name, not an instance; see `UserDefaultsHostStore.init(suiteName:)`.
  init(suiteName: String? = nil) {
    defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
  }

  func trustedKey(for hostname: String) async -> SSHHostKey? {
    load()[hostname]
  }

  func trust(_ key: SSHHostKey, for hostname: String) async {
    var all = load()
    all[hostname] = key
    save(all)
  }

  func forget(_ hostname: String) async {
    var all = load()
    all[hostname] = nil
    save(all)
  }

  private func load() -> [String: SSHHostKey] {
    guard let data = defaults.data(forKey: key) else { return [:] }
    // Unreadable reads as empty: the worst case is a safe re-prompt, and a throw would
    // break connecting.
    return (try? JSONDecoder().decode([String: SSHHostKey].self, from: data)) ?? [:]
  }

  private func save(_ all: [String: SSHHostKey]) {
    guard let data = try? JSONEncoder().encode(all) else { return }
    defaults.set(data, forKey: key)
  }
}
