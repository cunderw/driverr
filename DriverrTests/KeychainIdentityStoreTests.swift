@testable import Driverr
import DriverrCore
import Foundation
import Testing

/// Exercises the real iOS Keychain, not a fake.
///
/// An unsigned bundle gets `errSecMissingEntitlement` on every write, so a Keychain store can
/// only be proven from inside the signed, app-hosted process. Each test uses its own service
/// name, so a failure leaves nothing to poison the next run.
@Suite("KeychainIdentityStore", .serialized)
struct KeychainIdentityStoreTests {
  private func makeStore() -> KeychainIdentityStore {
    KeychainIdentityStore(service: "com.cunderw.driverr.tests.\(UUID().uuidString)")
  }

  private func makeKey(_ byte: UInt8) -> SSHPrivateKey {
    SSHPrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
  }

  @Test("an identity survives a round trip through the Keychain")
  func roundTripsAnIdentity() async throws {
    let store = makeStore()
    defer { try? store.deleteAll() }

    let identity = SSHIdentity(name: "laptop", publicKeyBlob: Data("public".utf8))
    try await store.add(identity, privateKey: makeKey(9))

    let listed = try await store.identities()
    #expect(listed.count == 1)
    #expect(listed.first?.name == "laptop")
    #expect(listed.first?.id == identity.id)
  }

  @Test("the private key read back is byte-identical to the one stored")
  func privateKeyRoundTrips() async throws {
    let store = makeStore()
    defer { try? store.deleteAll() }

    let identity = SSHIdentity(name: "laptop", publicKeyBlob: Data("public".utf8))
    try await store.add(identity, privateKey: makeKey(42))

    let recovered = try await store.privateKey(for: identity.id)
    #expect(recovered == makeKey(42))
  }

  @Test("deleting an identity removes its key from the Keychain too")
  func deleteRemovesEverything() async throws {
    let store = makeStore()
    defer { try? store.deleteAll() }

    let identity = SSHIdentity(name: "laptop", publicKeyBlob: Data("public".utf8))
    try await store.add(identity, privateKey: makeKey(1))
    try await store.delete(identity.id)

    #expect(try await store.identities().isEmpty)
    await #expect(throws: AppError.self) {
      try await store.privateKey(for: identity.id)
    }
  }

  @Test("two identities are kept separate rather than overwriting each other")
  func keepsIdentitiesSeparate() async throws {
    let store = makeStore()
    defer { try? store.deleteAll() }

    let first = SSHIdentity(name: "laptop", publicKeyBlob: Data("a".utf8))
    let second = SSHIdentity(name: "phone", publicKeyBlob: Data("b".utf8))
    try await store.add(first, privateKey: makeKey(1))
    try await store.add(second, privateKey: makeKey(2))

    #expect(try await store.identities().count == 2)
    #expect(try await store.privateKey(for: first.id) == makeKey(1))
    #expect(try await store.privateKey(for: second.id) == makeKey(2))
  }

  @Test("asking for a key that was never stored throws")
  func missingKeyThrows() async {
    let store = makeStore()
    await #expect(throws: AppError.self) {
      try await store.privateKey(for: UUID())
    }
  }
}
