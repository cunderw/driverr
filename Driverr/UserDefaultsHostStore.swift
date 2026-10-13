import DriverrCore
import Foundation

/// Persists the host list in `UserDefaults`.
///
/// Hosts carry no secrets (passwords and keys are in the Keychain, by host id). Order is
/// kept as written, so editing an entry does not reshuffle the list.
actor UserDefaultsHostStore: HostStore {
  private let defaults: UserDefaults
  private let key = "com.cunderw.driverr.hosts"

  /// Takes a suite name, not an instance, so the instance is made inside the actor.
  /// `UserDefaults` is not `Sendable`, and passing one across the boundary is a data race.
  init(suiteName: String? = nil) {
    defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
  }

  func hosts() async throws -> [DriverrCore.Host] {
    guard let data = defaults.data(forKey: key) else { return [] }
    // Unreadable reads as empty: a host can be re-added, but a throw would break launch.
    return (try? JSONDecoder().decode([DriverrCore.Host].self, from: data)) ?? []
  }

  func save(_ host: DriverrCore.Host) async throws {
    var all = try await hosts()
    if let index = all.firstIndex(where: { $0.id == host.id }) {
      all[index] = host
    } else {
      all.append(host)
    }
    persist(all)
  }

  func delete(_ id: UUID) async throws {
    persist(try await hosts().filter { $0.id != id })
  }

  private func persist(_ hosts: [DriverrCore.Host]) {
    guard let data = try? JSONEncoder().encode(hosts) else { return }
    defaults.set(data, forKey: key)
  }
}
