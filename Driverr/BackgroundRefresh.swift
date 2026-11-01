import BackgroundTasks
import DriverrCore
import DriverrHerdr
import Foundation

/// A check of the last selected host every fifteen minutes while Driverr is not running.
///
/// `beginBackgroundTask` buys under 30 seconds after backgrounding, and the case this serves
/// is minutes. A `BGAppRefreshTask` that connects and takes one snapshot runs about every
/// 15 to 17 minutes while the phone is in use.
///
/// This connection is deliberately outside `ConnectionRegistry`. The registry keeps a
/// connection for the life of the process because a person is using it. Here nobody is
/// looking and the process lives only until `setTaskCompleted`, so the refresh makes its own
/// `ConnectionModel`, uses it once and closes it. Never hand it to the registry, and never
/// use the registry's connections from here.
enum BackgroundRefresh {
  /// Must match `BGTaskSchedulerPermittedIdentifiers` in `Info.plist`. A mismatch fails
  /// silently: the system never launches the task. `BackgroundWatchRunnerTests` reads the
  /// plist array back and checks it.
  static let taskIdentifier = "com.cunderw.driverr.refresh"
}

// MARK: - The scheduler seam

/// Registering the handler and submitting the next request, as two calls a fake can answer.
///
/// A `-uiTesting` launch must reach neither: a UI run would install a real handler in a
/// process the harness kills, and leave a queued request on the simulator.
protocol BackgroundRefreshScheduling: Sendable {
  /// Installs the launch handler. Must be called before the app finishes launching.
  func register(_ run: @escaping @Sendable @MainActor () async -> Void)
  /// Queues the next refresh, replacing any request already waiting.
  func schedule()
}

/// The real `BGTaskScheduler`.
struct LiveBackgroundRefreshScheduler: BackgroundRefreshScheduling {
  func register(_ run: @escaping @Sendable @MainActor () async -> Void) {
    // `using: nil` runs the handler on a background queue, so the work hops to the main actor.
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: BackgroundRefresh.taskIdentifier,
      using: nil
    ) { task in
      // `BGTask` is not `Sendable`. The box is safe because the only calls on it are
      // `setTaskCompleted` and `expirationHandler`, which the system serialises, and it does
      // not outlive the handler.
      let box = UncheckedSendableBox(task)
      let work = Task { @MainActor in
        await run()
        // Always report completion. iOS schedules a task less often after it has to revoke one
        // that never reported.
        box.value.setTaskCompleted(success: !Task.isCancelled)
      }
      // Cancelling stops the run between steps, and the task above reports failure.
      task.expirationHandler = { work.cancel() }
    }
  }

  func schedule() {
    // Replace rather than add: a second queued request would be the same request twice.
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundRefresh.taskIdentifier)
    let request = BGAppRefreshTaskRequest(identifier: BackgroundRefresh.taskIdentifier)
    request.earliestBeginDate = BackgroundRefreshPolicy.nextEarliestBegin(after: Date())
    // A failed submit is dropped. The next backgrounding submits again.
    try? BGTaskScheduler.shared.submit(request)
  }
}

#if DEBUG
/// A scheduler that reaches nothing, for every launch that is not the real app, like
/// `SilentNotificationCenter`.
struct SilentBackgroundRefreshScheduler: BackgroundRefreshScheduling {
  func register(_ run: @escaping @Sendable @MainActor () async -> Void) {}
  func schedule() {}
}
#endif

/// Carries a non-`Sendable` reference across one concurrency boundary, under the caller's
/// own argument that it is safe.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
  let value: Value
  init(_ value: Value) { self.value = value }
}

// MARK: - What one refresh does

/// The connection a refresh drives, as the four things it needs.
///
/// Lets `DriverrTests` assert the run's order and its cancellation paths without a transport.
@MainActor
protocol BackgroundRefreshSession {
  func connectForRefresh() async
  var isConnectedForRefresh: Bool { get }
  func snapshotForRefresh() async -> SessionTree?
  func disconnect() async
}

extension ConnectionModel: BackgroundRefreshSession {
  /// Connects only with a credential Driverr already holds: a key, or a password in the
  /// Keychain. There is nobody to ask for a password. Both Keychain stores use
  /// `AfterFirstUnlockThisDeviceOnly`, so they are readable once the phone has been unlocked
  /// since boot.
  func connectForRefresh() async {
    await connectIfCredentialIsAvailable()
  }

  var isConnectedForRefresh: Bool { phase == .connected }

  func snapshotForRefresh() async -> SessionTree? {
    guard let herdr = liveHerdr else { return nil }
    return try? await herdr.snapshot()
  }
}

/// One background refresh, start to finish.
@MainActor
final class BackgroundRefreshRunner {
  /// What a run did, for tests. The app does not read it.
  enum Outcome: Equatable {
    /// The system took the budget back before, or part-way through, the run.
    case cancelled
    /// No host has been selected yet, or the one that was has since been deleted.
    case noHostSelected
    /// The host would not connect, or herdr would not answer.
    case couldNotReachTheHost
    /// A snapshot was taken and put through the notification rule.
    case refreshed(blockedPanes: Int)
  }

  private let environment: AppEnvironment
  private let storedSelection: @MainActor () -> String?
  private let makeSession: @MainActor (DriverrCore.Host, AppEnvironment) -> any BackgroundRefreshSession

  /// - Parameters:
  ///   - storedSelection: the raw value `ContentView` wrote for the last selected host.
  ///     A closure so a test needs no `UserDefaults`.
  ///   - makeSession: builds a `ConnectionModel` owned by this run only. See
  ///     `BackgroundRefresh` for why the registry is not used.
  init(
    environment: AppEnvironment,
    storedSelection: @escaping @MainActor () -> String? = {
      UserDefaults.standard.string(forKey: ContentView.selectedHostDefaultsKey)
    },
    makeSession: @escaping @MainActor (DriverrCore.Host, AppEnvironment) -> any
      BackgroundRefreshSession = { host, environment in
        ConnectionModel(host: host, environment: environment)
      }
  ) {
    self.environment = environment
    self.storedSelection = storedSelection
    self.makeSession = makeSession
  }

  /// Connects to the last selected host, takes one snapshot, posts whatever has newly
  /// blocked, and closes the connection.
  ///
  /// Only the last selected host, because refreshing every saved host would open one SSH
  /// connection per machine every fifteen minutes. `ContentView.restoredSelection` is the
  /// rule launch uses too, so the two agree. `isAppActive` is always `false` because a
  /// `BGAppRefreshTask` runs only while the app is not in front.
  @discardableResult
  func run() async -> Outcome {
    // Reschedule whatever the run found. One request is one launch, so a run that returns
    // without rescheduling ends background refresh until the next backgrounding.
    defer { environment.backgroundRefresh.schedule() }

    guard !Task.isCancelled else { return .cancelled }

    let hosts = (try? await environment.hostStore.hosts()) ?? []
    guard
      let id = ContentView.restoredSelection(stored: storedSelection(), hosts: hosts),
      let host = hosts.first(where: { $0.id == id })
    else { return .noHostSelected }

    let session = makeSession(host, environment)

    // Cancellation has to reach the connect. `ConnectionModel.connect` awaits an unstructured
    // `Task` that does not inherit cancellation, so an expiry mid-handshake would otherwise
    // wait out the twenty-second connect deadline. `disconnect()` cancels `connectAttempt`,
    // which makes the connect return at once.
    let box = UncheckedSendableBox(session)
    await withTaskCancellationHandler {
      await session.connectForRefresh()
    } onCancel: {
      // `onCancel` may run on any thread, so it hops to the main actor explicitly. A second
      // disconnect below is a no-op.
      Task { @MainActor in await box.value.disconnect() }
    }

    guard !Task.isCancelled else {
      await session.disconnect()
      return .cancelled
    }
    guard session.isConnectedForRefresh, let reported = await session.snapshotForRefresh() else {
      await session.disconnect()
      return .couldNotReachTheHost
    }
    // This process has no registry, so the card says what its other hosts already count.
    let tree = reported.hidingMachines(
      coveredBy: environment.blockedPaneActivities.coreIDs(coveringHost: host.id))

    // Its own notifier, reading the announced set the last run persisted. See
    // `AnnouncedPaneStore`.
    let notifier = BlockedPaneNotifier(
      host: host,
      center: environment.notifications,
      store: environment.announcedPanes
    )
    await notifier.sessionChanged(to: tree, isAppActive: false)

    // This process has no `SettingsModel`, so it reads both preference stores and pushes
    // them before the feed. With the switch off, the feed below ends the card instead of
    // updating it.
    await environment.blockedPaneActivities.preferencesChanged(
      LiveActivityPreferences(
        isEnabled: await environment.settingsStore.settings().liveActivities,
        hostOverrides: await environment.liveActivityPreferences.hostOverrides()
      )
    )

    // `canRequest: false`: a Live Activity may only be requested from the foreground, and a
    // background request fails with no card and no log.
    //
    // `scope: .oneHost` keeps this run from ending the card for hosts it did not look at.
    // This process has no registry, so the standing card's `hosts` array carries the others.
    //
    // `isConnected: true` because the observation is about the host's panes. The
    // `disconnect()` below closes this run's borrowed socket and must not take the card down.
    await environment.blockedPaneActivities.observed(
      [
        HostActivityObservation(
          hostID: host.id,
          hostName: host.name,
          isConnected: true,
          blockedPanes: tree.blockedPanes,
          counts: tree.agentStatusCounts,
          observedAt: .now,
          coreID: tree.coreID
        )
      ],
      scope: .oneHost(host.id),
      canRequest: false
    )

    // Always close before returning, or the far side keeps a socket nothing closes.
    await session.disconnect()
    return .refreshed(blockedPanes: tree.blockedPanes.count)
  }
}
