import Testing

@testable import DriverrCore

/// The host list's words. `HostBadgeUITests` proves the badge is on the row.
@Suite("HostStatus")
struct HostStatusTests {
  @Test("a connected host keeps its address and names the herdr that answered on it")
  func connectedNamesHerdr() {
    // Swapping the address for the version made an unnamed host unidentifiable while
    // scanning rows.
    let status = HostStatus(hostname: "10.1.0.9", isConnected: true, herdrVersion: "0.8.0")
    #expect(status.subtitle == "10.1.0.9 · herdr 0.8.0")
  }

  @Test("a host nobody has connected to names its hostname")
  func coldNamesTheHostname() {
    let status = HostStatus(hostname: "10.1.0.9")
    #expect(status.subtitle == "10.1.0.9")
  }

  /// No herdr, or not finished asking. Inventing a version would be worse than the address.
  @Test("a connected host with no herdr falls back to its hostname")
  func connectedWithoutHerdrFallsBack() {
    let status = HostStatus(hostname: "10.1.0.9", isConnected: true)
    #expect(status.subtitle == "10.1.0.9")
  }

  /// A lost host is distinct from a cold one and keeps its address, because it is the one
  /// somebody may walk over to.
  @Test("a lost connection names itself and still says which machine it was")
  func lostConnectionNamesItself() {
    let status = HostStatus(hostname: "10.1.0.9", connection: .lost, herdrVersion: "0.8.0")
    #expect(status.subtitle == "10.1.0.9 · Connection lost")
  }

  @Test("a connected host with blocked panes wears their count")
  func connectedWithBlockedPanesWearsACount() {
    let status = HostStatus(
      hostname: "10.1.0.9",
      isConnected: true,
      herdrVersion: "0.8.0",
      blockedPaneCount: 3
    )
    #expect(status.badge == "3")
  }

  /// Only herdr can report a count, so a zero badge would claim Driverr had looked.
  @Test("a host that has never been connected wears no badge at all")
  func coldHostWearsNoBadge() {
    #expect(HostStatus(hostname: "10.1.0.9").badge == nil)
    #expect(HostStatus(hostname: "10.1.0.9").badgeAccessibilityLabel == nil)
  }

  /// The badge belongs to a live poll.
  @Test("a disconnected host wears no badge even with a count still in hand")
  func disconnectedHostDropsItsCount() {
    let status = HostStatus(
      hostname: "10.1.0.9",
      agentStatusCounts: AgentStatusCounts(blocked: 2)
    )
    #expect(status.badge == nil)
  }

  @Test("a lost connection wears no badge even with a count still in hand")
  func lostConnectionDropsItsCount() {
    let status = HostStatus(
      hostname: "10.1.0.9",
      connection: .lost,
      agentStatusCounts: AgentStatusCounts(blocked: 2)
    )
    #expect(status.badge == nil)
  }

  /// A red `0` would ask for attention about nothing.
  @Test("a connected host with nothing blocked wears no badge either")
  func connectedWithNothingBlockedWearsNoBadge() {
    let status = HostStatus(hostname: "10.1.0.9", isConnected: true, herdrVersion: "0.8.0")
    #expect(status.badge == nil)
  }

  /// "3" alone says nothing about what three of.
  @Test("the badge is spoken as a sentence, not as a number")
  func badgeIsSpokenInWords() {
    let one = HostStatus(hostname: "h", isConnected: true, blockedPaneCount: 1)
    let several = HostStatus(hostname: "h", isConnected: true, blockedPaneCount: 4)
    #expect(one.badgeAccessibilityLabel == "1 pane needs you")
    #expect(several.badgeAccessibilityLabel == "4 panes need you")
  }

  @Test("the dot is spoken as words rather than left to its colour")
  func dotIsSpokenInWords() {
    #expect(
      HostStatus(hostname: "h", isConnected: true).connectionAccessibilityLabel == "Connected"
    )
    #expect(HostStatus(hostname: "h").connectionAccessibilityLabel == "Not connected")
    #expect(
      HostStatus(hostname: "h", connection: .lost).connectionAccessibilityLabel
        == "Connection lost"
    )
  }

  @Test("each connection state names its own glyph role")
  func connectionStateNamesItsGlyphRole() {
    #expect(HostConnectionState.idle.glyphRole == .none)
    #expect(HostConnectionState.connected.glyphRole == .ok)
    #expect(HostConnectionState.lost.glyphRole == .warning)
  }
}

@Suite("HostStatus.calmSummary")
struct HostStatusCalmSummaryTests {
  /// The calm sentence competes with the badge, so it does not exist while the badge does.
  @Test("nil whenever anything is blocked")
  func nilWhenBlocked() {
    let status = HostStatus(
      hostname: "h",
      isConnected: true,
      blockedPaneCount: 1
    )
    #expect(status.calmSummary == nil)
  }

  @Test("nothing to report reads as a bare sentence, not an empty one")
  func nothingAtAllIsStillASentence() {
    let status = HostStatus(hostname: "h")
    #expect(status.calmSummary == "Nothing needs you")
  }

  @Test("names every non-zero state, in order")
  func namesEveryNonZeroState() {
    let status = HostStatus(
      hostname: "h",
      connection: .connected,
      agentStatusCounts: AgentStatusCounts(done: 1, working: 2, idle: 3)
    )
    #expect(status.calmSummary == "Nothing needs you · 2 working · 1 finished · 3 idle")
  }

  @Test("a zero count is left out rather than spoken as zero")
  func zeroCountsAreOmitted() {
    let status = HostStatus(
      hostname: "h",
      agentStatusCounts: AgentStatusCounts(working: 2)
    )
    #expect(status.calmSummary == "Nothing needs you · 2 working")
  }

  @Test("one of a state and many of it use the same word, unlike a shell")
  func oneVersusMany() {
    let one = HostStatus(hostname: "h", agentStatusCounts: AgentStatusCounts(working: 1))
    let many = HostStatus(hostname: "h", agentStatusCounts: AgentStatusCounts(working: 5))
    #expect(one.calmSummary == "Nothing needs you · 1 working")
    #expect(many.calmSummary == "Nothing needs you · 5 working")
  }

  @Test("shells pluralise where the other states do not")
  func shellsPluraliseByCount() {
    let one = HostStatus(hostname: "h", agentStatusCounts: AgentStatusCounts(shells: 1))
    let several = HostStatus(hostname: "h", agentStatusCounts: AgentStatusCounts(shells: 3))
    #expect(one.calmSummary == "Nothing needs you · 1 shell")
    #expect(several.calmSummary == "Nothing needs you · 3 shells")
  }
}

@Suite("HostListSummary")
struct HostListSummaryTests {
  @Test("the footer counts the hosts and how many are up")
  func footerReadsTheDesignedSentence() {
    let summary = HostListSummary(hostCount: 3, connectedCount: 1)
    #expect(summary.text == "3 hosts · 1 connected")
  }

  @Test("one host is a host, not 1 hosts")
  func footerIsSingularForOne() {
    #expect(HostListSummary(hostCount: 1, connectedCount: 0).text == "1 host · 0 connected")
  }

  @Test("the summary counts the statuses it is built from")
  func summaryCountsStatuses() {
    let summary = HostListSummary(statuses: [
      HostStatus(hostname: "a", isConnected: true),
      HostStatus(hostname: "b"),
      HostStatus(hostname: "c", isConnected: true),
    ])
    #expect(summary.hostCount == 3)
    #expect(summary.connectedCount == 2)
    #expect(summary.text == "3 hosts · 2 connected")
  }

  @Test("the summary counts hosts whose connection was lost")
  func summaryCountsLostHosts() {
    let summary = HostListSummary(statuses: [
      HostStatus(hostname: "a", connection: .connected),
      HostStatus(hostname: "b", connection: .lost),
      HostStatus(hostname: "c", connection: .lost),
    ])
    #expect(summary.lostCount == 2)
    #expect(summary.text == "3 hosts · 1 connected · 2 lost")
  }

  /// Each row already shows its own pane count.
  @Test("the summary counts hosts with something blocked, not panes")
  func summaryCountsHostsThatNeedYou() {
    let summary = HostListSummary(statuses: [
      HostStatus(hostname: "a", isConnected: true, blockedPaneCount: 3),
      HostStatus(hostname: "b", isConnected: true, blockedPaneCount: 1),
      HostStatus(hostname: "c", isConnected: true),
    ])
    #expect(summary.needsYouCount == 2)
    #expect(summary.text == "3 hosts · 3 connected · 2 hosts need you")
  }

  @Test("one host needing you is singular")
  func needsYouIsSingularForOne() {
    let summary = HostListSummary(statuses: [
      HostStatus(hostname: "a", isConnected: true, blockedPaneCount: 1)
    ])
    #expect(summary.text == "1 host · 1 connected · 1 host needs you")
  }

  /// The row badges panes and the footer counts hosts, so the footer names its unit.
  @Test("one host with two blocked panes reads as one host, beside a badge of 2")
  func needsYouNamesHostsBesideAPaneBadge() {
    let blocked = HostStatus(hostname: "a", isConnected: true, blockedPaneCount: 2)
    let summary = HostListSummary(statuses: [
      blocked,
      HostStatus(hostname: "b"),
      HostStatus(hostname: "c"),
    ])
    #expect(blocked.badge == "2")
    #expect(summary.text == "3 hosts · 1 connected · 1 host needs you")
  }

  @Test("two hosts needing you are plural")
  func needsYouIsPluralForTwo() {
    let summary = HostListSummary(statuses: [
      HostStatus(hostname: "a", isConnected: true, blockedPaneCount: 2),
      HostStatus(hostname: "b", isConnected: true, blockedPaneCount: 1),
      HostStatus(hostname: "c"),
    ])
    #expect(summary.text == "3 hosts · 2 connected · 2 hosts need you")
  }

  /// A lost host keeps its last counts and wears no badge, so the footer must not claim it.
  @Test("a lost host with blocked panes is not a host that needs you")
  func aLostHostWithBlockedPanesIsNotCounted() {
    let lost = HostStatus(
      hostname: "b", connection: .lost, agentStatusCounts: AgentStatusCounts(blocked: 2))
    let summary = HostListSummary(statuses: [
      HostStatus(hostname: "a", isConnected: true),
      lost,
      HostStatus(hostname: "c"),
    ])
    #expect(lost.badge == nil)
    #expect(summary.needsYouCount == 0)
    #expect(summary.text == "3 hosts · 1 connected · 1 lost")
  }

  @Test("only the hosts whose rows wear a badge are counted")
  func needsYouCountsOnlyBadgedHosts() {
    let statuses = [
      HostStatus(hostname: "a", isConnected: true, blockedPaneCount: 1),
      HostStatus(
        hostname: "b", connection: .lost, agentStatusCounts: AgentStatusCounts(blocked: 2)),
      HostStatus(hostname: "c"),
    ]
    let summary = HostListSummary(statuses: statuses)
    #expect(summary.needsYouCount == statuses.filter { $0.badge != nil }.count)
    #expect(summary.text == "3 hosts · 1 connected · 1 host needs you · 1 lost")
  }
}

/// The session tree renders the same sentence from its own counts.
@Suite("AgentStatusCounts.calmSummary")
struct AgentStatusCountsCalmSummaryTests {
  @Test("the counts speak for themselves, and say what the host row says")
  func theCountsAreTheSource() {
    let counts = AgentStatusCounts(done: 1, working: 2)

    #expect(counts.calmSummary == "Nothing needs you · 2 working · 1 finished")
    #expect(HostStatus(hostname: "h", agentStatusCounts: counts).calmSummary == counts.calmSummary)
  }

  @Test("a blocked pane silences the calm sentence wherever it is read")
  func blockedSilencesIt() {
    #expect(AgentStatusCounts(blocked: 1, working: 2).calmSummary == nil)
  }
}

extension HostStatus {
  /// A connected-or-idle host with only blocked panes, the shape most of these tests need.
  fileprivate init(
    hostname: String,
    isConnected: Bool,
    herdrVersion: String? = nil,
    blockedPaneCount: Int = 0
  ) {
    self.init(
      hostname: hostname,
      connection: isConnected ? .connected : .idle,
      herdrVersion: herdrVersion,
      agentStatusCounts: AgentStatusCounts(blocked: blockedPaneCount)
    )
  }
}
