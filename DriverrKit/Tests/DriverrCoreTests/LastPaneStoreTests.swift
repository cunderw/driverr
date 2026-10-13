import Foundation
import Testing

@testable import DriverrCore

/// The contract every `LastPaneStore` owes, pinned against the in-memory one.
/// `UserDefaultsLastPaneStore` makes the same claims.
@Suite("Last pane per host")
struct LastPaneStoreTests {
  private let workbox = UUID(uuidString: "00000000-0000-0000-0000-00000000D701")!
  private let laptop = UUID(uuidString: "00000000-0000-0000-0000-00000000D702")!

  /// `Pane.sessionWitness` is herdr's terminal id when it reports one.
  private func record(_ paneID: String, _ witness: String = "term_a1") -> LastPaneRecord {
    LastPaneRecord(paneID: paneID, witness: witness)
  }

  @Test("a host nobody has opened a pane on has no record")
  func anUnknownHostHasNoRecord() async {
    let store = InMemoryLastPaneStore()
    #expect(await store.lastPane(forHost: workbox) == nil)
  }

  @Test("the pane written is the pane read back")
  func aWriteIsReadBack() async {
    let store = InMemoryLastPaneStore()
    await store.setLastPane(record("w1:p1"), forHost: workbox)
    #expect(await store.lastPane(forHost: workbox) == record("w1:p1"))
  }

  /// `BlockedPaneActivityRoute.resumed` checks the witness against the tree.
  @Test("the witness written is the witness read back")
  func theWitnessSurvivesTheRoundTrip() async {
    let store = InMemoryLastPaneStore()
    await store.setLastPane(record("w1:p1", "term_1a2b"), forHost: workbox)
    #expect(await store.lastPane(forHost: workbox)?.witness == "term_1a2b")
  }

  @Test("a second pane on the same host replaces the first")
  func aSecondPaneReplacesTheFirst() async {
    let store = InMemoryLastPaneStore()
    await store.setLastPane(record("w1:p1"), forHost: workbox)
    await store.setLastPane(record("w2:p3", "term_b2"), forHost: workbox)
    #expect(await store.lastPane(forHost: workbox) == record("w2:p3", "term_b2"))
  }

  /// herdr's pane ids are unique within a session only, so two machines both have `w1:p1`.
  @Test("two hosts keep their own records")
  func twoHostsKeepTheirOwn() async {
    let store = InMemoryLastPaneStore()
    await store.setLastPane(record("w1:p1", "term_a1"), forHost: workbox)
    await store.setLastPane(record("w1:p2", "term_b2"), forHost: laptop)
    #expect(await store.lastPane(forHost: workbox) == record("w1:p1", "term_a1"))
    #expect(await store.lastPane(forHost: laptop) == record("w1:p2", "term_b2"))
  }

  /// Closing the pane, opening the plain shell and deleting the host all write `nil`.
  @Test("nil forgets the host's record")
  func nilForgets() async {
    let store = InMemoryLastPaneStore()
    await store.setLastPane(record("w1:p1"), forHost: workbox)
    await store.setLastPane(nil, forHost: workbox)
    #expect(await store.lastPane(forHost: workbox) == nil)
  }

  /// Both conformances must agree. The mirror is
  /// `UserDefaultsLastPaneStoreTests.anEmptyHalfIsNotStored`.
  @Test("an empty pane id forgets the record rather than storing it")
  func anEmptyPaneIDForgets() async {
    let store = InMemoryLastPaneStore()
    await store.setLastPane(record("w1:p1"), forHost: workbox)

    await store.setLastPane(record(""), forHost: workbox)

    #expect(await store.lastPane(forHost: workbox) == nil)
  }

  /// A blank witness cannot be compared against the tree, so the resume would match on the
  /// pane id alone.
  @Test("an empty witness forgets the record rather than storing it")
  func anEmptyWitnessForgets() async {
    let store = InMemoryLastPaneStore()
    await store.setLastPane(record("w1:p1"), forHost: workbox)

    await store.setLastPane(record("w1:p1", ""), forHost: workbox)

    #expect(await store.lastPane(forHost: workbox) == nil)
  }

  /// A UI launch given a blank `-uiTestingLastPane` behaves like one given none.
  @Test("an empty pane id written to a fresh host stores nothing")
  func anEmptyPaneIDOnAFreshHostStoresNothing() async {
    let store = InMemoryLastPaneStore()

    await store.setLastPane(record(""), forHost: workbox)

    #expect(await store.lastPane(forHost: workbox) == nil)
  }

  /// UI runs use an in-memory store, so seeding is how they get a record.
  @Test("a seeded store answers without a write")
  func aSeededStoreAnswers() async {
    let store = InMemoryLastPaneStore(seeded: [workbox: record("w1:p1")])
    #expect(await store.lastPane(forHost: workbox) == record("w1:p1"))
    #expect(await store.lastPane(forHost: laptop) == nil)
  }

  /// Seeds follow the write's rule, so a fixture cannot hand a UI run an uncheckable record.
  @Test("a seeded record with an empty half is not seeded at all")
  func anUnresumableSeedIsDropped() async {
    let store = InMemoryLastPaneStore(
      seeded: [workbox: record("w1:p1", ""), laptop: record("", "term_b2")])
    #expect(await store.lastPane(forHost: workbox) == nil)
    #expect(await store.lastPane(forHost: laptop) == nil)
  }
}
