import DriverrCore
import Foundation
import Testing

@testable import Driverr

private func pane(_ id: String, status: AgentStatus) -> Pane {
  Pane(
    id: id,
    tabID: "t1",
    workspaceID: "w1",
    title: "pane \(id)",
    agent: Agent(name: "Claude", status: status)
  )
}

private func tree(_ panes: [Pane]) -> SessionTree {
  SessionTree(workspaces: [
    Workspace(
      id: "w1", number: 1, label: "one",
      tabs: [Tab(id: "t1", workspaceID: "w1", number: 1, label: "a", panes: panes)]
    )
  ])
}

/// A connection that answers without a transport, and records the order it was asked in.
///
/// The order is the claim: connect, snapshot, notify, disconnect — with the disconnect
/// happening on every path out, including the ones that failed.
@MainActor
private final class FakeSession: BackgroundRefreshSession {
  enum Step: Equatable { case connect, snapshot, disconnect }

  /// Why a pending connect stopped being pending.
  ///
  /// The expiration test asserts on this, not a stopwatch: suites share the main actor, so a
  /// correct run can come back late. The claim is that the connect ended because the
  /// run was cancelled, not on its own deadline.
  enum ConnectEnding: Equatable { case disconnect, ownDeadline }

  private(set) var steps: [Step] = []
  var isConnectedForRefresh = true
  var snapshot: SessionTree?
  /// Run inside `connectForRefresh`, so a test can take the budget away mid-run.
  var duringConnect: (@MainActor () -> Void)?
  /// How long a connect hangs about before answering on its own.
  ///
  /// `ConnectionModel.connect` awaits an unstructured `Task`, which does not inherit the run's
  /// cancellation, so a pending handshake ends when `disconnect()` cancels it or when its own
  /// deadline expires. Both endings are modelled; waiting out the second is the defect.
  var connectAnswersAfter: Duration?

  private var pendingConnect: CheckedContinuation<Void, Never>?
  /// Whether a connect is out there to be cancelled.
  ///
  /// Set synchronously before the await, as `ConnectionModel.connect` assigns `connectAttempt`
  /// before awaiting it. Without it the hop into `withCheckedContinuation` would give the fake
  /// a window the real model does not have, where a disconnect finds nothing to cancel.
  private var connectIsPending = false
  /// What ended the connect, set once by whichever got there first.
  private(set) var connectEnding: ConnectEnding?

  init(snapshot: SessionTree? = nil) {
    self.snapshot = snapshot
  }

  func connectForRefresh() async {
    steps.append(.connect)
    duringConnect?()
    guard let delay = connectAnswersAfter else { return }
    connectIsPending = true
    await withCheckedContinuation { continuation in
      // A disconnect during the hop onto the actor already cancelled the attempt.
      guard connectIsPending else { return continuation.resume() }
      pendingConnect = continuation
      // Unstructured, so it is not cancelled with the run, as the connect's own deadline is not.
      Task { @MainActor in
        try? await Task.sleep(for: delay)
        self.endConnect(.ownDeadline)
      }
    }
  }

  private func endConnect(_ ending: ConnectEnding) {
    guard connectIsPending else { return }
    connectIsPending = false
    connectEnding = ending
    pendingConnect?.resume()
    pendingConnect = nil
  }

  func snapshotForRefresh() async -> SessionTree? {
    steps.append(.snapshot)
    return snapshot
  }

  func disconnect() async {
    steps.append(.disconnect)
    // As `ConnectionModel.disconnect` cancels `connectAttempt`: a handshake in flight ends here
    // rather than at its own deadline.
    endConnect(.disconnect)
  }
}

/// A scheduler that counts submissions instead of making them.
private final class CountingScheduler: BackgroundRefreshScheduling, @unchecked Sendable {
  private let lock = NSLock()
  private var _scheduled = 0
  private var _registrations = 0

  var scheduled: Int { lock.withLock { _scheduled } }
  var registrations: Int { lock.withLock { _registrations } }

  func register(_ run: @escaping @Sendable @MainActor () async -> Void) {
    lock.withLock { _registrations += 1 }
  }

  func schedule() {
    lock.withLock { _scheduled += 1 }
  }
}

/// The fifteen-minute background look at the last selected host. A `BGAppRefreshTask` cannot
/// be driven from XCUITest, so a device check is the only end-to-end test.
@MainActor
@Suite("BackgroundRefresh", .timeLimit(.minutes(1)))
struct BackgroundRefreshTests {
  private let workbox = DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson")

  private func environment(
    hosts: [DriverrCore.Host],
    center: FakeNotificationCenter,
    scheduler: CountingScheduler,
    announced: any AnnouncedPaneStore = InMemoryAnnouncedPaneStore()
  ) -> AppEnvironment {
    var environment = AppEnvironment.ephemeral
    environment.hostStore = InMemoryHostStore(seeded: hosts)
    environment.notifications = center
    environment.announcedPanes = announced
    environment.backgroundRefresh = scheduler
    return environment
  }

  @Test("a refresh connects, snapshots, posts and disconnects")
  func aRefreshPostsForANewlyBlockedPane() async {
    let center = FakeNotificationCenter(status: .authorized)
    let scheduler = CountingScheduler()
    let session = FakeSession(snapshot: tree([pane("w1:p1", status: .blocked)]))
    let runner = BackgroundRefreshRunner(
      environment: environment(hosts: [workbox], center: center, scheduler: scheduler),
      storedSelection: { self.workbox.id.uuidString },
      makeSession: { _, _ in session }
    )

    let outcome = await runner.run()

    #expect(outcome == .refreshed(blockedPanes: 1))
    #expect(session.steps == [.connect, .snapshot, .disconnect])
    let posts = await center.posts
    #expect(posts.map(\.id) == [BlockedPaneAlerts.notificationID(hostID: workbox.id, paneID: "w1:p1")])
    #expect(posts.first?.userInfo[NotificationTapRouter.paneIDKey] == "w1:p1")
    // One request is one launch, so a run that did not reschedule would be the last.
    #expect(scheduler.scheduled == 1)
  }

  /// A cold background launch starts with an empty announced set unless it reads the one the
  /// last run wrote.
  @Test("a pane announced by an earlier run is not announced again")
  func anEarlierRunsAnnouncementIsNotRepeated() async {
    let center = FakeNotificationCenter(status: .authorized)
    let scheduler = CountingScheduler()
    let session = FakeSession(snapshot: tree([pane("w1:p1", status: .blocked)]))
    let runner = BackgroundRefreshRunner(
      environment: environment(
        hosts: [workbox],
        center: center,
        scheduler: scheduler,
        announced: InMemoryAnnouncedPaneStore(seeded: [workbox.id: ["w1:p1"]])
      ),
      storedSelection: { self.workbox.id.uuidString },
      makeSession: { _, _ in session }
    )

    #expect(await runner.run() == .refreshed(blockedPanes: 1))
    #expect(await center.posts.isEmpty)
  }

  /// The last selected host, not every saved one.
  @Test("no host has been selected, so nothing is connected to")
  func noSelectionConnectsToNothing() async {
    let center = FakeNotificationCenter(status: .authorized)
    let scheduler = CountingScheduler()
    let session = FakeSession(snapshot: tree([pane("w1:p1", status: .blocked)]))
    let runner = BackgroundRefreshRunner(
      environment: environment(hosts: [workbox], center: center, scheduler: scheduler),
      storedSelection: { nil },
      makeSession: { _, _ in session }
    )

    #expect(await runner.run() == .noHostSelected)
    #expect(session.steps.isEmpty)
    #expect(await center.posts.isEmpty)
    // Still rescheduled: a launch with no selection yet must not end the chain.
    #expect(scheduler.scheduled == 1)
  }

  /// A host deleted since the launch that selected it. The stored id resolves against the
  /// list, exactly as `ContentView` resolves it on the way up.
  @Test("a stored host that no longer exists is not connected to")
  func aDeletedHostIsNotConnectedTo() async {
    let center = FakeNotificationCenter(status: .authorized)
    let scheduler = CountingScheduler()
    let session = FakeSession()
    let runner = BackgroundRefreshRunner(
      environment: environment(hosts: [], center: center, scheduler: scheduler),
      storedSelection: { self.workbox.id.uuidString },
      makeSession: { _, _ in session }
    )

    #expect(await runner.run() == .noHostSelected)
    #expect(session.steps.isEmpty)
  }

  /// A host that would need a password nobody can be asked for, or a herdr that does not
  /// answer: the run ends without a card and, importantly, without a session left open.
  @Test("a host that will not connect is put down again")
  func aHostThatWillNotConnectIsPutDown() async {
    let center = FakeNotificationCenter(status: .authorized)
    let scheduler = CountingScheduler()
    let session = FakeSession()
    session.isConnectedForRefresh = false
    let runner = BackgroundRefreshRunner(
      environment: environment(hosts: [workbox], center: center, scheduler: scheduler),
      storedSelection: { self.workbox.id.uuidString },
      makeSession: { _, _ in session }
    )

    #expect(await runner.run() == .couldNotReachTheHost)
    #expect(session.steps == [.connect, .disconnect])
    #expect(await center.posts.isEmpty)
    #expect(scheduler.scheduled == 1)
  }

  /// The expiration path, first half: the system took the budget back before the run got
  /// going. Nothing is connected to at all.
  @Test("a run cancelled before it starts connects to nothing and still reschedules")
  func cancelledBeforeStarting() async {
    let center = FakeNotificationCenter(status: .authorized)
    let scheduler = CountingScheduler()
    let session = FakeSession()
    let runner = BackgroundRefreshRunner(
      environment: environment(hosts: [workbox], center: center, scheduler: scheduler),
      storedSelection: { self.workbox.id.uuidString },
      makeSession: { _, _ in session }
    )

    // Cancelled before the task body has had a chance to run: this test is on the main
    // actor and never suspends between the two lines, so the body cannot have started.
    let task = Task { @MainActor in await runner.run() }
    task.cancel()

    #expect(await task.value == .cancelled)
    #expect(session.steps.isEmpty)
    #expect(scheduler.scheduled == 1)
  }

  /// The expiration path, second half: the budget runs out while the connection is up. The
  /// snapshot is abandoned and the session is still put down.
  @Test("a run cancelled after connecting disconnects instead of snapshotting")
  func cancelledAfterConnecting() async {
    let center = FakeNotificationCenter(status: .authorized)
    let scheduler = CountingScheduler()
    let session = FakeSession(snapshot: tree([pane("w1:p1", status: .blocked)]))
    let runner = BackgroundRefreshRunner(
      environment: environment(hosts: [workbox], center: center, scheduler: scheduler),
      storedSelection: { self.workbox.id.uuidString },
      makeSession: { _, _ in session }
    )

    // The fake cancels the run from inside `connectForRefresh`, as the expiration handler
    // does from outside, but deterministically.
    let box = TaskBox()
    session.duringConnect = { box.value?.cancel() }
    let run = Task { @MainActor in await runner.run() }
    // Set before the body can start: a `Task` does not run until the main actor suspends,
    // and this line is on the main actor with no `await` between it and the creation above.
    box.value = run

    #expect(await run.value == .cancelled)
    // `contains` rather than an exact list: the cancellation handler and the guard both
    // disconnect, in either order.
    #expect(session.steps.contains(.connect))
    #expect(session.steps.contains(.disconnect))
    #expect(!session.steps.contains(.snapshot))
    #expect(await center.posts.isEmpty)
    #expect(scheduler.scheduled == 1)
  }

  /// The expiration handler cancels the run's task, and a cancellation handler has to carry
  /// that to `ConnectionModel.connect`, which awaits an unstructured `Task`. Otherwise the run
  /// sits in the handshake for its full deadline after the system took the budget back.
  ///
  /// The connect here answers on its own after two seconds, and `FakeSession.ConnectEnding`
  /// records which ending arrived.
  @Test("an expiration during the connect ends the connect")
  func expirationDuringConnectEndsTheConnect() async {
    let center = FakeNotificationCenter(status: .authorized)
    let scheduler = CountingScheduler()
    let session = FakeSession(snapshot: tree([pane("w1:p1", status: .blocked)]))
    session.connectAnswersAfter = .seconds(2)
    let runner = BackgroundRefreshRunner(
      environment: environment(hosts: [workbox], center: center, scheduler: scheduler),
      storedSelection: { self.workbox.id.uuidString },
      makeSession: { _, _ in session }
    )

    let box = TaskBox()
    session.duringConnect = { box.value?.cancel() }
    let run = Task { @MainActor in await runner.run() }
    box.value = run
    let outcome = await run.value

    #expect(outcome == .cancelled)
    #expect(
      session.connectEnding == .disconnect,
      "the expiration did not reach the connect; it ended on its own deadline"
    )
    #expect(session.steps.contains(.connect))
    #expect(session.steps.contains(.disconnect))
    #expect(!session.steps.contains(.snapshot))
    #expect(await center.posts.isEmpty)
  }
}

/// Somewhere to put a task that has to be reachable from inside its own body.
///
/// Written before the task starts and read from the main actor only: the test never
/// suspends between assigning it and the fake reading it back.
@MainActor
private final class TaskBox {
  var value: Task<BackgroundRefreshRunner.Outcome, Never>?
}
