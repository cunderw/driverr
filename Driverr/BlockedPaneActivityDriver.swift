import ActivityKit
import DriverrCore
import Foundation
import SwiftUI

/// Where an observation of the connected hosts becomes a Live Activity.
///
/// A protocol so a UI run reaches no system service that outlives the process. A Live
/// Activity survives the app being killed, and the first request raises a system consent
/// sheet that a UI test would then fail on.
@MainActor
protocol BlockedPaneActivityDriving: AnyObject, Sendable {
  /// One pass over the connected hosts.
  ///
  /// - Parameters:
  ///   - scope: `.everyConnectedHost` from the registry's gather, `.oneHost` from a
  ///     background refresh.
  ///   - canRequest: whether this pass may start a card. `false` from a `BGAppRefreshTask`.
  func observed(
    _ observations: [HostActivityObservation], scope: ObservationScope, canRequest: Bool
  ) async

  /// The reader opened a pane. De-escalates the card that names it.
  func notePaneWasOpened(hostID: UUID, paneID: String) async

  /// The cores of the card's other hosts, for a `.oneHost` pass to hide before it counts. See
  /// `BlockedPaneActivityPlan.coreIDs(coveringHost:in:)`.
  func coreIDs(coveringHost hostID: UUID) -> Set<String>

  /// The global switch or a per-host setting changed.
  ///
  /// Pushed in rather than read on each pass, because a `BGAppRefreshTask` relaunch has no
  /// `SettingsModel`. `ContentView` pushes at launch and on change, and
  /// `BackgroundRefreshRunner` reads the stores and pushes before its feed. A driver told
  /// nothing uses the preferences' defaults, which are on.
  func preferencesChanged(_ preferences: LiveActivityPreferences) async
}

/// The ActivityKit side of the automatic Live Activity lifecycle.
///
/// Nothing is persisted. `Activity.activities` returns each card's `attributes.hostID` and
/// `content.state` after a cold launch, and a stored copy would go stale when the system
/// ends an activity itself. Every decision is in `BlockedPaneActivityPlan` in `DriverrCore`,
/// so the rules are tested with `swift test` and this file only makes the calls.
@MainActor
final class LiveBlockedPaneActivityDriver: BlockedPaneActivityDriving {
  nonisolated init() {}

  /// Returns once the work is queued, not once it has run. A call that arrives during a
  /// drain queues its item and returns, and the running drain performs it. Callers are
  /// fire-and-forget, so the foreground poll never waits on ActivityKit.
  func observed(
    _ observations: [HostActivityObservation], scope: ObservationScope, canRequest: Bool
  ) async {
    // A newer pass replaces a queued one for the same scope, so a slow drain does not build
    // a backlog of superseded passes. Only the same scope: an authoritative pass and a
    // one-host pass say different things.
    pending.removeAll {
      if case .observation(_, let queued, _) = $0 { return queued == scope }
      return false
    }
    pending.append(.observation(observations, scope, canRequest: canRequest))
    await drain()
  }

  /// Never coalesced: dropping an open would leave the card escalated about a pane the
  /// reader is already looking at.
  func notePaneWasOpened(hostID: UUID, paneID: String) async {
    pending.append(.opened(hostID: hostID, paneID: paneID))
    await drain()
  }

  func coreIDs(coveringHost hostID: UUID) -> Set<String> {
    BlockedPaneActivityPlan.coreIDs(coveringHost: hostID, in: readExistingActivities())
  }

  /// A queued preference change is replaced by a newer one, so flipping the switch twice
  /// does not end a card and request it again.
  func preferencesChanged(_ preferences: LiveActivityPreferences) async {
    // Assign before queueing. A pass queued earlier runs after this call, and must see the
    // new value or it could request a card after the reader turned the switch off.
    self.preferences = preferences
    pending.removeAll {
      if case .preferencesChanged = $0 { return true }
      return false
    }
    // The queued item carries no value. A change queued during a drain runs after a later
    // change was already assigned, so re-assigning a stored value would undo the newer one.
    pending.append(.preferencesChanged)
    await drain()
  }

  /// Whether the reader allows a card at all, and for which hosts. Starts at the
  /// preferences' defaults.
  private var preferences = LiveActivityPreferences()

  /// The panes, per host, the reader explicitly opened.
  ///
  /// This keeps an open from flickering back. `SessionModel` fires the change hook on every
  /// poll, and the opened pane stays blocked until the reader answers it. The rule is in
  /// `BlockedPaneActivityPlan.reconcile`.
  ///
  /// Per process. A `BGAppRefreshTask` relaunch starts empty, so a background pass can
  /// re-escalate a standing card about a pane already opened. It cannot request a new card.
  /// Persisting this, as `AnnouncedPaneStore` does for notifications, would stop a pane opened
  /// yesterday from ever escalating again.
  private var openedPanes: [UUID: Set<String>] = [:]

  // MARK: - One at a time

  private enum Work {
    case observation([HostActivityObservation], ObservationScope, canRequest: Bool)
    case opened(hostID: UUID, paneID: String)
    case preferencesChanged
  }

  private var pending: [Work] = []
  private var isDraining = false

  /// Performs one item at a time. The read of `activities` decides between request and
  /// update, so a second pass that read the list before the first pass's request landed
  /// would request a second card.
  private func drain() async {
    guard !isDraining else { return }
    isDraining = true
    defer { isDraining = false }
    while !pending.isEmpty {
      await perform(pending.removeFirst())
    }
  }

  private func perform(_ work: Work) async {
    let existing = readExistingActivities()
    let actions: [LiveActivityAction]
    switch work {
    case .observation(let observations, let scope, let canRequest):
      // An entry lapses when its pane stops being blocked, so a pane that blocks again
      // escalates again. Only the hosts this pass looked at: a `.oneHost` pass says nothing
      // about the others.
      for observation in observations {
        let stillBlocked = Set(observation.blockedPanes.map(\.id))
        openedPanes[observation.hostID] =
          openedPanes[observation.hostID]?.intersection(stillBlocked)
      }
      actions = BlockedPaneActivityPlan.reconcile(
        observations: observations, scope: scope, existing: existing,
        preferences: preferences, canRequest: canRequest, now: .now, openedPanes: openedPanes)
    case .opened(let hostID, let paneID):
      openedPanes[hostID, default: []].insert(paneID)
      // Nothing is written on an open. The next pass computes the de-escalation with this
      // pane left out.
      return
    case .preferencesChanged:
      // Turning it on requests nothing here. The next foreground gather requests through the
      // ordinary path, which knows what is connected. Turning it off must reach a card no
      // observation mentions, including one from the last launch, so the reconciler gets an
      // empty pass and ends everything.
      guard !preferences.isEnabled else { return }
      actions = BlockedPaneActivityPlan.reconcile(
        observations: [], scope: .everyConnectedHost, existing: existing,
        preferences: preferences, canRequest: false, now: .now)
    }
    // Without consent, perform only the ends. A request without consent throws, but a card
    // the reader has since forbidden must still come down, and `end` needs no permission.
    let isAllowed = ActivityAuthorizationInfo().areActivitiesEnabled
    for action in actions {
      switch action {
      case .request(let state):
        guard isAllowed else { continue }
        request(state)
      case .update(let activityID, let state):
        await update(activityID: activityID, state: state)
      case .end(let activityID, _):
        await end(activityID: activityID)
      }
    }
  }

  // MARK: - ActivityKit

  /// Every activity this app holds, minus the DEBUG capture fixture's, so the driver and
  /// `BlockedPaneActivityCapture` do not fight over one card.
  private func readExistingActivities() -> [ExistingLiveActivity] {
    Activity<BlockedPaneActivityAttributes>.activities
      .filter { !Self.isCaptureFixture($0.attributes.hostID) }
      .map { ExistingLiveActivity(activityID: $0.attributes.hostID, state: $0.content.state) }
  }

  private func request(_ state: BlockedPaneActivityAttributes.ContentState) {
    // A failed request is dropped: the next gather asks again in three seconds. Under DEBUG
    // the outcome goes to `debug.liveActivity.lastRequest`, because a refused request is
    // otherwise silent.
    do {
      _ = try Activity.request(
        attributes: BlockedPaneActivityAttributes(
          hostID: BlockedPaneActivityAttributes.aggregateHostID),
        content: ActivityContent(state: state, staleDate: state.staleDate),
        pushType: nil
      )
      #if DEBUG
      Self.lastRequestOutcome = "ok"
      #endif
    } catch {
      #if DEBUG
      Self.lastRequestOutcome = "\(error)"
      #endif
    }
  }

  /// `nonisolated` with the lookup inline, because ActivityKit's `update` and `end` are
  /// `@concurrent`. A handle fetched on the main actor lands in its region, and sending it
  /// to a `@concurrent` method is a strict-concurrency data-race error.
  private nonisolated func update(
    activityID: UUID, state: BlockedPaneActivityAttributes.ContentState
  ) async {
    guard !Self.isCaptureFixture(activityID),
      let activity = Activity<BlockedPaneActivityAttributes>.activities
        .first(where: { $0.attributes.hostID == activityID })
    else { return }
    await activity.update(ActivityContent(state: state, staleDate: state.staleDate))
  }

  /// `.immediate` because `.default` leaves an ended card on the Lock Screen for up to four
  /// hours, and a card must never stay after Driverr has disconnected.
  private nonisolated func end(activityID: UUID) async {
    guard !Self.isCaptureFixture(activityID),
      let activity = Activity<BlockedPaneActivityAttributes>.activities
        .first(where: { $0.attributes.hostID == activityID })
    else { return }
    await activity.end(nil, dismissalPolicy: .immediate)
  }

  /// Whether an activity is `BlockedPaneActivityCapture`'s card. Never in Release, where
  /// that type does not exist and nothing can request its card.
  private nonisolated static func isCaptureFixture(_ activityID: UUID) -> Bool {
    #if DEBUG
    activityID == BlockedPaneActivityCapture.hostID
    #else
    false
    #endif
  }

  #if DEBUG
  /// What the most recent `Activity.request` did, for `debug.liveActivity.lastRequest`.
  @MainActor static var lastRequestOutcome = "none"
  #endif
}

#if DEBUG
/// A driver that reaches nothing, for every launch that is not the real app.
///
/// Like `SilentNotificationCenter`, it keeps a UI run from leaving a real Live Activity
/// behind or meeting the system consent sheet.
@MainActor
final class SilentBlockedPaneActivityDriver: BlockedPaneActivityDriving {
  nonisolated init() {}
  func observed(
    _ observations: [HostActivityObservation], scope: ObservationScope, canRequest: Bool
  ) async {}
  func notePaneWasOpened(hostID: UUID, paneID: String) async {}
  func coreIDs(coveringHost hostID: UUID) -> Set<String> { [] }
  func preferencesChanged(_ preferences: LiveActivityPreferences) async {}
}

/// Shows the count of Live Activities this process holds and the last request's outcome,
/// under `-uiTestingLiveActivity` only.
///
/// Adoption cannot be seen in a screenshot: a second launch that adopts the card and one
/// that requests a second both show one card. The count tells them apart. A refused request
/// leaves no card and no message, so the outcome is shown too. Each value is its own element
/// outside any container with an identifier.
private struct BlockedPaneActivityProbe: ViewModifier {
  @State private var count = 0
  @State private var lastRequest = "none"

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .bottom) {
        if AppEnvironment.isLiveActivityDriven {
          VStack(spacing: 2) {
            Text("Live Activities: \(count)")
              .accessibilityIdentifier("debug.liveActivity.count")
            Text("Last request: \(lastRequest)")
              .accessibilityIdentifier("debug.liveActivity.lastRequest")
          }
          .font(.caption)
          .padding(6)
          .background(.regularMaterial)
        }
      }
      .task {
        guard AppEnvironment.isLiveActivityDriven else { return }
        // Polled, because `activityUpdates` reports only activities this process started,
        // and the claim is about one adopted from the last launch.
        while !Task.isCancelled {
          count = Activity<BlockedPaneActivityAttributes>.activities.count
          lastRequest = LiveBlockedPaneActivityDriver.lastRequestOutcome
          try? await Task.sleep(for: .seconds(1))
        }
      }
  }
}

extension View {
  func blockedPaneActivityProbe() -> some View { modifier(BlockedPaneActivityProbe()) }
}
#endif
