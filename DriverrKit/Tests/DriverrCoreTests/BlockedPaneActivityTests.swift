import Foundation
import Testing

@testable import DriverrCore

@Suite("Live Activity content contract")
struct BlockedPaneActivityTests {
  private let now = Date(timeIntervalSince1970: 1_000_000)
  private let workbox = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
  private let buildbox = UUID(uuidString: "22222222-0000-0000-0000-000000000002")!

  private func host(
    _ hostID: UUID, name: String, counts: AgentStatusCounts = AgentStatusCounts()
  ) -> BlockedPaneActivityAttributes.HostSummary {
    BlockedPaneActivityAttributes.HostSummary(hostID: hostID, hostName: name, counts: counts)
  }

  private func escalated(count: Int = 1, agent: String? = "Claude")
    -> BlockedPaneActivityAttributes.ContentState
  {
    BlockedPaneActivityAttributes.ContentState(
      hosts: [host(workbox, name: "workbox", counts: AgentStatusCounts(blocked: count))],
      blocked: BlockedPaneActivityAttributes.BlockedPaneSummary(
        hostID: workbox, hostName: "workbox", paneID: "p1", paneTitle: "Fix tests",
        agentName: agent),
      lastConfirmedAt: now)
  }

  private func calm(_ counts: AgentStatusCounts) -> BlockedPaneActivityAttributes.ContentState {
    BlockedPaneActivityAttributes.ContentState(
      hosts: [host(workbox, name: "workbox", counts: counts)], lastConfirmedAt: now)
  }

  @Test("observations expire at twice the occasional refresh interval")
  func expiry() {
    let state = escalated()
    #expect(state.staleDate == now.addingTimeInterval(2 * BackgroundRefreshPolicy.interval))
    #expect(!state.isStale(at: now.addingTimeInterval(1799)))
    #expect(state.isStale(at: now.addingTimeInterval(1800)))
  }

  // MARK: - Calm copy

  private func line(_ names: [String]) -> String {
    BlockedPaneActivityAttributes.ContentState(
      hosts: names.map { host(UUID(), name: $0) }, lastConfirmedAt: now
    ).hostsLine
  }

  /// "2 hosts" says nothing about which, and that is what a calm card exists to say.
  @Test("a calm card names its hosts")
  func theHostsLineNamesThem() {
    #expect(calm(AgentStatusCounts()).hostsLine == "workbox")
    #expect(line(["workbox", "buildbox"]) == "workbox · buildbox")
    #expect(line(["workbox", "buildbox", "sandbox"]) == "workbox · buildbox · sandbox")
    let two = BlockedPaneActivityAttributes.ContentState(
      hosts: [host(workbox, name: "workbox"), host(buildbox, name: "buildbox")],
      lastConfirmedAt: now)
    #expect(two.headline(isStale: false) == "workbox · buildbox")
  }

  /// Past three hosts, or past a conservative character budget, a count beats a half-named
  /// host. `DriverrCore` has no text metrics.
  @Test("the count is the fallback past three hosts or past the line budget")
  func theHostsLineFallsBackToACount() {
    #expect(line(["a", "b", "c", "d"]) == "4 hosts")
    #expect(
      line(["workbox-with-a-long-name", "buildbox-with-a-long-name"]) == "2 hosts",
      "two names too long for the headline's two lines fall back to the count")
    #expect(
      BlockedPaneActivityAttributes.ContentState(hosts: [], lastConfirmedAt: now).hostsLine
        == "No hosts",
      "no pass produces this, but a payload from another build could decode to it")
  }

  @Test("the calm card words the counts and carries no pane caption")
  func theCalmCard() {
    let state = calm(AgentStatusCounts(done: 1, working: 2, idle: 1, shells: 2))
    #expect(state.needsYou == false)
    #expect(state.blockedCount == 0)
    #expect(state.headline(isStale: false) == "workbox")
    #expect(state.detail(isStale: false) == "2 working · 1 finished · 1 idle · 2 shells")
    #expect(state.context == nil)
  }

  @Test("a host with nothing running still says it is connected")
  func aHostWithNothingRunning() {
    #expect(calm(AgentStatusCounts()).detail(isStale: false) == "Connected")
  }

  @Test("the counts line sums every host on the card")
  func theCountsLineSumsHosts() {
    let state = BlockedPaneActivityAttributes.ContentState(
      hosts: [
        host(workbox, name: "workbox", counts: AgentStatusCounts(working: 2, idle: 1)),
        host(buildbox, name: "buildbox", counts: AgentStatusCounts(done: 1, working: 1)),
      ],
      lastConfirmedAt: now)
    #expect(state.detail(isStale: false) == "3 working · 1 finished · 1 idle")
    #expect(state.headline(isStale: false) == "workbox · buildbox")
  }

  // MARK: - Escalated copy

  @Test("single and multiple copy retain host and pane context")
  func freshCopy() {
    #expect(escalated().headline(isStale: false) == "Needs you")
    #expect(escalated().detail(isStale: false) == "Claude is waiting")
    #expect(escalated(agent: nil).detail(isStale: false) == "Agent is waiting")
    #expect(escalated(agent: "  ").detail(isStale: false) == "Agent is waiting")
    #expect(escalated().context == "workbox · Fix tests")
    #expect(escalated(count: 3).headline(isStale: false) == "3 panes need you")
    #expect(escalated(count: 3).detail(isStale: false) == "on workbox")
  }

  @Test("stale copy cannot assert that any pane still needs the user")
  func staleCopy() {
    for count in [1, 3] {
      #expect(escalated(count: count).headline(isStale: true) == "Status may have changed")
      #expect(escalated(count: count).detail(isStale: true) == "workbox · Fix tests")
    }
  }

  /// A calm card has no pane to caption.
  @Test("a stale calm card falls back to its counts")
  func aStaleCalmCard() {
    let state = calm(AgentStatusCounts(working: 2))
    #expect(state.headline(isStale: true) == "Status may have changed")
    #expect(state.detail(isStale: true) == "2 working")
  }

  // MARK: - The wire

  @Test("the activity payload round trips with its hosts and confirmation time")
  func coding() throws {
    let attributes = BlockedPaneActivityAttributes(hostID: UUID())
    #expect(
      try JSONDecoder().decode(
        BlockedPaneActivityAttributes.self, from: JSONEncoder().encode(attributes)) == attributes)
    for original in [escalated(count: 3), calm(AgentStatusCounts(working: 2, shells: 1))] {
      #expect(
        try JSONDecoder().decode(
          BlockedPaneActivityAttributes.ContentState.self,
          from: JSONEncoder().encode(original)) == original)
    }
  }

  @Test("a host on a card written before core ids decodes with none")
  func hostSummaryWithoutACoreID() throws {
    let json = #"""
      {"hostID":"11111111-0000-0000-0000-000000000001","hostName":"workbox",
      "counts":{"blocked":0,"done":0,"working":0,"idle":0,"unknown":0,"shells":0}}
      """#
    let host = try JSONDecoder().decode(
      BlockedPaneActivityAttributes.HostSummary.self, from: Data(json.utf8))
    #expect(host.coreID == nil)

    let carried = BlockedPaneActivityAttributes.HostSummary(
      hostID: host.hostID, hostName: host.hostName, counts: host.counts, coreID: "core-a")
    #expect(
      try JSONDecoder().decode(
        BlockedPaneActivityAttributes.HostSummary.self, from: JSONEncoder().encode(carried))
        == carried)
  }

  /// Derived on decode, so a payload cannot claim a stale date that contradicts it.
  @Test("a payload cannot carry a stale date that contradicts its confirmation time")
  func staleDateIsDerivedNotDecoded() throws {
    let encoded = try JSONEncoder().encode(escalated())
    var payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(payload["staleDate"] == nil)
    payload["staleDate"] = 4_000_000_000.0
    let tampered = try JSONSerialization.data(withJSONObject: payload)
    let decoded = try JSONDecoder().decode(
      BlockedPaneActivityAttributes.ContentState.self, from: tampered)
    #expect(decoded.staleDate == now.addingTimeInterval(2 * BackgroundRefreshPolicy.interval))
  }

  /// A hand-written payload in the old shape, not a round trip through this build's encoder.
  /// A state that will not decode is a card the driver cannot see to end.
  /// `theShippedBuildsCardIsEndedAndReplaced` covers what happens next.
  @Test("a card from the shipped build decodes as the one-host escalated card it is")
  func theOldFlatShapeDecodes() throws {
    let json = """
      {
        "hostName": "workbox",
        "paneID": "w1:p2",
        "paneTitle": "needs a decision",
        "agentName": "Claude",
        "blockedCount": 3,
        "lastConfirmedAt": 1000000
      }
      """
    let decoded = try JSONDecoder().decode(
      BlockedPaneActivityAttributes.ContentState.self, from: Data(json.utf8))
    #expect(decoded.hosts.count == 1)
    #expect(decoded.hosts[0].hostName == "workbox")
    #expect(decoded.hosts[0].counts.blocked == 3)
    #expect(decoded.blockedCount == 3)
    #expect(decoded.needsYou)
    #expect(decoded.blocked?.paneID == "w1:p2")
    #expect(decoded.blocked?.agentName == "Claude")
    #expect(decoded.headline(isStale: false) == "3 panes need you")
    #expect(decoded.lastConfirmedAt == Date(timeIntervalSinceReferenceDate: 1_000_000))
    #expect(decoded.staleDate == decoded.lastConfirmedAt.addingTimeInterval(
      2 * BackgroundRefreshPolicy.interval))
  }

  /// The old build kept the host id in the attributes, where a `Decoder` cannot reach it.
  /// The reconciler ends such a card on its first pass.
  @Test("an old-shape card carries a host id that names nobody")
  func theOldShapeHasNoHostID() throws {
    let json = """
      {"hostName":"workbox","paneID":"p","paneTitle":"t","blockedCount":1,
       "lastConfirmedAt":1000000}
      """
    let decoded = try JSONDecoder().decode(
      BlockedPaneActivityAttributes.ContentState.self, from: Data(json.utf8))
    #expect(decoded.hosts[0].hostID == UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
    #expect(decoded.blocked?.agentName == nil)
  }

  /// A calm card is the ordinary state.
  @Test("a card with nothing blocked is an ordinary payload")
  func zeroBlockedIsRepresentable() throws {
    let json = """
      {"hosts":[{"hostID":"11111111-0000-0000-0000-000000000001","hostName":"workbox",
       "counts":{"blocked":0,"done":0,"working":2,"idle":0,"unknown":0,"shells":0}}],
       "lastConfirmedAt":1000000}
      """
    let decoded = try JSONDecoder().decode(
      BlockedPaneActivityAttributes.ContentState.self, from: Data(json.utf8))
    #expect(decoded.blockedCount == 0)
    #expect(decoded.needsYou == false)
    #expect(decoded.detail(isStale: false) == "2 working")
  }

  @Test("only the new shape is written")
  func onlyTheNewShapeIsEncoded() throws {
    let encoded = try JSONEncoder().encode(calm(AgentStatusCounts(working: 1)))
    let payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(payload["hosts"] != nil)
    #expect(payload["hostName"] == nil)
    #expect(payload["blockedCount"] == nil)
    #expect(payload["blocked"] == nil)
  }
}
