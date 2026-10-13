import Foundation

/// The host keys the user has accepted, keyed by hostname.
///
/// Host keys are public, so this is ordinary persisted data, not Keychain. It must survive
/// launches: re-prompting on every connection trains the user to tap "Trust" even on the day
/// the key really changed.
public protocol KnownHostsStore: Sendable {
  func trustedKey(for hostname: String) async -> SSHHostKey?
  func trust(_ key: SSHHostKey, for hostname: String) async
  /// The sanctioned way back after a legitimate rebuild: forget, then trust the new key
  /// through the normal first-contact prompt.
  func forget(_ hostname: String) async
}

extension KnownHostsStore {
  /// Forgets `host`'s trusted key unless another host in `others` still relies on it.
  ///
  /// The key is stored by hostname alone, so every saved host naming one machine shares it,
  /// whatever its port or user. Deleting one must not re-prompt the others.
  public func forget(_ host: Host, unlessUsedBy others: [Host]) async {
    guard !others.sharesHostname(with: host) else { return }
    await forget(host.hostname)
  }
}

extension Array where Element == Host {
  /// Whether a host other than `host` has the same hostname, and so the same trusted key.
  ///
  /// Matched by hostname alone, as `KnownHostsStore` keys it; the store ignores the port, so
  /// this does too. `host` itself is excluded by id.
  public func sharesHostname(with host: Host) -> Bool {
    contains { $0.id != host.id && $0.hostname == host.hostname }
  }
}

#if DEBUG
/// A non-persistent `KnownHostsStore` for tests, previews, and demo mode.
public actor InMemoryKnownHostsStore: KnownHostsStore {
  private var keys: [String: SSHHostKey] = [:]

  public init(seeded: [String: SSHHostKey] = [:]) {
    keys = seeded
  }

  public func trustedKey(for hostname: String) async -> SSHHostKey? { keys[hostname] }

  public func trust(_ key: SSHHostKey, for hostname: String) async {
    keys[hostname] = key
  }

  public func forget(_ hostname: String) async {
    keys[hostname] = nil
  }
}
#endif
