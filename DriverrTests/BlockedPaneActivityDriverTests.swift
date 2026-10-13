import DriverrCore
import Foundation
import Testing

@testable import Driverr

/// A driver that records what the app asked of it and reaches no system service.
///
/// The claims here are wiring: each feed builds the observation the reconciler needs and hands
/// it over with the right `canRequest`. The rules are `BlockedPaneActivityPlanTests`.
///
/// Internal, because `ConnectionModelTests` drives the foreground feed.
@MainActor
final class RecordingActivityDriver: BlockedPaneActivityDriving {
  struct Pass {
    let observations: [HostActivityObservation]
    let scope: ObservationScope
    let canRequest: Bool
  }

  private(set) var passes: [Pass] = []
  private(set) var opens: [(hostID: UUID, paneID: String)] = []
  /// Every preference value the app pushed, in order.
  private(set) var preferenceValues: [LiveActivityPreferences] = []
  /// The calls in arrival order: the preferences have to reach the driver before the pass that
  /// would request a card.
  private(set) var events: [String] = []

  func observed(
    _ observations: [HostActivityObservation], scope: ObservationScope, canRequest: Bool
  ) async {
    passes.append(Pass(observations: observations, scope: scope, canRequest: canRequest))
    events.append("observed")
    // The wake-up for `ConnectionModelTests`' waits on `passes`: a plain array, fed from an
    // unstructured `Task` the test cannot await.
    Waker.signalShared()
  }

  func notePaneWasOpened(hostID: UUID, paneID: String) async {
    opens.append((hostID, paneID))
  }

  func preferencesChanged(_ preferences: LiveActivityPreferences) async {
    preferenceValues.append(preferences)
    events.append("preferences(isEnabled: \(preferences.isEnabled))")
  }
}

private func pane(_ id: String, status: AgentStatus) -> Pane {
  Pane(id: id, tabID: "t1", workspaceID: "w1", title: "pane \(id)",
    agent: Agent(name: "Claude", status: status))
}

private func tree(_ panes: [Pane]) -> SessionTree {
  SessionTree(workspaces: [
    Workspace(id: "w1", number: 1, label: "one",
      tabs: [Tab(id: "t1", workspaceID: "w1", number: 1, label: "a", panes: panes)])
  ])
}

/// A connection that answers without a transport, so a refresh can be run end to end.
@MainActor
private final class StubSession: BackgroundRefreshSession {
  let snapshot: SessionTree?
  var isConnectedForRefresh = true
  init(snapshot: SessionTree?) { self.snapshot = snapshot }
  func connectForRefresh() async {}
  func snapshotForRefresh() async -> SessionTree? { snapshot }
  func disconnect() async {}
}

@MainActor
@Suite("Live Activity wiring", .timeLimit(.minutes(1)))
struct BlockedPaneActivityDriverTests {
  private let workbox = DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson")

  private func environment(_ driver: RecordingActivityDriver) -> AppEnvironment {
    var environment = AppEnvironment.ephemeral
    environment.hostStore = InMemoryHostStore(seeded: [workbox])
    environment.blockedPaneActivities = driver
    return environment
  }

  /// An activity is requested from the foreground. A `BGAppRefreshTask` handler may update and
  /// end one but not start one; a silently refused request would be a card that never appears.
  @Test("a background refresh observes its host and may not request")
  func theBackgroundFeedCannotRequest() async throws {
    let driver = RecordingActivityDriver()
    let runner = BackgroundRefreshRunner(
      environment: environment(driver),
      storedSelection: { self.workbox.id.uuidString },
      makeSession: { _, _ in
        StubSession(snapshot: tree([pane("w1:p1", status: .blocked),
          pane("w1:p2", status: .working)]))
      }
    )

    #expect(await runner.run() == .refreshed(blockedPanes: 1))
    let pass = try #require(driver.passes.first)
    #expect(driver.passes.count == 1)
    #expect(pass.canRequest == false)
    // `.oneHost`: this process reached one machine and says nothing about others. An
    // authoritative scope would end the card for every host but this one.
    #expect(pass.scope == .oneHost(workbox.id))
    let seen = try #require(pass.observations.first)
    #expect(pass.observations.count == 1)
    #expect(seen.hostID == workbox.id)
    #expect(seen.hostName == "workbox")
    // The refresh's own `session.disconnect()` is not a host disconnect: the observation is
    // about the host's panes, not the borrowed socket.
    #expect(seen.isConnected)
    #expect(seen.blockedPanes.map(\.id) == ["w1:p1"])
    #expect(seen.counts == AgentStatusCounts(blocked: 1, working: 1))
  }

  /// A `BGAppRefreshTask` relaunch has no `SettingsModel`, so the runner reads the store
  /// itself. Otherwise the driver defaults to on and updates a card for a reader who turned the
  /// feature off. Pushed before the feed, so the pass that follows knows the answer.
  @Test("a background refresh reads the setting from the store and pushes it first")
  func theBackgroundFeedPushesTheSetting() async {
    let driver = RecordingActivityDriver()
    var environment = environment(driver)
    environment.settingsStore = InMemorySettingsStore(TerminalSettings(liveActivities: false))
    let runner = BackgroundRefreshRunner(
      environment: environment,
      storedSelection: { self.workbox.id.uuidString },
      makeSession: { _, _ in StubSession(snapshot: tree([pane("w1:p1", status: .blocked)])) }
    )

    #expect(await runner.run() == .refreshed(blockedPanes: 1))
    #expect(driver.preferenceValues.map(\.isEnabled) == [false])
    #expect(driver.events == ["preferences(isEnabled: false)", "observed"])
  }

  /// A host the reader stopped stays stopped through a relaunch, and only the store knows.
  @Test("a background refresh reads the per-host overrides from their own store")
  func theBackgroundFeedPushesTheHostOverrides() async {
    let driver = RecordingActivityDriver()
    var environment = environment(driver)
    environment.liveActivityPreferences = InMemoryLiveActivityPreferenceStore(
      [workbox.id.uuidString: false])
    let runner = BackgroundRefreshRunner(
      environment: environment,
      storedSelection: { self.workbox.id.uuidString },
      makeSession: { _, _ in StubSession(snapshot: tree([pane("w1:p1", status: .blocked)])) }
    )

    #expect(await runner.run() == .refreshed(blockedPanes: 1))
    #expect(driver.preferenceValues.first?.isOn(for: workbox.id) == false)
  }

  /// The other value, so a runner that pushed a hardcoded `false` would fail here.
  @Test("a background refresh pushes the setting it actually read")
  func theBackgroundFeedPushesAnEnabledSetting() async {
    let driver = RecordingActivityDriver()
    var environment = environment(driver)
    environment.settingsStore = InMemorySettingsStore(TerminalSettings(liveActivities: true))
    let runner = BackgroundRefreshRunner(
      environment: environment,
      storedSelection: { self.workbox.id.uuidString },
      makeSession: { _, _ in StubSession(snapshot: tree([pane("w1:p1", status: .blocked)])) }
    )

    #expect(await runner.run() == .refreshed(blockedPanes: 1))
    #expect(driver.preferenceValues.map(\.isEnabled) == [true])
  }

  /// A refresh that finds nothing blocked still has to say so, or the card it could have
  /// ended stays up until its own stale date.
  @Test("a background refresh that finds a clear host still reports it")
  func theBackgroundFeedReportsAClearHost() async throws {
    let driver = RecordingActivityDriver()
    let runner = BackgroundRefreshRunner(
      environment: environment(driver),
      storedSelection: { self.workbox.id.uuidString },
      makeSession: { _, _ in StubSession(snapshot: tree([pane("w1:p1", status: .working)])) }
    )

    #expect(await runner.run() == .refreshed(blockedPanes: 0))
    let pass = try #require(driver.passes.first)
    let seen = try #require(pass.observations.first)
    #expect(seen.blockedPanes.isEmpty)
    #expect(seen.isConnected)
    #expect(pass.canRequest == false)
  }

  @Test("a refresh that could not reach the host observes nothing at all")
  func anUnreachableHostIsNotAnObservation() async {
    let driver = RecordingActivityDriver()
    let runner = BackgroundRefreshRunner(
      environment: environment(driver),
      storedSelection: { self.workbox.id.uuidString },
      makeSession: { _, _ in StubSession(snapshot: nil) }
    )

    #expect(await runner.run() == .couldNotReachTheHost)
    #expect(driver.passes.isEmpty)
  }

  /// The same funnel `withdrawNotification` hangs off, one surface over.
  @Test("opening a pane tells the driver which pane it was")
  func anOpenReachesTheDriver() async throws {
    let driver = RecordingActivityDriver()
    let environment = environment(driver)
    let presenter = TerminalPresenter()
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    let model = registry.model(for: workbox, environment: environment)
    presenter.configure(
      hostStore: environment.hostStore,
      connections: registry,
      environment: environment,
      select: { _ in }
    )

    presenter.present(host: workbox, model: model, pane: pane("w1:p2", status: .blocked))
    try await Task.sleep(for: .milliseconds(50))
    let open = try #require(driver.opens.first)
    #expect(driver.opens.count == 1)
    #expect(open.hostID == workbox.id)
    #expect(open.paneID == "w1:p2")
  }

  /// A shell carries no pane, so there is no card it could de-escalate.
  @Test("presenting a plain shell de-escalates nothing")
  func aShellIsNotAnOpen() async throws {
    let driver = RecordingActivityDriver()
    let environment = environment(driver)
    let presenter = TerminalPresenter()
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    let model = registry.model(for: workbox, environment: environment)
    presenter.configure(
      hostStore: environment.hostStore,
      connections: registry,
      environment: environment,
      select: { _ in }
    )

    presenter.present(host: workbox, model: model)
    try await Task.sleep(for: .milliseconds(50))
    #expect(driver.opens.isEmpty)
  }

  /// The app-side half of the orphaned-card rule.
  ///
  /// `ContentView`'s `.task` pushes one pass before anything has connected. That push still
  /// happens with an empty observation list, which the reconciler turns into
  /// `.end(.noConnectedHosts)` for a card the last process left standing.
  @Test("a push over an empty registry still reaches the driver, carrying nothing")
  func anEmptyRegistryStillPushes() {
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    var passes: [(observations: [HostActivityObservation], canRequest: Bool)] = []
    registry.onLiveActivityInputChanged = { passes.append(($0, $1)) }

    #expect(registry.liveActivityObservations().isEmpty)
    registry.pushLiveActivityObservations()

    #expect(passes.count == 1, "a launch with no connections must still push a pass")
    #expect(passes.first?.observations.isEmpty == true)
    #expect(passes.first?.canRequest == true, "the app is in front at launch")
  }

  /// The guard that keeps UI classes off ActivityKit. This process carries no
  /// `-uiTestingLiveActivity`, as most UI classes do not.
  @Test("a launch that did not ask for Live Activities gets the silent driver")
  func theDefaultDriverIsSilent() {
    #expect(AppEnvironment.isLiveActivityDriven == false)
    #expect(AppEnvironment.ephemeral.blockedPaneActivities is SilentBlockedPaneActivityDriver)
  }
}
