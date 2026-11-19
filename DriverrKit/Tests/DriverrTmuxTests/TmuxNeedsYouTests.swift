import DriverrCore
import DriverrHerdr
import Foundation
import Testing

@testable import DriverrTmux

/// A Claude waiting in a tmux pane reaches Needs You, the notification and the Live Activity as a
/// herdr pane does.
///
/// Each path reads the host's `SessionTree` and nothing else, so these tests take the tree from
/// the control the app builds, `CombinedControl.joining`, and hand it to the same rules the
/// foreground poll and the background pass run. Nothing here branches on the `tmux:` prefix.
@Suite("tmux Needs You")
struct TmuxNeedsYouTests {
  enum Shape: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// No herdr. `joining` hands back the bare `TmuxControl`.
    case tmuxAlone
    /// A herdr TUI with nothing blocked, and tmux as a side.
    case besideHerdr

    var testDescription: String { rawValue }
  }

  private let hostID = UUID()
  private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
  private let claudeSession = "11111111-2222-3333-4444-555555555555"

  /// The control `AppEnvironment.makeHerdrControl` builds for this host.
  private func control(_ shape: Shape, host: FakeTmuxHost) throws -> any HerdrControl {
    let tmux = CombinedControl.Side(prefix: TmuxID.prefix, control: TmuxControl(run: host.runner))
    let tui: (any HerdrControl)? =
      shape == .besideHerdr ? FakeControl(tree: FakeControl.treeWithoutTheBlockedPane) : nil
    return try #require(CombinedControl.joining(tui: tui, sides: [tmux]))
  }

  /// What `ConnectionRegistry.liveActivityObservations` and the background pass build.
  private func observation(_ tree: SessionTree) -> HostActivityObservation {
    HostActivityObservation(
      hostID: hostID,
      hostName: "workbox",
      isConnected: true,
      blockedPanes: tree.blockedPanes,
      counts: tree.agentStatusCounts,
      observedAt: now,
      coreID: tree.coreID,
      machineCoreIDs: tree.machineCoreIDs
    )
  }

  private func reconcile(
    _ tree: SessionTree, existing: [ExistingLiveActivity] = []
  ) -> [LiveActivityAction] {
    BlockedPaneActivityPlan.reconcile(
      observations: [observation(tree)], scope: .everyConnectedHost, existing: existing,
      preferences: LiveActivityPreferences(), canRequest: true, now: now)
  }

  @Test("a waiting Claude in tmux is announced, carried by the card, and withdrawn when it works",
    arguments: Shape.allCases)
  func waitingThenBusy(shape: Shape) async throws {
    let host = FakeTmuxHost.seeded()
    let control = try control(shape, host: host)
    #expect((control is CombinedControl) == (shape == .besideHerdr))

    // Needs You.
    let waiting = try await control.snapshot()
    #expect(waiting.blockedPanes.map(\.id) == ["tmux:%1"])
    let pane = try #require(waiting.pane(id: "tmux:%1"))
    #expect(pane.agent?.status == .blocked)
    #expect(pane.agent?.blockedKind == .permission)
    #expect(waiting.loneBlockedPane?.id == "tmux:%1")
    #expect(waiting.agentStatusCounts.blocked == 1)

    // The notification: announced once, and not again while it still waits.
    var alerts = BlockedPaneAlerts()
    let announced = alerts.update(to: waiting, isAppActive: false)
    #expect(announced.announce.map(\.id) == ["tmux:%1"])
    #expect(announced.clear.isEmpty)
    #expect(alerts.update(to: try await control.snapshot(), isAppActive: false).isEmpty)

    // The Live Activity names the pane, and a tap on it opens that pane.
    guard case .request(let card) = try #require(reconcile(waiting).first) else {
      Issue.record("no card was requested: \(reconcile(waiting))")
      return
    }
    #expect(card.blocked?.paneID == "tmux:%1")
    #expect(card.blocked?.hostID == hostID)
    #expect(card.blockedCount == 1)
    let target = BlockedPaneActivityRoute.Target.pane(hostID: hostID, paneID: "tmux:%1")
    #expect(BlockedPaneActivityRoute.target(of: card) == target)
    let url = try #require(BlockedPaneActivityRoute.url(for: card))
    #expect(BlockedPaneActivityRoute.target(of: url) == target)

    // Answered at the desk: Claude works again.
    await host.setRecord(
      pid: 5002, FakeTmuxHost.claudeRecord(pid: 5002, sessionID: claudeSession, status: "busy"))
    let working = try await control.snapshot()
    #expect(working.pane(id: "tmux:%1")?.agent?.status == .working)
    #expect(working.pane(id: "tmux:%1")?.agent?.blockedKind == nil)
    #expect(working.blockedPanes.isEmpty)

    let withdrawn = alerts.update(to: working, isAppActive: false)
    #expect(withdrawn.clear == ["tmux:%1"])
    #expect(withdrawn.announce.isEmpty)

    let standing = ExistingLiveActivity(activityID: UUID(), state: card)
    guard case .update(_, let calm) = try #require(reconcile(working, existing: [standing]).first)
    else {
      Issue.record("the card was not updated: \(reconcile(working, existing: [standing]))")
      return
    }
    #expect(calm.blocked == nil)
    #expect(calm.blockedCount == 0)
  }

  @Test("a question in tmux is blocked on a question, and a new wait is announced again",
    arguments: Shape.allCases)
  func questionAfterWork(shape: Shape) async throws {
    let host = FakeTmuxHost.seeded()
    await host.setRecord(
      pid: 5002, FakeTmuxHost.claudeRecord(pid: 5002, sessionID: claudeSession, status: "busy"))
    let control = try control(shape, host: host)
    var alerts = BlockedPaneAlerts()
    #expect(alerts.update(to: try await control.snapshot(), isAppActive: false).isEmpty)

    await host.setRecord(
      pid: 5002,
      FakeTmuxHost.claudeRecord(
        pid: 5002, sessionID: claudeSession, status: "waiting", waitingFor: "input needed"))
    let asking = try await control.snapshot()
    #expect(asking.pane(id: "tmux:%1")?.agent?.blockedKind == .question)
    #expect(alerts.update(to: asking, isAppActive: false).announce.map(\.id) == ["tmux:%1"])
  }

  // MARK: Codex (#102 S4b)

  /// `%1` runs Codex, behind a foreground-group leader that is not Codex, in `/home/dev/app`.
  private func codexHost(title: String) -> FakeTmuxHost {
    FakeTmuxHost(
      sessions: [
        .init(
          id: 0, name: "work", attached: 1,
          windows: [
            .init(
              id: 0, index: 0, name: "codex", isActive: true,
              panes: [
                .init(id: 0, isActive: true),
                .init(id: 1, title: title, command: "codex", path: "/home/dev/app"),
              ])
          ])
      ],
      processes: [
        .init(pid: 5001, tty: "ttys100", command: "zsh"),
        .init(pid: 6000, groupID: 6000, foregroundGroupID: 6000, tty: "ttys101", command: "sh"),
        .init(
          pid: 6001, groupID: 6000, foregroundGroupID: 6000, tty: "ttys101",
          command: "/home/dev/.local/bin/codex"),
      ]
    )
  }

  @Test("a Codex asking for approval in tmux is announced once across the blink, carried by the card, and withdrawn when it works",
    arguments: Shape.allCases)
  func codexWaitingThenWorking(shape: Shape) async throws {
    let host = codexHost(title: "[ ! ] Action Required | app")
    let control = try control(shape, host: host)

    let waiting = try await control.snapshot()
    #expect(waiting.blockedPanes.map(\.id) == ["tmux:%1"])
    let pane = try #require(waiting.pane(id: "tmux:%1"))
    #expect(pane.agent?.kind == TranscriptAgent.codex.rawValue)
    #expect(pane.agent?.status == .blocked)
    #expect(pane.agent?.blockedKind == nil)
    #expect(pane.agent?.session == nil)
    #expect(pane.directory == "/home/dev/app")
    #expect(waiting.loneBlockedPane?.id == "tmux:%1")
    #expect(waiting.agentStatusCounts.blocked == 1)

    var alerts = BlockedPaneAlerts()
    #expect(alerts.update(to: waiting, isAppActive: false).announce.map(\.id) == ["tmux:%1"])

    // The title blinks each second. The other frame is the same request, not a new one.
    await host.setTitle(of: 1, "[ . ] Action Required | app")
    let blinked = try await control.snapshot()
    #expect(blinked.blockedPanes.map(\.id) == ["tmux:%1"])
    #expect(blinked.pane(id: "tmux:%1")?.title == pane.title)
    #expect(alerts.update(to: blinked, isAppActive: false).isEmpty)

    guard case .request(let card) = try #require(reconcile(waiting).first) else {
      Issue.record("no card was requested: \(reconcile(waiting))")
      return
    }
    #expect(card.blocked?.paneID == "tmux:%1")
    #expect(card.blockedCount == 1)
    // The standing card still names the same pane in the other frame.
    for action in reconcile(blinked, existing: [ExistingLiveActivity(activityID: UUID(), state: card)]) {
      switch action {
      case .update(_, let state): #expect(state.blocked?.paneID == "tmux:%1")
      case .request, .end: Issue.record("the blink changed the card: \(action)")
      }
    }

    // Approved at the desk: Codex works again.
    await host.setTitle(of: 1, "⠙ app")
    let working = try await control.snapshot()
    #expect(working.pane(id: "tmux:%1")?.agent?.status == .working)
    #expect(working.blockedPanes.isEmpty)
    #expect(alerts.update(to: working, isAppActive: false).clear == ["tmux:%1"])

    let standing = ExistingLiveActivity(activityID: UUID(), state: card)
    guard case .update(_, let calm) = try #require(reconcile(working, existing: [standing]).first)
    else {
      Issue.record("the card was not updated: \(reconcile(working, existing: [standing]))")
      return
    }
    #expect(calm.blocked == nil)
    #expect(calm.blockedCount == 0)
  }
}
