import Foundation

/// Which panes have newly gone blocked since the last poll, and which notifications should
/// come down.
///
/// It takes a `SessionTree`, so the live poll and a background refresh get the same answers.
/// One per host, because herdr's pane ids are unique only within a session.
public struct BlockedPaneAlerts: Equatable, Sendable {
  /// What one poll asks the app tier to do.
  public struct Outcome: Equatable, Sendable {
    /// Every pane that went from not-blocked to blocked in this update.
    ///
    /// Separate from `announce`, which is empty while the app is active. The observation
    /// still tells the app tier that asking for notification permission is now fair. See
    /// `BlockedPaneNotifier` in the app target.
    public var newlyBlocked: [Pane]
    /// The panes to post a notification for: `newlyBlocked`, or nothing at all while the
    /// app is active.
    public var announce: [Pane]
    /// Pane ids whose notification should be withdrawn: the pane stopped being blocked or
    /// left the session. Answered elsewhere, closed or renamed all look the same, and all
    /// mean the question is no longer being asked. Sorted, so a poll's result is
    /// deterministic.
    public var clear: [String]

    public init(newlyBlocked: [Pane] = [], announce: [Pane] = [], clear: [String] = []) {
      self.newlyBlocked = newlyBlocked
      self.announce = announce
      self.clear = clear
    }

    public var isEmpty: Bool { newlyBlocked.isEmpty && announce.isEmpty && clear.isEmpty }
  }

  /// The panes this host has been told about and not seen unblock since. Readable so tests
  /// can assert the recorded-but-not-announced case.
  public private(set) var announced: Set<String> = []

  public init() {}

  /// Picks up where a previous process left off.
  ///
  /// A background refresh launches the app cold. Built with `init()`, it would find every
  /// blocked pane newly blocked and re-alert all of them. The ids are host pane ids, not
  /// notification identifiers; see `notificationID(hostID:paneID:)`.
  public init(announced: Set<String>) {
    self.announced = announced
  }

  /// Folds one poll's tree in, and says what the app tier should do about it.
  ///
  /// The rules:
  ///
  /// - A blocked pane not in `announced` is newly blocked.
  /// - A pane already in `announced` is not announced again, or a three-second poll would
  ///   post twenty cards a minute.
  /// - Blocked, then working, then blocked again is a second announcement: the agent asked a
  ///   new question.
  /// - A pane that leaves the tree leaves the set, so a reused pane id starts clean.
  /// - With `isAppActive`, ids are recorded and nothing is announced. The user saw it, and
  ///   it must not notify later when the phone locks.
  public mutating func update(to tree: SessionTree, isAppActive: Bool) -> Outcome {
    let blocked = tree.blockedPanes
    let blockedIDs = Set(blocked.map(\.id))

    let newlyBlocked = blocked.filter { !announced.contains($0.id) }
    let clear = announced.subtracting(blockedIDs).sorted()

    announced = blockedIDs

    return Outcome(
      newlyBlocked: newlyBlocked,
      announce: isAppActive ? [] : newlyBlocked,
      clear: clear
    )
  }

  /// The notification identifier for one pane on one host.
  ///
  /// Unique across hosts, which a pane id is not (`w1:p1` exists on every host). Built here
  /// because the poll posts it and the terminal presenter withdraws it.
  public static func notificationID(hostID: UUID, paneID: String) -> String {
    "blocked:\(hostID.uuidString):\(paneID)"
  }
}
