@testable import Driverr
import DriverrCore
import Foundation
import Testing

/// A throwaway suite name per test, so one test can never see another's record and nothing
/// leaks into the app's real defaults.
private func makeSuiteName() -> String {
  "driverr.tests.lastpane.\(UUID().uuidString)"
}

private func cleanUp(_ suiteName: String) {
  UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
}

/// The persisted last-pane store. `LastPaneStoreTests` pins the contract against the in-memory
/// store; this adds surviving the process, which the cold-launch tap depends on.
@Suite("UserDefaultsLastPaneStore", .serialized)
struct UserDefaultsLastPaneStoreTests {
  private let workbox = UUID(uuidString: "00000000-0000-0000-0000-00000000D701")!
  private let laptop = UUID(uuidString: "00000000-0000-0000-0000-00000000D702")!

  private func record(_ paneID: String, _ witness: String = "term_a1") -> LastPaneRecord {
    LastPaneRecord(paneID: paneID, witness: witness)
  }

  private func key(for hostID: UUID) -> String {
    "com.cunderw.driverr.lastPane.\(hostID.uuidString)"
  }

  @Test("a host with no record answers nil")
  func anUnknownHostAnswersNil() async {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    #expect(await UserDefaultsLastPaneStore(suiteName: suite).lastPane(forHost: workbox) == nil)
  }

  /// A second store over the same defaults is the next launch, and it has to find the record.
  @Test("a record survives into another store over the same defaults")
  func aRecordSurvivesTheProcess() async {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }

    await UserDefaultsLastPaneStore(suiteName: suite)
      .setLastPane(record("w1:p1", "term_1a2b"), forHost: workbox)

    let reopened = UserDefaultsLastPaneStore(suiteName: suite)
    #expect(await reopened.lastPane(forHost: workbox) == record("w1:p1", "term_1a2b"))
  }

  /// One key per host, so two hosts' writes cannot land on each other, as in
  /// `UserDefaultsAnnouncedPaneStore`.
  @Test("two hosts keep their own records")
  func twoHostsKeepTheirOwn() async {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    let store = UserDefaultsLastPaneStore(suiteName: suite)

    await store.setLastPane(record("w1:p1", "term_a1"), forHost: workbox)
    await store.setLastPane(record("w1:p2", "term_b2"), forHost: laptop)

    #expect(await store.lastPane(forHost: workbox) == record("w1:p1", "term_a1"))
    #expect(await store.lastPane(forHost: laptop) == record("w1:p2", "term_b2"))
  }

  /// `nil` removes the key rather than storing an empty value, so a host nobody has a pane
  /// open on leaves nothing behind for the life of the install.
  @Test("nil removes the key from the defaults")
  func nilRemovesTheKey() async {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    let store = UserDefaultsLastPaneStore(suiteName: suite)
    await store.setLastPane(record("w1:p1"), forHost: workbox)

    await store.setLastPane(nil, forHost: workbox)

    #expect(await store.lastPane(forHost: workbox) == nil)
    let domain = UserDefaults(suiteName: suite)?.persistentDomain(forName: suite) ?? [:]
    #expect(
      !domain.keys.contains { $0.contains(workbox.uuidString) },
      "a key for a host with no record is still in the defaults"
    )
  }

  /// A record with an empty pane id or an empty witness is not stored, so a later read finds
  /// nothing rather than a pane called "" or a check that proves nothing.
  @Test("a record with an empty half is not stored")
  func anEmptyHalfIsNotStored() async {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    let store = UserDefaultsLastPaneStore(suiteName: suite)

    await store.setLastPane(record("", "term_a1"), forHost: workbox)
    await store.setLastPane(record("w1:p1", ""), forHost: laptop)

    #expect(await store.lastPane(forHost: workbox) == nil)
    #expect(await store.lastPane(forHost: laptop) == nil)
  }

  /// The migration. An older record is a bare `String` under this key, and
  /// `UserDefaults.data(forKey:)` answers `nil` for it, so it reads as absent and the reader
  /// gets the host's tree. Read as a record, it would resume a pane with no witness to check.
  @Test("a record left by the old build reads as absent rather than matching")
  func anOldShapeRecordReadsAsAbsent() async {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    UserDefaults(suiteName: suite)?.set("w1:p1", forKey: key(for: workbox))

    #expect(await UserDefaultsLastPaneStore(suiteName: suite).lastPane(forHost: workbox) == nil)
  }

  /// The next write replaces it in the new shape.
  @Test("a write over an old-shape value replaces it")
  func aWriteReplacesAnOldShapeValue() async {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    UserDefaults(suiteName: suite)?.set("w1:p1", forKey: key(for: workbox))
    let store = UserDefaultsLastPaneStore(suiteName: suite)

    await store.setLastPane(record("w1:p2", "term_b2"), forHost: workbox)

    #expect(await store.lastPane(forHost: workbox) == record("w1:p2", "term_b2"))
  }

  /// Anything else this build cannot decode reads as absent too, for
  /// `BlockedPaneActivityRoute.target(of:)`'s reason.
  @Test("an undecodable value reads as no record")
  func anUndecodableValueIsNoRecord() async {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    UserDefaults(suiteName: suite)?.set(Data([0x7b, 0x21]), forKey: key(for: workbox))

    #expect(await UserDefaultsLastPaneStore(suiteName: suite).lastPane(forHost: workbox) == nil)
  }
}
