import Foundation
import Testing

@testable import DriverrCore

private func pane(_ id: String, status: AgentStatus) -> Pane {
  Pane(
    id: id,
    tabID: "t1",
    workspaceID: "w1",
    title: id,
    agent: Agent(name: "Claude", status: status)
  )
}

private func tree(_ panes: [Pane]) -> SessionTree {
  SessionTree(workspaces: [
    Workspace(
      id: "w1", number: 1, label: "one",
      tabs: [Tab(id: "t1", workspaceID: "w1", number: 1, label: "a", panes: panes)]
    )
  ])
}

@Suite("BlockedPaneAlerts")
struct BlockedPaneAlertsTests {
  @Test("a pane that has newly gone blocked is announced once")
  func newlyBlockedIsAnnounced() {
    var alerts = BlockedPaneAlerts()

    let outcome = alerts.update(
      to: tree([pane("p1", status: .working), pane("p2", status: .blocked)]),
      isAppActive: false
    )

    #expect(outcome.newlyBlocked.map(\.id) == ["p2"])
    #expect(outcome.announce.map(\.id) == ["p2"])
    #expect(outcome.clear.isEmpty)
    #expect(alerts.announced == ["p2"])
  }

  @Test("a pane that was already blocked is not announced again")
  func alreadyBlockedIsSilent() {
    var alerts = BlockedPaneAlerts()
    let blocked = tree([pane("p1", status: .blocked)])
    _ = alerts.update(to: blocked, isAppActive: false)

    let second = alerts.update(to: blocked, isAppActive: false)

    #expect(second.isEmpty)
    #expect(alerts.announced == ["p1"])
  }

  @Test("blocked, then working, then blocked again is a second announcement")
  func reblockingAnnouncesAgain() {
    var alerts = BlockedPaneAlerts()
    _ = alerts.update(to: tree([pane("p1", status: .blocked)]), isAppActive: false)

    let unblocked = alerts.update(to: tree([pane("p1", status: .working)]), isAppActive: false)
    let reblocked = alerts.update(to: tree([pane("p1", status: .blocked)]), isAppActive: false)

    #expect(unblocked.announce.isEmpty)
    #expect(unblocked.clear == ["p1"])
    #expect(reblocked.announce.map(\.id) == ["p1"])
    #expect(reblocked.clear.isEmpty)
  }

  @Test("a pane that leaves the tree drops its dedupe state and clears its card")
  func aPaneLeavingTheTreeIsForgotten() {
    var alerts = BlockedPaneAlerts()
    _ = alerts.update(to: tree([pane("p1", status: .blocked)]), isAppActive: false)

    let gone = alerts.update(to: .empty, isAppActive: false)

    #expect(gone.clear == ["p1"])
    #expect(alerts.announced.isEmpty)

    // herdr reuses ids, so a reused id is a different pane.
    let reused = alerts.update(to: tree([pane("p1", status: .blocked)]), isAppActive: false)
    #expect(reused.announce.map(\.id) == ["p1"])
  }

  @Test("a pane that blocks while the app is active is recorded and announced to nobody")
  func activeSuppressesButRecords() {
    var alerts = BlockedPaneAlerts()

    let outcome = alerts.update(to: tree([pane("p1", status: .blocked)]), isAppActive: true)

    #expect(outcome.announce.isEmpty)
    // Recorded, so the app can ask for permission while the user is looking.
    #expect(outcome.newlyBlocked.map(\.id) == ["p1"])
    #expect(alerts.announced == ["p1"])

    // Backgrounding afterwards must not turn it into a notification.
    let backgrounded = alerts.update(to: tree([pane("p1", status: .blocked)]), isAppActive: false)
    #expect(backgrounded.isEmpty)
  }

  @Test("clear names every id that stopped being blocked, in a stable order")
  func clearNamesTheRightIDs() {
    var alerts = BlockedPaneAlerts()
    _ = alerts.update(
      to: tree([
        pane("p3", status: .blocked), pane("p1", status: .blocked),
        pane("p2", status: .blocked),
      ]),
      isAppActive: false
    )

    let outcome = alerts.update(
      to: tree([
        pane("p3", status: .done), pane("p1", status: .blocked), pane("p2", status: .idle),
      ]),
      isAppActive: false
    )

    #expect(outcome.clear == ["p2", "p3"])
    #expect(outcome.announce.isEmpty)
    #expect(alerts.announced == ["p1"])
  }

  @Test("a shell pane can never be blocked, so it is never announced")
  func shellsAreNeverAnnounced() {
    var alerts = BlockedPaneAlerts()

    let outcome = alerts.update(
      to: tree([Pane(id: "p1", tabID: "t1", workspaceID: "w1", title: "zsh")]),
      isAppActive: false
    )

    #expect(outcome.isEmpty)
    #expect(alerts.announced.isEmpty)
  }

  // MARK: - Surviving the process

  /// A `BGAppRefreshTask` launches cold, so without the persisted set every blocked pane
  /// would re-alert on each refresh.
  @Test("a restored set announces nothing for panes that were already blocked")
  func aRestoredSetDoesNotReannounce() {
    var alerts = BlockedPaneAlerts(announced: ["p1", "p2"])

    let outcome = alerts.update(
      to: tree([pane("p1", status: .blocked), pane("p2", status: .blocked)]),
      isAppActive: false
    )

    #expect(outcome.isEmpty)
    #expect(alerts.announced == ["p1", "p2"])
  }

  /// If this stops announcing, the test above passes for the wrong reason.
  @Test("the same tree met by an empty set is the burst the restore exists to stop")
  func anEmptySetAnnouncesTheWholeTree() {
    var alerts = BlockedPaneAlerts()

    let outcome = alerts.update(
      to: tree([pane("p1", status: .blocked), pane("p2", status: .blocked)]),
      isAppActive: false
    )

    #expect(outcome.announce.map(\.id).sorted() == ["p1", "p2"])
  }

  /// Answered elsewhere while the phone slept, so the card comes down on the next refresh.
  @Test("a restored id that is no longer blocked is cleared")
  func aRestoredIDThatUnblockedIsCleared() {
    var alerts = BlockedPaneAlerts(announced: ["p1"])

    let outcome = alerts.update(to: tree([pane("p1", status: .working)]), isAppActive: false)

    #expect(outcome.clear == ["p1"])
    #expect(outcome.announce.isEmpty)
    #expect(alerts.announced.isEmpty)
  }

  @Test("the notification id carries the host, so two machines' p1 are two cards")
  func notificationIDIsUniqueAcrossHosts() {
    let one = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let two = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    #expect(
      BlockedPaneAlerts.notificationID(hostID: one, paneID: "w1:p1")
        == "blocked:11111111-1111-1111-1111-111111111111:w1:p1"
    )
    #expect(
      BlockedPaneAlerts.notificationID(hostID: one, paneID: "w1:p1")
        != BlockedPaneAlerts.notificationID(hostID: two, paneID: "w1:p1")
    )
  }
}
