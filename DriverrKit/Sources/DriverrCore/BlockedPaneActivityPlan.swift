import Foundation

/// One host, as one pass over its session tree saw it.
///
/// Built by `ConnectionRegistry`'s foreground poll and `BackgroundRefreshRunner`'s snapshot.
/// It carries panes rather than a built `ContentState`, so `reconcile` alone decides what
/// the card says.
public struct HostActivityObservation: Equatable, Sendable {
  public let hostID: UUID
  public let hostName: String

  /// Whether this host is connected now. The card starts on connect and ends when the last
  /// host drops, so this is the trigger, not the blocked set.
  public let isConnected: Bool

  /// The blocked panes in tree order: `SessionTree.blockedPanes`.
  public let blockedPanes: [Pane]

  /// Every pane on the host by state, for the card's second line.
  public let counts: AgentStatusCounts

  public let observedAt: Date

  /// `SessionTree.coreID`, for the card to carry. See `HostSummary.coreID`.
  public let coreID: String?

  public init(
    hostID: UUID,
    hostName: String,
    isConnected: Bool,
    blockedPanes: [Pane],
    counts: AgentStatusCounts,
    observedAt: Date,
    coreID: String? = nil
  ) {
    self.hostID = hostID
    self.hostName = hostName
    self.isConnected = isConnected
    self.blockedPanes = blockedPanes
    self.counts = counts
    self.observedAt = observedAt
    self.coreID = coreID
  }
}

/// How much of the world a pass looked at.
///
/// A background refresh reaches one machine and has no other state. Under `.oneHost` a
/// missing host is unlooked-at, not gone, and is carried over from the card's own `hosts`.
/// Without this a background relaunch would end the card for hosts it never saw.
public enum ObservationScope: Equatable, Sendable {
  /// Every host the app is holding a connection for. Authoritative.
  case everyConnectedHost
  /// One machine, and nothing said about the others.
  case oneHost(UUID)
}

/// An activity the system already holds, as the driver read it back from
/// `Activity.activities`. That list survives a cold launch, so nothing here persists an id.
/// `activityID` is the card's `attributes.hostID`, now only a lookup handle.
public struct ExistingLiveActivity: Equatable, Sendable {
  public let activityID: UUID
  public let state: BlockedPaneActivityAttributes.ContentState

  public init(activityID: UUID, state: BlockedPaneActivityAttributes.ContentState) {
    self.activityID = activityID
    self.state = state
  }
}

/// One thing the driver should do to ActivityKit.
public enum LiveActivityAction: Equatable, Sendable {
  case request(BlockedPaneActivityAttributes.ContentState)
  case update(activityID: UUID, BlockedPaneActivityAttributes.ContentState)
  case end(activityID: UUID, EndReason)

  public enum EndReason: Equatable, Sendable {
    /// Nothing is connected. The card lasts as long as a connection, so this is the ordinary
    /// end.
    case noConnectedHosts
    /// No pass could confirm what the card says, and it is past its own stale date.
    case couldNotConfirm
    /// The global Live Activities setting is off. No pass requests another card until it is
    /// back on.
    case settingOff
    /// An extra card from a build that drew one per host. One survives and is adopted.
    case replacedByOneCard
    /// A card in an earlier build's one-host shape, which carries no host id routing can use.
    /// Ended and replaced rather than adopted; see `reconcile`.
    case fromAnEarlierBuildsShape
  }

  var activityID: UUID? {
    switch self {
    case .request: nil
    case .update(let id, _), .end(let id, _): id
    }
  }
}

/// What to request, update or end, as a pure function over what was seen and what exists.
///
/// No ActivityKit, so `swift test` pins adoption, throttling, the scope merge and every end,
/// and the app-side driver only makes the calls. There is one aggregated card, so there is
/// no cap and no ranking between cards.
public enum BlockedPaneActivityPlan {
  /// How much newer a confirmation must be before a timestamp alone is worth a write.
  ///
  /// The foreground poll runs every three seconds, and a write per poll would spend the
  /// system's update budget on a clock. This is half the stale window, so a confirmed card
  /// stays ahead of its boundary. A background refresh always clears it, and so always
  /// writes a fresh stale date. That matters: a card that crosses its stale date while shown
  /// keeps drawing its fresh copy, so nothing may rely on the system retiring it.
  public static let refreshFloor: TimeInterval = BackgroundRefreshPolicy.interval

  /// Whether a card showing `existing` should be written with `desired`: anything visible
  /// differs, or the confirmation moved on by `refreshFloor`. `now` is unused but taken, so
  /// a clock-based rule changes only this function.
  public static func shouldUpdate(
    existing: BlockedPaneActivityAttributes.ContentState,
    desired: BlockedPaneActivityAttributes.ContentState,
    now: Date
  ) -> Bool {
    if existing.hosts != desired.hosts { return true }
    if existing.blocked != desired.blocked { return true }
    return desired.lastConfirmedAt.timeIntervalSince(existing.lastConfirmedAt) >= refreshFloor
  }

  /// What to do about `observations`, given the activities that already exist.
  ///
  /// - Parameters:
  ///   - scope: how much of the world this pass looked at. See `ObservationScope`.
  ///   - existing: every card this app holds, including per-host cards from an older
  ///     build. At most one survives.
  ///   - preferences: the global switch and the per-host Start/Stop.
  ///   - canRequest: whether this pass may start a card. False in the background, where a
  ///     refresh handler may update and end but not request.
  ///   - now: the clock, passed so every rule is testable.
  ///   - openedPanes: the panes, per host, the reader has opened.
  ///
  /// An opened pane drops out of the escalation and the count, but does not end the card.
  /// `SessionModel` runs its change hook on every poll, and an opened pane stays blocked
  /// until answered, so ending the card would bring it back three seconds later. It is a set
  /// because keeping only the latest opened pane makes the card flap between two. An entry
  /// lapses when its pane stops being blocked, so it can escalate again.
  ///
  /// Ends come first, then updates, then requests. The array is deterministic and a test
  /// compares it whole.
  public static func reconcile(
    observations: [HostActivityObservation],
    scope: ObservationScope,
    existing: [ExistingLiveActivity],
    preferences: LiveActivityPreferences,
    canRequest: Bool,
    now: Date,
    openedPanes: [UUID: Set<String>] = [:]
  ) -> [LiveActivityAction] {
    // Sorted because `Activity.activities` has no order. The first is the card from here on.
    let incumbents = existing.sorted { $0.activityID.uuidString < $1.activityID.uuidString }

    // The setting is off: take down everything, including a card the last launch requested,
    // and request nothing.
    guard preferences.isEnabled else {
      return incumbents.map { .end(activityID: $0.activityID, .settingOff) }
    }

    // A host observed twice keeps its last observation, as the driver's pending slot does.
    var eligible: [UUID: HostActivityObservation] = [:]
    var eligibleOrder: [UUID] = []
    for seen in observations where seen.isConnected && preferences.isOn(for: seen.hostID) {
      if eligible[seen.hostID] == nil { eligibleOrder.append(seen.hostID) }
      eligible[seen.hostID] = seen
    }

    // An earlier build's card is ended, never adopted. Its host id lived in the attributes,
    // where a `Decoder` cannot reach it, so `ContentState` holds a placeholder: a tap opens
    // nothing and a `.oneHost` pass would carry a phantom host forward. The cost: if the
    // first pass after an upgrade is a background one, there is no card until the next
    // foreground pass.
    var ends: [LiveActivityAction] = []
    var adoptable: [ExistingLiveActivity] = []
    for incumbent in incumbents {
      if incumbent.state.isFromAnEarlierBuildsShape {
        ends.append(.end(activityID: incumbent.activityID, .fromAnEarlierBuildsShape))
      } else {
        adoptable.append(incumbent)
      }
    }
    // Every card past the first is a per-host leftover. Two cards is never the answer.
    for extra in adoptable.dropFirst() {
      ends.append(.end(activityID: extra.activityID, .replacedByOneCard))
    }

    let card = adoptable.first
    let merged = mergedHosts(
      eligible: eligibleOrder.compactMap { eligible[$0] },
      scope: scope,
      card: card?.state,
      preferences: preferences,
      openedPanes: openedPanes
    )

    guard !merged.hosts.isEmpty else {
      // No connected host is allowed a card, so the card ends.
      if let card { ends.append(.end(activityID: card.activityID, .noConnectedHosts)) }
      return ends
    }

    // Nothing confirmed the card and it is past its stale date. Only reachable under
    // `.oneHost`, because an authoritative pass has seen every host on the merged set.
    if let card, merged.confirmedAt == nil, now >= card.state.staleDate {
      ends.append(.end(activityID: card.activityID, .couldNotConfirm))
      return ends
    }

    let desired = BlockedPaneActivityAttributes.ContentState(
      hosts: merged.hosts,
      blocked: merged.blocked,
      lastConfirmedAt: merged.confirmedAt ?? card?.state.lastConfirmedAt ?? now
    )

    guard let card else {
      // A request is checked against the stale date and an update is not. A request already
      // stale is accepted and drawn nowhere. An update carries a fresh stale date, and
      // withholding it would leave a frozen card standing.
      guard canRequest, now < desired.staleDate else { return ends }
      return ends + [.request(desired)]
    }

    guard shouldUpdate(existing: card.state, desired: desired, now: now) else { return ends }
    return ends + [.update(activityID: card.activityID, desired)]
  }

  /// The cores of the hosts the standing card speaks for, other than `hostID`.
  ///
  /// What a `.oneHost` pass hides from its tree, because the card carries those hosts over and
  /// their counts already hold those machines. A host the card does not name covers nothing,
  /// so with no card a machine is counted through the core that added it.
  public static func coreIDs(
    coveringHost hostID: UUID,
    in existing: [ExistingLiveActivity]
  ) -> Set<String> {
    Set(existing.flatMap(\.state.hosts).filter { $0.hostID != hostID }.compactMap(\.coreID))
  }

  // MARK: - Building the one state

  private struct MergedHosts {
    let hosts: [BlockedPaneActivityAttributes.HostSummary]
    let blocked: BlockedPaneActivityAttributes.BlockedPaneSummary?
    /// `nil` when this pass confirmed nothing and every host was carried over.
    let confirmedAt: Date?
  }

  private static func mergedHosts(
    eligible: [HostActivityObservation],
    scope: ObservationScope,
    card: BlockedPaneActivityAttributes.ContentState?,
    preferences: LiveActivityPreferences,
    openedPanes: [UUID: Set<String>]
  ) -> MergedHosts {
    var summaries: [BlockedPaneActivityAttributes.HostSummary] = []
    // The blocked pane each host would have the card name. A carried host brings the card's
    // own summary, so a blocked pane whose host is gone goes with it.
    var candidates: [UUID: BlockedPaneActivityAttributes.BlockedPaneSummary] = [:]

    if case .oneHost(let observedID) = scope, let card {
      for carried in card.hosts
      where carried.hostID != observedID && preferences.isOn(for: carried.hostID) {
        summaries.append(carried)
        if let blocked = card.blocked, blocked.hostID == carried.hostID {
          candidates[carried.hostID] = blocked
        }
      }
    }

    var confirmedAt: Date?
    for seen in eligible {
      let open = openedPanes[seen.hostID] ?? []
      let waiting = seen.blockedPanes.filter { !open.contains($0.id) }
      var counts = seen.counts
      // The count follows the exclusion, so the card never counts panes already read.
      counts.blocked = waiting.count
      summaries.removeAll { $0.hostID == seen.hostID }
      summaries.append(
        BlockedPaneActivityAttributes.HostSummary(
          hostID: seen.hostID, hostName: seen.hostName, counts: counts, coreID: seen.coreID))
      if let first = waiting.first {
        candidates[seen.hostID] = BlockedPaneActivityAttributes.BlockedPaneSummary(
          hostID: seen.hostID, hostName: seen.hostName, paneID: first.id,
          paneTitle: first.title, agentName: first.agent?.name)
      } else {
        candidates[seen.hostID] = nil
      }
      confirmedAt = max(confirmedAt ?? seen.observedAt, seen.observedAt)
    }

    // Deterministic, and a test compares the array whole.
    summaries.sort { lhs, rhs in
      lhs.hostName == rhs.hostName
        ? lhs.hostID.uuidString < rhs.hostID.uuidString
        : lhs.hostName < rhs.hostName
    }
    let blocked = summaries.lazy.compactMap { candidates[$0.hostID] }.first
    return MergedHosts(hosts: summaries, blocked: blocked, confirmedAt: confirmedAt)
  }
}
