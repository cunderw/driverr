import DriverrCore
import DriverrHerdr
import DriverrSSH
import Foundation
import Testing

@testable import Driverr

/// The connect screen's model, without a screen.
@MainActor
@Suite("ConnectionModel", .serialized, .timeLimit(.minutes(1)))
struct ConnectionModelTests {
  private let workbox = DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson")

  /// `.ephemeral` with the host's key already trusted. Otherwise TOFU raises a prompt nobody
  /// answers, and the connect suspends rather than failing.
  private func environment(
    trustingTheHostKey: Bool = true,
    stallingTheHandshakeFor stall: Duration? = nil
  ) -> AppEnvironment {
    var environment = AppEnvironment.ephemeral
    environment.knownHostsStore = InMemoryKnownHostsStore(
      seeded: trustingTheHostKey ? [workbox.hostname: FakeSSHTransport.defaultHostKey] : [:]
    )
    // A handshake slow enough that the phase is certainly still an attempt when a test looks.
    // `.ephemeral`'s own stall comes from launch arguments, which a unit test does not have.
    if let stall {
      environment.makeTransport = { FakeSSHTransport(handshakeStall: stall) }
    }
    return environment
  }

  private func connected() async -> ConnectionModel {
    let model = ConnectionModel(host: workbox, environment: environment())
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    return model
  }

  /// A connected model whose writes land in `store`, with its session tree loaded.
  ///
  /// The write needs the tree: the witness comes off the pane herdr reports. Every pane in
  /// `FakeControl.seededTree` carries a terminal id.
  private func connected(rememberingInto store: InMemoryLastPaneStore) async -> ConnectionModel {
    var rememberingPanes = environment()
    rememberingPanes.lastPanes = store
    let model = ConnectionModel(host: workbox, environment: rememberingPanes)
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    await model.session?.refresh()
    return model
  }

  private func record(_ paneID: String, _ witness: String) -> LastPaneRecord {
    LastPaneRecord(paneID: paneID, witness: witness)
  }

  // MARK: - Which pane this host was last open on

  /// Closing the pane the record names takes the record with it, so nothing tries to resume
  /// a pane that is gone. The tree check in `BlockedPaneActivityRoute.resumed` would catch
  /// it too; this keeps the defaults from carrying dead ids.
  @Test("closing the remembered pane forgets the record")
  func closingTheRememberedPaneForgetsIt() async throws {
    let store = InMemoryLastPaneStore(seeded: [workbox.id: record("w1:p1", "term_w1p1")])
    var rememberingPanes = environment()
    rememberingPanes.lastPanes = store
    let model = ConnectionModel(host: workbox, environment: rememberingPanes)

    model.forgetLastPane("w1:p1")

    try await untilLastPane(store, is: nil)
  }

  /// A scene that switched to `w1:p2` and then closes `w1:p1` must not throw away the record
  /// for the pane still on screen.
  @Test("closing a pane the record does not name leaves it alone")
  func closingAnotherPaneLeavesTheRecord() async throws {
    let store = InMemoryLastPaneStore(seeded: [workbox.id: record("w1:p2", "term_w1p2")])
    var rememberingPanes = environment()
    rememberingPanes.lastPanes = store
    let model = ConnectionModel(host: workbox, environment: rememberingPanes)

    // Matched on the pane id alone; the witness has no part in a close.
    model.forgetLastPane("w1:p1")

    try await untilLastPane(store, is: record("w1:p2", "term_w1p2"))
  }

  /// The witness comes off the tree at the write. A resume checks the host's panes against it;
  /// a record carrying only the pane id would resume a stranger in a rebuilt session.
  @Test("noting a pane writes it against this host, with the pane's witness")
  func notingAPaneWritesIt() async throws {
    let store = InMemoryLastPaneStore()
    let model = await connected(rememberingInto: store)

    model.noteLastPane("w2:p1")

    try await untilLastPane(store, is: record("w2:p1", "term_w2p1"))
  }

  /// A pane the tree does not report is forgotten. With no witness, a record could not be
  /// checked, and keeping an older one would resume a pane the reader has since left.
  @Test("noting a pane the host does not report forgets the record")
  func notingAnUnknownPaneForgetsTheRecord() async throws {
    let store = InMemoryLastPaneStore(seeded: [workbox.id: record("w1:p1", "term_w1p1")])
    let model = await connected(rememberingInto: store)

    model.noteLastPane("w9:p9")

    try await untilLastPane(store, is: nil)
  }

  /// A card's or a notification's tap presents a pane before the poll has filled the tree, and
  /// `TerminalPresenter.present` notes it at once. Reading the empty tree as "no such pane"
  /// would wipe the record, and `TerminalSceneModel.select` would not put it back.
  ///
  /// An empty tree is an absence of evidence, so the write does nothing. The resume fails
  /// closed: it checks the witness against the tree at the tap.
  @Test("noting a pane before the tree has loaded leaves the record alone")
  func notingBeforeTheTreeLoadsLeavesTheRecordAlone() async throws {
    let kept = record("w1:p1", "term_w1p1")
    let store = InMemoryLastPaneStore(seeded: [workbox.id: kept])
    var rememberingPanes = environment()
    rememberingPanes.lastPanes = store
    let model = ConnectionModel(host: workbox, environment: rememberingPanes)
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    try #require(
      model.session?.tree.isEmpty == true,
      "the tree filled before the note, so this run proves nothing about the empty case")

    model.noteLastPane("w1:p2")

    // The write is fire-and-forget, so the record has to survive longer than a write takes.
    try await stillLastPane(store, is: kept)
  }

  /// Somebody whose last act was to open the plain shell was not left in a pane.
  @Test("noting the plain shell forgets the record")
  func notingTheShellForgetsTheRecord() async throws {
    let store = InMemoryLastPaneStore(seeded: [workbox.id: record("w1:p1", "term_w1p1")])
    let model = await connected(rememberingInto: store)

    model.noteLastPane(for: .shell)

    try await untilLastPane(store, is: nil)
  }

  /// `settledPhase` returns at once for a phase that is not an attempt, so the ordinary
  /// resume pays nothing for the wait that the racing one needs.
  @Test("settling returns immediately when no attempt is running")
  func settlingIsFreeWhenIdle() async {
    let model = ConnectionModel(host: workbox, environment: environment())
    await model.settledPhase()
    #expect(model.phase == .idle)
  }

  /// It waits out an attempt that is running, the race `TerminalPresenter.resumeRememberedPane`
  /// meets when the host screen's own connect got there first.
  @Test("settling waits for an attempt that is already running")
  func settlingWaitsForAnInFlightAttempt() async {
    let model = ConnectionModel(
      host: workbox, environment: environment(stallingTheHandshakeFor: .milliseconds(400)))
    let inFlight = Task { await model.connect(password: "hunter2", persistence: .promptEveryTime) }
    // Wait for the attempt to start, or `settledPhase` finds `.idle` and returns at once.
    while model.phase == .idle { await Task.yield() }
    #expect(
      model.phase == .connecting || model.phase == .authenticating,
      "the stall did not hold the attempt open, so this run proves nothing"
    )

    await model.settledPhase()

    #expect(model.phase == .connected, "the wait ended before the attempt did")
    await inFlight.value
  }

  /// The budget is a backstop, not a second deadline. A wait that runs out returns and
  /// changes nothing; the caller treats anything but `.connected` as a connect that did not
  /// arrive.
  @Test("a budget that runs out returns with the attempt still running")
  func anExhaustedBudgetReturnsAnyway() async {
    // Stalled, or the attempt could move between the two reads of the phase.
    let model = ConnectionModel(
      host: workbox, environment: environment(stallingTheHandshakeFor: .milliseconds(400)))
    let inFlight = Task { await model.connect(password: "hunter2", persistence: .promptEveryTime) }
    while model.phase == .idle { await Task.yield() }
    let before = model.phase

    await model.settledPhase(within: .zero)

    #expect(model.phase == before, "the wait moved a phase it only observes")
    await inFlight.value
  }

  /// That a write which should not happen has not. Polling for an unchanged value returns at
  /// once, so this waits out a window several times longer than a write takes.
  private func stillLastPane(
    _ store: InMemoryLastPaneStore, is expected: LastPaneRecord?
  ) async throws {
    for _ in 0..<25 {
      try await Task.sleep(for: .milliseconds(20))
      let actual = await store.lastPane(forHost: workbox.id)
      guard actual == expected else {
        Issue.record("the record was changed to \(actual as Any), expected \(expected as Any)")
        return
      }
    }
  }

  /// Both writes are fire-and-forget (see `ConnectionModel.noteLastPane`), so a test polls. The
  /// value has to hold across a short settle, so a later write cannot change it.
  private func untilLastPane(
    _ store: InMemoryLastPaneStore, is expected: LastPaneRecord?
  ) async throws {
    for _ in 0..<200 {
      if await store.lastPane(forHost: workbox.id) == expected {
        try await Task.sleep(for: .milliseconds(20))
        if await store.lastPane(forHost: workbox.id) == expected { return }
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    let actual = await store.lastPane(forHost: workbox.id)
    Issue.record("last pane was \(actual as Any), expected \(expected as Any)")
  }

  /// The foreground feed. With `BlockedPaneActivityDriverTests.theBackgroundFeedCannotRequest`
  /// it pins that the two feeds differ in scope and `canRequest`. The registry gathers, because
  /// the card is one for the whole app and a `ConnectionModel` sees only its own host.
  @Test("a connect reaches the driver as an authoritative pass that may request")
  func aConnectIsTheTrigger() async throws {
    let driver = RecordingActivityDriver()
    var environment = self.environment()
    environment.blockedPaneActivities = driver
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    registry.onLiveActivityInputChanged = { observations, canRequest in
      Task {
        await driver.observed(
          observations, scope: .everyConnectedHost, canRequest: canRequest)
      }
    }
    let model = registry.model(for: workbox, environment: environment)
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    #expect(model.phase == .connected)

    await waitUntil("the connect never reached the driver as a connected pass") {
      driver.passes.contains { $0.observations.contains { $0.isConnected } }
    }
    let pass = try #require(
      driver.passes.last(where: { $0.observations.contains { $0.isConnected } }))
    #expect(pass.canRequest, "a card is requested from the foreground")
    #expect(pass.scope == .everyConnectedHost)
    let seen = try #require(pass.observations.first)
    #expect(seen.hostID == workbox.id)
    #expect(seen.hostName == "workbox")
    #expect(seen.isConnected)
  }

  /// The card's counts and blocked pane move with the tree, so the poll has to keep pushing
  /// passes. Nothing polls until somebody is looking, so the test starts live updates.
  @Test("the foreground poll keeps pushing the host's panes and counts")
  func theForegroundPollKeepsPushing() async throws {
    let driver = RecordingActivityDriver()
    var environment = self.environment()
    environment.blockedPaneActivities = driver
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    registry.onLiveActivityInputChanged = { observations, canRequest in
      Task {
        await driver.observed(
          observations, scope: .everyConnectedHost, canRequest: canRequest)
      }
    }
    let model = registry.model(for: workbox, environment: environment)
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    model.session?.startLiveUpdates()

    await waitUntil("the poll never pushed a pass carrying a blocked pane") {
      driver.passes.contains { $0.observations.contains { !$0.blockedPanes.isEmpty } }
    }
    let pass = try #require(
      driver.passes.last(where: { $0.observations.contains { !$0.blockedPanes.isEmpty } }))
    let seen = try #require(pass.observations.first)
    // `FakeControl.seededTree`'s one blocked pane, through the production path.
    #expect(seen.blockedPanes.map(\.id) == ["w1:p2"])
    #expect(seen.counts.blocked == 1)
    #expect(seen.counts.working + seen.counts.idle + seen.counts.shells > 0)
  }

  /// A disconnect ends the card, so it reaches the driver through the phase, not through a
  /// poll that has already stopped.
  @Test("a disconnect reaches the driver as a pass with nothing connected")
  func aDisconnectIsTheEnd() async throws {
    let driver = RecordingActivityDriver()
    var environment = self.environment()
    environment.blockedPaneActivities = driver
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    registry.onLiveActivityInputChanged = { observations, canRequest in
      Task {
        await driver.observed(
          observations, scope: .everyConnectedHost, canRequest: canRequest)
      }
    }
    let model = registry.model(for: workbox, environment: environment)
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    await model.disconnect()
    #expect(model.phase == .idle)

    await waitUntil("the disconnect never reached the driver as a pass with nothing connected") {
      driver.passes.contains { pass in
        !pass.observations.isEmpty && pass.observations.allSatisfy { !$0.isConnected }
      }
    }
    #expect(
      driver.passes.contains { pass in
        !pass.observations.isEmpty && pass.observations.allSatisfy { !$0.isConnected }
      },
      "a disconnect must push a pass the reconciler can end the card from")
  }

  /// One bad command must not put a healthy connection into `.failed`, which would empty the
  /// tree and remove Disconnect. The error belongs beside the command.
  ///
  /// Both endings of `run`: an unknown command returns a shell's 127, not a throw, and a
  /// refused channel reaches the `catch`.
  @Test("a command that fails does not take the connection down with it")
  func failedCommandKeepsThePhase() async {
    let transport = FakeSSHTransport()
    var environment = self.environment()
    environment.makeTransport = { transport }
    let model = ConnectionModel(host: workbox, environment: environment)
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    #expect(model.phase == .connected)

    // The fake answers an unknown command as a shell does: 127, and no throw.
    await model.run("definitely-not-a-command")

    #expect(model.phase == .connected, "a 127 must not change the connection")
    #expect(model.commandFailure == nil, "a 127 is output, not an error")
    #expect(model.output.contains("command not found"))

    // The throwing path: channels down without a loss, so the coordinator is still
    // `.connected` and `execChannel` refuses.
    await transport.tearDownEveryChannel()
    await model.run("herdr list")

    #expect(model.phase == .connected, "an ad-hoc command must not change the connection")
    #expect(model.failure == nil, "the failure belongs beside the command, not on the pill")
    #expect(model.commandFailure != nil, "the command's own error has to be reported")
  }

  /// A cancelled attempt must not report over a live one.
  ///
  /// Cancelling leaves the handshake suspended in the transport, so Connect straight
  /// afterwards leaves two attempts alive. If the dead one's ending were written, the spinner
  /// would become a Connect button mid-handshake and Cancel would lose the live attempt.
  @Test("a cancelled attempt does not report over the attempt that replaced it")
  func aCancelledAttemptDoesNotOverwriteANewerOne() async {
    var environment = self.environment()
    // Long enough that both attempts are unambiguously still in the handshake.
    environment.makeTransport = { FakeSSHTransport(handshakeStall: .seconds(30)) }
    let model = ConnectionModel(host: workbox, environment: environment)

    let first = Task { await model.connect(password: "hunter2", persistence: .promptEveryTime) }
    while model.phase != .connecting, model.phase != .authenticating {
      await Task.yield()
    }
    await model.cancelConnect()
    #expect(model.phase == .idle)

    // The user tries again immediately, while the cancelled handshake is still parked.
    let second = Task { await model.connect(password: "hunter2", persistence: .promptEveryTime) }
    while model.phase != .connecting, model.phase != .authenticating {
      await Task.yield()
    }
    // The cancelled attempt now runs its own ending.
    await first.value

    #expect(
      model.phase == .connecting || model.phase == .authenticating,
      "the dead attempt wrote \(model.phase) over the live one"
    )
    // Cancel still reaches the running attempt.
    await model.cancelConnect()
    await second.value
    #expect(model.phase == .idle)
  }

  /// A Cancel that lands inside the actor hop of `phase = await coordinator.phase`.
  ///
  /// An identity guard only before that hop would miss the cancel: the retired attempt would
  /// write `.connected` and build the whole connected set-up under an idle screen.
  ///
  /// Asserted on what was built, not the phase: `cancelConnect` writes `.idle` after the
  /// retired attempt finishes, so the phase is `.idle` either way.
  @Test("a cancel while connecting leaves nothing connected behind the idle screen")
  func cancelWhileConnectingBuildsNothing() async {
    await aCancelMidHandshakeBuildsNothing()
    await aCancelAimedAtThePhaseHopBuildsNothing()
  }

  /// The half that always runs: a cancel unambiguously inside the handshake.
  ///
  /// A stalled handshake makes this deterministic, so the invariant is asserted on every run
  /// even when the opportunistic half hits nothing.
  private func aCancelMidHandshakeBuildsNothing() async {
    var environment = self.environment()
    environment.makeTransport = { FakeSSHTransport(handshakeStall: .seconds(30)) }
    let model = ConnectionModel(host: workbox, environment: environment)

    let attempt = Task { await model.connect(password: "hunter2", persistence: .promptEveryTime) }
    while model.phase != .connecting, model.phase != .authenticating {
      await Task.yield()
    }
    await model.cancelConnect()
    await attempt.value

    expectNothingWasBuilt(by: model, "a cancel inside the handshake")
  }

  /// The half that aims at the hop itself, and reaches it a fraction of the time.
  ///
  /// Woken by the connection's progress, not a clock: `CoordinatorStepTransport` signals when
  /// `watchForClosure()` runs, the coordinator's last step after publishing `.connected`. The
  /// canceller and the attempt's resumption then race onto the main actor. Only an undelayed
  /// cancel ever lands inside the hop, from nearly always to never depending on the machine;
  /// any delay moves it past the window.
  ///
  /// **Do not trim the 120 repetitions.** They are the whole mechanism. At the lowest hit rate
  /// seen (7 of 60), 120 passes let a regression through about once in three million runs.
  ///
  /// This cannot be made deterministic from outside `DriverrSSH`: the window is one main-actor
  /// job wide and there is no seam between the guard and the write.
  private func aCancelAimedAtThePhaseHopBuildsNothing() async {
    for repetition in 0..<120 {
      let transport = CoordinatorStepTransport()
      var environment = self.environment()
      environment.makeTransport = { transport }
      let model = ConnectionModel(host: workbox, environment: environment)

      // Parked before the connect starts, so the signal wakes a job already waiting on the
      // main actor.
      let armed = AsyncStream<Void>.makeStream()
      let canceller = Task { @MainActor in
        for await _ in armed.stream { break }
        await model.cancelConnect()
      }
      await transport.signalWhenWatchingForClosure {
        armed.continuation.yield(())
        armed.continuation.finish()
      }

      await model.connect(password: "hunter2", persistence: .promptEveryTime)
      // A handshake that failed before `watchForClosure()` would leave the canceller parked.
      armed.continuation.finish()
      await canceller.value

      // The cancel arrived after `.connected`, so this pass connected. Correct, and not the
      // subject.
      guard model.phase != .connected else { continue }

      expectNothingWasBuilt(by: model, "repetition \(repetition)")
    }
  }

  /// A cancelled attempt leaves an idle screen with nothing hanging off it. `sourceLocation`
  /// makes a failure name the half that produced it.
  private func expectNothingWasBuilt(
    by model: ConnectionModel,
    _ pass: String,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(model.phase == .idle, "\(pass): the phase is \(model.phase)", sourceLocation: sourceLocation)
    #expect(
      model.failure == nil,
      "\(pass): a cancelled attempt reported a failure",
      sourceLocation: sourceLocation
    )
    expectNoConnectedSetUp(on: model, pass, sourceLocation: sourceLocation)
  }

  /// The four objects the connected block publishes, none of which an attempt that never
  /// finished it may leave behind. Separate from `expectNothingWasBuilt` for an attempt that
  /// ends `.failed` on purpose.
  private func expectNoConnectedSetUp(
    on model: ConnectionModel,
    _ pass: String,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(
      model.session == nil,
      "\(pass): a session was built by an attempt that never connected",
      sourceLocation: sourceLocation
    )
    #expect(
      model.herdr == nil,
      "\(pass): a herdr control was built by an attempt that never connected",
      sourceLocation: sourceLocation
    )
    #expect(
      model.herdrAvailability == nil,
      "\(pass): a retired attempt published what herdr the host has",
      sourceLocation: sourceLocation
    )
    #expect(
      model.transcripts == nil,
      "\(pass): a transcript cache was built by an attempt that never connected",
      sourceLocation: sourceLocation
    )
  }

  /// A superseded attempt must not publish its connected set-up over the live one.
  ///
  /// Two awaits follow the phase read: `environment.makeHerdrControl(transport)` and
  /// `control.availability()`. An attempt retired inside either needs an identity check on the
  /// way out, or it writes its control, caches, `herdrAvailability`, `SessionModel` and loss
  /// watcher over the live attempt's.
  ///
  /// This is the superseding case: a second attempt publishes while the first is parked.
  /// `aStalledSetUpCanBeEnded` covers Cancel and Disconnect alone.
  ///
  /// Deterministic, because `AppEnvironment.makeHerdrControl` is the test's own seam: the first
  /// attempt parks there while Disconnect and a second Connect run.
  ///
  /// Asserted on values and identities, never the phase, which is `.connected` either way.
  @Test("a superseded attempt does not publish the connection it built")
  func aSupersededAttemptPublishesNothing() async {
    await aSupersededAttemptParkedInAvailabilityPublishesNothing()
    await aSupersededAttemptParkedInTheControlFactoryPublishesNothing()
  }

  /// The second of the two awaits: parked inside `control.availability()`.
  ///
  /// The retired attempt has published `herdr` and the caches before it parks, so what it
  /// could overwrite on the way out is `herdrAvailability`, the `SessionModel` and the loss
  /// watcher.
  private func aSupersededAttemptParkedInAvailabilityPublishesNothing() async {
    let parked = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let dispenser = ControlDispenser([
      GatedHerdrControl(
        inner: FakeControl(availability: retiredAttemptHerdr),
        onPark: {
          parked.continuation.yield(())
          parked.continuation.finish()
        },
        release: release.stream
      ),
      FakeControl(availability: liveAttemptHerdr),
    ])
    var environment = self.environment()
    environment.makeTransport = { FakeSSHTransport() }
    environment.makeHerdrControl = { _ in await dispenser.next() }
    let model = ConnectionModel(host: workbox, environment: environment)

    let superseded = Task {
      await model.connect(password: "hunter2", persistence: .promptEveryTime)
    }
    for await _ in parked.stream { break }

    // Disconnect alone retires the parked attempt. The Connect is still needed: without a
    // live set-up there is nothing for the retired attempt to overwrite.
    await model.disconnect()
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    let live = ConnectedSet(model)

    release.continuation.yield(())
    release.continuation.finish()
    await superseded.value

    expectTheLiveAttemptStillOwns(model, live, "parked in availability()")
  }

  /// The first of the two awaits: parked inside `makeHerdrControl` itself.
  ///
  /// The factory is already the test's closure, so nothing has to be wrapped. Parked here, the
  /// retired attempt has written nothing yet, so it could publish the whole set-up.
  private func aSupersededAttemptParkedInTheControlFactoryPublishesNothing() async {
    let parked = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let calls = CallCounter()
    var environment = self.environment()
    environment.makeTransport = { FakeSSHTransport() }
    environment.makeHerdrControl = { _ in
      guard await calls.isFirst() else { return FakeControl(availability: liveAttemptHerdr) }
      parked.continuation.yield(())
      parked.continuation.finish()
      for await _ in release.stream { break }
      return FakeControl(availability: retiredAttemptHerdr)
    }
    let model = ConnectionModel(host: workbox, environment: environment)

    let superseded = Task {
      await model.connect(password: "hunter2", persistence: .promptEveryTime)
    }
    for await _ in parked.stream { break }

    await model.disconnect()
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    let live = ConnectedSet(model)

    release.continuation.yield(())
    release.continuation.finish()
    await superseded.value

    expectTheLiveAttemptStillOwns(model, live, "parked in makeHerdrControl()")
  }

  /// Everything the connected block publishes, read off the model when the live attempt
  /// finished.
  private struct ConnectedSet {
    let session: SessionModel?
    let transcripts: PaneTranscriptCache?
    let paneScreens: PaneScreenCache?
    let composers: PaneComposerCache?
    let binaryPath: String?

    @MainActor
    init(_ model: ConnectionModel) {
      session = model.session
      transcripts = model.transcripts
      paneScreens = model.paneScreens
      composers = model.composers
      binaryPath = model.herdr?.binaryPath
    }
  }

  /// After the retired attempt has run its ending, the model still holds exactly what the live
  /// attempt published.
  ///
  /// The `!= nil` check keeps the identity comparisons from holding vacuously.
  ///
  /// The `paneScreens` and `composers` comparisons cannot fail: both are built only while nil,
  /// and kept across a reconnect. The regression is caught by `session`, `transcripts`,
  /// `herdr` (through `binaryPath`) and `herdrAvailability`.
  private func expectTheLiveAttemptStillOwns(
    _ model: ConnectionModel,
    _ live: ConnectedSet,
    _ half: String,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(
      model.phase == .connected,
      "\(half): the phase is \(model.phase)",
      sourceLocation: sourceLocation
    )
    #expect(
      live.session != nil,
      "\(half): the live attempt built no session, so nothing below is being tested",
      sourceLocation: sourceLocation
    )
    #expect(
      model.herdrAvailability == liveAttemptHerdr,
      "\(half): availability reads \(String(describing: model.herdrAvailability))",
      sourceLocation: sourceLocation
    )
    #expect(
      model.session === live.session,
      "\(half): a superseded attempt replaced the live SessionModel",
      sourceLocation: sourceLocation
    )
    #expect(
      model.transcripts === live.transcripts,
      "\(half): a superseded attempt replaced the live transcript cache",
      sourceLocation: sourceLocation
    )
    #expect(
      model.paneScreens === live.paneScreens,
      "\(half): a superseded attempt replaced the live screen cache",
      sourceLocation: sourceLocation
    )
    #expect(
      model.composers === live.composers,
      "\(half): a superseded attempt replaced the live composer cache",
      sourceLocation: sourceLocation
    )
    #expect(
      model.herdr?.binaryPath == live.binaryPath,
      "\(half): a superseded attempt replaced the live herdr control",
      sourceLocation: sourceLocation
    )
  }

  /// A host that finishes the handshake and then stops answering.
  ///
  /// `ConnectionCoordinator.withHandshakeDeadline` bounds everything up to authentication. The
  /// two hops after it, `environment.makeHerdrControl(transport)` and `control.availability()`,
  /// run herdr over an exec channel that can wait for ever, so they need `setUpDeadline`.
  ///
  /// Never awaits `connect` directly: on a regression that is the hang, and the suite would
  /// hang rather than this test fail. The attempt raises a `Flag` instead.
  ///
  /// The release stream is not yielded until the assertions are done, so the hop is still
  /// parked when the deadline fires however loaded the machine is.
  @Test("a set-up that never answers ends the attempt rather than parking it")
  func aSetUpThatNeverAnswersEndsTheAttempt() async {
    await aParkedControlFactoryEndsTheAttempt()
    await aParkedAvailabilityEndsTheAttempt()
  }

  /// The first hop: parked inside `makeHerdrControl` itself.
  ///
  /// Nothing has been published when it parks, so the abandoned hop must not build the whole
  /// connected set-up under a failed screen on its way back.
  private func aParkedControlFactoryEndsTheAttempt() async {
    let parked = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let resumed = AsyncStream<Void>.makeStream()
    var environment = self.environment()
    environment.makeTransport = { FakeSSHTransport() }
    environment.makeHerdrControl = { _ in
      parked.continuation.yield(())
      parked.continuation.finish()
      for await _ in release.stream { break }
      resumed.continuation.yield(())
      resumed.continuation.finish()
      return FakeControl(availability: retiredAttemptHerdr)
    }
    let model = ConnectionModel(
      host: workbox,
      environment: environment,
      setUpDeadline: .milliseconds(20)
    )

    let attempt = Flag()
    Task {
      await model.connect(password: "hunter2", persistence: .promptEveryTime)
      attempt.raise()
    }
    for await _ in parked.stream { break }
    await attempt.wait()

    expectTheSetUpWasGivenUpOn(model, "the control factory parked")

    // The abandoned hop lands into a model that has retired it.
    release.continuation.yield(())
    release.continuation.finish()
    for await _ in resumed.stream { break }
    expectTheSetUpWasGivenUpOn(model, "the abandoned control factory returned")
  }

  /// The second hop: parked inside `control.availability()`.
  ///
  /// What a real host produces: `herdr --version` down an exec channel that never answers.
  private func aParkedAvailabilityEndsTheAttempt() async {
    let parked = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let resumed = AsyncStream<Void>.makeStream()
    let dispenser = ControlDispenser([
      GatedHerdrControl(
        inner: FakeControl(availability: retiredAttemptHerdr),
        onPark: {
          parked.continuation.yield(())
          parked.continuation.finish()
        },
        release: release.stream,
        onResume: {
          resumed.continuation.yield(())
          resumed.continuation.finish()
        }
      )
    ])
    var environment = self.environment()
    environment.makeTransport = { FakeSSHTransport() }
    environment.makeHerdrControl = { _ in await dispenser.next() }
    let model = ConnectionModel(
      host: workbox,
      environment: environment,
      setUpDeadline: .milliseconds(20)
    )

    let attempt = Flag()
    Task {
      await model.connect(password: "hunter2", persistence: .promptEveryTime)
      attempt.raise()
    }
    for await _ in parked.stream { break }
    await attempt.wait()

    expectTheSetUpWasGivenUpOn(model, "availability() parked")

    release.continuation.yield(())
    release.continuation.finish()
    for await _ in resumed.stream { break }
    expectTheSetUpWasGivenUpOn(model, "the abandoned availability() returned")
  }

  /// The attempt reports a failure a person can act on and leaves nothing connected behind.
  /// The whole phase value is asserted, because "the host stopped answering" and "the
  /// handshake was refused" are different sentences.
  private func expectTheSetUpWasGivenUpOn(
    _ model: ConnectionModel,
    _ pass: String,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(
      model.phase == .failed(.herdrDidNotAnswer(host: workbox.hostname)),
      "\(pass): the phase is \(model.phase)",
      sourceLocation: sourceLocation
    )
    expectNoConnectedSetUp(on: model, pass, sourceLocation: sourceLocation)
  }

  /// The set-up runs under `.connecting`, so Cancel and Disconnect both work throughout.
  ///
  /// `cancelConnect` guards `.connecting` and `.authenticating`, so a `.connected` phase during
  /// set-up would leave no Cancel. `disconnect()` has to bump `currentAttempt`, or the parked
  /// hop comes back and publishes under an idle screen.
  ///
  /// `setUpDeadline` is long here, so `giveUpOnSetUp` cannot race the button and write
  /// `.failed`. Never awaits `connect` directly; see `aSetUpThatNeverAnswersEndsTheAttempt`.
  @Test("a set-up that is still running can be cancelled and disconnected")
  func aStalledSetUpCanBeEnded() async {
    await aStalledSetUpIsEndedBy({ await $0.cancelConnect() }, "Cancel")
    await aStalledSetUpIsEndedBy({ await $0.disconnect() }, "Disconnect")
  }

  /// Both halves, differing only in which button the user pressed.
  ///
  /// Gated in `makeHerdrControl`. The screen ends idle with nothing built, and the abandoned
  /// hop publishes nothing when it lands.
  private func aStalledSetUpIsEndedBy(
    _ end: @MainActor (ConnectionModel) async -> Void,
    _ half: String,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    let parked = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let resumed = AsyncStream<Void>.makeStream()
    var environment = self.environment()
    environment.makeTransport = { FakeSSHTransport() }
    environment.makeHerdrControl = { _ in
      parked.continuation.yield(())
      parked.continuation.finish()
      for await _ in release.stream { break }
      resumed.continuation.yield(())
      resumed.continuation.finish()
      return FakeControl(availability: retiredAttemptHerdr)
    }
    let model = ConnectionModel(
      host: workbox,
      environment: environment,
      setUpDeadline: .seconds(30)
    )

    let attempt = Flag()
    Task {
      await model.connect(password: "hunter2", persistence: .promptEveryTime)
      attempt.raise()
    }
    for await _ in parked.stream { break }

    // Why either button works at all.
    #expect(
      model.phase == .connecting,
      "\(half): the phase while the set-up is parked is \(model.phase)",
      sourceLocation: sourceLocation
    )

    await end(model)

    #expect(
      model.phase == .idle,
      "\(half): the phase straight after is \(model.phase)",
      sourceLocation: sourceLocation
    )
    expectNoConnectedSetUp(on: model, "\(half) was pressed", sourceLocation: sourceLocation)

    // The abandoned hop lands into a model that has retired it.
    release.continuation.yield(())
    release.continuation.finish()
    for await _ in resumed.stream { break }
    await attempt.wait()

    #expect(
      model.phase == .idle,
      "\(half): the abandoned hop moved the phase to \(model.phase)",
      sourceLocation: sourceLocation
    )
    expectNoConnectedSetUp(
      on: model,
      "\(half): the abandoned hop returned",
      sourceLocation: sourceLocation
    )
  }

  /// Connected is not said until it is true, and then it is. Gated on `control.availability()`.
  @Test("a connect whose set-up is still running does not say it is connected")
  func aStalledSetUpDoesNotReadAsConnected() async {
    let parked = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let dispenser = ControlDispenser([
      GatedHerdrControl(
        inner: FakeControl(availability: retiredAttemptHerdr),
        onPark: {
          parked.continuation.yield(())
          parked.continuation.finish()
        },
        release: release.stream
      )
    ])
    var environment = self.environment()
    environment.makeTransport = { FakeSSHTransport() }
    environment.makeHerdrControl = { _ in await dispenser.next() }
    let model = ConnectionModel(
      host: workbox,
      environment: environment,
      setUpDeadline: .seconds(30)
    )

    let attempt = Flag()
    Task {
      await model.connect(password: "hunter2", persistence: .promptEveryTime)
      attempt.raise()
    }
    for await _ in parked.stream { break }

    #expect(
      model.phase == .connecting,
      "the phase while herdr is being asked for its version is \(model.phase)"
    )
    #expect(
      model.herdrAvailability == nil,
      "what herdr the host has was published before the answer arrived"
    )

    release.continuation.yield(())
    release.continuation.finish()
    await attempt.wait()

    // The set-up published, so the screen may say so.
    #expect(model.phase == .connected, "the phase after the set-up published is \(model.phase)")
    #expect(model.herdrAvailability == retiredAttemptHerdr)
  }

  /// Nothing was sent, so nothing can have been refused.
  @Test("connecting with no password reports a missing password, not a refusal")
  func emptyPasswordIsNotARefusal() async {
    let model = ConnectionModel(host: workbox, environment: environment())

    await model.connect(password: "", persistence: .promptEveryTime)

    #expect(model.phase == .failed(.passwordRequired(host: "10.1.0.9")))
  }

  /// A password nobody remembered is not Driverr's to supply. An attempt with nothing to offer
  /// would put a red error on a screen the user just opened.
  @Test("a host that would have to ask does not connect on its own")
  func appearanceLeavesAPasswordHostAlone() async {
    let model = ConnectionModel(host: workbox, environment: environment())

    await model.connectIfCredentialIsAvailable()

    #expect(model.phase == .idle)
  }

  @Test("a host whose password Driverr already holds connects on its own")
  func appearanceConnectsWithASavedPassword() async {
    var environment = self.environment()
    environment.passwordStore = InMemoryPasswordStore(seeded: [workbox.id: "hunter2"])
    let model = ConnectionModel(host: workbox, environment: environment)

    await model.connectIfCredentialIsAvailable()

    #expect(model.phase == .connected)
  }

  /// The way back from a rebuilt server. Asserted on the store: a model that only cleared its
  /// own error would look the same and fail on the next attempt.
  @Test("forgetting a host key clears the store and clears the mismatch")
  func forgetHostKeyClearsTheStore() async {
    let store = InMemoryKnownHostsStore(
      seeded: [workbox.hostname: AppEnvironment.staleHostKey]
    )
    var environment = self.environment()
    environment.knownHostsStore = store
    let model = ConnectionModel(host: workbox, environment: environment)

    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    #expect(model.phase == .failed(.hostKeyMismatch(host: "10.1.0.9")))
    #expect(await model.trustedHostKey() == AppEnvironment.staleHostKey)

    await model.forgetHostKey()

    #expect(await store.trustedKey(for: workbox.hostname) == nil)
    // Leaving the mismatch on screen would read as the forget having done nothing.
    #expect(model.phase == .idle)
  }

  /// The deadline is the coordinator's; this is the user's.
  @Test("cancelling a connect in flight returns the model to idle")
  func cancelReturnsToIdle() async {
    var environment = self.environment()
    // Long enough that the cancel below is unambiguously mid-handshake.
    environment.makeTransport = { FakeSSHTransport(handshakeStall: .seconds(30)) }
    let model = ConnectionModel(host: workbox, environment: environment)

    let attempt = Task { await model.connect(password: "hunter2", persistence: .promptEveryTime) }
    while model.phase != .connecting, model.phase != .authenticating {
      await Task.yield()
    }
    await model.cancelConnect()
    await attempt.value

    #expect(model.phase == .idle, "a cancelled attempt must not report a failure")
    #expect(model.failure == nil)
  }
}

/// A transport that signals the coordinator's last step, taken after it has already
/// published `.connected`.
///
/// `ConnectionCoordinator.connect` sets `phase = .connected`, arms the loss signal, then ends
/// with `watchForClosure()`, which reads `disconnections`. That read is the latest moment a
/// test can observe from outside `DriverrSSH`, close enough to `ConnectionModel`'s phase read
/// to aim a cancel at. Everything else forwards to `FakeSSHTransport`, which previews, demo
/// mode and the UI suite share, so the hook stays here.
private actor CoordinatorStepTransport: SSHTransport {
  private let inner = FakeSSHTransport()
  private var whenWatchingForClosure: (@Sendable () -> Void)?

  func signalWhenWatchingForClosure(_ signal: @escaping @Sendable () -> Void) {
    whenWatchingForClosure = signal
  }

  func connect(to host: DriverrCore.Host, hostKeyValidator: any HostKeyValidator) async throws {
    try await inner.connect(to: host, hostKeyValidator: hostKeyValidator)
  }

  func authenticate(_ method: SSHAuthMethod) async throws {
    try await inner.authenticate(method)
  }

  func ptyChannel(size: TerminalSize) async throws -> any PTYChannel {
    try await inner.ptyChannel(size: size)
  }

  func execChannel(command: String) async throws -> CommandResult {
    try await inner.execChannel(command: command)
  }

  func execStream(command: String) async throws -> any ExecStream {
    try await inner.execStream(command: command)
  }

  func disconnect() async {
    await inner.disconnect()
  }

  var disconnections: AsyncStream<AppError> {
    get async {
      whenWatchingForClosure?()
      return await inner.disconnections
    }
  }
}

/// What the live attempt's control reports, and what a superseded one's would.
///
/// Two distinct versions, so every assertion reads a value rather than comparing two fakes of
/// one type. File scope, because the `@Sendable` `makeHerdrControl` closures read them and the
/// suite is `@MainActor`.
private let liveAttemptHerdr = HerdrAvailability.ready(
  version: "9.9.9",
  protocolVersion: HerdrProtocol.lastVerified
)
private let retiredAttemptHerdr = HerdrAvailability.ready(
  version: "1.1.1",
  protocolVersion: HerdrProtocol.lastVerified
)

/// Hands a prepared control to each connect attempt in turn.
///
/// `AppEnvironment.makeHerdrControl` is one closure serving every attempt, so telling the
/// superseded attempt's control apart from the live one's needs the factory to answer
/// differently the second time.
private actor ControlDispenser {
  private var remaining: [any HerdrControl]

  init(_ remaining: [any HerdrControl]) {
    self.remaining = remaining
  }

  func next() -> any HerdrControl {
    remaining.isEmpty ? FakeControl() : remaining.removeFirst()
  }
}

/// `true` to the first caller and `false` to every one after it.
private actor CallCounter {
  private var seen = 0

  func isFirst() -> Bool {
    seen += 1
    return seen == 1
  }
}

/// A `HerdrControl` that parks inside `availability()` until the test lets it go.
///
/// A wrapper rather than a gate in `FakeControl`, which previews, demo mode and the UI suite
/// share.
private struct GatedHerdrControl: HerdrControl {
  let inner: FakeControl
  /// Tells the test the attempt has reached the await it is being held at.
  let onPark: @Sendable () -> Void
  /// Ends the park on its first element. The test finishes the stream straight after.
  let release: AsyncStream<Void>
  /// Tells the test the released call has returned, for asserting that an abandoned hop
  /// published nothing after it landed.
  var onResume: @Sendable () -> Void = {}

  /// Distinct from `FakeControl`'s plain `herdr`, so an assertion can name which control a
  /// value came from.
  var binaryPath: String { "gated-herdr" }

  func availability() async -> HerdrAvailability {
    onPark()
    for await _ in release { break }
    let answer = await inner.availability()
    onResume()
    return answer
  }

  func snapshot() async throws -> SessionTree {
    try await inner.snapshot()
  }

  func attachCommand(for pane: Pane) -> String {
    inner.attachCommand(for: pane)
  }

  func sendText(paneID: String, text: String) async throws {
    try await inner.sendText(paneID: paneID, text: text)
  }

  func submitText(paneID: String, text: String) async throws {
    try await inner.submitText(paneID: paneID, text: text)
  }

  func sendKeys(paneID: String, keys: [PaneKey]) async throws {
    try await inner.sendKeys(paneID: paneID, keys: keys)
  }

  func readPanes(ids: [String], lines: Int) async throws -> [String: [String]] {
    try await inner.readPanes(ids: ids, lines: lines)
  }

  func readScreen(of pane: Pane, lines: Int) async throws -> PaneScreen {
    try await inner.readScreen(of: pane, lines: lines)
  }

  func perform(_ action: PaneAction, on paneID: String) async throws {
    try await inner.perform(action, on: paneID)
  }

  func rename(_ target: RenameTarget, to label: String) async throws {
    try await inner.rename(target, to: label)
  }
}
