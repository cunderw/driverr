import DriverrCore
import Foundation
import Testing

@testable import Driverr

// The app-target half of Continue in Background.
//
// The decisions are `BackgroundWatchPolicyTests` in the kit. This is the wiring: what the
// submit asks for, what the loop feeds the Live Activity driver, and that every end reports
// completion to the system exactly once. The scheduler and the task are behind protocols, the
// seam that also keeps a UI run from submitting a real one.

// MARK: - Fakes

/// A scheduler that records rather than reaching `BGTaskScheduler`.
///
/// `@unchecked Sendable` because `BackgroundWatchScheduling` is `Sendable`. Every call comes
/// from the main actor, so there is no concurrent access to guard.
private final class FakeWatchScheduler: BackgroundWatchScheduling, @unchecked Sendable {
  struct Submission: Equatable {
    let title: String
    let subtitle: String
  }

  private(set) var submissions: [Submission] = []
  private(set) var cancelled: [String] = []
  var registerAnswer = true
  var acceptsSubmissions = true
  private(set) var didRegister = false

  func register(_ run: @escaping @Sendable @MainActor (BackgroundWatchTask) -> Void) -> Bool {
    didRegister = true
    return registerAnswer
  }

  func submit(title: String, subtitle: String) -> String? {
    submissions.append(Submission(title: title, subtitle: subtitle))
    return acceptsSubmissions ? BackgroundWatch.taskIdentifier : nil
  }

  func cancel(identifier: String) { cancelled.append(identifier) }
}

/// A stand-in for the live `BGContinuedProcessingTask`.
@MainActor
private final class FakeWatchTask: BackgroundWatchTask {
  let watchIdentifier = BackgroundWatch.taskIdentifier

  private(set) var cards: [(title: String, subtitle: String)] = []
  private(set) var completions: [Bool] = []
  private(set) var didReportIndeterminate = false
  private var expiration: (@Sendable () -> Void)?

  func updateCard(title: String, subtitle: String) { cards.append((title, subtitle)) }
  func reportIndeterminateProgress() { didReportIndeterminate = true }
  func complete(success: Bool) { completions.append(success) }
  func onExpiration(_ handler: @escaping @Sendable () -> Void) { expiration = handler }

  /// What iOS does when the person taps Cancel on its own card, or when the scheduler takes
  /// the budget back. The API gives Driverr one delivery for both.
  func expire() { expiration?() }
}

/// A connection that answers without a transport.
@MainActor
private final class FakeWatchSession: BackgroundWatchSession {
  /// Why a pending connect stopped being pending. The expiry test asserts on this, not a
  /// stopwatch: the connect ended because the run was expired, not on its own deadline.
  enum ConnectEnding: Equatable { case disconnect, ownDeadline }

  var isConnectedForWatch = true
  var snapshot: SessionTree? = tree([pane("p1", status: .working)])
  private(set) var snapshots = 0
  private(set) var disconnects = 0
  private(set) var connects = 0
  private(set) var connectEnding: ConnectEnding?
  /// Run after each snapshot, so a test can end the run from inside the loop rather than
  /// from a stopwatch.
  var afterSnapshot: (@MainActor (Int) -> Void)?
  /// Run inside `connectForWatch`, so a test can take the budget away mid-handshake.
  var duringConnect: (@MainActor () -> Void)?

  /// Whether a connect hangs until something ends it.
  ///
  /// This lets the expiry test fail. `ConnectionModel.connect` awaits an unstructured `Task`,
  /// so a pending handshake ends only when `disconnect()` cancels it or its own deadline runs
  /// out. A connect that returns promptly would pass whether or not the expiration handler
  /// reached it.
  var connectHangs = false

  private var pendingConnect: CheckedContinuation<Void, Never>?
  private var connectIsPending = false

  func connectForWatch() async {
    connects += 1
    duringConnect?()
    guard connectHangs else {
      for _ in 0..<4 { await Task.yield() }
      return
    }
    // Set before the await, as `ConnectionModel` assigns `connectAttempt`, so a disconnect at
    // any point after the connect starts finds something to end.
    connectIsPending = true
    // The connect's own deadline, so a run that never reaches the connect fails rather than
    // hanging the suite.
    let ownDeadline = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(300))
      self.endConnect(.ownDeadline)
    }
    await withCheckedContinuation { continuation in
      if connectIsPending {
        pendingConnect = continuation
      } else {
        continuation.resume()
      }
    }
    ownDeadline.cancel()
  }

  private func endConnect(_ ending: ConnectEnding) {
    guard connectIsPending else { return }
    connectIsPending = false
    connectEnding = ending
    pendingConnect?.resume()
    pendingConnect = nil
  }

  func snapshotForWatch() async -> SessionTree? {
    snapshots += 1
    afterSnapshot?(snapshots)
    return snapshot
  }

  func disconnect() async {
    disconnects += 1
    // A real disconnect takes the link down, and the run reads `isConnectedForWatch` after
    // the connect returns.
    isConnectedForWatch = false
    endConnect(.disconnect)
  }
}

private func pane(_ id: String, status: AgentStatus) -> Pane {
  Pane(
    id: id, tabID: "t1", workspaceID: "w1", title: "pane \(id)",
    agent: Agent(name: "Claude", status: status))
}

private func tree(_ panes: [Pane]) -> SessionTree {
  SessionTree(workspaces: [
    Workspace(
      id: "w1", number: 1, label: "one",
      tabs: [Tab(id: "t1", workspaceID: "w1", number: 1, label: "a", panes: panes)])
  ])
}

// MARK: - The suite

@MainActor
@Suite("Continue in Background — the runner")
struct BackgroundWatchRunnerTests {
  private let host = DriverrCore.Host(
    id: UUID(uuidString: "33333333-0000-0000-0000-000000000003")!,
    name: "workbox", hostname: "10.1.0.9", username: "carson")

  private func makeRunner(
    connecting made: FakeWatchSession? = nil
  ) -> (BackgroundWatchRunner, FakeWatchScheduler, RecordingActivityDriver) {
    let scheduler = FakeWatchScheduler()
    let driver = RecordingActivityDriver()
    var environment = AppEnvironment.ephemeral
    environment.backgroundWatch = scheduler
    environment.blockedPaneActivities = driver
    // A millisecond rather than the app's three seconds.
    //
    // `made` is what the runner builds when the borrowed connection has gone. A seam, because
    // only the owned-connection path disconnects anything, and without it the disconnect
    // assertions could not fail.
    let runner = BackgroundWatchRunner(
      environment: environment,
      pollInterval: .milliseconds(1),
      makeSession: { _, _ in made ?? FakeWatchSession() })
    return (runner, scheduler, driver)
  }

  // MARK: The tap

  /// The card iOS draws takes its title and subtitle from the tap: a pane from the … menu, the
  /// host from the host screen.
  @Test("the tap submits a request naming what is being watched")
  func theTapSubmitsARequest() {
    let (runner, scheduler, _) = makeRunner()
    let session = FakeWatchSession()

    runner.start(host: host, subject: "claude", session: session)

    #expect(scheduler.submissions == [.init(title: "Watching claude", subtitle: "on workbox")])
    #expect(runner.isRunning(for: host.id))
    #expect(runner.machine.state == .running(hostID: host.id, hasLaunched: false))
  }

  /// A refused submit must put the control back, or it reads "Stop Continuing in Background"
  /// for a run that will never start.
  @Test("a refused submit ends the run instead of leaving a Stop on screen")
  func aRefusedSubmitEndsTheRun() {
    let (runner, scheduler, _) = makeRunner()
    scheduler.acceptsSubmissions = false

    runner.start(host: host, subject: "claude", session: FakeWatchSession())

    #expect(runner.isRunning(for: host.id) == false)
    #expect(runner.machine.state == .ended(.couldNotSubmit))
    // One attempt, and no retry under a suffixed identifier: `register` is called for the
    // plain identifier alone, so such a request could be accepted and never launched. See
    // `LiveBackgroundWatchScheduler.submit`.
    #expect(scheduler.submissions.count == 1)
  }

  /// One run at a time: a second host's tap cannot submit. The rule is
  /// `BackgroundWatchPolicyTests`'.
  @Test("a second host cannot submit while a run is up")
  func aSecondHostCannotSubmit() {
    let (runner, scheduler, _) = makeRunner()
    let other = DriverrCore.Host(
      id: UUID(uuidString: "44444444-0000-0000-0000-000000000004")!,
      name: "buildbox", hostname: "10.1.0.10", username: "carson")

    runner.start(host: host, subject: "claude", session: FakeWatchSession())
    runner.start(host: other, subject: "codex", session: FakeWatchSession())

    #expect(scheduler.submissions.count == 1)
    #expect(runner.isRunningForAnotherHost(than: other.id))
    #expect(runner.isRunningForAnotherHost(than: host.id) == false)
  }

  /// The second tap on the same control stops rather than submitting again.
  @Test("tapping again stops the run")
  func tappingAgainStopsTheRun() async {
    let (runner, scheduler, _) = makeRunner()
    let session = FakeWatchSession()
    let task = FakeWatchTask()
    let host = host
    session.afterSnapshot = { _ in
      runner.toggle(host: host, subject: "claude", session: session)
    }

    runner.toggle(host: host, subject: "claude", session: session)
    await runner.run(task)

    #expect(scheduler.submissions.count == 1)
    #expect(runner.machine.state == .ended(.stoppedFromTheApp))
    #expect(task.completions == [true])
  }

  // MARK: The loop

  /// The poll keeps going, and every tick feeds the same Live Activity driver the foreground
  /// gather does.
  @Test("each poll feeds the activity driver for this host alone and requests nothing")
  func eachPollFeedsTheDriver() async {
    let (runner, _, driver) = makeRunner()
    let session = FakeWatchSession()
    let task = FakeWatchTask()
    session.afterSnapshot = { count in if count == 2 { runner.stop() } }

    runner.start(host: host, subject: "claude", session: session)
    await runner.run(task)

    #expect(driver.passes.count == 2)
    #expect(driver.passes.first?.scope == .oneHost(host.id))
    // A card is requested from the foreground only. `canRequest: false` makes a background
    // request unreachable rather than a silent throw.
    #expect(driver.passes.first?.canRequest == false)
    #expect(driver.passes.first?.observations.map(\.hostID) == [host.id])
    #expect(driver.passes.first?.observations.first?.isConnected == true)
    // No preferences are pushed: this runs in the process the person was just in, unlike
    // `BackgroundRefreshRunner`, which wakes with no `SettingsModel`.
    #expect(driver.preferenceValues.isEmpty)
  }

  /// A watch sees one host, and the card carries the others' counts, machines included.
  @Test("a poll leaves out a machine another host on the card shows")
  func aPollHidesACoveredMachine() async throws {
    let (runner, _, driver) = makeRunner()
    driver.coveringCoreIDs[host.id] = ["core-b"]
    let session = FakeWatchSession()
    session.snapshot = SessionTree(
      workspaces: [
        Workspace(
          id: "bee", number: 1, label: "bee",
          tabs: [
            Tab(
              id: "t1", workspaceID: "bee", number: 1, label: "a",
              panes: [pane("core:bee/t1", status: .blocked)])
          ],
          machineCoreID: "core-b")
      ],
      coreID: "core-a"
    )
    let task = FakeWatchTask()
    session.afterSnapshot = { _ in runner.stop() }

    runner.start(host: host, subject: "claude", session: session)
    await runner.run(task)

    let seen = try #require(driver.passes.first?.observations.first)
    #expect(seen.blockedPanes.isEmpty)
    #expect(seen.counts == AgentStatusCounts())
    #expect(seen.coreID == "core-a")
  }

  /// Indeterminate progress, reported once before any work. Watching a pane has no honest
  /// completion fraction.
  @Test("progress is reported indeterminate")
  func progressIsIndeterminate() async {
    let (runner, _, _) = makeRunner()
    let session = FakeWatchSession()
    let task = FakeWatchTask()
    session.afterSnapshot = { _ in runner.stop() }

    runner.start(host: host, subject: "claude", session: session)
    await runner.run(task)

    #expect(task.didReportIndeterminate)
  }

  /// The card's subtitle is the only place this feature can say what it has done, so it counts
  /// checks.
  @Test("the system card is retitled with the check count")
  func theSystemCardCountsChecks() async {
    let (runner, _, _) = makeRunner()
    let session = FakeWatchSession()
    let task = FakeWatchTask()
    session.afterSnapshot = { count in if count == 2 { runner.stop() } }

    runner.start(host: host, subject: "claude", session: session)
    await runner.run(task)

    #expect(task.cards.map(\.title) == ["Watching claude", "Watching claude"])
    #expect(task.cards.map(\.subtitle) == ["on workbox · 1 check", "on workbox · 2 checks"])
  }

  /// The borrowed connection is the person's own foreground session: released, never closed.
  ///
  /// The next test, which does disconnect, is what lets this one fail. Together they separate
  /// "never disconnects" from "cannot disconnect".
  @Test("the run never disconnects the session it borrowed")
  func theRunNeverDisconnectsTheBorrowedSession() async {
    let (runner, _, _) = makeRunner()
    let session = FakeWatchSession()
    let task = FakeWatchTask()
    session.afterSnapshot = { _ in runner.stop() }

    runner.start(host: host, subject: "claude", session: session)
    await runner.run(task)

    #expect(session.disconnects == 0)
    #expect(session.connects == 0)
  }

  /// A connection this run made is this run's to put down, as in `BackgroundRefreshRunner`:
  /// nobody is looking at it.
  ///
  /// The branch fires when the link dropped between the tap and the launch, which a
  /// `strategy: .queue` request can delay. A relaunch leaves nothing pending and takes
  /// `.nothingToWatch` instead.
  @Test("a connection the run made itself is disconnected on the way out")
  func aConnectionTheRunMadeIsDisconnected() async {
    let made = FakeWatchSession()
    let (runner, _, _) = makeRunner(connecting: made)
    let borrowed = FakeWatchSession()
    borrowed.isConnectedForWatch = false
    let task = FakeWatchTask()
    made.afterSnapshot = { _ in runner.stop() }

    runner.start(host: host, subject: "claude", session: borrowed)
    await runner.run(task)

    #expect(made.connects == 1)
    #expect(made.disconnects == 1)
    // The borrowed one is still not this run's to close.
    #expect(borrowed.disconnects == 0)
  }

  /// An expiry during the connect is an expiry, not a host Driverr could not reach.
  ///
  /// The expiration handler firing does not make a handshake return. The handler hops to the
  /// main actor and disconnects the session this run owns, so the pending connect returns at
  /// once rather than after its own deadline, long after iOS took the budget back.
  @Test("an expiry during the connect ends the run and puts that connection down")
  func anExpiryDuringTheConnectEndsTheRun() async {
    let made = FakeWatchSession()
    let (runner, _, _) = makeRunner(connecting: made)
    let borrowed = FakeWatchSession()
    borrowed.isConnectedForWatch = false
    let task = FakeWatchTask()
    // The handshake hangs and the expiry lands in the middle of it.
    made.connectHangs = true
    made.duringConnect = { task.expire() }

    runner.start(host: host, subject: "claude", session: borrowed)
    await runner.run(task)

    // The connect ended because the expiry reached it. Without recording the session before
    // the await, or without the hop that disconnects it, this reads `.ownDeadline`.
    #expect(made.connectEnding == .disconnect)
    #expect(runner.machine.state == .ended(.systemEndedIt))
    #expect(task.completions == [false])
    // Put down exactly once, whether the handler's hop got there first or `finish` did.
    #expect(made.disconnects == 1)
    // The poll never started: the run ended before the loop.
    #expect(made.snapshots == 0)
  }

  /// The same ownership on the path where the fresh connection never came up.
  @Test("a connection that would not come up is still put down")
  func aConnectionThatWouldNotComeUpIsPutDown() async {
    let made = FakeWatchSession()
    made.isConnectedForWatch = false
    let (runner, _, _) = makeRunner(connecting: made)
    let borrowed = FakeWatchSession()
    borrowed.isConnectedForWatch = false
    let task = FakeWatchTask()

    runner.start(host: host, subject: "claude", session: borrowed)
    await runner.run(task)

    #expect(runner.machine.state == .ended(.couldNotReachTheHost))
    #expect(made.disconnects == 1)
    #expect(task.completions == [false])
  }

  // MARK: The ends

  /// Checked before the poll rather than inferred from a `nil` snapshot: a snapshot can fail
  /// on a link that is still up.
  @Test("the host going away ends the run and reports a successful completion")
  func theHostGoingAwayEndsTheRun() async {
    let (runner, _, _) = makeRunner()
    let session = FakeWatchSession()
    let task = FakeWatchTask()
    session.afterSnapshot = { _ in session.isConnectedForWatch = false }

    runner.start(host: host, subject: "claude", session: session)
    await runner.run(task)

    #expect(runner.machine.state == .ended(.hostDisconnected))
    #expect(task.completions == [true])
  }

  /// The person's Cancel on iOS's card and an iOS expiry are one delivery, and neither is a
  /// completion Driverr chose.
  @Test("expiry ends the run and reports an unsuccessful completion")
  func expiryEndsTheRun() async {
    let (runner, _, _) = makeRunner()
    let session = FakeWatchSession()
    let task = FakeWatchTask()
    session.afterSnapshot = { _ in task.expire() }

    runner.start(host: host, subject: "claude", session: session)
    await runner.run(task)

    #expect(runner.machine.state == .ended(.systemEndedIt))
    #expect(task.completions == [false])
  }

  /// Completion is reported once whichever end wins. `expirationHandler` arrives on any
  /// thread, so it can land as the loop notices the host has gone. The idempotence itself is
  /// `BackgroundWatchPolicyTests`'.
  @Test("an expiry and a disconnect together still report completion once")
  func anExpiryAndADisconnectReportOnce() async {
    let (runner, _, _) = makeRunner()
    let session = FakeWatchSession()
    let task = FakeWatchTask()
    session.afterSnapshot = { _ in
      task.expire()
      session.isConnectedForWatch = false
    }

    runner.start(host: host, subject: "claude", session: session)
    await runner.run(task)

    #expect(task.completions.count == 1)
  }

  /// A Stop before the system has launched anything has to end the run. A queued request
  /// otherwise leaves the control reading "Stop Continuing in Background" until iOS launches a
  /// cancelled run. A UI run never leaves this state, because its scheduler launches nothing.
  @Test("stopping a request the system has not launched withdraws it")
  func stoppingABeforeLaunchRequestWithdrawsIt() {
    let (runner, scheduler, _) = makeRunner()

    runner.start(host: host, subject: "claude", session: FakeWatchSession())
    runner.stop()

    #expect(runner.machine.state == .ended(.stoppedFromTheApp))
    #expect(scheduler.cancelled == [BackgroundWatch.taskIdentifier])
  }

  /// A relaunch between the submit and the launch leaves nothing pending. The handler still
  /// has to report, or the system can kill the app, and an idle state machine must not
  /// swallow that.
  @Test("a handler with nothing pending completes rather than hanging")
  func aHandlerWithNothingPendingCompletes() async {
    let (runner, _, _) = makeRunner()
    let task = FakeWatchTask()

    await runner.run(task)

    #expect(runner.machine.state == .idle)
    #expect(task.completions == [false])
  }

  // MARK: The plist

  /// The plist and the code cannot drift silently, and only this tier can read `Info.plist`.
  ///
  /// A registration missing from `BGTaskSchedulerPermittedIdentifiers` throws at launch, and
  /// an identifier with no handler is never launched. Neither is a build error.
  /// `DriverrTests` is app-hosted, so `Bundle.main` is the Driverr app.
  @Test("the app's Info.plist permits every identifier the code registers")
  func theInfoPlistPermitsTheIdentifiers() {
    let permitted =
      Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers")
      as? [String]
    #expect(permitted != nil, "Info.plist has no BGTaskSchedulerPermittedIdentifiers array")
    let permitted2 = permitted ?? []
    #expect(permitted2.contains(BackgroundWatch.taskIdentifier))
    #expect(permitted2.contains(BackgroundWatch.wildcardTaskIdentifier))
    // The background refresh shares the array; dropping it would stop the app waking up.
    #expect(permitted2.contains(BackgroundRefresh.taskIdentifier))
  }

  /// `UIBackgroundModes` holds `fetch` alone, for the `BGAppRefreshTask`; see `CLAUDE.md`.
  @Test("the app declares one background mode and it is fetch")
  func theAppDeclaresOneBackgroundMode() {
    let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
    #expect(modes == ["fetch"])
  }

  // MARK: The readout

  /// `register`'s answer is surfaced as `debug.backgroundWatch.register`, because app-side
  /// `print` never reaches xcodebuild's log.
  @Test("the register outcome names the identifier and the answer")
  func theRegisterOutcomeIsReadable() {
    let (runner, scheduler, _) = makeRunner()
    scheduler.registerAnswer = false

    runner.register()

    #expect(scheduler.didRegister)
    #expect(runner.registerOutcome == "com.cunderw.driverr.watch — register returned false")
  }
}
