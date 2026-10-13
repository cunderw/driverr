import DriverrCore
import DriverrHerdr
import DriverrSSH
import DriverrTranscript
import Foundation
import Observation
import Testing

@testable import Driverr

/// What a connection does when the link goes away.
///
/// The phase machine itself is `ConnectionLossTests` in `DriverrSSH`. This is the layer above:
/// the connection hears about a loss, knows whether getting back needs a person, and the
/// registry can ask a connection whether it is still there.
@MainActor
@Suite("Connection recovery", .timeLimit(.minutes(1)))
struct ConnectionRecoveryTests {
  private let workbox = DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson")
  private let edge = DriverrCore.Host(name: "edge-01", hostname: "10.1.0.99", username: "root")
  private var keyed: DriverrCore.Host {
    DriverrCore.Host(
      name: "keyed",
      hostname: "10.1.0.5",
      username: "carson",
      authMethod: .identity(UUID())
    )
  }

  /// `.ephemeral`, with both hosts' keys already trusted and one transport under the
  /// test's control.
  ///
  /// Seeded, or TOFU raises a prompt nobody answers and the connect hangs instead of failing.
  private func environment(
    transport: @escaping @Sendable () -> any SSHTransport = { FakeSSHTransport() }
  ) -> AppEnvironment {
    var environment = AppEnvironment.ephemeral
    environment.knownHostsStore = InMemoryKnownHostsStore(
      seeded: [
        workbox.hostname: FakeSSHTransport.defaultHostKey,
        edge.hostname: FakeSSHTransport.defaultHostKey,
        "10.1.0.5": FakeSSHTransport.defaultHostKey,
      ]
    )
    environment.makeTransport = transport
    environment.makeHerdrControl = { _ in FakeControl() }
    return environment
  }

  /// The shared `waitUntil` in `TestWaker.swift`, on a private waker. Keep the
  /// `Task.isCancelled` check; see `Waker`.
  private func waitUntil(
    _ condition: @MainActor () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    let waker = Waker()
    while true {
      let seen = waker.generation
      var satisfied = false
      withObservationTracking {
        satisfied = condition()
      } onChange: {
        waker.signalFromAnywhere()
      }
      if satisfied { return }
      await waker.next(after: seen)
      if Task.isCancelled {
        Issue.record(
          "waitUntil was cancelled before its condition ever held",
          sourceLocation: sourceLocation
        )
        return
      }
    }
  }

  /// `waitUntil` for a signal `onLoss` fires by hand. `onLoss` is `@ObservationIgnored`, so
  /// tracking cannot see it.
  private func waitForSignal(
    _ waker: Waker,
    until condition: @MainActor () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    while true {
      let seen = waker.generation
      if condition() { return }
      await waker.next(after: seen)
      if Task.isCancelled {
        Issue.record(
          "waitForSignal was cancelled before its condition ever held",
          sourceLocation: sourceLocation
        )
        return
      }
    }
  }

  // MARK: - Hearing about it

  @Test("a link that drops moves the connection to lost")
  func aDroppedLinkIsLost() async {
    let transport = FakeSSHTransport()
    let model = ConnectionModel(host: workbox, environment: environment { transport })
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    #expect(model.phase == .connected)

    await transport.drop()

    await waitUntil { model.phase != .connected }
    guard case .lost(let error) = model.phase else {
      Issue.record("expected .lost, got \(model.phase)")
      return
    }
    #expect(error.errorDescription?.contains("10.1.0.9") == true)
  }

  @Test("a lost connection is not a problem to correct")
  func lossIsNotAFailure() async {
    // The host screen's Problem section offers Retry for a connect attempt that went wrong.
    // A loss has nothing to correct.
    let transport = FakeSSHTransport()
    let model = ConnectionModel(host: workbox, environment: environment { transport })
    await model.connect(password: "hunter2", persistence: .promptEveryTime)

    await transport.drop()
    await waitUntil { model.phase != .connected }

    guard case .lost = model.phase else {
      Issue.record("expected .lost, got \(model.phase)")
      return
    }
    #expect(model.failure == nil)
  }

  @Test("a loss tells whoever is watching, once")
  func lossIsAnnouncedOnce() async {
    let transport = FakeSSHTransport()
    let model = ConnectionModel(host: workbox, environment: environment { transport })
    let waker = Waker()
    var announcements = 0
    model.onLoss = {
      announcements += 1
      waker.signalFromAnywhere()
    }
    await model.connect(password: "hunter2", persistence: .promptEveryTime)

    await transport.drop()
    await waitForSignal(waker) { announcements > 0 }

    #expect(announcements == 1, "the terminal scene would start two reconnects")
  }

  @Test("disconnecting on purpose is not announced as a loss")
  func disconnectIsNotALoss() async {
    let transport = FakeSSHTransport()
    let model = ConnectionModel(host: workbox, environment: environment { transport })
    var announcements = 0
    model.onLoss = { announcements += 1 }
    await model.connect(password: "hunter2", persistence: .promptEveryTime)

    await model.disconnect()
    // Nothing to wait for — the point is that nothing arrives.
    try? await Task.sleep(for: .milliseconds(50))

    #expect(model.phase == .idle)
    #expect(announcements == 0, "Disconnect would kick off a reconnect of what it just ended")
  }

  // MARK: - Whether getting back needs a person

  @Test("a host that keys in never needs asking")
  func keyedHostNeedsNoPrompt() async {
    let model = ConnectionModel(host: keyed, environment: environment())

    #expect(await model.needsPasswordToReconnect() == false)
  }

  @Test("a password host with nothing remembered has to ask")
  func passwordHostWithNothingRememberedAsks() async {
    let model = ConnectionModel(host: workbox, environment: environment())
    await model.connect(password: "hunter2", persistence: .promptEveryTime)

    #expect(await model.needsPasswordToReconnect() == true)
  }

  @Test("a password host that remembered its password does not have to ask")
  func passwordHostThatRememberedDoesNotAsk() async {
    let model = ConnectionModel(host: workbox, environment: environment())
    await model.connect(password: "hunter2", persistence: .remember)

    #expect(await model.needsPasswordToReconnect() == false)
  }

  // MARK: - Getting back

  // Every test below hands out a distinct transport per connection, as the app does. A
  // reconnect takes the link it replaces down (`ConnectionModel.retireReplacedLink`), and on a
  // shared instance that teardown would land on the new connection.

  @Test("reconnecting uses the credential the host already had")
  func reconnectUsesTheRememberedPassword() async {
    let supply = TransportSupply()
    let environment = environment { supply.make() }
    let model = ConnectionModel(host: workbox, environment: environment)
    await model.connect(password: "hunter2", persistence: .remember)
    await supply.latest?.drop()
    await waitUntil { model.phase != .connected }
    guard case .lost = model.phase else {
      Issue.record("expected .lost, got \(model.phase)")
      return
    }

    await model.reconnect()

    #expect(model.phase == .connected)
    #expect(
      await model.savedPassword() == "hunter2",
      "the reconnect wrote the password away as prompt-every-time and lost it"
    )
  }

  /// Waits for a transport to be told to go down, with a ceiling on the failure.
  ///
  /// The retirement is fire-and-forget (see `retireReplacedLink`), so the evidence is the
  /// transport's own state. A pass wakes on the `onActivity` signal `disconnect` sends. The
  /// ticker and the budget only bound a failure, so it is reported in this test's name rather
  /// than as the suite's `.timeLimit`.
  private func disconnectCount(
    of transport: FakeSSHTransport,
    within budget: Duration = .seconds(5)
  ) async -> Int {
    let ticker = Task { @MainActor in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(20))
        Waker.signalShared()
      }
    }
    defer { ticker.cancel() }
    let deadline = ContinuousClock.now + budget
    while true {
      let seen = Waker.shared.generation
      let count = await transport.disconnectCount
      if count > 0 { return count }
      if ContinuousClock.now >= deadline || Task.isCancelled { return count }
      await Waker.shared.next(after: seen)
    }
  }

  @Test("a reconnect takes the link it replaces down")
  func reconnectRetiresTheLinkItReplaces() async {
    // A probe that times out on a slow link reports a loss that never happened, and the
    // reconnect must not walk away from the live connection. `NIOSSHTransport` has no
    // `deinit` teardown, so the socket and its herdr processes would sit on the host for
    // about two hours.
    //
    // This reconnects without dropping anything, and asserts on the transports: an abandoned
    // connection is invisible from Driverr's own state.
    let supply = TransportSupply()
    let model = ConnectionModel(host: workbox, environment: environment { supply.make() })
    await model.connect(password: "hunter2", persistence: .remember)
    #expect(model.phase == .connected)

    await model.reconnect()

    #expect(model.phase == .connected, "the reconnect did not come back up")
    let handed = supply.handedOut
    #expect(handed.count == 2, "the reconnect did not ask for a second transport")
    guard handed.count == 2 else { return }

    #expect(
      await disconnectCount(of: handed[0]) == 1,
      "the link the reconnect replaced was left up on the host"
    )
    #expect(
      await handed[1].disconnectCount == 0,
      "the retirement landed on the connection that replaced it"
    )
  }

  @Test("a connect that fails does not leave its half-open link as the current one")
  func aFailedAttemptUnpublishesItsCoordinator() async {
    // A handshake that threw must not leave its coordinator assigned, or `run`, `openPTY`,
    // `makeImageUpload` and `bridgeClient` resolve against a link that is not there.
    //
    // The first count is not evidence of that: `ConnectionCoordinator.withHandshakeDeadline`
    // already tears the transport down on a throw. The count after the next connect is. If the
    // dead coordinator were still assigned, the swap would retire it again and the count would
    // reach two.
    let supply = TransportSupply()
    supply.isAccepting = false
    let model = ConnectionModel(host: workbox, environment: environment { supply.make() })
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    guard case .failed = model.phase else {
      Issue.record("expected .failed, got \(model.phase)")
      return
    }
    let refused = supply.handedOut
    #expect(refused.count == 1)
    guard let refused = refused.first else { return }
    // Awaited inside `performConnect`, so this needs no wait of any kind.
    #expect(
      await refused.disconnectCount == 1,
      "the attempt that failed left its own link up"
    )

    supply.isAccepting = true
    await model.connect(password: "hunter2", persistence: .promptEveryTime)

    #expect(model.phase == .connected)
    #expect(supply.handedOut.count == 2, "the second attempt did not ask for a transport")
    // Something that must not happen. Safe without a wait: the retirement is enqueued at the
    // swap, and a whole connect has run since.
    #expect(
      await refused.disconnectCount == 1,
      "the failed attempt's coordinator was still the current one when the next connect swapped"
    )
  }

  @Test("a reconnect keeps the herdr session polling for whoever was holding it")
  func reconnectCarriesLiveUpdates() async {
    // The terminal scene's `.task` starts live updates once. A reconnect builds a new
    // `SessionModel`, so without a hand-over the hold stays on the old one, which goes on
    // polling a dead link.
    let supply = TransportSupply()
    let model = ConnectionModel(host: workbox, environment: environment { supply.make() })
    await model.connect(password: "hunter2", persistence: .remember)
    let firstSession = model.session
    firstSession?.startLiveUpdates()
    #expect(firstSession?.isLive == true)

    await supply.latest?.drop()
    await waitUntil { model.phase != .connected }
    await model.reconnect()

    #expect(model.session !== firstSession, "a reconnect has to build a session on the new link")
    #expect(model.session?.isLive == true, "the scene's live updates were left behind")
    #expect(firstSession?.isLive == false, "the old session is still polling a dead link")
  }

  @Test("a lost connection stops handing out a herdr control, and hands one out again after")
  func lossWithholdsTheControl() async {
    // The tree stays, for the strip and titles, but anything that runs a command asks for
    // `liveHerdr`, or it spends the outage opening exec channels on a dead link. The pane
    // sheet's thumbnails poll on every tick.
    let supply = TransportSupply()
    let model = ConnectionModel(host: workbox, environment: environment { supply.make() })
    await model.connect(password: "hunter2", persistence: .remember)
    #expect(model.liveHerdr != nil)

    await supply.latest?.drop()
    await waitUntil { model.phase != .connected }

    #expect(model.liveHerdr == nil, "a poll would run herdr commands over a dead link")
    #expect(model.herdr != nil, "the tree the strip is drawn from went with the link")

    await model.reconnect()

    #expect(model.phase == .connected)
    #expect(model.liveHerdr != nil, "the thumbnails would stay blank after a reconnect")
  }

  // MARK: - Asking, on the way back to the foreground

  @Test("probing finds a link that went away without saying so")
  func probeFindsASilentDeath() async {
    // Torn down with nothing on the closure signal, as a link killed while the phone was
    // suspended looks on the way back.
    let transport = FakeSSHTransport()
    let registry = ConnectionRegistry()
    let environment = environment { transport }
    let model = registry.model(for: workbox, environment: environment)
    await model.connect(password: "hunter2", persistence: .remember)
    await transport.disconnect()
    #expect(model.phase == .connected, "the connection knew already, so the probe proves nothing")

    await registry.probeConnections()

    guard case .lost = model.phase else {
      Issue.record("expected .lost, got \(model.phase)")
      return
    }
  }

  @Test("probing a live connection leaves it alone")
  func probeLeavesALiveConnectionAlone() async {
    let registry = ConnectionRegistry()
    let environment = environment()
    let model = registry.model(for: workbox, environment: environment)
    await model.connect(password: "hunter2", persistence: .remember)

    await registry.probeConnections()

    #expect(model.phase == .connected)
  }

  @Test("probing tells whoever is watching, so a scene can start getting back")
  func probeAnnouncesTheLoss() async {
    let transport = FakeSSHTransport()
    let registry = ConnectionRegistry()
    let environment = environment { transport }
    let model = registry.model(for: workbox, environment: environment)
    var announcements = 0
    model.onLoss = { announcements += 1 }
    await model.connect(password: "hunter2", persistence: .remember)
    await transport.disconnect()

    await registry.probeConnections()

    #expect(announcements == 1)
  }

  @Test("probing a host that was never connected does nothing to it")
  func probeIgnoresAnIdleHost() async {
    let registry = ConnectionRegistry()
    let environment = environment()
    let model = registry.model(for: edge, environment: environment)

    await registry.probeConnections()

    #expect(model.phase == .idle)
  }

  // MARK: - The conversation, across a reconnect

  /// herdr's own id for the pane's Claude session, which is also the fixture's file name.
  private static let sessionID = "3f8c1d20-0000-4000-8000-000000000002"

  /// A blocked Claude pane whose session herdr has reported, so the resolver does not need the
  /// directory heuristic.
  private var claudePane: Pane {
    Pane(
      id: "w1:p2",
      tabID: "w1:t1",
      workspaceID: "w1",
      title: "needs a decision",
      agent: Agent(
        name: "Claude",
        kind: "claude",
        status: .blocked,
        session: AgentSession(agent: "claude", kind: "id", value: Self.sessionID)
      ),
      terminalID: "term_w1p2",
      directory: "/home/carson/dev/driverr"
    )
  }

  private var transcriptHost: FakeTranscriptHost {
    FakeTranscriptHost(
      sessionID: Self.sessionID,
      turns: [
        .init(speaker: .human, text: "make the connection pool async", secondsAgo: 900),
        .init(speaker: .assistant, text: "The pool is async now.", secondsAgo: 60),
      ]
    )
  }

  /// The test environment with a readable conversation behind it.
  ///
  /// `control` is for the assertions that count what herdr was asked for across a
  /// reconnect: the default builds a fresh `FakeControl` per connect, so its tally starts
  /// again on the new link and cannot answer "was the carried capture re-read?".
  private func readingEnvironment(
    transport: @escaping @Sendable () -> any SSHTransport,
    control: FakeControl? = nil
  ) -> AppEnvironment {
    var environment = environment(transport: transport)
    let fixture = transcriptHost
    environment.makeTranscriptReader = { _ in TranscriptReader(run: fixture.run) }
    if let control { environment.makeHerdrControl = { _ in control } }
    return environment
  }

  @Test("a reconnect keeps the conversation the chat was reading")
  func reconnectKeepsTheConversation() async {
    // A reconnect must carry the `PaneTranscriptCache`. `PaneChatView` fetches from
    // `.task(id: model.pane.id)`, and the pane id does not change, so a fresh `.idle` model
    // would be a spinner nothing re-asks.
    let supply = TransportSupply()
    let model = ConnectionModel(host: workbox, environment: readingEnvironment { supply.make() })
    await model.connect(password: "hunter2", persistence: .remember)

    let chat = model.transcripts?.model(for: claudePane)
    chat?.loadIfNeeded()
    await chat?.currentLoad?.value
    #expect(chat?.transcript?.turns.isEmpty == false, "the fixture never reached the model")

    await supply.latest?.drop()
    await waitUntil { model.phase != .connected }
    await model.reconnect()
    #expect(model.phase == .connected)

    let after = model.transcripts?.model(for: claudePane)
    #expect(after === chat, "the reconnect handed the chat a model nobody had asked to load")
    #expect(
      after?.transcript?.turns.isEmpty == false,
      "the reconnect emptied the conversation the reader was looking at"
    )
    #expect(after?.isLoading == false, "the carried page went back to a spinner")
    await after?.currentLoad?.value
    #expect(after?.transcript?.turns.isEmpty == false)
  }

  @Test("a reconnect re-reads the page it carried, on the link that came back")
  func reconnectReReadsTheConversation() async {
    // The carried page is as old as the outage, so it is re-read quietly on the new link.
    let supply = TransportSupply()
    let model = ConnectionModel(host: workbox, environment: readingEnvironment { supply.make() })
    await model.connect(password: "hunter2", persistence: .remember)

    let chat = model.transcripts?.model(for: claudePane)
    chat?.loadIfNeeded()
    await chat?.currentLoad?.value
    let before = chat?.lastFetchedAt

    await supply.latest?.drop()
    await waitUntil { model.phase != .connected }
    await model.reconnect()
    await chat?.currentLoad?.value

    #expect(chat?.lastFetchedAt != before, "the carried page was never re-read on the new link")
    #expect(chat?.isRefreshing == false)
    #expect(chat?.transcript?.turns.isEmpty == false)
  }

  @Test("a reconnect does not fetch a conversation nobody has opened yet")
  func reconnectLeavesAnUnopenedConversationIdle() async {
    // The Needs you row makes a model for a blocked pane without anybody opening the chat.
    // Re-reading it would cost a round trip per blocked pane on every reconnect.
    let supply = TransportSupply()
    let model = ConnectionModel(host: workbox, environment: readingEnvironment { supply.make() })
    await model.connect(password: "hunter2", persistence: .remember)

    let neverOpened = model.transcripts?.model(for: claudePane)
    #expect(neverOpened?.state == .idle, "nothing had asked this model to load yet")

    await supply.latest?.drop()
    await waitUntil { model.phase != .connected }
    await model.reconnect()
    #expect(model.phase == .connected)

    let after = model.transcripts?.model(for: claudePane)
    #expect(after === neverOpened, "the reconnect replaced the model instead of carrying it")
    #expect(after?.state == .idle, "relink fetched a conversation nobody had asked to see")
    #expect(after?.currentLoad == nil, "relink started a fetch for an idle model")
  }

  // MARK: - The reply and the screen, across a reconnect

  @Test("a reconnect keeps the text of a reply that failed during the outage")
  func reconnectKeepsAFailedReply() async {
    // The outage is the likeliest moment for a send to fail, so the reconnect must carry the
    // `PaneComposerCache` and the staged reply with its Retry.
    let supply = TransportSupply()
    let model = ConnectionModel(host: workbox, environment: readingEnvironment { supply.make() })
    await model.connect(password: "hunter2", persistence: .remember)

    let composer = model.composers?.model(for: claudePane)
    composer?.text = "yes, go ahead"

    // `liveHerdr` is nil while `.lost`, so `perform` records `.notConnected` and leaves the
    // text staged.
    await supply.latest?.drop()
    await waitUntil { model.phase != .connected }
    await composer?.send()
    #expect(composer?.failure != nil, "the send over a dead link was supposed to fail")
    #expect(composer?.text == "yes, go ahead", "the failure cleared the field before the reconnect")

    await model.reconnect()
    #expect(model.phase == .connected)

    let after = model.composers?.model(for: claudePane)
    #expect(after === composer, "the reconnect rebuilt the cache and handed back a fresh composer")
    #expect(after?.text == "yes, go ahead", "the reply somebody typed went with the old cache")
    #expect(after?.failure != nil, "the Retry behind the failed reply went with it")
  }

  @Test("a reconnect keeps the captured screen the reader was looking at")
  func reconnectKeepsTheCapturedScreen() async {
    // The same for the screen cache: `PaneScreenView` reads from `.task(id: model.pane.id)`.
    let supply = TransportSupply()
    let model = ConnectionModel(host: workbox, environment: readingEnvironment { supply.make() })
    await model.connect(password: "hunter2", persistence: .remember)

    let screen = model.paneScreens?.model(for: claudePane)
    screen?.loadIfNeeded()
    await screen?.currentLoad?.value
    #expect(screen?.screen != nil, "the fake never answered the first read")

    await supply.latest?.drop()
    await waitUntil { model.phase != .connected }
    await model.reconnect()
    #expect(model.phase == .connected)

    let after = model.paneScreens?.model(for: claudePane)
    #expect(after === screen, "the reconnect handed the reader a fresh model in .idle")
    #expect(after?.state != .idle, "the capture on screen went back to a spinner")
    #expect(after?.screen != nil, "the capture the reader was reading was thrown away")
    await after?.currentLoad?.value
  }

  @Test("a reconnect re-reads the screen it carried, on the link that came back")
  func reconnectRereadsTheCapturedScreen() async {
    // The carried capture is re-read quietly on the new link. One `FakeControl` across both
    // connects, so its tally covers the whole session.
    let supply = TransportSupply()
    let control = FakeControl()
    let model = ConnectionModel(
      host: workbox,
      environment: readingEnvironment(transport: { supply.make() }, control: control)
    )
    await model.connect(password: "hunter2", persistence: .remember)

    let screen = model.paneScreens?.model(for: claudePane)
    screen?.loadIfNeeded()
    await screen?.currentLoad?.value
    let readsBefore = await control.screenReads.count
    #expect(readsBefore == 1, "the first read never reached the fake")

    await supply.latest?.drop()
    await waitUntil { model.phase != .connected }
    await model.reconnect()
    #expect(model.phase == .connected)
    await screen?.currentLoad?.value

    let readsAfter = await control.screenReads.count
    #expect(readsAfter == readsBefore + 1, "the carried capture was never re-read on the new link")
    #expect(screen?.isRereading == false, "the re-read never settled")
    #expect(screen?.screen != nil)
  }

  @Test("a reconnect does not read a screen nobody has opened yet")
  func reconnectLeavesAnUnopenedScreenIdle() async {
    // See `reconnectLeavesAnUnopenedConversationIdle`.
    let supply = TransportSupply()
    let control = FakeControl()
    let model = ConnectionModel(
      host: workbox,
      environment: readingEnvironment(transport: { supply.make() }, control: control)
    )
    await model.connect(password: "hunter2", persistence: .remember)

    let neverOpened = model.paneScreens?.model(for: claudePane)
    #expect(neverOpened?.state == .idle, "nothing had asked this model to read yet")

    await supply.latest?.drop()
    await waitUntil { model.phase != .connected }
    await model.reconnect()
    #expect(model.phase == .connected)

    let after = model.paneScreens?.model(for: claudePane)
    #expect(after === neverOpened, "the reconnect replaced the model instead of carrying it")
    #expect(after?.state == .idle, "the re-read asked for a screen nobody had opened")
    #expect(await control.screenReads.isEmpty, "a round trip was spent on an unopened capture")
  }
}
