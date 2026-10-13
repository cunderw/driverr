import DriverrCore
import Foundation
import Testing

/// The trusted key is stored by hostname, so deleting a host forgets it only when no other
/// saved host names the same machine.
@Suite("Known hosts shared by hostname")
struct KnownHostsSharingTests {
  private let workbox = DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson")
  private let key = SSHHostKey(algorithm: "ssh-ed25519", blob: Data("alpha".utf8))

  @Test("another host with the same hostname shares the key, whatever its port and user")
  func sameHostnameShares() {
    let asRoot = DriverrCore.Host(
      name: "root", hostname: workbox.hostname, port: 2222, username: "root")
    #expect([workbox, asRoot].sharesHostname(with: workbox))
  }

  @Test("the host itself does not count, so the list may still contain it")
  func selfIsExcluded() {
    #expect(![workbox].sharesHostname(with: workbox))
    #expect(![DriverrCore.Host]().sharesHostname(with: workbox))
  }

  @Test("a different hostname does not share, even on the same port and user")
  func differentHostnameDoesNotShare() {
    let edge = DriverrCore.Host(name: "edge", hostname: "10.1.0.99", username: workbox.username)
    #expect(![workbox, edge].sharesHostname(with: workbox))
  }

  @Test("hostnames match exactly, as the store keys them")
  func matchIsExact() {
    let upper = DriverrCore.Host(name: "upper", hostname: "WORKBOX.local", username: "carson")
    let lower = DriverrCore.Host(name: "lower", hostname: "workbox.local", username: "carson")
    #expect(![upper].sharesHostname(with: lower))
  }

  @Test("forgetting a host another host shares keeps the key")
  func sharedHostKeepsTheKey() async {
    let asRoot = DriverrCore.Host(
      name: "root", hostname: workbox.hostname, port: 2222, username: "root")
    let store = InMemoryKnownHostsStore(seeded: [workbox.hostname: key])

    await store.forget(workbox, unlessUsedBy: [asRoot])

    #expect(await store.trustedKey(for: workbox.hostname) == key)
  }

  @Test("forgetting the last host with that hostname removes the key")
  func lastHostRemovesTheKey() async {
    let edge = DriverrCore.Host(name: "edge", hostname: "10.1.0.99", username: "root")
    let store = InMemoryKnownHostsStore(seeded: [workbox.hostname: key, edge.hostname: key])

    await store.forget(workbox, unlessUsedBy: [edge])

    #expect(await store.trustedKey(for: workbox.hostname) == nil)
    #expect(await store.trustedKey(for: edge.hostname) == key)
  }
}
