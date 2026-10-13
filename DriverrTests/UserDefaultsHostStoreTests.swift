@testable import Driverr
import DriverrCore
import Foundation
import Testing

private func makeSuiteName() -> String { "driverr.tests.hosts.\(UUID().uuidString)" }

private func cleanUp(_ suiteName: String) {
  UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
}

@Suite("UserDefaultsHostStore", .serialized)
struct UserDefaultsHostStoreTests {
  private func host(_ name: String) -> DriverrCore.Host {
    DriverrCore.Host(name: name, hostname: "10.1.0.9", username: "carson")
  }

  @Test("a saved host reads back")
  func savesAndReads() async throws {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    let store = UserDefaultsHostStore(suiteName: suite)

    try await store.save(host("workbox"))

    #expect(try await store.hosts().map(\.name) == ["workbox"])
  }

  @Test("hosts survive a fresh store, which is what surviving a launch means")
  func persistsAcrossInstances() async throws {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    try await UserDefaultsHostStore(suiteName: suite).save(host("workbox"))

    let reopened = UserDefaultsHostStore(suiteName: suite)

    #expect(try await reopened.hosts().map(\.name) == ["workbox"])
  }

  @Test("auth settings persist with the host")
  func persistsAuthSettings() async throws {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    let identity = UUID()
    let configured = DriverrCore.Host(
      name: "workbox",
      hostname: "10.1.0.9",
      port: 2222,
      username: "carson",
      authMethod: .identity(identity),
      herdrSocketPath: "/run/herdr.sock"
    )
    try await UserDefaultsHostStore(suiteName: suite).save(configured)

    let reopened = try await UserDefaultsHostStore(suiteName: suite).hosts().first

    #expect(reopened?.authMethod == .identity(identity))
    #expect(reopened?.port == 2222)
    #expect(reopened?.herdrSocketPath == "/run/herdr.sock")
  }

  @Test("editing a host updates it in place instead of duplicating")
  func editUpdatesInPlace() async throws {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    let store = UserDefaultsHostStore(suiteName: suite)
    var existing = host("workbox")
    try await store.save(existing)

    existing.name = "renamed"
    try await store.save(existing)

    let all = try await store.hosts()
    #expect(all.count == 1)
    #expect(all.first?.name == "renamed")
  }

  @Test("deleting removes the host, and that survives too")
  func deletePersists() async throws {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    let store = UserDefaultsHostStore(suiteName: suite)
    let existing = host("workbox")
    try await store.save(existing)

    try await store.delete(existing.id)

    #expect(try await UserDefaultsHostStore(suiteName: suite).hosts().isEmpty)
  }

  @Test("a corrupt list reads as empty rather than failing at launch")
  func corruptListIsEmpty() async throws {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    UserDefaults(suiteName: suite)?.set(Data("nope".utf8), forKey: "com.cunderw.driverr.hosts")

    #expect(try await UserDefaultsHostStore(suiteName: suite).hosts().isEmpty)
  }
}
