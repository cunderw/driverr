import Foundation
import Testing

@testable import DriverrCore

/// When a connecting host is offered Driverr's hooks: once per host, never again after a
/// decline, and once more for a new hook set version.
@Suite("Hook offer policy and store")
struct HookOfferStoreTests {
  private let workbox = UUID(uuidString: "00000000-0000-0000-0000-00000000C001")!
  private let laptop = UUID(uuidString: "00000000-0000-0000-0000-00000000C002")!
  private let agent = AgentIntegration.claudeCode.agent

  private func offer(_ stored: HookOfferState?, _ host: AgentIntegrationStatus, version: Int = 1) -> Bool {
    HookOfferPolicy.shouldOffer(stored: stored, hostStatus: host, currentVersion: version)
  }

  @Test("a host never asked, without the hooks, is asked")
  func firstConnectAsks() {
    #expect(offer(nil, .absent))
    #expect(offer(nil, .outdated))
  }

  @Test("a host that already has the hooks is never asked, whatever was stored")
  func installedHostIsNotAsked() {
    #expect(!offer(nil, .installed))
    #expect(!offer(.offered(version: 0), .installed))
  }

  @Test("an offer already shown for this version is not shown again")
  func askedOnce() {
    #expect(!offer(.offered(version: 1), .absent))
  }

  @Test("a decline is never asked again, not even for a later version")
  func declineIsFinal() {
    #expect(!offer(.declined, .absent))
    #expect(!offer(.declined, .outdated, version: 2))
    #expect(!offer(.declined, .absent, version: 9))
  }

  @Test("a new hook set version is offered once to a host that installed or was offered an earlier one")
  func versionBumpOffersOnce() {
    #expect(offer(.installed(version: 1), .outdated, version: 2))
    #expect(offer(.offered(version: 1), .absent, version: 2))
    #expect(!offer(.offered(version: 2), .outdated, version: 2))
  }

  @Test("a host that installed this version and lost the hooks since is not asked again")
  func removedByHandIsNotAsked() {
    #expect(!offer(.installed(version: 1), .absent))
  }

  /// The whole connect-time sequence against the store: shown, declined, a version bump,
  /// and a second host that is unaffected.
  @Test("the store drives the asked-once and version-bump rules per host")
  func storeSequence() async {
    let store = InMemoryHookOfferStore()
    #expect(await store.state(forHost: workbox, agent: agent) == nil)
    #expect(offer(await store.state(forHost: workbox, agent: agent), .absent))

    await store.setState(.offered(version: 1), forHost: workbox, agent: agent)
    #expect(!offer(await store.state(forHost: workbox, agent: agent), .absent))

    await store.setState(.installed(version: 1), forHost: workbox, agent: agent)
    #expect(!offer(await store.state(forHost: workbox, agent: agent), .outdated, version: 1))
    #expect(offer(await store.state(forHost: workbox, agent: agent), .outdated, version: 2))

    await store.setState(.declined, forHost: workbox, agent: agent)
    #expect(!offer(await store.state(forHost: workbox, agent: agent), .outdated, version: 3))

    #expect(await store.state(forHost: laptop, agent: agent) == nil)
    #expect(await store.state(forHost: workbox, agent: "codex") == nil)

    await store.setState(nil, forHost: workbox, agent: agent)
    #expect(await store.state(forHost: workbox, agent: agent) == nil)
  }

  @Test("a seeded decline reads back")
  func seeded() async {
    let store = InMemoryHookOfferStore(seeded: [.init(hostID: workbox, agent: agent): .declined])
    #expect(await store.state(forHost: workbox, agent: agent) == .declined)
  }

  @Test("the state round-trips through JSON")
  func codable() throws {
    for state in [HookOfferState.offered(version: 3), .declined, .installed(version: 2)] {
      let data = try JSONEncoder().encode(state)
      #expect(try JSONDecoder().decode(HookOfferState.self, from: data) == state)
    }
  }
}
