#if DEBUG
import ActivityKit
import DriverrCore
import Foundation
import SwiftUI

/// A debug capture of the Live Activity card in states the live path cannot produce on demand.
/// Launch with `-debugBlockedActivity calm|single|multiple|stale|staleview|long|clear`.
///
/// `-uiTestingLiveActivity` drives the real driver and is the source for ordinary captures.
/// This covers the four it cannot: an already stale card, a card with no system stale date,
/// a long host name and pane title, and a blocked count above the seeded tree's. `calm` and
/// `single` let one run put a hand-built card beside the live one.
///
/// It respects the Live Activities setting, so a capture never shows a card the setting
/// should have suppressed.
@MainActor
@Observable
final class BlockedPaneActivityCapture {
  private(set) var status = "Preparing Live Activity fixture"

  static var requestedMode: String? {
    let args = ProcessInfo.processInfo.arguments
    guard let index = args.firstIndex(of: "-debugBlockedActivity"),
      args.indices.contains(index + 1)
    else { return nil }
    return args[index + 1]
  }

  func run(mode: String, isEnabled: Bool, now: Date = .now) async {
    cancelObservers()
    // Only the fixture's own host is removed.
    for activity in Activity<BlockedPaneActivityAttributes>.activities
      where activity.attributes.hostID == Self.hostID
    {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
    guard mode != "clear" else {
      status = "Live Activity fixture cleared"
      return
    }
    guard isEnabled else {
      status = "Live Activities are off in Settings"
      return
    }
    guard ["calm", "single", "multiple", "stale", "staleview", "long"].contains(mode) else {
      status = "Unknown Live Activity fixture: \(mode)"
      return
    }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      status = "Live Activities are disabled"
      return
    }
    let args = ProcessInfo.processInfo.arguments
    var confirmedAt = ["stale", "staleview"].contains(mode)
      ? now.addingTimeInterval(-31 * 60) : now
    if let index = args.firstIndex(of: "-debugBlockedActivityConfirmedAt"),
      args.indices.contains(index + 1), let seconds = Double(args[index + 1])
    {
      confirmedAt = Date(timeIntervalSince1970: seconds)
    }
    let hostName = mode == "long" ? "workbox-with-a-long-descriptive-host-name" : "workbox"
    let blockedCount = mode == "calm" ? 0 : (mode == "multiple" ? 3 : 1)
    let state = BlockedPaneActivityAttributes.ContentState(
      hosts: [
        BlockedPaneActivityAttributes.HostSummary(
          hostID: Self.hostID,
          hostName: hostName,
          counts: AgentStatusCounts(blocked: blockedCount, done: 1, working: 2, idle: 1, shells: 2)
        )
      ],
      blocked: mode == "calm"
        ? nil
        : BlockedPaneActivityAttributes.BlockedPaneSummary(
          hostID: Self.hostID,
          hostName: hostName,
          paneID: "fixture-pane",
          paneTitle: mode == "long"
            ? "Investigate the intermittent integration test failure in the transcript parser"
            : "Fix failing tests",
          agentName: "Claude"
        ),
      lastConfirmedAt: confirmedAt
    )
    // `staleview` withholds the system stale date. ActivityKit shows no card for an activity
    // requested with a past stale date, and it moves a displayed one to `.stale` without
    // re-rendering it. So only the widget's own render-time date check can show the stale
    // copy. `stale` keeps the real contract.
    let systemStaleDate: Date? = mode == "staleview" ? nil : state.staleDate
    do {
      let activity = try Activity.request(
        attributes: BlockedPaneActivityAttributes(hostID: Self.hostID),
        content: ActivityContent(state: state, staleDate: systemStaleDate), pushType: nil
      )
      report(mode: mode, activity: activity)
      observe(mode: mode, activity: activity)
    } catch {
      status = "Live Activity fixture failed: \(error.localizedDescription)"
    }
  }

  /// Reports the live handle's current state and stale date, so a capture shows whether the
  /// system has moved the activity to `.stale`.
  private func report(mode: String, activity: Activity<BlockedPaneActivityAttributes>) {
    let expiry = activity.content.staleDate.map { String($0.timeIntervalSince1970) } ?? "nil"
    status = "Live Activity fixture ready: \(mode) · \(activity.id)"
      + " · state=\(activity.activityState) · staleDate=\(expiry)"
  }

  private func observe(mode: String, activity: Activity<BlockedPaneActivityAttributes>) {
    observers = [
      Task { [weak self] in
        for await _ in activity.activityStateUpdates {
          guard let self, !Task.isCancelled else { return }
          report(mode: mode, activity: activity)
        }
      },
      // `activityStateUpdates` is not documented to deliver every transition, so the label is
      // also refreshed on a timer for about as long as a capture run lasts.
      Task { [weak self] in
        for _ in 0..<120 {
          try? await Task.sleep(for: .seconds(5))
          guard let self, !Task.isCancelled else { return }
          report(mode: mode, activity: activity)
        }
      },
    ]
  }

  private func cancelObservers() {
    for observer in observers { observer.cancel() }
    observers = []
  }

  private var observers: [Task<Void, Never>] = []
  /// Not private and `nonisolated`, because `LiveBlockedPaneActivityDriver.isCaptureFixture`
  /// reads it off the main actor to leave this card alone.
  nonisolated static let hostID = UUID(uuidString: "55100000-0000-0000-0000-000000000001")!
}

private struct BlockedPaneActivityCaptureModifier: ViewModifier {
  let mode: String?
  /// Passed in, not read from `@Environment`. See CLAUDE.md, "Two environment rules".
  let settings: SettingsModel
  @State private var fixture = BlockedPaneActivityCapture()

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .top) {
        if mode != nil {
          Text(fixture.status)
            .font(.caption)
            .padding(8)
            .background(.regularMaterial)
            .accessibilityIdentifier("debug.blockedActivity.status")
        }
      }
      .task {
        if let mode { await fixture.run(mode: mode, isEnabled: settings.settings.liveActivities) }
      }
  }
}

extension View {
  func blockedPaneActivityCapture(settings: SettingsModel) -> some View {
    modifier(
      BlockedPaneActivityCaptureModifier(
        mode: BlockedPaneActivityCapture.requestedMode, settings: settings))
  }
}
#endif
