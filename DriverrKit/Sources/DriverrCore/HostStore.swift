import Foundation

/// The user's list of hosts.
///
/// Hosts hold no secrets. Passwords and keys are reached separately, by host id, from the
/// Keychain.
public protocol HostStore: Sendable {
  func hosts() async throws -> [Host]
  /// Adds a host, or replaces the existing one with the same id.
  func save(_ host: Host) async throws
  func delete(_ id: UUID) async throws
}

#if DEBUG
/// A non-persistent `HostStore` for previews, UI tests, and demo mode.
public actor InMemoryHostStore: HostStore {
  private var ordered: [Host] = []

  public init(seeded: [Host] = []) {
    ordered = seeded
  }

  public func hosts() async throws -> [Host] { ordered }

  public func save(_ host: Host) async throws {
    // Update in place, so re-saving a host does not make the list jump.
    if let index = ordered.firstIndex(where: { $0.id == host.id }) {
      ordered[index] = host
    } else {
      ordered.append(host)
    }
  }

  public func delete(_ id: UUID) async throws {
    ordered.removeAll { $0.id == id }
  }
}

extension Host {
  /// The one host the UI-test environment starts with, when asked for it.
  ///
  /// Here rather than in the test target, like `FakeControl`, because the app constructs it
  /// at launch and tests and screenshots must share one definition. The id is fixed so tests
  /// can name it and launches are identical. The values match what the add-host tests type,
  /// so a class can switch to the seed without changing assertions.
  public static let uiTestSeed = Host(
    id: UUID(uuidString: "00000000-0000-0000-0000-00000000D701")!,
    name: "workbox",
    hostname: "10.1.0.9",
    username: "carson"
  )

  /// A second host, for the pane switcher's cross-host test, which needs two connected
  /// machines. Seeding saves driving the add-host form and a full connect in that test.
  ///
  /// Requested with `-uiTestingSecondHost`, alongside `uiTestSeed`. `AppEnvironment` seeds its
  /// password and host key from the same `-uiTestingConnected`.
  ///
  /// It has its own hostname, because known hosts are keyed by hostname and a shared address
  /// would share a trust decision. Named "beta" so the switcher's name ordering visibly
  /// differs from the seeded list, which has workbox first.
  public static let uiTestSecondSeed = Host(
    id: UUID(uuidString: "00000000-0000-0000-0000-00000000D702")!,
    name: "beta",
    hostname: "10.1.0.42",
    username: "carson"
  )
}
#endif
