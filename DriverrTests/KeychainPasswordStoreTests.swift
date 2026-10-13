@testable import Driverr
import DriverrCore
import Foundation
import Testing

/// Exercises the real iOS Keychain — see `KeychainIdentityStoreTests` for why that is
/// only possible from this app-hosted bundle.
@Suite("KeychainPasswordStore", .serialized)
struct KeychainPasswordStoreTests {
  private func makeStore() -> KeychainPasswordStore {
    KeychainPasswordStore(service: "com.cunderw.driverr.tests.pw.\(UUID().uuidString)")
  }

  @Test("a saved password reads back unchanged")
  func roundTrips() async throws {
    let store = makeStore()
    defer { try? store.deleteAll() }
    let host = UUID()

    try await store.save("hunter2", for: host)

    #expect(try await store.password(for: host) == "hunter2")
  }

  @Test("a host with no saved password returns nil rather than throwing")
  func missingPasswordIsNil() async throws {
    let store = makeStore()
    // Absence is a normal state — it means "ask the user" — so it must not be an error.
    #expect(try await store.password(for: UUID()) == nil)
  }

  @Test("saving twice replaces rather than duplicating or failing")
  func saveReplaces() async throws {
    let store = makeStore()
    defer { try? store.deleteAll() }
    let host = UUID()

    try await store.save("old", for: host)
    try await store.save("new", for: host)

    #expect(try await store.password(for: host) == "new")
  }

  @Test("deleting removes the password")
  func deleteRemoves() async throws {
    let store = makeStore()
    defer { try? store.deleteAll() }
    let host = UUID()
    try await store.save("hunter2", for: host)

    try await store.delete(for: host)

    #expect(try await store.password(for: host) == nil)
  }

  @Test("passwords are kept per host")
  func perHost() async throws {
    let store = makeStore()
    defer { try? store.deleteAll() }
    let first = UUID()
    let second = UUID()

    try await store.save("first", for: first)
    try await store.save("second", for: second)

    #expect(try await store.password(for: first) == "first")
    #expect(try await store.password(for: second) == "second")
  }

  @Test("declining to remember leaves nothing in the real Keychain")
  func promptEveryTimeWritesNothingToKeychain() async throws {
    // The consent rule proven against real storage, not just the in-memory fake.
    let store = makeStore()
    defer { try? store.deleteAll() }
    let host = UUID()
    let credentials = PasswordCredentials(store: store)

    try await credentials.remember("hunter2", for: host, persistence: .promptEveryTime)

    #expect(try await store.password(for: host) == nil)
  }
}
