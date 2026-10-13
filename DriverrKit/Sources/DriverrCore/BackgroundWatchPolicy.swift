import Foundation

/// Continue in Background: everything about it that is decidable without `BackgroundTasks`.
///
/// It is a `BGContinuedProcessingTask`, submitted from a tap while Driverr is in front, that
/// keeps the SSH connection and the herdr poll running after the app is backgrounded.
/// SwiftPM cannot build against that type, so the identifiers, offer rule, copy and state
/// machine live here, and `Driverr/BackgroundWatch.swift` holds only the framework calls.
public enum BackgroundWatch {
  /// The identifier `BGTaskScheduler.register` and `submit` use. Plain, with no `.*`.
  ///
  /// `BGContinuedProcessingTaskRequest.init`'s documentation says the identifier must end in
  /// `.*`, but Apple's article on long-running tasks registers a plain string. On a device,
  /// `register` returned false for the wildcard form. What `submit` does with the plain form
  /// on a phone is not yet established, which is why the plist also permits the wildcard.
  public static let taskIdentifier = "com.cunderw.driverr.watch"

  /// The `.*` form. Permitted by `Info.plist` and used by nothing.
  ///
  /// Driverr registers a handler only for the plain identifier, so a request submitted under
  /// this one would be accepted and never launched, and the control would claim a run that
  /// never starts. Do not submit it without registering it.
  ///
  /// It stays in the plist so that trying the initialiser's reading later changes this file
  /// and `LiveBackgroundWatchScheduler`, not a shared plist. A permitted identifier with no
  /// handler costs nothing, and this allowlist is not a capability claim like
  /// `UIBackgroundModes`.
  public static let wildcardTaskIdentifier = taskIdentifier + ".*"

  /// What `BGTaskSchedulerPermittedIdentifiers` must carry for this feature, beside
  /// `BackgroundRefresh.taskIdentifier`.
  ///
  /// A registered identifier missing from the plist throws at launch, and a listed one with
  /// no handler is silently never launched. Neither is a build error, so a Kit test pins
  /// these strings against the plist.
  public static let permittedIdentifiers = [taskIdentifier, wildcardTaskIdentifier]

  /// Whether the two surfaces offer the action at all: only when connected. Not gated on the
  /// Live Activities setting, because it keeps the connection and poll alive, not only the
  /// card.
  public static func isOffered(isConnected: Bool) -> Bool { isConnected }

  /// Whether the host screen's control can be tapped.
  ///
  /// One run at a time for the whole app, because the system grants one task under one
  /// identifier. The host screen dims the control and `BackgroundWatchCopy.hostFooter`
  /// explains why. The pane menu uses `isInMenu` instead.
  public static func isEnabled(isConnected: Bool, isRunningForAnotherHost: Bool) -> Bool {
    isOffered(isConnected: isConnected) && !isRunningForAnotherHost
  }

  /// Whether the pane menu draws the item at all.
  ///
  /// The menu hides where the host screen dims, because a `Menu` has no footer to explain a
  /// dimmed row (the same rule as `LiveActivityCopy`). The condition is `isEnabled`'s, called
  /// rather than repeated, so the two cannot drift.
  public static func isInMenu(isConnected: Bool, isRunningForAnotherHost: Bool) -> Bool {
    isEnabled(isConnected: isConnected, isRunningForAnotherHost: isRunningForAnotherHost)
  }
}

// MARK: - How a run ends

/// Why a Continue in Background run stopped.
///
/// Cancel on the system card and iOS expiring the task are one case, `.systemEndedIt`,
/// because both arrive through `expirationHandler`, which carries no reason.
/// `.stoppedFromTheApp` exists because the controls retitle to "Stop" while a run is up.
public enum BackgroundWatchEndReason: String, Equatable, Sendable, CaseIterable {
  /// `expirationHandler` fired: Cancel on iOS's card, or the scheduler took the budget back.
  /// The API does not say which.
  case systemEndedIt
  /// The host's connection went down, so there is nothing left to keep alive.
  case hostDisconnected
  /// The person tapped the item again, on either surface.
  case stoppedFromTheApp
  /// The handler ran but could not get a connection or a herdr control to poll with.
  case couldNotReachTheHost
  /// The handler launched with nothing pending, as after a relaunch between submit and
  /// handler.
  case nothingToWatch
  /// `BGTaskScheduler.submit` threw for the plain identifier.
  case couldNotSubmit

  /// What `setTaskCompleted(success:)` is told. Every end reports, because not calling it
  /// before the handler returns is documented grounds for the system killing the app.
  ///
  /// A run stopped by the person or by a disconnect did its job. A revoked run or one that
  /// never connected did not, and reporting success would mislead the scheduler about how
  /// generous to be next time.
  public var completedSuccessfully: Bool {
    switch self {
    case .stoppedFromTheApp, .hostDisconnected: true
    case .systemEndedIt, .couldNotReachTheHost, .nothingToWatch, .couldNotSubmit: false
    }
  }
}

// MARK: - The state machine

/// Where one host's Continue in Background run is.
///
/// `hasLaunched` is false between the tap and the system launching the handler. The request
/// is `strategy: .queue`, so that wait can be long, and the control must already read "Stop"
/// or the tap looks like it did nothing.
public enum BackgroundWatchState: Equatable, Sendable {
  case idle
  /// Submitted, and running once `hasLaunched` is true.
  case running(hostID: UUID, hasLaunched: Bool)
  case ended(BackgroundWatchEndReason)

  /// The host this state is about, or `nil` when it is about no host.
  public var hostID: UUID? {
    if case .running(let hostID, _) = self { return hostID }
    return nil
  }
}

/// The transitions, as a value the app's runner holds and `swift test` drives.
///
/// One run at a time for the whole app, refused here rather than discovered as a `submit`
/// that throws. Each mutating method returns whether the caller must act, so submitting and
/// `setTaskCompleted` happen exactly once. `expirationHandler` can fire on any thread at the
/// same moment the poll loop notices a disconnect.
public struct BackgroundWatchMachine: Equatable, Sendable {
  public private(set) var state: BackgroundWatchState

  public init(state: BackgroundWatchState = .idle) {
    self.state = state
  }

  /// Whether a run is up for this host, which retitles both controls.
  public func isRunning(for hostID: UUID) -> Bool {
    state.hostID == hostID
  }

  /// Whether any run is up at all.
  public var isRunning: Bool { state.hostID != nil }

  /// Whether a run is up for another host, which dims this host's control.
  public func isRunningForAnotherHost(than hostID: UUID) -> Bool {
    guard let running = state.hostID else { return false }
    return running != hostID
  }

  /// The tap. Returns whether the caller should submit. A run already up refuses any host,
  /// which also makes a double tap harmless.
  @discardableResult
  public mutating func start(hostID: UUID) -> Bool {
    guard !isRunning else { return false }
    state = .running(hostID: hostID, hasLaunched: false)
    return true
  }

  /// The system launched the handler. Ignored unless a run is up for that host, so a late
  /// handler cannot revive a stopped run.
  @discardableResult
  public mutating func noteLaunched(hostID: UUID) -> Bool {
    guard case .running(let running, let hasLaunched) = state, running == hostID,
      !hasLaunched
    else { return false }
    state = .running(hostID: hostID, hasLaunched: true)
    return true
  }

  /// Ends the run. Returns whether this call ended it, and so whether the caller reports
  /// completion. Idempotent, because the expiration handler and the disconnect check can
  /// both fire for one run.
  @discardableResult
  public mutating func end(_ reason: BackgroundWatchEndReason) -> Bool {
    guard isRunning else { return false }
    state = .ended(reason)
    return true
  }
}

// MARK: - Copy

/// Everything Continue in Background says, on Driverr's two surfaces and on iOS's card.
/// Kept here, as `LiveActivityCopy` is, so `swift test` covers it.
public enum BackgroundWatchCopy {
  /// The pane menu item and the host screen's row. The title retitles with the state, as
  /// `LiveActivityMenuItem` does.
  public static func buttonTitle(isRunning: Bool) -> String {
    isRunning ? "Stop Continuing in Background" : "Continue in Background"
  }

  /// The glyph beside it. The stop state keeps the clock family, so the row does not look
  /// like a different control.
  public static func systemImage(isRunning: Bool) -> String {
    isRunning ? "clock.badge.xmark" : "clock.arrow.circlepath"
  }

  /// The title on iOS's progress card: the pane's name from a pane, the host's from the host
  /// screen.
  public static func taskTitle(watching subject: String) -> String {
    "Watching \(subject)"
  }

  /// The card's subtitle before the first poll answers.
  public static func taskSubtitle(hostName: String) -> String {
    "on \(hostName)"
  }

  /// The card's subtitle once polls start: what Driverr has done, not a budget fraction.
  public static func liveSubtitle(hostName: String, checks: Int) -> String {
    checks == 1 ? "on \(hostName) · 1 check" : "on \(hostName) · \(checks) checks"
  }

  /// The host screen's `Background` section footer for this row.
  ///
  /// The running copy mentions swiping out, because iOS cancels the task then, and people
  /// would otherwise report it as a lost connection.
  public static func hostFooter(isRunning: Bool, isRunningForAnotherHost: Bool = false)
    -> String
  {
    if isRunningForAnotherHost {
      // The row's title cannot explain this case, so the footer does.
      return "Driverr continues one host at a time, and another host is being continued now."
    }
    return isRunning
      ? "Driverr is checking this host while you are away. Stop it here or from the card iOS "
        + "shows. Swiping Driverr out of the app switcher also ends it."
      : "Keep this host connected and checked for a while after you leave Driverr. iOS shows "
        + "a card of its own with a Cancel control."
  }
}
