import Foundation

/// Which pane a host was last opened on, and what proves it is still the same pane.
///
/// A herdr pane id alone is not an identity: ids are positional, so a rebuilt session puts a
/// different pane behind `w1:p2`. `witness` is a value the pane reports that a rebuilt
/// session does not reproduce (`Pane.sessionWitness`). herdr's `session.snapshot` has no
/// session id to bind to, and workspace ids are positional too, so identity is per pane.
///
/// `Codable` for `UserDefaultsLastPaneStore`. An older record stored as a bare `String` under
/// the same key reads as `nil` from `UserDefaults.data(forKey:)`, so it is simply absent.
public struct LastPaneRecord: Codable, Equatable, Sendable {
  /// herdr's pane id, `w1:p2`.
  public let paneID: String
  /// What `Pane.sessionWitness` said about that pane when it was opened.
  public let witness: String

  public init(paneID: String, witness: String) {
    self.paneID = paneID
    self.witness = witness
  }
}

/// Which pane each host was last opened on, stored so it outlives the process.
///
/// The calm Live Activity card's tap often launches the app cold, so an in-memory note would
/// be useless to it. Keyed by host id, because pane ids repeat across hosts. The store does
/// not decide whether the pane is still worth opening; `BlockedPaneActivityRoute.resumed`
/// checks that against the tree at the tap.
public protocol LastPaneStore: Sendable {
  func lastPane(forHost hostID: UUID) async -> LastPaneRecord?
  /// `nil` forgets the host's record: opening the plain shell, closing the remembered pane,
  /// or deleting the host.
  ///
  /// An empty `paneID` or `witness` must also remove the record, in every conformance. Neither
  /// can be resumed or compared, so storing one would look for a pane called "" or resume on a
  /// check that proves nothing.
  func setLastPane(_ record: LastPaneRecord?, forHost hostID: UUID) async
}

/// Whether a record is worth storing: both halves non-empty. Shared so the conformances
/// agree.
extension LastPaneRecord {
  public var isResumable: Bool { !paneID.isEmpty && !witness.isEmpty }
}

#if DEBUG
/// A non-persistent `LastPaneStore` for tests, previews and UI runs, so no UI test carries a
/// remembered pane into the next launch. `seeded` gives a UI test a record to resume from.
public actor InMemoryLastPaneStore: LastPaneStore {
  private var panes: [UUID: LastPaneRecord]

  /// The seed follows the write rule: a record with an empty half is dropped, so a blank
  /// `-uiTestingLastPane` acts like none.
  public init(seeded: [UUID: LastPaneRecord] = [:]) {
    panes = seeded.filter { $0.value.isResumable }
  }

  public func lastPane(forHost hostID: UUID) async -> LastPaneRecord? {
    panes[hostID]
  }

  public func setLastPane(_ record: LastPaneRecord?, forHost hostID: UUID) async {
    // `nil` or an empty half removes, matching `UserDefaultsLastPaneStore`.
    guard let record, record.isResumable else {
      panes[hostID] = nil
      return
    }
    panes[hostID] = record
  }
}
#endif
