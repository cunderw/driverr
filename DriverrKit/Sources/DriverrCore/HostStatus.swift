/// What one host's row in the list says about it, as a value rather than as view code.
///
/// The host list answers "is anything waiting on me?" before a host is chosen, so the
/// badge, its spoken form and the second line are derived here for `swift test`.
///
/// Three connection states. There is no "unreachable", which would mean probing every saved
/// host in the background for a verdict that is stale when read. `lost` is a connection
/// Driverr was holding and watched drop, which it knows for free. Without it a dropped host
/// looked like one never reached, and automatic reconnect only runs while a terminal is open.
public struct HostStatus: Equatable, Sendable {
  /// The host's address.
  public let hostname: String
  /// Live, never reached, or dropped. See `HostConnectionState`.
  public let connection: HostConnectionState
  /// Which herdr answered on this host, when one did.
  public let herdrVersion: String?
  /// How many of this host's panes are in each state, as of the last poll. The badge and the
  /// calm sentence both read this, so they cannot disagree.
  public let agentStatusCounts: AgentStatusCounts

  public init(
    hostname: String,
    connection: HostConnectionState = .idle,
    herdrVersion: String? = nil,
    agentStatusCounts: AgentStatusCounts = AgentStatusCounts()
  ) {
    self.hostname = hostname
    self.connection = connection
    self.herdrVersion = herdrVersion
    self.agentStatusCounts = agentStatusCounts
  }

  /// Whether Driverr holds a live connection now. `.lost` gets no green dot and no badge,
  /// like `.idle`.
  public var isConnected: Bool { connection == .connected }

  /// How many panes are blocked: the badge's number.
  public var blockedPaneCount: Int { agentStatusCounts.blocked }

  /// The row's second line.
  ///
  /// Connected shows `10.1.0.9 · herdr 0.8.0`, keeping the address so an unnamed host stays
  /// identifiable. A connected host with no usable herdr shows only the address, because
  /// naming a version Driverr was not told is worse. Lost says so and keeps the address,
  /// because that is the host someone may be about to go and check.
  public var subtitle: String {
    switch connection {
    case .lost:
      return "\(hostname) · Connection lost"
    case .idle:
      return hostname
    case .connected:
      guard let herdrVersion else { return hostname }
      return "\(hostname) · herdr \(herdrVersion)"
    }
  }

  /// The red badge's text, or `nil`. A host not connected gets none, because only a live
  /// poll can report blocked panes. A connected host with nothing waiting gets none too.
  public var badge: String? {
    guard isConnected, blockedPaneCount > 0 else { return nil }
    return String(blockedPaneCount)
  }

  /// What VoiceOver says in place of the bare number, which is only a digit.
  public var badgeAccessibilityLabel: String? {
    guard badge != nil else { return nil }
    return blockedPaneCount == 1 ? "1 pane needs you" : "\(blockedPaneCount) panes need you"
  }

  /// What the dot means, in words, because a colour is not a label.
  public var connectionAccessibilityLabel: String { connection.spokenLabel }

  /// "Nothing needs you · 2 working · 1 finished", or `nil` when anything is blocked. See
  /// `AgentStatusCounts.calmSummary`, which the session tree also reads.
  public var calmSummary: String? { agentStatusCounts.calmSummary }
}

/// A host row's connection state.
public enum HostConnectionState: Equatable, Sendable {
  /// Never connected, or a connection Driverr closed on purpose.
  case idle
  /// Driverr is holding a live connection to this host right now.
  case connected
  /// Driverr was holding a connection to this host and watched it drop. Distinct from
  /// `idle`, which otherwise reads identically on the row.
  case lost

  /// What VoiceOver says in place of the dot. Never a colour alone.
  public var spokenLabel: String {
    switch self {
    case .idle: "Not connected"
    case .connected: "Connected"
    case .lost: "Connection lost"
    }
  }

  /// Which shape the row's dot takes, by role. The symbol and colour are the view's, as
  /// with `AgentStatusBadge`.
  public var glyphRole: HostConnectionGlyphRole {
    switch self {
    case .idle: .none
    case .connected: .ok
    case .lost: .warning
    }
  }
}

/// The role a connection state's glyph plays. A view maps it to an SF Symbol and a semantic
/// colour.
public enum HostConnectionGlyphRole: Equatable, Sendable {
  /// Nothing to draw attention to: a hollow dot, or none.
  case none
  /// Everything is fine: a filled dot.
  case ok
  /// Something needs a look: an orange triangle.
  case warning
}

/// The list's footer: how many hosts there are, how many are up, and how many want you.
public struct HostListSummary: Equatable, Sendable {
  public let hostCount: Int
  public let connectedCount: Int
  /// How many hosts wear a badge: connected, with something blocked. Hosts, not panes: each
  /// row badges its own panes.
  public let needsYouCount: Int
  /// How many hosts Driverr was connected to and watched drop.
  public let lostCount: Int

  public init(
    hostCount: Int,
    connectedCount: Int,
    needsYouCount: Int = 0,
    lostCount: Int = 0
  ) {
    self.hostCount = hostCount
    self.connectedCount = connectedCount
    self.needsYouCount = needsYouCount
    self.lostCount = lostCount
  }

  public init(statuses: [HostStatus]) {
    self.init(
      hostCount: statuses.count,
      connectedCount: statuses.filter { $0.connection == .connected }.count,
      // The badge's own rule, so the footer cannot claim a host that no row marks. A lost
      // host keeps its last counts and wears no badge.
      needsYouCount: statuses.filter { $0.badge != nil }.count,
      lostCount: statuses.filter { $0.connection == .lost }.count
    )
  }

  /// `3 hosts · 2 connected · 1 host needs you · 1 lost`. The last two clauses appear only
  /// when non-zero. The middle one names its unit, because the row beside it badges panes.
  public var text: String {
    var parts = [
      "\(hostCount) \(hostCount == 1 ? "host" : "hosts")",
      "\(connectedCount) connected",
    ]
    if needsYouCount > 0 {
      parts.append(needsYouCount == 1 ? "1 host needs you" : "\(needsYouCount) hosts need you")
    }
    if lostCount > 0 {
      parts.append("\(lostCount) lost")
    }
    return parts.joined(separator: " · ")
  }
}
