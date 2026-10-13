import Foundation
import Testing
@testable import DriverrCore

private func makeIdentity(name: String) -> SSHIdentity {
  SSHIdentity(name: name, publicKeyBlob: Data("public-\(name)".utf8))
}

private func makeKey(_ byte: UInt8) -> SSHPrivateKey {
  SSHPrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
}

@Suite("InMemoryIdentityStore")
struct IdentityStoreTests {
  @Test("a stored identity comes back in the list")
  func storesAndLists() async throws {
    let store = InMemoryIdentityStore()
    let identity = makeIdentity(name: "laptop")
    try await store.add(identity, privateKey: makeKey(1))

    let listed = try await store.identities()
    #expect(listed.map(\.id) == [identity.id])
  }

  @Test("identities are listed newest first, so a just-made key is at the top")
  func listsNewestFirst() async throws {
    let store = InMemoryIdentityStore()
    let older = SSHIdentity(
      name: "older",
      publicKeyBlob: Data("a".utf8),
      createdAt: Date(timeIntervalSince1970: 1000)
    )
    let newer = SSHIdentity(
      name: "newer",
      publicKeyBlob: Data("b".utf8),
      createdAt: Date(timeIntervalSince1970: 2000)
    )
    try await store.add(older, privateKey: makeKey(1))
    try await store.add(newer, privateKey: makeKey(2))

    let listed = try await store.identities()
    #expect(listed.map(\.name) == ["newer", "older"])
  }

  @Test("the private key can be fetched back by identity id")
  func fetchesPrivateKey() async throws {
    let store = InMemoryIdentityStore()
    let identity = makeIdentity(name: "laptop")
    try await store.add(identity, privateKey: makeKey(7))

    let key = try await store.privateKey(for: identity.id)
    #expect(key == makeKey(7))
  }

  @Test("asking for an unknown identity's key throws rather than returning nothing")
  func unknownKeyThrows() async {
    let store = InMemoryIdentityStore()
    await #expect(throws: AppError.self) {
      try await store.privateKey(for: UUID())
    }
  }

  @Test("deleting removes both the identity and its key")
  func deleteRemovesKey() async throws {
    let store = InMemoryIdentityStore()
    let identity = makeIdentity(name: "laptop")
    try await store.add(identity, privateKey: makeKey(1))
    try await store.delete(identity.id)

    #expect(try await store.identities().isEmpty)
    await #expect(throws: AppError.self) {
      try await store.privateKey(for: identity.id)
    }
  }
}
