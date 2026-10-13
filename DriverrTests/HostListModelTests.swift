import DriverrCore
import DriverrSSH
import Foundation
import Testing

@testable import Driverr

/// What deleting a host actually removes.
///
/// Against the real Keychain, so the claim is that the secret is gone, not that a call was
/// made.
@MainActor
@Suite("HostListModel", .serialized)
struct HostListModelTests {
  private let workbox = DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson")

  private func keychain() -> KeychainPasswordStore {
    KeychainPasswordStore(service: "com.cunderw.driverr.tests.hostlist.\(UUID().uuidString)")
  }

  /// A deleted host's password and trusted key go with it. A leftover password is a secret no
  /// screen can delete. The trusted key is stored by hostname, so a leftover one would be
  /// inherited by whatever is later saved at that address.
  @Test("deleting a host takes its Keychain password and its trusted key with it")
  func deleteClearsWhatTheHostLeftBehind() async throws {
    let passwords = keychain()
    defer { try? passwords.deleteAll() }
    let knownHosts = InMemoryKnownHostsStore(
      seeded: [workbox.hostname: FakeSSHTransport.defaultHostKey]
    )
    try await passwords.save("hunter2", for: workbox.id)

    // The last-pane record too, or a key per deleted host accumulates in the defaults.
    let lastPanes = InMemoryLastPaneStore(
      seeded: [workbox.id: LastPaneRecord(paneID: "w1:p1", witness: "term_w1p1")])

    let model = HostListModel(
      store: InMemoryHostStore(seeded: [workbox]),
      knownHosts: knownHosts,
      credentials: PasswordCredentials(store: passwords),
      lastPanes: lastPanes,
      hookOffers: InMemoryHookOfferStore(),
      announcedPanes: InMemoryAnnouncedPaneStore()
    )
    await model.load()
    #expect(model.hosts.count == 1)

    await model.delete(workbox)

    #expect(model.hosts.isEmpty)
    #expect(try await passwords.password(for: workbox.id) == nil, "the secret is still here")
    #expect(await knownHosts.trustedKey(for: workbox.hostname) == nil)
    #expect(await lastPanes.lastPane(forHost: workbox.id) == nil, "the resume record stayed")
    #expect(model.errorMessage == nil)
  }

  /// The announced set is one defaults key per host, and nothing else removes it once the
  /// host is gone. Against the real store and a throwaway suite, so the claim is that the key
  /// is gone. The key is found by the host's id, so the test does not repeat the store's
  /// prefix.
  @Test("deleting a host removes its announced-panes key from the defaults")
  func deleteRemovesTheAnnouncedPanes() async throws {
    let suite = "driverr.tests.hostlist.announced.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let announced = UserDefaultsAnnouncedPaneStore(suiteName: suite)
    await announced.setAnnouncedPanes(["w1:p1"], forHost: workbox.id)
    func keysNamingTheHost() -> [String] {
      (UserDefaults(suiteName: suite)?.persistentDomain(forName: suite) ?? [:]).keys
        .filter { $0.contains(workbox.id.uuidString) }
    }
    #expect(keysNamingTheHost().count == 1, "the fixture wrote no key, so the test proves nothing")

    let model = HostListModel(
      store: InMemoryHostStore(seeded: [workbox]),
      knownHosts: InMemoryKnownHostsStore(),
      credentials: PasswordCredentials(store: InMemoryPasswordStore()),
      lastPanes: InMemoryLastPaneStore(),
      hookOffers: InMemoryHookOfferStore(),
      announcedPanes: announced
    )
    await model.load()

    await model.delete(workbox)

    #expect(model.hosts.isEmpty)
    #expect(keysNamingTheHost() == [], "the deleted host's announced set stayed in the defaults")
    #expect(await announced.announcedPanes(forHost: workbox.id).isEmpty)
    #expect(model.errorMessage == nil)
  }

  /// Deleting one host must not touch another's credentials.
  ///
  /// The password is keyed by host id and the trusted key by hostname, so a deletion that used
  /// the wrong key would still pass the test above.
  @Test("deleting one host leaves another host's password and key alone")
  func deleteIsNotShared() async throws {
    let edge = DriverrCore.Host(name: "edge-01", hostname: "10.1.0.99", username: "root")
    let passwords = keychain()
    defer { try? passwords.deleteAll() }
    let knownHosts = InMemoryKnownHostsStore(
      seeded: [
        workbox.hostname: FakeSSHTransport.defaultHostKey,
        edge.hostname: FakeSSHTransport.defaultHostKey,
      ]
    )
    try await passwords.save("hunter2", for: workbox.id)
    try await passwords.save("correcthorse", for: edge.id)

    let model = HostListModel(
      store: InMemoryHostStore(seeded: [workbox, edge]),
      knownHosts: knownHosts,
      credentials: PasswordCredentials(store: passwords),
      lastPanes: InMemoryLastPaneStore(),
      hookOffers: InMemoryHookOfferStore(),
      announcedPanes: InMemoryAnnouncedPaneStore()
    )
    await model.load()

    await model.delete(workbox)

    #expect(try await passwords.password(for: edge.id) == "correcthorse")
    #expect(await knownHosts.trustedKey(for: edge.hostname) != nil)
  }

  /// The trusted key is stored by hostname alone, so two saved hosts that name one machine
  /// share it. Deleting one of them must leave the other trusted, or its next
  /// connect asks again about a key the user already accepted.
  @Test("deleting one of two hosts with the same hostname keeps the shared trusted key")
  func deleteKeepsTrustAnotherHostUses() async throws {
    let workboxAsRoot = DriverrCore.Host(
      name: "workbox (root)", hostname: workbox.hostname, port: 2222, username: "root")
    let passwords = keychain()
    defer { try? passwords.deleteAll() }
    let knownHosts = InMemoryKnownHostsStore(
      seeded: [workbox.hostname: FakeSSHTransport.defaultHostKey]
    )

    let model = HostListModel(
      store: InMemoryHostStore(seeded: [workbox, workboxAsRoot]),
      knownHosts: knownHosts,
      credentials: PasswordCredentials(store: passwords),
      lastPanes: InMemoryLastPaneStore(),
      hookOffers: InMemoryHookOfferStore(),
      announcedPanes: InMemoryAnnouncedPaneStore()
    )
    await model.load()

    await model.delete(workbox)

    #expect(model.hosts.map(\.id) == [workboxAsRoot.id])
    #expect(
      await knownHosts.trustedKey(for: workbox.hostname) != nil,
      "the other host's trust went with the deleted one")

    await model.delete(workboxAsRoot)

    #expect(await knownHosts.trustedKey(for: workbox.hostname) == nil)
  }
}
