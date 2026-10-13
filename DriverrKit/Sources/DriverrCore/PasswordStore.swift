import Foundation

/// Whether a host's password is kept between connections.
public enum PasswordPersistence: String, Hashable, Sendable, Codable {
  /// Keep it in the Keychain so the user is not asked again.
  case remember
  /// Ask on every connection; nothing is written anywhere.
  case promptEveryTime

  /// Prompting. A `.remember` default would keep a credential the user never agreed to, so
  /// a caller that forgets to choose cannot leak one.
  public static let `default` = PasswordPersistence.promptEveryTime
}

/// Storage for host passwords. One entry per host.
public protocol PasswordStore: Sendable {
  func password(for hostID: UUID) async throws -> String?
  func save(_ password: String, for hostID: UUID) async throws
  func delete(for hostID: UUID) async throws
}

/// The consent rule, in one place.
///
/// Nothing else should call `PasswordStore.save`. Routing every write through here makes
/// "never persist without consent" a property of the code, and the tests pin it.
public struct PasswordCredentials: Sendable {
  private let store: any PasswordStore

  public init(store: any PasswordStore) {
    self.store = store
  }

  /// Saves the password only when the user asked for it to be remembered.
  ///
  /// `.promptEveryTime` deletes rather than doing nothing, so a host switched back to
  /// prompting does not keep its old password in the Keychain.
  public func remember(
    _ password: String,
    for hostID: UUID,
    persistence: PasswordPersistence
  ) async throws {
    switch persistence {
    case .remember:
      try await store.save(password, for: hostID)
    case .promptEveryTime:
      try await store.delete(for: hostID)
    }
  }

  public func saved(for hostID: UUID) async throws -> String? {
    try await store.password(for: hostID)
  }

  public func forget(for hostID: UUID) async throws {
    try await store.delete(for: hostID)
  }
}

#if DEBUG
/// A non-persistent `PasswordStore` for previews, UI tests, and demo mode.
public actor InMemoryPasswordStore: PasswordStore {
  private var passwords: [UUID: String] = [:]

  /// - Parameter seeded: passwords already in the store, keyed by host id.
  ///
  /// Seeded through `init`, because `AppEnvironment.ephemeral` is a non-async computed
  /// property and cannot await `save`. `InMemoryKnownHostsStore` does the same.
  public init(seeded: [UUID: String] = [:]) {
    passwords = seeded
  }

  public func password(for hostID: UUID) async throws -> String? { passwords[hostID] }

  public func save(_ password: String, for hostID: UUID) async throws {
    passwords[hostID] = password
  }

  public func delete(for hostID: UUID) async throws {
    passwords[hostID] = nil
  }
}
#endif
