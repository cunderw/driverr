import Foundation
import Testing

@testable import DriverrCore

@Suite("Live Activity reconciler")
struct BlockedPaneActivityPlanTests {
  private let now = Date(timeIntervalSince1970: 1_000_000)
  private let workbox = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
  private let buildbox = UUID(uuidString: "22222222-0000-0000-0000-000000000002")!
  private let sandbox = UUID(uuidString: "33333333-0000-0000-0000-000000000003")!
  private let cardA = UUID(uuidString: "aaaaaaaa-0000-0000-0000-00000000000a")!
  private let cardB = UUID(uuidString: "bbbbbbbb-0000-0000-0000-00000000000b")!

  /// `ContentState` derives this from `BackgroundRefreshPolicy.interval`.
  private var staleWindow: TimeInterval { 2 * BackgroundRefreshPolicy.interval }

  private func blocked(
    _ id: String, title: String = "needs a decision", agent: String? = "Claude"
  ) -> Pane {
    Pane(
      id: id, tabID: "t1", workspaceID: "w1", title: title,
      agent: Agent(name: agent ?? "Claude", status: .blocked))
  }

  private func seen(
    _ hostID: UUID,
    name: String = "workbox",
    connected: Bool = true,
    panes: [Pane] = [],
    counts: AgentStatusCounts? = nil,
    at offset: TimeInterval = 0
  ) -> HostActivityObservation {
    HostActivityObservation(
      hostID: hostID, hostName: name, isConnected: connected, blockedPanes: panes,
      counts: counts ?? AgentStatusCounts(blocked: panes.count, working: 2, idle: 1),
      observedAt: now.addingTimeInterval(offset))
  }

  private func host(
    _ hostID: UUID, name: String = "workbox", counts: AgentStatusCounts = AgentStatusCounts()
  ) -> BlockedPaneActivityAttributes.HostSummary {
    BlockedPaneActivityAttributes.HostSummary(hostID: hostID, hostName: name, counts: counts)
  }

  private func card(
    _ activityID: UUID,
    hosts: [BlockedPaneActivityAttributes.HostSummary],
    blocked: BlockedPaneActivityAttributes.BlockedPaneSummary? = nil,
    confirmedAt offset: TimeInterval = 0
  ) -> ExistingLiveActivity {
    ExistingLiveActivity(
      activityID: activityID,
      state: BlockedPaneActivityAttributes.ContentState(
        hosts: hosts, blocked: blocked, lastConfirmedAt: now.addingTimeInterval(offset)))
  }

  private func requested(_ actions: [LiveActivityAction])
    -> BlockedPaneActivityAttributes.ContentState?
  {
    for action in actions { if case .request(let state) = action { return state } }
    return nil
  }

  private func updated(_ actions: [LiveActivityAction])
    -> BlockedPaneActivityAttributes.ContentState?
  {
    for action in actions { if case .update(_, let state) = action { return state } }
    return nil
  }

  // MARK: - Who covers a machine

  @Test("a background pass is told the cores of the card's other hosts, not its own")
  func coveringCores() {
    let standing = card(
      cardA,
      hosts: [
        BlockedPaneActivityAttributes.HostSummary(
          hostID: workbox, hostName: "workbox", counts: AgentStatusCounts(), coreID: "core-a"),
        BlockedPaneActivityAttributes.HostSummary(
          hostID: buildbox, hostName: "buildbox", counts: AgentStatusCounts(), coreID: "core-b"),
        // The TUI, or a card an earlier build wrote.
        host(sandbox, name: "sandbox"),
      ])
    #expect(
      BlockedPaneActivityPlan.coreIDs(coveringHost: workbox, in: [standing]) == ["core-b"])
    #expect(BlockedPaneActivityPlan.coreIDs(coveringHost: workbox, in: []).isEmpty)
  }

  @Test("the card keeps each host's core, through a pass that only saw one of them")
  func coreIDsSurviveAScopedPass() throws {
    let observed = HostActivityObservation(
      hostID: workbox, hostName: "workbox", isConnected: true, blockedPanes: [],
      counts: AgentStatusCounts(), observedAt: now, coreID: "core-a")
    let standing = card(
      cardA,
      hosts: [
        BlockedPaneActivityAttributes.HostSummary(
          hostID: buildbox, hostName: "buildbox", counts: AgentStatusCounts(), coreID: "core-b"),
        host(workbox),
      ])
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [observed], scope: .oneHost(workbox), existing: [standing],
      preferences: LiveActivityPreferences(), canRequest: false, now: now)
    let state = try #require(updated(actions))
    #expect(state.hosts.map(\.coreID) == ["core-b", "core-a"])
  }

  // MARK: - The trigger
  // MARK: - The trigger

  @Test("a connected host with nothing blocked still gets a card")
  func connectIsTheTrigger() throws {
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox)], scope: .everyConnectedHost, existing: [],
      preferences: LiveActivityPreferences(), canRequest: true, now: now)
    let state = try #require(requested(actions))
    #expect(actions.count == 1)
    #expect(state.hosts.map(\.hostName) == ["workbox"])
    #expect(state.blocked == nil)
    #expect(state.needsYou == false)
    #expect(state.headline(isStale: false) == "workbox")
    #expect(state.detail(isStale: false) == "2 working · 1 idle")
  }

  /// The setting's footer states the trigger in words, so it has to agree with
  /// `connectIsTheTrigger`: a connection puts the card up, not a blocked pane.
  @Test("the setting's footer names the connection as the trigger")
  func theFooterNamesTheTrigger() {
    #expect(LiveActivityCopy.footer.contains("while a host is connected"))
    #expect(LiveActivityCopy.footer.contains("needs you") == false)
  }

  @Test("a host that is not connected is not on the card")
  func disconnectedHostsAreLeftOut() throws {
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox), seen(buildbox, name: "buildbox", connected: false)],
      scope: .everyConnectedHost, existing: [], preferences: LiveActivityPreferences(),
      canRequest: true, now: now)
    let state = try #require(requested(actions))
    #expect(state.hosts.map(\.hostName) == ["workbox"])
  }

  @Test("the last host disconnecting ends the card")
  func theLastDisconnectEndsIt() {
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox, connected: false)], scope: .everyConnectedHost,
      existing: [card(cardA, hosts: [host(workbox)])],
      preferences: LiveActivityPreferences(), canRequest: true, now: now)
    #expect(actions == [.end(activityID: cardA, .noConnectedHosts)])
  }

  @Test("nothing connected and no card is no action at all")
  func nothingConnectedAndNoCard() {
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [], scope: .everyConnectedHost, existing: [],
      preferences: LiveActivityPreferences(), canRequest: true, now: now)
    #expect(actions.isEmpty)
  }

  /// A card outlives the process that requested it, so a crashed build leaves one standing.
  /// `ContentView`'s `.task` pushes this pass at launch, before anything connects.
  @Test("a relaunch with nothing connected ends the card the last process left")
  func aRelaunchEndsAnOrphanedCard() {
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [], scope: .everyConnectedHost,
      existing: [card(cardA, hosts: [host(workbox)])],
      preferences: LiveActivityPreferences(), canRequest: true, now: now)
    #expect(actions == [.end(activityID: cardA, .noConnectedHosts)])
  }

  @Test("the background may never request a card")
  func theBackgroundNeverRequests() {
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox, panes: [blocked("w1:p2")])], scope: .oneHost(workbox),
      existing: [], preferences: LiveActivityPreferences(), canRequest: false, now: now)
    #expect(actions.isEmpty)
  }

  @Test("a request whose state is already stale is withheld")
  func aStaleRequestIsWithheld() {
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox, at: -staleWindow)], scope: .everyConnectedHost,
      existing: [], preferences: LiveActivityPreferences(), canRequest: true, now: now)
    #expect(actions.isEmpty)
  }

  // MARK: - One card for every host

  @Test("every connected host is on one card, sorted by name")
  func oneCardCarriesEveryHost() throws {
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [
        seen(sandbox, name: "sandbox"), seen(workbox, name: "workbox"),
        seen(buildbox, name: "buildbox"),
      ],
      scope: .everyConnectedHost, existing: [], preferences: LiveActivityPreferences(),
      canRequest: true, now: now)
    #expect(actions.count == 1)
    let state = try #require(requested(actions))
    #expect(state.hosts.map(\.hostName) == ["buildbox", "sandbox", "workbox"])
    #expect(state.hostsLine == "buildbox · sandbox · workbox")
    #expect(state.headline(isStale: false) == "buildbox · sandbox · workbox")
    #expect(state.detail(isStale: false) == "6 working · 3 idle")
  }

  @Test("the newest observation in the pass is what the card was last confirmed at")
  func confirmationIsTheNewestObservation() throws {
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox, at: -30), seen(buildbox, name: "buildbox", at: -5)],
      scope: .everyConnectedHost, existing: [], preferences: LiveActivityPreferences(),
      canRequest: true, now: now)
    let state = try #require(requested(actions))
    #expect(state.lastConfirmedAt == now.addingTimeInterval(-5))
  }

  // MARK: - Escalation

  @Test("any blocked pane escalates the card")
  func aBlockedPaneEscalates() throws {
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox, panes: [blocked("w1:p2"), blocked("w2:p9", title: "other")])],
      scope: .everyConnectedHost, existing: [], preferences: LiveActivityPreferences(),
      canRequest: true, now: now)
    let state = try #require(requested(actions))
    #expect(state.needsYou)
    #expect(state.blockedCount == 2)
    #expect(state.blocked?.paneID == "w1:p2")
    #expect(state.headline(isStale: false) == "2 panes need you")
    #expect(state.detail(isStale: false) == "on workbox")
  }

  @Test("one blocked pane names its agent and captions its host and pane")
  func oneBlockedPaneNamesItsAgent() throws {
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox, panes: [blocked("w1:p2")])], scope: .everyConnectedHost,
      existing: [], preferences: LiveActivityPreferences(), canRequest: true, now: now)
    let state = try #require(requested(actions))
    #expect(state.headline(isStale: false) == "Needs you")
    #expect(state.detail(isStale: false) == "Claude is waiting")
    #expect(state.context == "workbox · needs a decision")
  }

  @Test("the blocked pane the card names is the first in host-sort then tree order")
  func theBlockedPaneFollowsTheHostSort() throws {
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [
        seen(workbox, name: "workbox", panes: [blocked("w1:p2")]),
        seen(buildbox, name: "buildbox", panes: [blocked("b1:p1", title: "build waiting")]),
      ],
      scope: .everyConnectedHost, existing: [], preferences: LiveActivityPreferences(),
      canRequest: true, now: now)
    let state = try #require(requested(actions))
    #expect(state.blocked?.hostName == "buildbox")
    #expect(state.blocked?.paneID == "b1:p1")
    #expect(state.blockedCount == 2)
  }

  @Test("an opened pane de-escalates the card rather than ending it")
  func anOpenedPaneDeEscalates() throws {
    let existing = card(
      cardA, hosts: [host(workbox, counts: AgentStatusCounts(blocked: 1, working: 2, idle: 1))],
      blocked: BlockedPaneActivityAttributes.BlockedPaneSummary(
        hostID: workbox, hostName: "workbox", paneID: "w1:p2", paneTitle: "needs a decision",
        agentName: "Claude"))
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox, panes: [blocked("w1:p2")])], scope: .everyConnectedHost,
      existing: [existing], preferences: LiveActivityPreferences(), canRequest: true, now: now,
      openedPanes: [workbox: ["w1:p2"]])
    let state = try #require(updated(actions))
    #expect(actions.count == 1)
    #expect(state.blocked == nil)
    #expect(state.blockedCount == 0)
    #expect(state.headline(isStale: false) == "workbox")
  }

  @Test("opening one of two blocked panes leaves the card escalated and lowers its count")
  func openingOneOfTwoLowersTheCount() throws {
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox, panes: [blocked("w1:p2"), blocked("w2:p9", title: "other")])],
      scope: .everyConnectedHost, existing: [], preferences: LiveActivityPreferences(),
      canRequest: true, now: now, openedPanes: [workbox: ["w1:p2"]])
    let state = try #require(requested(actions))
    #expect(state.blockedCount == 1)
    #expect(state.blocked?.paneID == "w2:p9")
  }

  // MARK: - Preferences

  @Test("the setting off ends every card and requests nothing")
  func theSettingOffEndsEverything() {
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox, panes: [blocked("w1:p2")])], scope: .everyConnectedHost,
      existing: [card(cardB, hosts: [host(workbox)]), card(cardA, hosts: [host(buildbox)])],
      preferences: LiveActivityPreferences(isEnabled: false), canRequest: true, now: now)
    #expect(
      actions == [
        .end(activityID: cardA, .settingOff), .end(activityID: cardB, .settingOff),
      ])
  }

  @Test("a stopped host is left off the card and the others stay on it")
  func aStoppedHostIsLeftOff() throws {
    let preferences = LiveActivityPreferences(
      hostOverrides: [workbox.uuidString: false])
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox), seen(buildbox, name: "buildbox")],
      scope: .everyConnectedHost, existing: [], preferences: preferences,
      canRequest: true, now: now)
    let state = try #require(requested(actions))
    #expect(state.hosts.map(\.hostName) == ["buildbox"])
  }

  @Test("stopping the only connected host ends the card")
  func stoppingTheOnlyHostEndsTheCard() {
    let preferences = LiveActivityPreferences(hostOverrides: [workbox.uuidString: false])
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox)], scope: .everyConnectedHost,
      existing: [card(cardA, hosts: [host(workbox)])], preferences: preferences,
      canRequest: true, now: now)
    #expect(actions == [.end(activityID: cardA, .noConnectedHosts)])
  }

  @Test("a host nobody has touched follows the global setting")
  func anUntouchedHostFollowsTheGlobalSetting() {
    #expect(LiveActivityPreferences().isOn(for: workbox))
    #expect(LiveActivityPreferences(isEnabled: false).isOn(for: workbox) == false)
  }

  // MARK: - The upgrade path

  @Test("three per-host cards become one, the first adopted and the rest ended")
  func theUpgradeLeavesExactlyOneCard() throws {
    let cardC = UUID(uuidString: "cccccccc-0000-0000-0000-00000000000c")!
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox), seen(buildbox, name: "buildbox")],
      scope: .everyConnectedHost,
      existing: [
        card(cardC, hosts: [host(sandbox, name: "sandbox")]),
        card(cardA, hosts: [host(workbox)]),
        card(cardB, hosts: [host(buildbox, name: "buildbox")]),
      ],
      preferences: LiveActivityPreferences(), canRequest: true, now: now)
    #expect(actions.count == 3)
    #expect(actions[0] == .end(activityID: cardB, .replacedByOneCard))
    #expect(actions[1] == .end(activityID: cardC, .replacedByOneCard))
    guard case .update(let adopted, let state) = actions[2] else {
      Issue.record("expected the first card to be updated in place, got \(actions[2])")
      return
    }
    #expect(adopted == cardA)
    #expect(state.hosts.map(\.hostName) == ["buildbox", "workbox"])
  }

  @Test("nothing is requested while a card is being adopted")
  func adoptionNeverRequests() {
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox)], scope: .everyConnectedHost,
      existing: [card(cardA, hosts: [host(buildbox, name: "buildbox")])],
      preferences: LiveActivityPreferences(), canRequest: true, now: now)
    #expect(!actions.contains { if case .request = $0 { return true } else { return false } })
  }

  /// The placeholder host id an old-shape payload decodes to. Written out rather than read
  /// off the constant, so renaming the constant cannot change this assertion.
  private let noHostAtAll = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

  /// Decoded from the old flat payload, because the migration is a claim about what a
  /// `Decoder` produces.
  private func shippedBuildsCard(_ activityID: UUID) throws -> ExistingLiveActivity {
    let json = """
      {"hostName":"workbox","paneID":"w1:p2","paneTitle":"needs a decision",
       "agentName":"Claude","blockedCount":1,
       "lastConfirmedAt":\(now.timeIntervalSinceReferenceDate)}
      """
    let state = try JSONDecoder().decode(
      BlockedPaneActivityAttributes.ContentState.self, from: Data(json.utf8))
    // The old build kept the host id in the attributes, where a `Decoder` cannot reach it.
    #expect(state.hosts.map(\.hostID) == [noHostAtAll])
    return ExistingLiveActivity(activityID: activityID, state: state)
  }

  private func endedIDs(_ actions: [LiveActivityAction]) -> [UUID] {
    actions.compactMap { if case .end(let id, _) = $0 { return id } else { return nil } }
  }

  /// The placeholder host id routes nowhere, so the card is ended and requested again rather
  /// than adopted.
  @Test("the shipped build's card is ended and replaced, not adopted")
  func theShippedBuildsCardIsEndedAndReplaced() throws {
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox)], scope: .everyConnectedHost,
      existing: [try shippedBuildsCard(cardA)],
      preferences: LiveActivityPreferences(), canRequest: true, now: now)
    #expect(endedIDs(actions) == [cardA])
    #expect(actions.first == .end(activityID: cardA, .fromAnEarlierBuildsShape))
    let state = try #require(requested(actions))
    #expect(state.hosts.map(\.hostID) == [workbox])
    #expect(state.blocked == nil)
    #expect(actions.count == 2)
  }

  /// A background pass cannot request, so the card is gone until the next foreground pass.
  /// Adopting it instead would show the placeholder as an extra machine that opens nothing.
  @Test("a background pass ends the shipped build's card without replacing it")
  func theShippedBuildsCardIsEndedInTheBackgroundToo() throws {
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox)], scope: .oneHost(workbox),
      existing: [try shippedBuildsCard(cardA)],
      preferences: LiveActivityPreferences(), canRequest: false, now: now)
    #expect(actions == [.end(activityID: cardA, .fromAnEarlierBuildsShape)])
  }

  /// A `.oneHost` pass must not carry the placeholder over from the card it updates.
  @Test("no pass writes a state carrying the placeholder host id")
  func noWrittenStateCarriesThePlaceholder() throws {
    for canRequest in [true, false] {
      let actions = BlockedPaneActivityPlan.reconcile(
        observations: [seen(workbox)], scope: .oneHost(workbox),
        existing: [try shippedBuildsCard(cardA)],
        preferences: LiveActivityPreferences(), canRequest: canRequest, now: now)
      for state in [requested(actions), updated(actions)].compactMap({ $0 }) {
        #expect(!state.hosts.contains { $0.hostID == noHostAtAll })
        #expect(state.blocked?.hostID != noHostAtAll)
      }
    }
  }

  // MARK: - Scope

  @Test("a one-host pass carries the other hosts over from the card it is updating")
  func aOneHostPassCarriesTheOthersOver() throws {
    let existing = card(
      cardA,
      hosts: [
        host(buildbox, name: "buildbox", counts: AgentStatusCounts(working: 1)),
        host(workbox, name: "workbox", counts: AgentStatusCounts(working: 4)),
      ],
      confirmedAt: -staleWindow / 2)
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox, counts: AgentStatusCounts(working: 2, idle: 1))],
      scope: .oneHost(workbox), existing: [existing],
      preferences: LiveActivityPreferences(), canRequest: false, now: now)
    let state = try #require(updated(actions))
    #expect(state.hosts.map(\.hostName) == ["buildbox", "workbox"])
    #expect(state.totals.working == 3)
    #expect(state.lastConfirmedAt == now)
  }

  @Test("an authoritative pass drops a host the card was carrying")
  func anAuthoritativePassDropsAMissingHost() throws {
    let existing = card(
      cardA, hosts: [host(buildbox, name: "buildbox"), host(workbox)],
      confirmedAt: -staleWindow / 2)
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox)], scope: .everyConnectedHost, existing: [existing],
      preferences: LiveActivityPreferences(), canRequest: true, now: now)
    let state = try #require(updated(actions))
    #expect(state.hosts.map(\.hostName) == ["workbox"])
  }

  @Test("a one-host pass that confirms nothing leaves a fresh card alone")
  func aOneHostPassThatConfirmsNothingLeavesAFreshCard() {
    let existing = card(cardA, hosts: [host(buildbox, name: "buildbox")])
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox, connected: false)], scope: .oneHost(workbox),
      existing: [existing], preferences: LiveActivityPreferences(), canRequest: false, now: now)
    #expect(actions.isEmpty)
  }

  @Test("a one-host pass that confirms nothing ends a card past its stale date")
  func aOneHostPassEndsAnUnconfirmableStaleCard() {
    let existing = card(
      cardA, hosts: [host(buildbox, name: "buildbox")], confirmedAt: -staleWindow)
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox, connected: false)], scope: .oneHost(workbox),
      existing: [existing], preferences: LiveActivityPreferences(), canRequest: false, now: now)
    #expect(actions == [.end(activityID: cardA, .couldNotConfirm)])
  }

  @Test("a one-host pass drops a carried host the reader has since stopped")
  func aOneHostPassHonoursAStop() throws {
    let existing = card(
      cardA, hosts: [host(buildbox, name: "buildbox"), host(workbox)],
      confirmedAt: -staleWindow / 2)
    let preferences = LiveActivityPreferences(hostOverrides: [buildbox.uuidString: false])
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox)], scope: .oneHost(workbox), existing: [existing],
      preferences: preferences, canRequest: false, now: now)
    let state = try #require(updated(actions))
    #expect(state.hosts.map(\.hostName) == ["workbox"])
  }

  @Test("a one-host pass keeps another host's blocked pane on the card")
  func aOneHostPassKeepsAnotherHostsEscalation() throws {
    let existing = card(
      cardA,
      hosts: [
        host(buildbox, name: "buildbox", counts: AgentStatusCounts(blocked: 1)),
        host(workbox, counts: AgentStatusCounts(blocked: 1, working: 1)),
      ],
      blocked: BlockedPaneActivityAttributes.BlockedPaneSummary(
        hostID: buildbox, hostName: "buildbox", paneID: "b1:p1", paneTitle: "build waiting",
        agentName: "Codex"),
      confirmedAt: -staleWindow / 2)
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox, counts: AgentStatusCounts(working: 2))],
      scope: .oneHost(workbox), existing: [existing],
      preferences: LiveActivityPreferences(), canRequest: false, now: now)
    let state = try #require(updated(actions))
    #expect(state.blocked?.hostName == "buildbox")
    #expect(state.blockedCount == 1)
  }

  // MARK: - The throttle

  @Test("a timestamp alone is not worth a write until the refresh floor")
  func aTimestampAloneIsThrottled() {
    let hosts = [host(workbox, counts: AgentStatusCounts(blocked: 0, working: 2, idle: 1))]
    let existing = card(cardA, hosts: hosts, confirmedAt: -BlockedPaneActivityPlan.refreshFloor + 1)
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox)], scope: .everyConnectedHost, existing: [existing],
      preferences: LiveActivityPreferences(), canRequest: true, now: now)
    #expect(actions.isEmpty)
  }

  @Test("the refresh floor makes a timestamp-only write worth it")
  func theRefreshFloorWrites() {
    let hosts = [host(workbox, counts: AgentStatusCounts(blocked: 0, working: 2, idle: 1))]
    let existing = card(cardA, hosts: hosts, confirmedAt: -BlockedPaneActivityPlan.refreshFloor)
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox)], scope: .everyConnectedHost, existing: [existing],
      preferences: LiveActivityPreferences(), canRequest: true, now: now)
    #expect(actions.count == 1)
    #expect(updated(actions) != nil)
  }

  @Test("a host joining the card is written at once")
  func aNewHostIsWrittenAtOnce() throws {
    let hosts = [host(workbox, counts: AgentStatusCounts(blocked: 0, working: 2, idle: 1))]
    let existing = card(cardA, hosts: hosts)
    let actions = BlockedPaneActivityPlan.reconcile(
      observations: [seen(workbox), seen(buildbox, name: "buildbox")],
      scope: .everyConnectedHost, existing: [existing],
      preferences: LiveActivityPreferences(), canRequest: true, now: now)
    let state = try #require(updated(actions))
    #expect(state.hosts.count == 2)
  }
}
