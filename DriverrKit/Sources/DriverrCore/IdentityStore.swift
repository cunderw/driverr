import Foundation

/// Where the user's SSH identities live.
///
/// A protocol so previews and UI tests use an in-memory store and the app uses the Keychain.
/// Identities come back in bulk, private keys only one at a time on request, so nothing can
/// enumerate secrets.
public protocol IdentityStore: Sendable {
  /// Every identity, newest first.
  func identities() async throws -> [SSHIdentity]
  func add(_ identity: SSHIdentity, privateKey: SSHPrivateKey) async throws
  /// The private half, fetched at the moment of authentication and not before.
  func privateKey(for id: UUID) async throws -> SSHPrivateKey
  func delete(_ id: UUID) async throws
}

#if DEBUG
/// A non-persistent `IdentityStore` for previews, UI tests, and demo mode.
public actor InMemoryIdentityStore: IdentityStore {
  private var stored: [UUID: (identity: SSHIdentity, privateKey: SSHPrivateKey)] = [:]

  public init() {}

  public func identities() async throws -> [SSHIdentity] {
    stored.values.map(\.identity).sorted { $0.createdAt > $1.createdAt }
  }

  public func add(_ identity: SSHIdentity, privateKey: SSHPrivateKey) async throws {
    stored[identity.id] = (identity, privateKey)
  }

  public func privateKey(for id: UUID) async throws -> SSHPrivateKey {
    guard let entry = stored[id] else {
      throw AppError.keyImportFailed(reason: "That key is no longer available.")
    }
    return entry.privateKey
  }

  public func delete(_ id: UUID) async throws {
    stored[id] = nil
  }
}
#endif
