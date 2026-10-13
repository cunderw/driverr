import Foundation
import Testing

@testable import DriverrCore

/// The Live Activity's routing rule. `DriverrWatch` holds no rule and applies whatever URL
/// this returns, so the one-versus-many choice is asserted here.
@Suite("Blocked-pane Live Activity route")
struct BlockedPaneActivityRouteTests {
  private let now = Date(timeIntervalSince1970: 1_000_000)
  private let hostID = UUID(uuidString: "00000000-0000-0000-0000-00000000D701")!

  private let otherHostID = UUID(uuidString: "00000000-0000-0000-0000-00000000D702")!

  private func host(_ id: UUID, name: String, blocked: Int = 0)
    -> BlockedPaneActivityAttributes.HostSummary
  {
    BlockedPaneActivityAttributes.HostSummary(
      hostID: id, hostName: name, counts: AgentStatusCounts(blocked: blocked))
  }

  private func escalated(count: Int, paneID: String = "w1:p2")
    -> BlockedPaneActivityAttributes.ContentState
  {
    BlockedPaneActivityAttributes.ContentState(
      hosts: [host(hostID, name: "workbox", blocked: count)],
      blocked: BlockedPaneActivityAttributes.BlockedPaneSummary(
        hostID: hostID, hostName: "workbox", paneID: paneID, paneTitle: "needs a decision",
        agentName: "Claude"),
      lastConfirmedAt: now)
  }

  // MARK: - Which destination a card carries

  @Test("one blocked pane opens that pane")
  func oneBlockedPaneOpensThePane() {
    #expect(
      BlockedPaneActivityRoute.target(of: escalated(count: 1))
        == .pane(hostID: hostID, paneID: "w1:p2")
    )
  }

  /// The rule `SessionTree.loneBlockedPane` records for the host list's badge. With several
  /// blocked panes, a guess would open the wrong conversation.
  @Test("several blocked panes open the host's tree")
  func severalBlockedPanesOpenTheHost() {
    #expect(BlockedPaneActivityRoute.target(of: escalated(count: 2)) == .host(hostID: hostID))
    #expect(BlockedPaneActivityRoute.target(of: escalated(count: 9)) == .host(hostID: hostID))
  }

  /// Not reachable from the driver, and it must not produce a URL that parses to nothing.
  @Test("a lone blocked pane with no id falls back to the host")
  func aLonePaneWithNoIDFallsBackToTheHost() {
    #expect(
      BlockedPaneActivityRoute.target(of: escalated(count: 1, paneID: ""))
        == .host(hostID: hostID)
    )
  }

  /// The host comes off the state, not the attributes. The card speaks for every connected
  /// host, so a tap lands on the one that needs you.
  @Test("a tap opens the host that needs you, not the first on the card")
  func theTapOpensTheHostThatNeedsYou() {
    let state = BlockedPaneActivityAttributes.ContentState(
      hosts: [host(hostID, name: "buildbox"), host(otherHostID, name: "workbox", blocked: 2)],
      blocked: BlockedPaneActivityAttributes.BlockedPaneSummary(
        hostID: otherHostID, hostName: "workbox", paneID: "w1:p2",
        paneTitle: "needs a decision", agentName: "Claude"),
      lastConfirmedAt: now)
    #expect(BlockedPaneActivityRoute.target(of: state) == .host(hostID: otherHostID))
  }

  @Test("a calm card opens the first host on it")
  func aCalmCardOpensTheFirstHost() {
    let state = BlockedPaneActivityAttributes.ContentState(
      hosts: [host(hostID, name: "buildbox"), host(otherHostID, name: "workbox")],
      lastConfirmedAt: now)
    #expect(BlockedPaneActivityRoute.target(of: state) == .host(hostID: hostID))
    #expect(
      BlockedPaneActivityRoute.url(for: state)?.absoluteString
        == "driverr://host?host=00000000-0000-0000-0000-00000000D701")
  }

  /// No pass produces an empty card, but a payload from another build could decode to one.
  @Test("a card with no hosts routes nowhere")
  func aCardWithNoHostsRoutesNowhere() {
    let state = BlockedPaneActivityAttributes.ContentState(hosts: [], lastConfirmedAt: now)
    #expect(BlockedPaneActivityRoute.target(of: state) == nil)
    #expect(BlockedPaneActivityRoute.url(for: state) == nil)
  }

  // MARK: - The URL itself

  @Test("the two URL shapes are what the Info.plist scheme registers")
  func urlShapes() {
    #expect(
      BlockedPaneActivityRoute.url(for: .pane(hostID: hostID, paneID: "w1:p2")).absoluteString
        == "driverr://pane?host=00000000-0000-0000-0000-00000000D701&pane=w1:p2"
    )
    #expect(
      BlockedPaneActivityRoute.url(for: .host(hostID: hostID)).absoluteString
        == "driverr://host?host=00000000-0000-0000-0000-00000000D701"
    )
  }

  @Test("both targets survive the round trip")
  func roundTrip() {
    for target in [
      BlockedPaneActivityRoute.Target.pane(hostID: hostID, paneID: "w1:p2"),
      .host(hostID: hostID),
    ] {
      #expect(BlockedPaneActivityRoute.target(of: BlockedPaneActivityRoute.url(for: target))
        == target)
    }
  }

  /// herdr pane ids are unconstrained. `&` or `=` would split a hand-built query and `%`
  /// would fail the parse, so both directions percent-encode. `+` is not a space in a query
  /// component and must survive.
  @Test("a pane id full of query metacharacters round-trips")
  func ahostilePaneIDRoundTrips() {
    for paneID in ["a&b", "a=b", "a+b", "100%", "two words", "w1:p2?x#y", "π/√2"] {
      let url = BlockedPaneActivityRoute.url(for: .pane(hostID: hostID, paneID: paneID))
      #expect(
        BlockedPaneActivityRoute.target(of: url) == .pane(hostID: hostID, paneID: paneID),
        "'\(paneID)' did not survive \(url.absoluteString)"
      )
    }
  }

  // MARK: - What a card this build does not understand does

  /// A card outlives the build that posted it, so an unrecognised URL returns `nil`, as
  /// `NotificationTapRouter.route(userInfo:)` does for an old notification.
  @Test("anything unrecognised is nil")
  func unrecognisedURLsAreNil() {
    let unrecognised = [
      "https://pane?host=00000000-0000-0000-0000-00000000D701&pane=w1:p2",
      "driverr://tab?host=00000000-0000-0000-0000-00000000D701",
      "driverr://?host=00000000-0000-0000-0000-00000000D701",
      "driverr://host",
      "driverr://host?host=",
      "driverr://host?host=workbox",
      "driverr://pane?pane=w1:p2",
      "driverr://pane?host=00000000-0000-0000-0000-00000000D701",
      "driverr://pane?host=00000000-0000-0000-0000-00000000D701&pane=",
    ]
    for string in unrecognised {
      let url = URL(string: string)!
      #expect(BlockedPaneActivityRoute.target(of: url) == nil, "'\(string)' routed somewhere")
    }
  }

  /// LaunchServices matches schemes case-insensitively.
  @Test("the scheme is matched without regard to case")
  func theSchemeIsCaseInsensitive() {
    let url = URL(string: "DRIVERR://host?host=00000000-0000-0000-0000-00000000D701")!
    #expect(BlockedPaneActivityRoute.target(of: url) == .host(hostID: hostID))
  }

  /// A card from a future build that adds a parameter cannot change destination.
  @Test("the authority decides the destination, not the parameters present")
  func theAuthorityDecides() {
    let url = URL(string: "driverr://host?host=00000000-0000-0000-0000-00000000D701&pane=w1:p2")!
    #expect(BlockedPaneActivityRoute.target(of: url) == .host(hostID: hostID))
  }

  // MARK: - Resuming the last pane a host was open on

  /// Pane id → `Pane.sessionWitness`.
  private let tree = ["w1:p1": "term_a1", "w1:p2": "term_b2"]

  private func record(_ paneID: String, _ witness: String) -> LastPaneRecord {
    LastPaneRecord(paneID: paneID, witness: witness)
  }

  @Test("a calm card resumes the pane the host was last open on")
  func aCalmCardResumesTheLastPane() {
    #expect(
      BlockedPaneActivityRoute.resumed(
        .host(hostID: hostID), lastPane: record("w1:p1", "term_a1"), panesOnHost: tree)
        == .pane(hostID: hostID, paneID: "w1:p1"))
  }

  /// herdr hands out pane ids by position, so a rebuilt session reports `w1:p1` for a
  /// terminal the reader was never in. Every creation path allocates a fresh terminal id, so
  /// the witness tells them apart; matching the id alone opened the stranger.
  @Test("a rebuilt session reusing the pane id falls back to the tree")
  func aRebuiltSessionFallsBackToTheTree() {
    #expect(
      BlockedPaneActivityRoute.resumed(
        .host(hostID: hostID), lastPane: record("w1:p1", "term_a1"),
        panesOnHost: ["w1:p1": "term_z9", "w1:p2": "term_y8"])
        == .host(hostID: hostID))
  }

  /// A pane closed elsewhere, or a session torn down while the phone was away.
  @Test("a remembered pane the host no longer has falls back to the tree")
  func aStaleRecordFallsBackToTheTree() {
    #expect(
      BlockedPaneActivityRoute.resumed(
        .host(hostID: hostID), lastPane: record("w9:p9", "term_a1"), panesOnHost: tree)
        == .host(hostID: hostID))
  }

  /// An empty half is no record either.
  @Test("no remembered pane leaves the host route alone")
  func noRecordLeavesTheHostRouteAlone() {
    #expect(
      BlockedPaneActivityRoute.resumed(
        .host(hostID: hostID), lastPane: nil, panesOnHost: tree) == .host(hostID: hostID))
    #expect(
      BlockedPaneActivityRoute.resumed(
        .host(hostID: hostID), lastPane: record("", "term_a1"), panesOnHost: tree)
        == .host(hostID: hostID))
    #expect(
      BlockedPaneActivityRoute.resumed(
        .host(hostID: hostID), lastPane: record("w1:p1", ""), panesOnHost: tree)
        == .host(hostID: hostID))
  }

  /// An empty-string witness must not match an empty-string record.
  @Test("a pane left out of the map for having no witness resumes nothing")
  func aPaneWithNoWitnessResumesNothing() {
    #expect(
      BlockedPaneActivityRoute.resumed(
        .host(hostID: hostID), lastPane: record("w1:p3", ""), panesOnHost: tree)
        == .host(hostID: hostID))
  }

  /// With no tree to check against, opening a pane would be a guess.
  @Test("a host with no panes reported resumes nothing")
  func anEmptySessionResumesNothing() {
    #expect(
      BlockedPaneActivityRoute.resumed(
        .host(hostID: hostID), lastPane: record("w1:p1", "term_a1"), panesOnHost: [:])
        == .host(hostID: hostID))
  }

  /// A card naming a blocked pane is about that pane, even when the record's witness is stale.
  @Test("an escalated card keeps opening its blocked pane")
  func anEscalatedCardIsUnchanged() {
    #expect(
      BlockedPaneActivityRoute.resumed(
        .pane(hostID: hostID, paneID: "w1:p2"), lastPane: record("w1:p1", "term_a1"),
        panesOnHost: tree) == .pane(hostID: hostID, paneID: "w1:p2"))
    #expect(
      BlockedPaneActivityRoute.resumed(
        .pane(hostID: hostID, paneID: "w1:p2"), lastPane: record("w1:p1", "term_gone"),
        panesOnHost: tree) == .pane(hostID: hostID, paneID: "w1:p2"))
  }

  /// The caller looks the record up by host id; the rule carries that id through.
  @Test("the resumed pane carries the routed host's id")
  func theResumedPaneCarriesTheRoutedHost() {
    #expect(
      BlockedPaneActivityRoute.resumed(
        .host(hostID: otherHostID), lastPane: record("w1:p1", "term_a1"), panesOnHost: tree)
        == .pane(hostID: otherHostID, paneID: "w1:p1"))
  }
}
