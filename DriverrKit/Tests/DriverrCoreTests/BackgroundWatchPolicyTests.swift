import Foundation
import Testing

@testable import DriverrCore

/// Everything about Continue in Background that can be decided without `BackgroundTasks`.
@Suite("Continue in Background")
struct BackgroundWatchPolicyTests {
  private let workbox = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
  private let buildbox = UUID(uuidString: "22222222-0000-0000-0000-000000000002")!

  // MARK: The identifiers

  /// A registration missing from `BGTaskSchedulerPermittedIdentifiers` throws at launch, and
  /// a plist entry with no handler never launches. Neither is a build error.
  @Test("the permitted identifiers are the plain one and its wildcard sibling")
  func theIdentifiersArePinned() {
    #expect(BackgroundWatch.taskIdentifier == "com.cunderw.driverr.watch")
    #expect(BackgroundWatch.wildcardTaskIdentifier == "com.cunderw.driverr.watch.*")
    #expect(
      BackgroundWatch.permittedIdentifiers == [
        "com.cunderw.driverr.watch", "com.cunderw.driverr.watch.*",
      ])
  }

  // MARK: The offer rule

  /// Deliberately not gated on the Live Activities setting.
  @Test("the action is offered while connected and not otherwise")
  func theActionIsOfferedWhileConnected() {
    #expect(BackgroundWatch.isOffered(isConnected: true))
    #expect(BackgroundWatch.isOffered(isConnected: false) == false)
  }

  /// Without this, every other host offered the action and a tap did nothing.
  @Test("the action is disabled while another host is being continued")
  func theActionIsDisabledForASecondHost() {
    #expect(BackgroundWatch.isEnabled(isConnected: true, isRunningForAnotherHost: false))
    #expect(
      BackgroundWatch.isEnabled(isConnected: true, isRunningForAnotherHost: true) == false)
    // Drawn dimmed rather than removed, so the host screen does not lose an item.
    #expect(BackgroundWatch.isOffered(isConnected: true))
  }

  @Test("a disconnected host is never enabled")
  func aDisconnectedHostIsNeverEnabled() {
    #expect(BackgroundWatch.isEnabled(isConnected: false, isRunningForAnotherHost: false) == false)
  }

  /// A `Menu` has nowhere to put the reason, so it hides the item. The host screen dims it
  /// because its footer explains why.
  @Test("the pane menu drops the item while another host is being continued")
  func theMenuDropsTheItemForASecondHost() {
    #expect(BackgroundWatch.isInMenu(isConnected: true, isRunningForAnotherHost: false))
    #expect(BackgroundWatch.isInMenu(isConnected: true, isRunningForAnotherHost: true) == false)
    #expect(BackgroundWatch.isInMenu(isConnected: false, isRunningForAnotherHost: false) == false)
    #expect(BackgroundWatch.isOffered(isConnected: true))
  }

  @Test("a machine knows which host is holding the run")
  func aMachineKnowsWhichHostHoldsTheRun() {
    var machine = BackgroundWatchMachine()
    #expect(machine.isRunningForAnotherHost(than: workbox) == false)
    machine.start(hostID: workbox)
    #expect(machine.isRunningForAnotherHost(than: workbox) == false)
    #expect(machine.isRunningForAnotherHost(than: buildbox))
    machine.end(.stoppedFromTheApp)
    #expect(machine.isRunningForAnotherHost(than: buildbox) == false)
  }

  // MARK: The state machine

  @Test("a fresh machine is idle and running for nobody")
  func aFreshMachineIsIdle() {
    let machine = BackgroundWatchMachine()
    #expect(machine.state == .idle)
    #expect(machine.isRunning == false)
    #expect(machine.isRunning(for: workbox) == false)
  }

  /// The control must read "Stop" before the system launches anything, or a queued request
  /// looks like a dead tap.
  @Test("starting marks the host running before the handler launches")
  func startingMarksTheHostRunning() {
    var machine = BackgroundWatchMachine()
    // `#expect` captures its expression immutably, so mutating calls get their own line.
    let started = machine.start(hostID: workbox)
    #expect(started)
    #expect(machine.state == .running(hostID: workbox, hasLaunched: false))
    #expect(machine.isRunning(for: workbox))
    #expect(machine.isRunning(for: buildbox) == false)
  }

  @Test("the handler launching is recorded once")
  func theHandlerLaunchingIsRecordedOnce() {
    var machine = BackgroundWatchMachine()
    machine.start(hostID: workbox)
    let launched = machine.noteLaunched(hostID: workbox)
    #expect(launched)
    #expect(machine.state == .running(hostID: workbox, hasLaunched: true))
    let launchedAgain = machine.noteLaunched(hostID: workbox)
    #expect(launchedAgain == false)
  }

  /// Submit and launch are separated by however long the system waits.
  @Test("a handler for a stopped run is ignored")
  func aHandlerForAStoppedRunIsIgnored() {
    var machine = BackgroundWatchMachine()
    machine.start(hostID: workbox)
    machine.end(.stoppedFromTheApp)
    let launched = machine.noteLaunched(hostID: workbox)
    #expect(launched == false)
    #expect(machine.state == .ended(.stoppedFromTheApp))
  }

  /// The grant is to Driverr, not a host, and the API holds one task per identifier.
  @Test("a second host cannot start while one run is up")
  func aSecondHostCannotStart() {
    var machine = BackgroundWatchMachine()
    machine.start(hostID: workbox)
    let second = machine.start(hostID: buildbox)
    #expect(second == false)
    #expect(machine.state == .running(hostID: workbox, hasLaunched: false))
  }

  @Test("a double tap on the same host does not submit twice")
  func aDoubleTapDoesNotSubmitTwice() {
    var machine = BackgroundWatchMachine()
    let first = machine.start(hostID: workbox)
    #expect(first)
    let again = machine.start(hostID: workbox)
    #expect(again == false)
  }

  /// The `@Sendable` expiration handler can race the poll loop; `setTaskCompleted` must be
  /// called once.
  @Test("only the first end reports completion")
  func onlyTheFirstEndReports() {
    var machine = BackgroundWatchMachine()
    machine.start(hostID: workbox)
    let ended = machine.end(.systemEndedIt)
    #expect(ended)
    let endedAgain = machine.end(.hostDisconnected)
    #expect(endedAgain == false)
    #expect(machine.state == .ended(.systemEndedIt))
  }

  @Test("ending a machine that never started does nothing")
  func endingAnIdleMachineDoesNothing() {
    var machine = BackgroundWatchMachine()
    let ended = machine.end(.systemEndedIt)
    #expect(ended == false)
    #expect(machine.state == .idle)
  }

  @Test("a host can be started again after a run has ended")
  func aHostCanStartAgainAfterEnding() {
    var machine = BackgroundWatchMachine()
    machine.start(hostID: workbox)
    machine.end(.systemEndedIt)
    #expect(machine.isRunning == false)
    let restarted = machine.start(hostID: workbox)
    #expect(restarted)
    #expect(machine.state == .running(hostID: workbox, hasLaunched: false))
  }

  // MARK: The end reasons

  /// iOS uses this to decide how generous the next grant is.
  @Test("only the ends Driverr chose report success")
  func onlyChosenEndsReportSuccess() {
    #expect(BackgroundWatchEndReason.stoppedFromTheApp.completedSuccessfully)
    #expect(BackgroundWatchEndReason.hostDisconnected.completedSuccessfully)
    #expect(BackgroundWatchEndReason.systemEndedIt.completedSuccessfully == false)
    #expect(BackgroundWatchEndReason.couldNotReachTheHost.completedSuccessfully == false)
    #expect(BackgroundWatchEndReason.nothingToWatch.completedSuccessfully == false)
    #expect(BackgroundWatchEndReason.couldNotSubmit.completedSuccessfully == false)
  }

  /// A new reason cannot default to success through a forgotten `switch` case.
  @Test("every end reason answers the completion question")
  func everyReasonAnswers() {
    #expect(BackgroundWatchEndReason.allCases.count == 6)
  }

  // MARK: The copy

  @Test("the button title is the state")
  func theButtonTitleIsTheState() {
    #expect(BackgroundWatchCopy.buttonTitle(isRunning: false) == "Continue in Background")
    #expect(BackgroundWatchCopy.buttonTitle(isRunning: true) == "Stop Continuing in Background")
  }

  @Test("the glyph stays in one family across the retitle")
  func theGlyphStaysInOneFamily() {
    #expect(BackgroundWatchCopy.systemImage(isRunning: false) == "clock.arrow.circlepath")
    #expect(BackgroundWatchCopy.systemImage(isRunning: true) == "clock.badge.xmark")
  }

  @Test("the system card names what is being watched and where")
  func theSystemCardNamesTheSubject() {
    #expect(BackgroundWatchCopy.taskTitle(watching: "claude") == "Watching claude")
    #expect(BackgroundWatchCopy.taskSubtitle(hostName: "workbox") == "on workbox")
  }

  /// Progress is indeterminate, so the subtitle is the only place to say what was done.
  @Test("the live subtitle counts checks and gets the singular right")
  func theLiveSubtitleCountsChecks() {
    #expect(BackgroundWatchCopy.liveSubtitle(hostName: "workbox", checks: 1) == "on workbox · 1 check")
    #expect(
      BackgroundWatchCopy.liveSubtitle(hostName: "workbox", checks: 4) == "on workbox · 4 checks")
  }

  @Test("the running footer warns about the app switcher")
  func theRunningFooterWarnsAboutTheAppSwitcher() {
    #expect(BackgroundWatchCopy.hostFooter(isRunning: true).contains("app switcher"))
    #expect(BackgroundWatchCopy.hostFooter(isRunning: false).contains("app switcher") == false)
  }

  @Test("the blocked footer says why the control is unavailable")
  func theBlockedFooterSaysWhy() {
    let blocked = BackgroundWatchCopy.hostFooter(
      isRunning: false, isRunningForAnotherHost: true)
    #expect(blocked.contains("one host at a time"))
    #expect(blocked.contains("another host is being continued now"))
  }
}
