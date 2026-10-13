import Foundation
import Testing
@testable import DriverrCore

private func makeHost(_ name: String, hostname: String = "10.1.0.9") -> DriverrCore.Host {
  DriverrCore.Host(name: name, hostname: hostname, port: 22, username: "carson")
}

@Suite("InMemoryHostStore")
struct HostStoreTests {
  @Test("an added host is listed")
  func addsAndLists() async throws {
    let store = InMemoryHostStore()
    let host = makeHost("workbox")

    try await store.save(host)

    #expect(try await store.hosts().map(\.id) == [host.id])
  }

  @Test("saving an existing host updates it rather than adding a duplicate")
  func saveUpdatesInPlace() async throws {
    let store = InMemoryHostStore()
    var host = makeHost("workbox")
    try await store.save(host)

    host.name = "renamed"
    try await store.save(host)

    let hosts = try await store.hosts()
    #expect(hosts.count == 1)
    #expect(hosts.first?.name == "renamed")
  }

  @Test("hosts are listed in a stable order, so the list does not shuffle")
  func stableOrder() async throws {
    let store = InMemoryHostStore()
    let first = makeHost("alpha", hostname: "10.0.0.1")
    let second = makeHost("beta", hostname: "10.0.0.2")
    try await store.save(first)
    try await store.save(second)

    // A list that reorders on save moves under the user's finger.
    try await store.save(first)

    #expect(try await store.hosts().map(\.name) == ["alpha", "beta"])
  }

  @Test("deleting removes the host")
  func deletes() async throws {
    let store = InMemoryHostStore()
    let host = makeHost("workbox")
    try await store.save(host)

    try await store.delete(host.id)

    #expect(try await store.hosts().isEmpty)
  }

  @Test("deleting a host that is not there is not an error")
  func deleteUnknownIsHarmless() async throws {
    let store = InMemoryHostStore()
    // Deleting twice is an ordinary UI race.
    try await store.delete(UUID())
  }
}

@Suite("Host auth settings")
struct HostAuthSettingsTests {
  @Test("a new host defaults to password auth, since it has no key yet")
  func defaultsToPassword() {
    #expect(makeHost("workbox").authMethod == .password)
  }

  @Test("a host can be pointed at a specific identity")
  func canUseAnIdentity() {
    let identityID = UUID()
    let host = DriverrCore.Host(
      name: "workbox",
      hostname: "10.1.0.9",
      username: "carson",
      authMethod: .identity(identityID)
    )
    #expect(host.authMethod == .identity(identityID))
  }

  @Test("the herdr socket path is optional and empty by default")
  func herdrSocketPathDefaultsToNil() {
    #expect(makeHost("workbox").herdrSocketPath == nil)
  }

  @Test("a host round-trips through Codable with its auth settings intact")
  func codableRoundTrip() throws {
    let identityID = UUID()
    let host = DriverrCore.Host(
      name: "workbox",
      hostname: "10.1.0.9",
      port: 2222,
      username: "carson",
      authMethod: .identity(identityID),
      herdrSocketPath: "/run/herdr.sock"
    )

    let decoded = try JSONDecoder().decode(DriverrCore.Host.self, from: JSONEncoder().encode(host))

    #expect(decoded == host)
    #expect(decoded.authMethod == .identity(identityID))
    #expect(decoded.herdrSocketPath == "/run/herdr.sock")
  }

  @Test("a host saved before auth settings existed still decodes")
  func decodesLegacyHostWithoutAuthFields() throws {
    // Older builds wrote hosts without these keys; a decode failure would lose the list.
    let json = """
      {"id":"\(UUID().uuidString)","name":"old","hostname":"10.1.0.9","port":22,
       "username":"carson"}
      """
    let decoded = try JSONDecoder().decode(DriverrCore.Host.self, from: Data(json.utf8))
    #expect(decoded.authMethod == .password)
    #expect(decoded.herdrSocketPath == nil)
  }
}
