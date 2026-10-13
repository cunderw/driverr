import Foundation

/// What Driverr remembers about offering one integration's hooks to one host.
///
/// `Codable` so the app can persist it as JSON beside the other per-host records.
public enum HookOfferState: Codable, Hashable, Sendable {
  /// The offer for this hook set version was shown. It was not answered, or the answer was
  /// not recorded, and it still counts as asked.
  case offered(version: Int)
  /// The user said no. No later version is offered on connect; the menu item still works.
  case declined
  /// The user installed this hook set version from Driverr.
  case installed(version: Int)
}

/// Whether to offer the hooks when a host connects. The menu item does not ask this: it is
/// available at any time, a decline included.
///
/// Ask once per host, never again after a decline, and when the hook set's version rises,
/// offer the update once to a host that installed or was shown an earlier version.
public enum HookOfferPolicy {
  public static func shouldOffer(
    stored: HookOfferState?,
    hostStatus: AgentIntegrationStatus,
    currentVersion: Int
  ) -> Bool {
    if hostStatus == .installed { return false }
    switch stored {
    case nil:
      return true
    case .declined:
      return false
    case .offered(let version), .installed(let version):
      return version < currentVersion
    }
  }
}

/// The offer state per host and per integration, kept somewhere that outlives the process.
///
/// Keyed by host id and by the integration's agent token, so a second integration has its
/// own offer and its own decline.
public protocol HookOfferStore: Sendable {
  func state(forHost hostID: UUID, agent: String) async -> HookOfferState?
  /// `nil` forgets the host's record for that agent, which is what deleting the host means.
  func setState(_ state: HookOfferState?, forHost hostID: UUID, agent: String) async
}

#if DEBUG
/// A non-persistent `HookOfferStore` for tests, previews and UI runs. `seeded` lets a UI test
/// start from a decline without having declined in a process it does not own.
public actor InMemoryHookOfferStore: HookOfferStore {
  public struct Key: Hashable, Sendable {
    public let hostID: UUID
    public let agent: String

    public init(hostID: UUID, agent: String) {
      self.hostID = hostID
      self.agent = agent
    }
  }

  private var states: [Key: HookOfferState]

  public init(seeded: [Key: HookOfferState] = [:]) {
    states = seeded
  }

  public func state(forHost hostID: UUID, agent: String) async -> HookOfferState? {
    states[Key(hostID: hostID, agent: agent)]
  }

  public func setState(_ state: HookOfferState?, forHost hostID: UUID, agent: String) async {
    states[Key(hostID: hostID, agent: agent)] = state
  }
}
#endif
