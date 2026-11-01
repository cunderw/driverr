import Foundation

#if os(iOS)
import ActivityKit
#endif

/// The one Live Activity Driverr draws while it is connected to anything.
///
/// Keep the type's name even though it no longer describes the card. `Activity<T>.activities`
/// matches on the attributes type, so renaming it would orphan the cards an installed build
/// holds, including old per-host cards this build must find to end. The card carries no
/// question, no transcript and no claim of continuous connectivity.
public struct BlockedPaneActivityAttributes: Codable, Hashable, Sendable {
  /// Read by nothing in the drawing. Every destination comes from the state (see
  /// `BlockedPaneActivityRoute.target(of:)`). It stays because installed cards carry it and
  /// the driver looks an activity up by it.
  public let hostID: UUID

  public init(hostID: UUID) { self.hostID = hostID }

  /// The id a card requested by this build carries. A fixed sentinel, so nothing reads a
  /// subject out of the attributes. An older build's card keeps its host id, which the driver
  /// ends it by.
  public static let aggregateHostID = UUID(uuidString: "57100000-0000-0000-0000-000000000571")!

  /// One connected host, as the card words it.
  public struct HostSummary: Codable, Hashable, Sendable {
    public let hostID: UUID
    public let hostName: String
    public let counts: AgentStatusCounts
    /// The host's herdr-core, if it has one. Absent from a card an earlier build wrote.
    ///
    /// A background pass sees one host and has no registry, so this is how it knows what the
    /// card's other hosts already count. See `BlockedPaneActivityPlan.coreIDs(coveringHost:in:)`.
    public let coreID: String?

    public init(hostID: UUID, hostName: String, counts: AgentStatusCounts, coreID: String? = nil) {
      self.hostID = hostID
      self.hostName = hostName
      self.counts = counts
      self.coreID = coreID
    }
  }

  /// The one blocked pane an escalated card names.
  ///
  /// It carries no total. The count is the sum of the hosts' `counts.blocked`, so it cannot
  /// drift from the hosts, as a second copy would when a background pass merges one host in.
  public struct BlockedPaneSummary: Codable, Hashable, Sendable {
    public let hostID: UUID
    public let hostName: String
    public let paneID: String
    public let paneTitle: String
    public let agentName: String?

    public init(
      hostID: UUID, hostName: String, paneID: String, paneTitle: String, agentName: String?
    ) {
      self.hostID = hostID
      self.hostName = hostName
      self.paneID = paneID
      self.paneTitle = paneTitle
      self.agentName = agentName
    }
  }

  public struct ContentState: Codable, Hashable, Sendable {
    /// Every connected host the card speaks for, sorted by name then id.
    ///
    /// Never empty in practice: no connected host ends the card (`.noConnectedHosts`). A
    /// decoded payload can still be empty, because a card outlives its build, so every
    /// reader copes rather than trapping.
    public let hosts: [HostSummary]

    /// The escalation, `nil` on a calm card.
    public let blocked: BlockedPaneSummary?

    public let lastConfirmedAt: Date
    public let staleDate: Date

    /// How many panes are waiting on a human, across every host on the card.
    public var blockedCount: Int { hosts.reduce(0) { $0 + $1.counts.blocked } }

    /// Whether the card is drawing its escalated copy.
    public var needsYou: Bool { blocked != nil }

    /// Every host's panes as one set of numbers, which is what the counts line words.
    public var totals: AgentStatusCounts {
      hosts.reduce(AgentStatusCounts()) { $0 + $1.counts }
    }

    /// No failable initialiser and no zero-blocked guard: the card lasts as long as a
    /// connection, and calm is its ordinary state.
    public init(
      hosts: [HostSummary],
      blocked: BlockedPaneSummary? = nil,
      lastConfirmedAt: Date
    ) {
      self.hosts = hosts
      self.blocked = blocked
      self.lastConfirmedAt = lastConfirmedAt
      staleDate = Self.staleDate(after: lastConfirmedAt)
    }

    private static func staleDate(after lastConfirmedAt: Date) -> Date {
      lastConfirmedAt.addingTimeInterval(2 * BackgroundRefreshPolicy.interval)
    }

    public func isStale(at now: Date) -> Bool { now >= staleDate }

    /// "workbox", "workbox · buildbox", or "4 hosts": the first line when nothing needs you.
    ///
    /// Names the hosts where they fit, because a calm card exists to say what Driverr is
    /// connected to. It falls back to a count past `namedHostLimit` hosts, or when the joined
    /// names exceed `nameBudget` characters, since a half-named host is worse than a count.
    /// The budget is a conservative character count, because `DriverrCore` has no text
    /// metrics.
    ///
    /// A single host is not budgeted: its name is the whole message, and the widget's
    /// `.lineLimit(1)` truncates it cleanly.
    ///
    /// "No hosts" only appears for a decoded empty payload, since `reconcile` never builds
    /// one. It avoids trapping in a widget extension. If it shows on a device, the bug is in
    /// the reconciler.
    public var hostsLine: String {
      guard !hosts.isEmpty else { return "No hosts" }
      if hosts.count == 1 { return hosts[0].hostName }
      guard hosts.count <= Self.namedHostLimit else { return "\(hosts.count) hosts" }
      let named = hosts.map(\.hostName).joined(separator: " · ")
      return named.count <= Self.nameBudget ? named : "\(hosts.count) hosts"
    }

    /// Past three the line cannot be read at a glance, whatever fits.
    static let namedHostLimit = 3

    /// The character budget for one `.headline` line inside the accent capsule.
    ///
    /// The capsule has 8 pt of padding each side, and a second line inside it reads as a
    /// mistake. The narrower column is the Lock Screen card's, about 310 pt, leaving 294 pt
    /// of text. At `.headline` a host name averages a little over 9 pt per character, so 31
    /// fits with room to spare. It is kept under what fits, so the count takes over before
    /// truncation would.
    static let nameBudget = 31

    /// "2 working · 1 finished · 1 idle", or "Connected" when there is nothing to count.
    public var countsLine: String { totals.activitySummary }

    /// "host · pane", host first, so a long pane title cannot push the host off the line.
    /// `nil` on a calm card, which has no single pane.
    public var context: String? {
      guard let blocked else { return nil }
      return "\(blocked.hostName) · \(blocked.paneTitle)"
    }

    public func headline(isStale: Bool) -> String {
      if isStale { return "Status may have changed" }
      guard needsYou else { return hostsLine }
      return blockedCount == 1 ? "Needs you" : "\(blockedCount) panes need you"
    }

    public func detail(isStale: Bool) -> String {
      // A stale escalated card names the pane it was last sure of. A stale calm card shows
      // what it last counted.
      if isStale { return context ?? countsLine }
      guard let blocked else { return countsLine }
      if blockedCount > 1 { return "on \(blocked.hostName)" }
      let agent = blocked.agentName?.trimmingCharacters(in: .whitespacesAndNewlines)
      return "\(agent.flatMap { $0.isEmpty ? nil : $0 } ?? "Agent") is waiting"
    }

    /// `staleDate` is not on the wire. It derives from `lastConfirmedAt`, and carrying it
    /// would let a payload contradict itself and still decode.
    ///
    /// The last five keys are an earlier build's flat shape, decoded but never written. See
    /// `init(from:)`.
    private enum CodingKeys: String, CodingKey {
      case hosts, blocked, lastConfirmedAt
      case hostName, paneID, paneTitle, agentName, blockedCount
    }

    public func encode(to encoder: any Encoder) throws {
      var values = encoder.container(keyedBy: CodingKeys.self)
      try values.encode(hosts, forKey: .hosts)
      try values.encodeIfPresent(blocked, forKey: .blocked)
      try values.encode(lastConfirmedAt, forKey: .lastConfirmedAt)
    }

    /// Decodes both shapes, and only ever writes the new one.
    ///
    /// An earlier build's card can still be on the Lock Screen after an upgrade, and a state
    /// that will not decode is one the driver cannot see to end. Its flat
    /// `hostName`/`paneID`/`paneTitle`/`agentName`/`blockedCount` payload reads as a one-host
    /// escalated card. Decoding is not adopting: the shape has no host id (see
    /// `earlierBuildPlaceholderHostID`), so `BlockedPaneActivityPlan.reconcile` ends it and
    /// requests a fresh card.
    public init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      let confirmedAt = try values.decode(Date.self, forKey: .lastConfirmedAt)
      lastConfirmedAt = confirmedAt
      staleDate = Self.staleDate(after: confirmedAt)
      if let hosts = try values.decodeIfPresent([HostSummary].self, forKey: .hosts) {
        self.hosts = hosts
        blocked = try values.decodeIfPresent(BlockedPaneSummary.self, forKey: .blocked)
        return
      }
      let hostName = try values.decode(String.self, forKey: .hostName)
      let paneID = try values.decode(String.self, forKey: .paneID)
      let paneTitle = try values.decode(String.self, forKey: .paneTitle)
      let agentName = try values.decodeIfPresent(String.self, forKey: .agentName)
      let blockedCount = try values.decode(Int.self, forKey: .blockedCount)
      hosts = [
        HostSummary(
          hostID: Self.earlierBuildPlaceholderHostID,
          hostName: hostName,
          counts: AgentStatusCounts(blocked: blockedCount)
        )
      ]
      blocked = BlockedPaneSummary(
        hostID: Self.earlierBuildPlaceholderHostID, hostName: hostName, paneID: paneID,
        paneTitle: paneTitle, agentName: agentName)
    }

    /// The host id an old-shape payload stands in with, because it has none of its own.
    ///
    /// The earlier build kept the host id in the attributes, which a `Decoder` cannot reach.
    /// A tap on such a card names no real host, and `ActivityURLRouter` does nothing. That
    /// is why the card is ended rather than adopted. Zeroed so it is recognisable in a dump.
    static let earlierBuildPlaceholderHostID = UUID(
      uuidString: "00000000-0000-0000-0000-000000000000")!

    /// Whether this state came from an earlier build's flat shape. Only `init(from:)` writes
    /// the placeholder, so its presence in either field is the tell.
    public var isFromAnEarlierBuildsShape: Bool {
      hosts.contains { $0.hostID == Self.earlierBuildPlaceholderHostID }
        || blocked?.hostID == Self.earlierBuildPlaceholderHostID
    }
  }
}

#if os(iOS)
extension BlockedPaneActivityAttributes: ActivityAttributes {}
#endif
