import DriverrCore
import Foundation

/// Persists whether each host was offered Driverr's hooks, and what the user said.
///
/// `UserDefaults`, because the record is not secret, and a decline must outlive the process
/// or the offer returns on every launch.
///
/// One key per host and agent, so a second integration has its own record.
actor UserDefaultsHookOfferStore: HookOfferStore {
  private let defaults: UserDefaults

  /// Takes a suite name, not an instance; see `UserDefaultsHostStore.init(suiteName:)`.
  init(suiteName: String? = nil) {
    defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
  }

  private func key(for hostID: UUID, agent: String) -> String {
    "com.cunderw.driverr.hookOffer.\(agent).\(hostID.uuidString)"
  }

  /// An undecodable payload reads as never asked; the worst case is one more offer.
  func state(forHost hostID: UUID, agent: String) async -> HookOfferState? {
    guard let data = defaults.data(forKey: key(for: hostID, agent: agent)) else { return nil }
    return try? JSONDecoder().decode(HookOfferState.self, from: data)
  }

  func setState(_ state: HookOfferState?, forHost hostID: UUID, agent: String) async {
    guard let state, let data = try? JSONEncoder().encode(state) else {
      defaults.removeObject(forKey: key(for: hostID, agent: agent))
      return
    }
    defaults.set(data, forKey: key(for: hostID, agent: agent))
  }
}
