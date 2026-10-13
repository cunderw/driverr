import DriverrCore
import DriverrSSH
import Foundation
import Observation

/// Drives the key management screen.
///
/// Holds only identities, never a private key. Generation and import hand the secret straight
/// to the store, so no view or log can read a key back out of this object.
@MainActor
@Observable
final class IdentityListModel {
  private(set) var identities: [SSHIdentity] = []
  private(set) var errorMessage: String?

  private let store: any IdentityStore
  private let hostStore: any HostStore

  init(store: any IdentityStore, hostStore: any HostStore) {
    self.store = store
    self.hostStore = hostStore
  }

  func load() async {
    do {
      identities = try await store.identities()
      errorMessage = nil
    } catch {
      errorMessage = message(for: error)
    }
  }

  func generate(name: String = defaultKeyName()) async {
    let generated = SSHKeyGenerator.generateEd25519(name: name)
    await perform { try await self.store.add(generated.identity, privateKey: generated.privateKey) }
  }

  /// Imports an OpenSSH private key. The key's own comment becomes its name when it has one.
  func importKey(pem: String) async {
    do {
      let parsed = try OpenSSHPrivateKey.parse(pem: pem)
      let name = parsed.comment.trimmingCharacters(in: .whitespacesAndNewlines)
      let identity = SSHIdentity(
        name: name.isEmpty ? Self.defaultKeyName() : name,
        publicKeyBlob: parsed.publicKeyBlob
      )
      try await store.add(identity, privateKey: parsed.privateKey)
      await load()
    } catch {
      errorMessage = message(for: error)
    }
  }

  func delete(_ identity: SSHIdentity) async {
    await perform { try await self.store.delete(identity.id) }
  }

  /// The display names of hosts that authenticate with `identity`, for the delete
  /// confirmation. Those hosts lose working auth when the key goes.
  func hostNames(usingKey identity: SSHIdentity) async -> [String] {
    let hosts = (try? await hostStore.hosts()) ?? []
    return
      hosts
      .filter { host in
        guard case .identity(let id) = host.authMethod else { return false }
        return id == identity.id
      }
      .map(\.displayName)
  }

  func dismissError() {
    errorMessage = nil
  }

  private func perform(_ work: () async throws -> Void) async {
    do {
      try await work()
      await load()
    } catch {
      errorMessage = message(for: error)
    }
  }

  private func message(for error: any Error) -> String {
    (error as? AppError)?.errorDescription ?? "Something went wrong."
  }

  /// "Driverr key · 27 Aug 2026", so two keys from this device can be told apart.
  ///
  /// A fixed `en_US_POSIX` format, because this is a stored label, not a localised date.
  static func defaultKeyName(date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "d MMM y"
    return "Driverr key · \(formatter.string(from: date))"
  }
}
