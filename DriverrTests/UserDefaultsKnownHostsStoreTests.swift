@testable import Driverr
import DriverrCore
import Foundation
import Testing

private func key(_ seed: String) -> SSHHostKey {
  SSHHostKey(algorithm: "ssh-ed25519", blob: Data(seed.utf8))
}

/// A throwaway suite name per test, so one test can never see another's trusted hosts
/// and nothing leaks into the app's real defaults.
private func makeSuiteName() -> String {
  "driverr.tests.knownhosts.\(UUID().uuidString)"
}

private func cleanUp(_ suiteName: String) {
  UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
}

@Suite("UserDefaultsKnownHostsStore", .serialized)
struct UserDefaultsKnownHostsStoreTests {
  @Test("a trusted key reads back")
  func trustRoundTrips() async {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    let store = UserDefaultsKnownHostsStore(suiteName: suite)

    await store.trust(key("alpha"), for: "10.1.0.9")

    #expect(await store.trustedKey(for: "10.1.0.9") == key("alpha"))
  }

  @Test("trusted keys survive a fresh store, which is what surviving a launch means")
  func persistsAcrossInstances() async {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }

    await UserDefaultsKnownHostsStore(suiteName: suite).trust(key("alpha"), for: "10.1.0.9")

    // A new store over the same suite stands in for a relaunch: nothing carries over in memory.
    let reopened = UserDefaultsKnownHostsStore(suiteName: suite)
    #expect(await reopened.trustedKey(for: "10.1.0.9") == key("alpha"))
  }

  @Test("an unknown host has no trusted key")
  func unknownHostIsNil() async {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }

    #expect(await UserDefaultsKnownHostsStore(suiteName: suite).trustedKey(for: "nowhere") == nil)
  }

  @Test("forgetting a host removes it, and that survives too")
  func forgetPersists() async {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    let store = UserDefaultsKnownHostsStore(suiteName: suite)
    await store.trust(key("alpha"), for: "10.1.0.9")

    await store.forget("10.1.0.9")

    let reopened = UserDefaultsKnownHostsStore(suiteName: suite)
    #expect(await reopened.trustedKey(for: "10.1.0.9") == nil)
  }

  @Test("hosts are stored independently")
  func hostsIndependent() async {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    let store = UserDefaultsKnownHostsStore(suiteName: suite)

    await store.trust(key("alpha"), for: "a")
    await store.trust(key("beta"), for: "b")

    #expect(await store.trustedKey(for: "a") == key("alpha"))
    #expect(await store.trustedKey(for: "b") == key("beta"))
  }

  @Test("a corrupt store reads as empty rather than breaking the connect flow")
  func corruptStoreIsEmpty() async {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    UserDefaults(suiteName: suite)?
      .set(Data("not json".utf8), forKey: "com.cunderw.driverr.knownHosts")

    // Re-prompting on first contact is safe; refusing to load at all would brick it.
    #expect(await UserDefaultsKnownHostsStore(suiteName: suite).trustedKey(for: "a") == nil)
  }
}
