import BackgroundTasks
import DriverrCore
import DriverrHerdr
import Foundation
import Observation
import SwiftUI

// Continue in Background: the part that needs `BackgroundTasks`.
//
// A tap submits a `BGContinuedProcessingTask`. While it runs, Driverr keeps the host's SSH
// connection open and keeps polling herdr, so the Live Activity stays fresh and the session
// is still there when the person comes back. The identifiers, the offer rule, the copy and
// the state machine are in `DriverrCore` (`BackgroundWatch`, `BackgroundWatchCopy`,
// `BackgroundWatchMachine`).
//
// Unlike `BackgroundRefresh`, this reuses the foreground `ConnectionModel` when it can,
// because keeping the session the person left is the point. It builds its own only when the
// borrowed connection has dropped.

// MARK: - The scheduler seam

/// Registering the launch handler and submitting a request, as two calls a fake can answer.
///
/// A UI run must never reach submit: a submitted task draws a system progress card that
/// outlives the process and lands on the next test class. Register is safe. See
/// `SilentBackgroundWatchScheduler`.
protocol BackgroundWatchScheduling: Sendable {
  /// Installs the launch handler and returns what `BGTaskScheduler.register` returned.
  ///
  /// A handler that fails to register leaves the feature with no mechanism and no error, so
  /// the answer is surfaced. The wildcard identifier has been seen returning `false` on a
  /// device.
  @discardableResult
  func register(_ run: @escaping @Sendable @MainActor (BackgroundWatchTask) -> Void) -> Bool

  /// Submits the request. Returns the identifier that was accepted, or `nil` if none was.
  func submit(title: String, subtitle: String) -> String?

  /// Withdraws a request the system has taken but not yet launched.
  ///
  /// A `strategy: .queue` request can wait, and the person can change their mind meanwhile.
  /// Without this the request would still launch later and complete with nothing to do.
  func cancel(identifier: String)
}

/// What the runner needs from a live `BGContinuedProcessingTask`, which only the system can
/// construct. `DriverrTests` drives the loop through this.
@MainActor
protocol BackgroundWatchTask {
  var watchIdentifier: String { get }
  /// The title and subtitle on iOS's own progress card.
  func updateCard(title: String, subtitle: String)
  /// Reports `NSProgress` as indeterminate (`totalUnitCount = -1`).
  func reportIndeterminateProgress()
  /// Called once, before the handler returns.
  func complete(success: Bool)
  /// Installs the expiration handler. It is `@Sendable` and arrives on any thread.
  func onExpiration(_ handler: @escaping @Sendable () -> Void)
}

/// The real `BGTaskScheduler`.
struct LiveBackgroundWatchScheduler: BackgroundWatchScheduling {
  @discardableResult
  func register(_ run: @escaping @Sendable @MainActor (BackgroundWatchTask) -> Void) -> Bool {
    // `using: nil` runs the handler on a background queue, so the work hops to the main actor.
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: BackgroundWatch.taskIdentifier,
      using: nil
    ) { task in
      guard let task = task as? BGContinuedProcessingTask else { return }
      // `BGTask` is not `Sendable`. It crosses once, in a box, and is only used on the main
      // actor afterwards.
      let box = UncheckedWatchBox(task)
      Task { @MainActor in run(LiveBackgroundWatchTask(task: box.value)) }
    }
  }

  /// Submits the plain identifier only, with no retry.
  ///
  /// `register` is called for the plain identifier, so a request accepted under a suffixed
  /// identifier would have no handler. It would never launch, and the control would read
  /// "Stop Continuing in Background" for a run that never starts. The plain form registers on
  /// the simulator (`HostConnectUITests.testThePlainContinuedProcessingIdentifierRegisters`).
  /// If a device refuses it, register the wildcard form here as well. The plist already
  /// permits it.
  func submit(title: String, subtitle: String) -> String? {
    let plain = BackgroundWatch.taskIdentifier
    return attempt(identifier: plain, title: title, subtitle: subtitle) ? plain : nil
  }

  func cancel(identifier: String) {
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
  }

  private func attempt(identifier: String, title: String, subtitle: String) -> Bool {
    let request = BGContinuedProcessingTaskRequest(
      identifier: identifier, title: title, subtitle: subtitle)
    // `.queue`, not `.fail`: `.fail` throws `immediateRunIneligible` on a busy system, right
    // after a tap. The cost, stated in the section footer, is that a queued request is
    // cancelled if Driverr is swiped out of the app switcher.
    request.strategy = .queue
    do {
      try BGTaskScheduler.shared.submit(request)
      return true
    } catch {
      return false
    }
  }
}

#if DEBUG
/// A scheduler that registers for real and submits nothing, for every launch that is not the
/// real app.
///
/// - `submit` must not reach the system: a real task draws a progress card that outlives the
///   UI test's process and lands on the next class.
/// - `register` is safe, because a handler cannot launch without a submitted request. Its
///   `Bool` goes to `debug.backgroundWatch.register`, so a `scripts/look.sh` run shows
///   whether the plain identifier registers.
struct SilentBackgroundWatchScheduler: BackgroundWatchScheduling {
  @discardableResult
  func register(_ run: @escaping @Sendable @MainActor (BackgroundWatchTask) -> Void) -> Bool {
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: BackgroundWatch.taskIdentifier,
      using: nil
    ) { task in
      // Unreachable, because nothing submits under this conformance. It still completes so
      // the system would hear back if that changed.
      task.setTaskCompleted(success: false)
    }
  }

  /// Accepts the request and sends nothing.
  ///
  /// Returning `nil` would make the runner end with `.couldNotSubmit`, so a UI run could never
  /// see the running state. Returning the identifier models a queued request that the system
  /// has taken but not launched.
  func submit(title: String, subtitle: String) -> String? { BackgroundWatch.taskIdentifier }

  func cancel(identifier: String) {}
}
#endif

/// The live task, wrapped so the runner never sees `BackgroundTasks`.
@MainActor
private struct LiveBackgroundWatchTask: BackgroundWatchTask {
  let task: BGContinuedProcessingTask

  var watchIdentifier: String { task.identifier }

  func updateCard(title: String, subtitle: String) {
    task.updateTitle(title, subtitle: subtitle)
  }

  /// Indeterminate, because a watch ends when the agent says something, which has no
  /// predictable fraction. `NSProgress` treats a negative total as indeterminate.
  ///
  /// The SDK header warns that tasks that appear stalled may be expired. That is unmeasured.
  func reportIndeterminateProgress() {
    task.progress.totalUnitCount = -1
    task.progress.completedUnitCount = 0
  }

  func complete(success: Bool) {
    task.setTaskCompleted(success: success)
  }

  func onExpiration(_ handler: @escaping @Sendable () -> Void) {
    task.expirationHandler = handler
  }
}

/// Carries a non-`Sendable` reference across one concurrency boundary, under the caller's
/// own argument that it is safe. Private, so each use makes its own argument.
private struct UncheckedWatchBox<Value>: @unchecked Sendable {
  let value: Value
  init(_ value: Value) { self.value = value }
}

/// A one-way flag the `@Sendable` expiration handler sets and the main actor reads. The
/// handler arrives on another thread, so it takes a lock.
final class BackgroundWatchFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  var isSet: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func set() {
    lock.lock()
    value = true
    lock.unlock()
  }
}

// MARK: - What one run watches

/// The connection a Continue in Background run drives, as the four things it needs.
///
/// Deliberately separate from `BackgroundRefreshSession`, although the members match. A
/// refresh makes a connection and closes it. A watch keeps the one the person left.
@MainActor
protocol BackgroundWatchSession {
  func connectForWatch() async
  var isConnectedForWatch: Bool { get }
  func snapshotForWatch() async -> SessionTree?
  func disconnect() async
}

extension ConnectionModel: BackgroundWatchSession {
  func connectForWatch() async {
    await connectIfCredentialIsAvailable()
  }

  var isConnectedForWatch: Bool { phase == .connected }

  func snapshotForWatch() async -> SessionTree? {
    guard let herdr = liveHerdr else { return nil }
    return try? await herdr.snapshot()
  }
}

/// One host's Continue in Background run, and the state both surfaces read.
///
/// Held for the app's lifetime by `DriverrApp` and injected through the environment, so the
/// pane menu, the host screen and the launch handler share one object.
@MainActor
@Observable
final class BackgroundWatchRunner {
  /// Where the one run is. `DriverrCore` owns the transitions; this holds the value.
  private(set) var machine = BackgroundWatchMachine()

  /// What `BGTaskScheduler.register` returned at launch, and for which identifier, for
  /// `debug.backgroundWatch.register`.
  private(set) var registerOutcome = "not attempted"

  /// What the most recent submit did, for `debug.backgroundWatch.state`.
  private(set) var lastSubmitOutcome = "not attempted"

  /// How many polls the current run has made. Shown in the card's subtitle.
  private(set) var checks = 0

  private let environment: AppEnvironment
  private let pollInterval: Duration
  /// How a connection is made when the borrowed one has gone. A closure so `DriverrTests` can
  /// drive the owned-connection path.
  private let makeSession:
    @MainActor (DriverrCore.Host, AppEnvironment) -> any BackgroundWatchSession

  /// Set at submit time and read by the launch handler in the same process. After a relaunch
  /// nothing is pending, which ends as `.nothingToWatch`.
  private var pendingHost: DriverrCore.Host?
  private var pendingSubject: String?
  private var pendingSession: (any BackgroundWatchSession)?
  /// Whether `pendingSession` was made by this run and so must be disconnected. A borrowed
  /// session belongs to the foreground screen and is only released.
  private var ownsSession = false
  /// Whether `disconnectOwnedSession` has already run for the current session.
  private var didDisconnectOwnedSession = false

  /// Set by a second tap. The system's Cancel arrives through `expirationHandler` instead.
  private var stopRequest = BackgroundWatchFlag()

  /// The accepted identifier, so a stop before launch can withdraw the request.
  private var submittedIdentifier: String?

  init(
    environment: AppEnvironment,
    pollInterval: Duration = SessionModel.defaultPollInterval,
    makeSession: @escaping @MainActor (DriverrCore.Host, AppEnvironment) -> any
      BackgroundWatchSession = { host, environment in
        ConnectionModel(host: host, environment: environment)
      }
  ) {
    self.environment = environment
    self.pollInterval = pollInterval
    self.makeSession = makeSession
  }

  // MARK: Registration

  /// Installs the launch handler. Called from `DriverrApp.init`.
  func register() {
    let registered = environment.backgroundWatch.register { [weak self] task in
      guard let self else {
        // Unreachable, because the runner lives as long as the app. It still completes,
        // because a task that never reports is grounds for iOS to kill the app.
        task.complete(success: false)
        return
      }
      Task { await self.run(task) }
    }
    registerOutcome = "\(BackgroundWatch.taskIdentifier) — register returned \(registered)"
  }

  // MARK: What both surfaces call

  /// Whether the control for this host reads "Stop Continuing in Background".
  func isRunning(for hostID: UUID) -> Bool { machine.isRunning(for: hostID) }

  /// Whether a run is up for another host, which disables this host's control. See
  /// `BackgroundWatch.isEnabled`.
  func isRunningForAnotherHost(than hostID: UUID) -> Bool {
    machine.isRunningForAnotherHost(than: hostID)
  }

  /// The tap, on either surface. Starts a run or stops the one that is up.
  ///
  /// - Parameters:
  ///   - subject: what iOS's card names: the pane's title, or the host's name.
  ///   - session: the connection on screen, reused by the handler if it is still up.
  func toggle(
    host: DriverrCore.Host,
    subject: String,
    session: (any BackgroundWatchSession)?
  ) {
    if machine.isRunning(for: host.id) {
      stop()
    } else {
      start(host: host, subject: subject, session: session)
    }
  }

  /// Must be called from a tap while Driverr is in front: the request is made on behalf of
  /// the foreground app.
  func start(host: DriverrCore.Host, subject: String, session: (any BackgroundWatchSession)?) {
    guard machine.start(hostID: host.id) else { return }
    pendingHost = host
    pendingSubject = subject
    pendingSession = session
    ownsSession = false
    didDisconnectOwnedSession = false
    stopRequest = BackgroundWatchFlag()
    checks = 0

    let identifier = environment.backgroundWatch.submit(
      title: BackgroundWatchCopy.taskTitle(watching: subject),
      subtitle: BackgroundWatchCopy.taskSubtitle(hostName: host.displayName)
    )
    if let identifier {
      submittedIdentifier = identifier
      lastSubmitOutcome = "submitted \(identifier)"
    } else {
      // Nothing was accepted. Reset the control rather than show Stop for a run that will
      // never start.
      lastSubmitOutcome = "submit refused"
      machine.end(.couldNotSubmit)
      clearPending()
    }
  }

  /// The person tapped the item again.
  ///
  /// Once the handler is running, it owns the end because it must call `setTaskCompleted`,
  /// so this only sets the flag. Before launch the request is only queued, so it is
  /// withdrawn and the machine ended here. Otherwise the control would show Stop until iOS
  /// launched a run the person had already cancelled.
  func stop() {
    guard case .running(_, let hasLaunched) = machine.state else { return }
    stopRequest.set()
    guard !hasLaunched else { return }
    if let submittedIdentifier {
      environment.backgroundWatch.cancel(identifier: submittedIdentifier)
    }
    machine.end(.stoppedFromTheApp)
    clearPending()
  }

  // MARK: The run

  /// The launch handler's body: the app's poll loop, for the task's lifetime.
  func run(_ task: BackgroundWatchTask) async {
    let expired = BackgroundWatchFlag()
    // `@Sendable`, on any thread. The system's expiry and the person tapping Cancel on iOS's
    // card both arrive here.
    //
    // The expiry must reach a connect still in flight. `ConnectionModel.connect` awaits an
    // unstructured `Task`, so without the hop below an expiry during the connect would wait
    // out its twenty-second deadline and report `.couldNotReachTheHost` instead of
    // `.systemEndedIt`. `disconnect()` cancels `connectAttempt`. Same as
    // `BackgroundRefreshRunner`.
    task.onExpiration { [weak self] in
      expired.set()
      Task { @MainActor in await self?.disconnectOwnedSession() }
    }
    task.reportIndeterminateProgress()

    guard let host = pendingHost, let subject = pendingSubject else {
      await finish(task, reason: .nothingToWatch)
      return
    }
    machine.noteLaunched(hostID: host.id)

    // Reuse the connection on screen. This branch is the link having dropped between the tap
    // and the launch, since a relaunch already ended in `.nothingToWatch`. A connection made
    // here belongs to this run and is closed in `finish`, as in `BackgroundRefreshRunner`.
    var session = pendingSession
    if session?.isConnectedForWatch != true {
      let fresh = makeSession(host, environment)
      // Recorded before the await, so the expiration handler can close it during the connect.
      session = fresh
      pendingSession = fresh
      ownsSession = true
      await fresh.connectForWatch()
    }
    // An expiry during that connect is its own end, not an unreachable host.
    if expired.isSet {
      await finish(task, reason: .systemEndedIt)
      return
    }
    guard let session, session.isConnectedForWatch else {
      await finish(task, reason: .couldNotReachTheHost)
      return
    }

    while !expired.isSet && !stopRequest.isSet {
      // Checked before the poll, not inferred from a failed snapshot: a snapshot can fail on a
      // live link, and ending then would close the connection too.
      guard session.isConnectedForWatch else {
        await finish(task, reason: .hostDisconnected)
        return
      }

      let tree = await session.snapshotForWatch()
      checks += 1
      if let tree {
        // The same feed as the foreground poll. `.oneHost` because this pass saw one machine,
        // and `canRequest: false` because cards are requested from the foreground. The driver
        // already has the preferences, because this is the same process.
        await environment.blockedPaneActivities.observed(
          [
            HostActivityObservation(
              hostID: host.id,
              hostName: host.name,
              isConnected: true,
              blockedPanes: tree.blockedPanes,
              counts: tree.agentStatusCounts,
              observedAt: Date()
            )
          ],
          scope: .oneHost(host.id),
          canRequest: false
        )
      }
      task.updateCard(
        title: BackgroundWatchCopy.taskTitle(watching: subject),
        subtitle: BackgroundWatchCopy.liveSubtitle(hostName: host.displayName, checks: checks)
      )

      try? await Task.sleep(for: pollInterval)
    }

    await finish(task, reason: expired.isSet ? .systemEndedIt : .stoppedFromTheApp)
  }

  /// Ends the machine, closes an owned session and always reports completion.
  ///
  /// Not calling `setTaskCompleted` is grounds for iOS to kill the app, so it is unconditional,
  /// even when nothing was pending. `run` returns right after every call, so there is exactly
  /// one completion. `machine.end` may return `false` when the person already stopped the
  /// run, and the machine keeps that first reason.
  private func finish(_ task: BackgroundWatchTask, reason: BackgroundWatchEndReason) async {
    machine.end(reason)
    // Before completion: once `setTaskCompleted` returns the process may be suspended, and
    // the socket would never be closed.
    await disconnectOwnedSession()
    clearPending()
    task.complete(success: reason.completedSuccessfully)
  }

  /// Closes a connection this run made, at most once. Called from the expiration handler, to
  /// reach a connect in flight, and from `finish`. The flag lets a test assert one disconnect.
  private func disconnectOwnedSession() async {
    guard ownsSession, !didDisconnectOwnedSession, let session = pendingSession else { return }
    didDisconnectOwnedSession = true
    await session.disconnect()
  }

  private func clearPending() {
    pendingHost = nil
    pendingSubject = nil
    submittedIdentifier = nil
    ownsSession = false
    didDisconnectOwnedSession = false
    // Released, never disconnected. The borrowed session is the person's own connection.
    pendingSession = nil
  }
}

// MARK: - Reaching it from a view

private struct BackgroundWatchRunnerKey: EnvironmentKey {
  /// A runner over `AppEnvironment.ephemeral`, so a preview or an uninjected view reaches the
  /// silent scheduler.
  ///
  /// Over `.live` in Release, where `ephemeral` does not exist. Building it submits nothing.
  #if DEBUG
  @MainActor static let fallback = BackgroundWatchRunner(environment: .ephemeral)
  #else
  @MainActor static let fallback = BackgroundWatchRunner(environment: .live)
  #endif
  nonisolated static var defaultValue: BackgroundWatchRunner {
    MainActor.assumeIsolated { fallback }
  }
}

extension EnvironmentValues {
  var backgroundWatch: BackgroundWatchRunner {
    get { self[BackgroundWatchRunnerKey.self] }
    set { self[BackgroundWatchRunnerKey.self] = newValue }
  }
}

// MARK: - The readout

#if DEBUG
/// What `register` returned and where the run is, on screen, under
/// `-uiTestingBackgroundWatchProbe` only.
///
/// Both facts are app-side, and app-side `print` never reaches xcodebuild's log. Whether the
/// plain identifier registers decides whether the feature works at all, and a submit has no
/// visible effect until the system launches the handler. Drawn, so a screenshot shows it.
/// Each value is its own `Text` outside any container with an identifier.
private struct BackgroundWatchProbe: ViewModifier {
  let runner: BackgroundWatchRunner

  func body(content: Content) -> some View {
    content.overlay(alignment: .top) {
      if AppEnvironment.isBackgroundWatchProbed {
        VStack(spacing: 2) {
          Text(runner.registerOutcome)
            .accessibilityIdentifier("debug.backgroundWatch.register")
          Text(Self.describe(runner))
            .accessibilityIdentifier("debug.backgroundWatch.state")
        }
        .font(.caption)
        .padding(6)
        .background(.regularMaterial)
      }
    }
  }

  private static func describe(_ runner: BackgroundWatchRunner) -> String {
    let state: String =
      switch runner.machine.state {
      case .idle: "idle"
      case .running(_, let hasLaunched): hasLaunched ? "running" : "submitted"
      case .ended(let reason): "ended(\(reason.rawValue))"
      }
    return "\(state) · \(runner.lastSubmitOutcome) · checks \(runner.checks)"
  }
}

extension View {
  /// Attached in `DriverrApp` beside `blockedPaneActivityProbe()`.
  func backgroundWatchProbe(runner: BackgroundWatchRunner) -> some View {
    modifier(BackgroundWatchProbe(runner: runner))
  }
}
#endif
