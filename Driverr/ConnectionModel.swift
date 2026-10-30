import DriverrCore
import DriverrHerdr
import DriverrSSH
import DriverrTerm
import DriverrTranscript
import Foundation
import Observation

/// Drives one host's connection.
///
/// Sequencing and failure modes live in `DriverrSSH.ConnectionCoordinator`. This type
/// resolves the credential, mirrors the phase for SwiftUI, and owns what the connection
/// carries: the herdr session and the per-pane caches.
@MainActor
@Observable
final class ConnectionModel {
  /// `didSet` fires the Live Activity hook on every change of phase, so every assignment
  /// reaches the card.
  private(set) var phase: ConnectionPhase = .idle {
    didSet {
      guard oldValue != phase else { return }
      onLiveActivityInputChanged?()
    }
  }

  /// Told when anything the card is drawn from changed on this host.
  ///
  /// Set by `ConnectionRegistry`, which sees every host and builds the pass. A closure, like
  /// `onLoss`, because what follows is work, and an observed property is for a view to read.
  @ObservationIgnored var onLiveActivityInputChanged: (@MainActor () -> Void)?
  private(set) var output: String = ""
  /// The error behind a `.failed` phase, as something to show a person.
  var failure: AppError? {
    if case .failed(let error) = phase { return error }
    return nil
  }

  /// Why a connection that was up is not any more, shown under the pill: a network change
  /// and a host that stopped answering need different responses.
  var lossReason: String? {
    guard case .lost(let error) = phase else { return nil }
    return error.errorDescription
  }

  /// What went wrong with the last ad-hoc command, if anything.
  ///
  /// Kept apart from `phase`, so a bad command does not mark a healthy link as failed and
  /// take the session tree, Disconnect and the terminal down with it.
  private(set) var commandFailure: AppError?

  /// The host this connection is to, as the registry last had it. Readable so
  /// `ConnectionRegistry` can tell a model built for a stale host value.
  let host: DriverrCore.Host
  private let environment: AppEnvironment
  private var coordinator: ConnectionCoordinator?
  /// The host's herdr session, built once the connection is up. A disconnect takes it down.
  private(set) var session: SessionModel?
  /// Kept so a pane can be turned into the command that attaches it.
  private(set) var herdr: (any HerdrControl)?
  /// The panes' conversations, read from the agent's own session files.
  ///
  /// Owned by the connection because the commands run on this link. The pane screen and the
  /// host screen's Needs you row share it, so a pane is read once.
  private(set) var transcripts: PaneTranscriptCache?
  /// The panes' captured screens, read from herdr on demand.
  ///
  /// Here rather than in `PaneChatView`'s `@State`, which a switch to Terminal and back
  /// rebuilds, so the screen being read survives the switch.
  private(set) var paneScreens: PaneScreenCache?
  /// The panes' composers.
  ///
  /// The composer bar is rebuilt by a switch to Terminal and back, and a failed reply must
  /// still be there with its text. The bar's own `@State` would lose it.
  private(set) var composers: PaneComposerCache?
  /// Which surface each of this host's panes was last left on.
  ///
  /// Here because the connection outlives the terminal scene. Not optional and never cleared
  /// by a connect: losing the link is not the user changing their mind. On a reconnect only
  /// `transcripts` is rebuilt, because its reader is built from the transport.
  /// `paneScreens` and `composers` are kept. `disconnect()` clears all three.
  let surfaces = PaneSurfaceMemory()
  /// What herdr this host has, asked once on connecting. `nil` until then.
  private(set) var herdrAvailability: HerdrAvailability?

  /// Which herdr answered on this host, or `nil` if none did.
  ///
  /// So the host list need not learn `HerdrAvailability`'s cases. `.serverNotRunning` does
  /// not count, because there is no session, and neither does `.statusUnreadable`, because
  /// Driverr cannot tell whether it works with that version.
  var herdrVersion: String? { herdrAvailability?.readyVersion }

  /// This host's first-contact trust prompt, owned by the connection because it outlives
  /// the screen. A prompt rebuilt with a view would not be the one the suspended handshake
  /// is waiting on, and its continuation would never resume.
  let prompt: InteractiveHostKeyPrompt

  // MARK: - Driverr's agent hooks

  /// The integration this connection is offering to install, until the offer is answered
  /// or dismissed. The root presents it, like `prompt`, through
  /// `ConnectionRegistry.pendingHookOffer`.
  private(set) var pendingHookOffer: AgentIntegration?

  /// The runners the hook sheet sends its commands through, or `nil` with no link up.
  func hookRunners() -> HookInstallRunners? {
    guard phase == .connected, let coordinator else { return nil }
    return environment.makeHookRunners(coordinator)
  }

  /// The runner the key install sends its command through, or `nil` with no link up.
  func keyInstallRunner() -> CommandRunner? {
    guard phase == .connected, let coordinator else { return nil }
    return environment.makeKeyInstallRunner(coordinator)
  }

  /// Checks each integration on the host and offers the first one the policy says to.
  ///
  /// Only after a connect the user started, so `HostDetailView` calls this and `connect`
  /// does not. Background refresh, Continue in Background and reconnect backoff connect with
  /// nobody looking. A declined host is not read. The sheet records the answer, and
  /// `hookOfferDismissed` records a sheet that went away without one.
  func offerHooksIfNeeded() async {
    guard pendingHookOffer == nil else { return }
    for integration in AgentIntegration.catalog {
      let stored = await environment.hookOffers.state(forHost: host.id, agent: integration.agent)
      if stored == .declined { continue }
      guard let runners = hookRunners() else { return }
      let check = await HookInstaller.status(of: integration, run: runners.run)
      guard phase == .connected else { return }
      if HookOfferPolicy.shouldOffer(stored: stored, check: check, currentVersion: integration.version) {
        pendingHookOffer = integration
        return
      }
    }
  }

  /// The offer's sheet has gone, however it was answered.
  func clearHookOffer() {
    pendingHookOffer = nil
  }

  /// The offer's sheet has gone: records it as asked when nothing else was recorded.
  ///
  /// A swipe down counts as asked, not declined, so this version is not offered again on
  /// connect but a later version is. Not Now and Install have already recorded their answer.
  func hookOfferDismissed(_ integration: AgentIntegration) async {
    clearHookOffer()
    let store = environment.hookOffers
    switch await store.state(forHost: host.id, agent: integration.agent) {
    case .declined:
      return
    case .installed(let version) where version >= integration.version:
      return
    default:
      await store.setState(.offered(version: integration.version), forHost: host.id, agent: integration.agent)
    }
  }

  /// How long each hop of the connected set-up may go unanswered. See `bounded(_:)`.
  ///
  /// Both hops are herdr commands over an exec channel, the case `PaneComposerCopy.sendDeadline`
  /// was chosen for, so it uses the same twelve seconds. Injected for tests.
  @ObservationIgnored private let setUpDeadline: Duration
  /// The prompt has a default because the registry builds these. Tests and previews can
  /// pass one.
  init(
    host: DriverrCore.Host,
    environment: AppEnvironment,
    prompt: InteractiveHostKeyPrompt = InteractiveHostKeyPrompt(),
    setUpDeadline: Duration = PaneComposerCopy.sendDeadline
  ) {
    self.host = host
    self.environment = environment
    self.prompt = prompt
    self.setUpDeadline = setUpDeadline
    notifier = BlockedPaneNotifier(
      host: host,
      center: environment.notifications,
      // The same store a background refresh writes, so a foreground and a background poll
      // cannot both announce one pane.
      store: environment.announcedPanes
    )
  }

  // MARK: - Which pane this host was last open on

  /// Records where this host was left, as a `TerminalTarget`.
  ///
  /// `.shell` forgets the record: reopening a pane the user had left for the shell would put
  /// them somewhere they had already left.
  ///
  /// Two callers. `TerminalPresenter.present` records the request before any scene appears.
  /// `TerminalSceneModel.select` records changes inside a standing scene (pane sheet,
  /// shortcuts, closed-pane notice), which `present` never sees. Both use the write below.
  func noteLastPane(for target: TerminalTarget) {
    switch target {
    case .pane(let paneID): noteLastPane(paneID)
    case .shell: noteLastPane(nil)
    }
  }

  /// What a note about `paneID` does to the host's record.
  ///
  /// - `.remember` when the tree reports the pane with a witness. The witness is read at the
  ///   write, so a rebuilt session reporting something else for the same id is caught by the
  ///   resume.
  /// - `.forget` when a loaded tree does not report the pane, or reports neither a terminal id
  ///   nor a cwd. Nothing could verify such a record later.
  /// - `.leaveAlone` when there is no tree yet. A card tap can arrive before the first poll,
  ///   and `TerminalPresenter.present` notes the pane before that. Forgetting then would wipe
  ///   the record on every notification tap, and `TerminalSceneModel.select` would not rewrite
  ///   it for a target already current.
  ///
  /// `.leaveAlone` is safe because the resume checks the witness against the tree at tap
  /// time. A stale record costs at most one screen.
  private enum LastPaneNote {
    case remember(LastPaneRecord)
    case forget
    case leaveAlone
  }

  private func lastPaneNote(for paneID: String) -> LastPaneNote {
    guard let tree = session?.tree, !tree.isEmpty else { return .leaveAlone }
    guard let witness = tree.pane(id: paneID)?.sessionWitness else { return .forget }
    return .remember(LastPaneRecord(paneID: paneID, witness: witness))
  }

  /// Remembers `paneID` as where this host was left, or forgets the record for `nil`.
  ///
  /// See `lastPaneNote(for:)` for when a pane is remembered, forgotten or left alone. `nil`
  /// is the plain shell and always forgets.
  ///
  /// Here, not on `TerminalPresenter`, because this object has the host and the environment,
  /// and a presenter in a unit test is often unconfigured. Fire-and-forget: the presentation
  /// has already happened, and a failed write cannot change it.
  func noteLastPane(_ paneID: String?) {
    let store = environment.lastPanes
    let hostID = host.id
    let note: LastPaneNote = paneID.map { lastPaneNote(for: $0) } ?? .forget
    let write: LastPaneRecord?
    switch note {
    case .remember(let record): write = record
    case .forget: write = nil
    case .leaveAlone: return
    }
    Task { await store.setLastPane(write, forHost: hostID) }
  }

  /// Forgets the record if it names `paneID`, and leaves a newer one alone.
  ///
  /// Called when a pane is closed from the scene's actions. Closing `w1:p1` from a scene now
  /// on `w1:p2` must not drop the record for `w1:p2`. `BlockedPaneActivityRoute.resumed`
  /// already falls back to the tree for a closed pane, so this only keeps stale ids out of
  /// the defaults.
  func forgetLastPane(_ paneID: String) {
    let store = environment.lastPanes
    let hostID = host.id
    Task {
      guard await store.lastPane(forHost: hostID)?.paneID == paneID else { return }
      await store.setLastPane(nil, forHost: hostID)
    }
  }

  // MARK: - A pane that needs you while nobody is looking

  /// This host's blocked-pane notifications. Per host, and here because this object sees
  /// every poll's result through `onSessionChanged`.
  @ObservationIgnored private let notifier: BlockedPaneNotifier

  /// Whether the app is in front, asked when a poll lands.
  ///
  /// A closure set by `ConnectionRegistry`, so no connection holds a stale copy of the scene
  /// phase. Defaults to `true`, so a test or preview model announces nothing.
  @ObservationIgnored var isAppActive: @MainActor () -> Bool = { true }

  /// Puts the poll's tree through the notification rule.
  ///
  /// Separate from `apply(_:)`, which takes a diff. `BlockedPaneAlerts` needs the whole
  /// tree: a pane herdr stops reporting is not in `Changes.moved`, and its card must still be
  /// withdrawn.
  private func announceBlockedPanes() {
    guard let tree = session?.tree else { return }
    let isActive = isAppActive()
    Task { await notifier.sessionChanged(to: tree, isAppActive: isActive) }

    // The Live Activity is one card for the whole app, so the registry gathers every host
    // and builds the pass.
    onLiveActivityInputChanged?()
  }

  /// Told when this connection goes away, so the terminal scene for this host can release
  /// its dead sessions and start reconnecting.
  ///
  /// A callback, because what follows is work, and an observed property is for a view to
  /// read. Only `TerminalSceneModel` sets it, capturing itself weakly.
  @ObservationIgnored var onLoss: (@MainActor () -> Void)?

  /// The one task waiting on this connection's loss signal.
  @ObservationIgnored private var lossWatch: Task<Void, Never>?

  /// This host's herdr control, but only while the link is up.
  ///
  /// `herdr` itself is kept across a loss, because its last tree draws the pane switcher and
  /// titles, and emptying them would look like the panes had gone. Anything that runs a
  /// command must use this instead, or it keeps opening exec channels through the outage.
  /// `SessionModel.pausePolling()` fixes the same problem for the poll.
  var liveHerdr: (any HerdrControl)? {
    phase == .connected ? herdr : nil
  }

  /// Whether getting this connection back would have to ask somebody.
  ///
  /// A key or a saved password can be offered without asking, so that host reconnects by
  /// itself. A password that was never saved is not Driverr's to supply, so that host gets an
  /// inline prompt and nothing retries, because a retry without a credential can only fail.
  func needsPasswordToReconnect() async -> Bool {
    guard case .password = await currentAuthMethod() else { return false }
    return await savedPassword()?.isEmpty ?? true
  }

  /// One reconnect attempt, on the credential the host already has.
  ///
  /// The terminal scene owns the backoff and decides when. Call `needsPasswordToReconnect()`
  /// first.
  func reconnect() async {
    let saved = await savedPassword()
    await connect(
      password: saved,
      // `.promptEveryTime` deletes the stored password in `resolveCredential`, so a reconnect
      // with it would spend the credential and the next loss would have to ask.
      persistence: saved == nil ? .promptEveryTime : .remember
    )
  }

  /// Puts a poll's findings through the three per-pane caches.
  ///
  /// Runs from `SessionModel.refresh`, inside a task, not a view body. Each cache reacts
  /// differently:
  ///
  /// - The transcript is re-read, not dropped, unless the pane's `agent_session` changed. A
  ///   changed session is a different conversation and goes back to a spinner.
  /// - The screen is left alone. It is re-read on appearance and after a send.
  /// - The composer is told, because its `Sent` notice waits for herdr to report the pane
  ///   has moved.
  ///
  /// Internal so `ConnectionModelPaneMovedTests` can drive it with a scripted `Changes`, which
  /// is deterministic where a UI test depends on a race.
  func apply(_ changes: SessionModel.Changes) {
    // Panes that have left the session, first: a pane id herdr reuses after a close must
    // not be answered with the closed pane's conversation.
    transcripts?.forgetEverythingExcept(changes.liveIDs)
    paneScreens?.forgetEverythingExcept(changes.liveIDs)
    composers?.forgetEverythingExcept(changes.liveIDs)
    surfaces.forgetEverythingExcept(changes.liveIDs)

    // Every cached transcript model records the live pane, not only moved ones. A model made
    // from an older `Pane` is corrected here on the next poll, and its watcher then sees
    // `hasMovedOn` and re-resolves.
    for pane in changes.livePanes {
      transcripts?.existingModel(for: pane.id)?.update(to: pane)
    }

    for pane in changes.moved {
      if let transcript = transcripts?.existingModel(for: pane.id) {
        transcript.update(to: pane)
        if transcript.hasMovedOn {
          // `invalidate()` alone leaves the model `.idle`, and `PaneChatView`'s
          // `.task(id: model.pane.id)` does not re-run because the id did not change. Without
          // the load the spinner would be permanent, for example when a pane starts its first
          // conversation.
          transcript.invalidate()
          transcript.loadIfNeeded()
        } else {
          transcript.refresh()
        }
      }
      composers?.existingModel(for: pane.id)?.paneChanged(to: pane)
    }
  }

  /// Checks the connection is still there, and records the loss if it is not. The
  /// registry calls this on return to the foreground, because a link that died while
  /// suspended announces nothing.
  func probe() async {
    guard phase == .connected, let coordinator else { return }
    if case .lost(let error) = await coordinator.probe() { recordLoss(error) }
  }

  /// Waits for an attempt already running to settle, and returns at once when none is.
  ///
  /// `connect` refuses a second attempt and `willConnectWithoutAsking()` needs `.idle`, so a
  /// caller that only asks "will you connect?" gets `false` from a host already connecting.
  /// The resume hits this: the route selects the host, `HostDetailView` starts its own
  /// connect, and the resume finds the phase neither `.idle` nor `.connected`.
  ///
  /// Polled, because `withObservationTracking` fires once and would need re-arming per
  /// transition. The budget is a backstop that only has to outlast the 20 s handshake deadline
  /// plus two set-up hops of `setUpDeadline` (12 s each), 44 s in all. A caller that times out
  /// treats it as a connect that did not arrive.
  func settledPhase(within budget: Duration = .seconds(45)) async {
    guard phase == .connecting || phase == .authenticating else { return }
    let step = Duration.milliseconds(50)
    var waited = Duration.zero
    while phase == .connecting || phase == .authenticating, waited < budget {
      try? await Task.sleep(for: step)
      waited += step
    }
  }

  /// Connects without being asked when the host has a credential Driverr can offer: a key
  /// or a saved password. Does nothing for a host that would have to ask.
  func connectIfCredentialIsAvailable() async {
    guard await willConnectWithoutAsking() else { return }
    await reconnect()
  }

  /// Whether `connectIfCredentialIsAvailable()` would start an attempt right now.
  ///
  /// `HostDetailView` needs the answer before the attempt starts, to decide what to draw,
  /// and `connectIfCredentialIsAvailable` returns only after the connect. Both use this one
  /// predicate.
  func willConnectWithoutAsking() async -> Bool {
    guard phase == .idle else { return false }
    return await !needsPasswordToReconnect()
  }

  /// Ends a handshake still in flight, at the user's request. A spinner must always have a
  /// way out.
  func cancelConnect() async {
    guard phase == .connecting || phase == .authenticating else { return }
    // Retire the attempt's identity, not only its task. The cancelled attempt is suspended in
    // a handshake and will resume and run its own `catch`. See `currentAttempt`.
    currentAttempt += 1
    connectAttempt?.cancel()
    connectAttempt = nil
    // The transport may have opened a socket, and a cancelled task does not close it.
    await coordinator?.disconnect()
    coordinator = nil
    phase = .idle
  }

  /// The connect in flight, so `cancelConnect` has something to cancel.
  @ObservationIgnored private var connectAttempt: Task<Void, Never>?

  /// Which connect attempt owns the phase right now.
  ///
  /// A cancelled attempt outlives its cancellation. It resumes later and runs to its own end,
  /// by which time the user may have pressed Connect again. Without this check it would write
  /// `.idle` over the live attempt's `.connecting` and clear `connectAttempt`, taking Cancel
  /// away from the attempt in flight. Every write in `performConnect`, and the handle clear in
  /// `connect`, happens only while this still names the writing attempt.
  @ObservationIgnored private var currentAttempt = 0

  func connect(password: String?, persistence: PasswordPersistence) async {
    // Re-entrancy guard. The screen connects on appearance, so a Connect button from the
    // frame before can still be tapped, and a second attempt would leak the first socket.
    guard phase != .connecting, phase != .authenticating else { return }
    // Set before the credential's actor hop, so "Connecting…" shows on the tap's frame and
    // the button is gone before a second tap.
    phase = .connecting
    currentAttempt += 1
    let attempt = currentAttempt
    let task = Task {
      await performConnect(password: password, persistence: persistence, attempt: attempt)
    }
    connectAttempt = task
    await task.value
    // Only this attempt's handle. Clearing a newer one's would leave Cancel with nothing
    // behind it.
    if attempt == currentAttempt { connectAttempt = nil }
  }

  private func performConnect(
    password: String?,
    persistence: PasswordPersistence,
    attempt: Int
  ) async {
    // This attempt's own coordinator. A newer attempt may have replaced `self.coordinator` by
    // the time this one has to close its socket.
    var ownCoordinator: ConnectionCoordinator?
    do {
      let credential = try await resolveCredential(password: password, persistence: persistence)
      // Cancelled or superseded during the credential read. Nothing is built yet.
      guard attempt == currentAttempt else { return }
      // herdr rides the same connection: `CLIControl` runs commands on this transport's exec
      // channels.
      let transport = environment.makeTransport()
      let coordinator = ConnectionCoordinator(transport: transport)
      ownCoordinator = coordinator
      // Take down the link this one replaces. Read before the assignment, which drops the last
      // reference to it.
      retireReplacedLink(self.coordinator, replacedBy: coordinator)
      self.coordinator = coordinator

      let validator = TOFUHostKeyValidator(store: environment.knownHostsStore, prompt: prompt)
      try await coordinator.connect(to: host, validator: validator, credential: credential)
      // Cancel landed while the handshake finished: the link is up and unwanted, so it goes
      // down. A newer attempt is the same case, but the phase and coordinator now belong to
      // it and must be left alone.
      //
      // The `await` below is its own window: `cancelConnect` can land during it. So the answer
      // is read into a local and the identity checked again, or a retired attempt would build
      // the whole connected set-up under a screen already back at idle.
      let connectedPhase = await coordinator.phase
      guard attempt == currentAttempt else {
        await coordinator.disconnect()
        return
      }
      // `.connected` is published at the end of the set-up. The two hops below
      // (`command -v herdr` and `herdr --version`) each have their own `setUpDeadline`, and
      // `cancelConnect` only works while `.connecting` or `.authenticating`. Publishing first
      // would show Connected, with no Cancel, for up to two deadlines on a host that stopped
      // answering.
      //
      // Held at `.connecting` rather than a new phase, because to the user it is still
      // connecting, and the spinner, Cancel and host-row badge come for free. So the branch
      // is on the local `connectedPhase`, and `phase` is written in the publish block below.
      if connectedPhase == .connected {
        // Both awaits first, then one publish behind one check. The attempt can be retired
        // during either hop, by Disconnect or by a new Connect, and a retired attempt must not
        // write its control, caches, `SessionModel` or loss watcher over the live one's. The
        // identity is checked after each await, and the publish has no `await`. A failed guard
        // closes only this attempt's link, like the `catch` blocks. `HerdrControl` has nothing
        // to close of its own: a `CoreControl`'s stream is a channel on that link.
        //
        // Both hops are bounded, because nothing under `CLIControl` or the exec channel ever
        // gives up. A host that finishes the handshake and then stops answering would park
        // here forever, and the reconnect path and `TerminalSceneModel.settle()` would never
        // return. `withHandshakeDeadline` covers only the handshake.
        guard let made = await bounded({ await self.environment.makeHerdrControl(transport) })
        else {
          await giveUpOnSetUp(coordinator, attempt: attempt)
          return
        }
        // `HERDR_SOCKET_PATH` is set here, where both the transport and the `Host` are in hand,
        // instead of widening the factory's signature for every caller.
        let control = made.bound(toSocketPath: host.herdrSocketPath)
        guard attempt == currentAttempt else {
          await coordinator.disconnect()
          return
        }
        guard let availability = await bounded({ await control.availability() }) else {
          await giveUpOnSetUp(coordinator, attempt: attempt)
          return
        }
        guard attempt == currentAttempt else {
          await coordinator.disconnect()
          return
        }

        // The phase is part of the publish. Nothing from here to the end of the block suspends,
        // so no screen sees a half-built connection.
        phase = connectedPhase
        herdr = control
        // Rebuilt per connection, because the reader closes over this transport. The existing
        // models are carried across and re-read on the new link, because `PaneChatView` fetches
        // from `.task(id: model.pane.id)`, which does not re-run on a reconnect. See
        // `takeOver(from:)`.
        let carriedTranscripts = PaneTranscriptCache(
          reader: environment.makeTranscriptReader(transport),
          // A new turn is evidence for the composer's `Sent` notice. See
          // `PaneTranscriptModel.onAdvanced`.
          onAdvanced: { [weak self] paneID in
            self?.composers?.existingModel(for: paneID)?.transcriptAdvanced()
          }
        )
        carriedTranscripts.takeOver(from: transcripts)
        transcripts = carriedTranscripts
        // These two are kept if they exist. Neither closes over the transport: both resolve
        // their control through `liveHerdr` on every use, and `onSent` reads `transcripts` and
        // `paneScreens` from `self` when it fires. So they work on the new link, and keeping
        // them keeps a failed reply's text and the screen being read. Nothing would re-fetch
        // them, because their views start from `.task(id: model.pane.id)`.
        //
        // `disconnect()` sets all three to nil, so a fresh connect builds new ones. A loss
        // clears nothing, so the reconnect finds them here.
        if paneScreens == nil {
          // Through `liveHerdr`, so no read is attempted on a link that has gone.
          paneScreens = PaneScreenCache { [weak self] in self?.liveHerdr }
        }
        // The kept captures are as old as the outage, so each one on screen is re-read on the
        // new link underneath what is drawn. A no-op for a screen nobody opened.
        paneScreens?.rereadOnNewLink()
        if composers == nil {
          // Through `liveHerdr`, so a reply over a dead link fails with a Retry instead of going
          // nowhere.
          composers = PaneComposerCache(
            control: { [weak self] in self?.liveHerdr },
            // Resolved per upload, because the link can go while a photo is staged.
            makeUpload: { [weak self] bytes, fileName in
              self?.makeImageUpload(bytes: bytes, fileName: fileName)
            },
            // After a send, refresh the conversation and the screen. Wired here because this
            // object owns all three caches; a composer reaching for its siblings would need a
            // service locator. Reads `self` when it fires, so after a reconnect it finds the
            // new `transcripts`.
            onSent: { [weak self] paneID, attempt in
              guard let self else { return }
              // Only text is echoed. An Esc or a key press is not a turn, but both still
              // warrant a re-read.
              let typed: String? = if case .text(let text) = attempt { text } else { nil }
              transcripts?.existingModel(for: paneID)?.recordSend(typed)
              paneScreens?.existingModel(for: paneID)?.refresh()
            }
          )
        }
        herdrAvailability = availability
        // The new session takes over the old one's live-update holders. See
        // `SessionModel.handOverConsumers()`.
        let carried = session?.handOverConsumers() ?? 0
        let session = SessionModel(control: control)
        // The three-second poll drives conversation freshness, so there is no second poller. A
        // snapshot is a few KB; a first transcript page is up to 100 KB. See
        // `SessionModel.Changes`.
        session.onSessionChanged = { [weak self] changes in
          self?.apply(changes)
          // After `apply`, on the stored tree, because the notification rule needs the whole
          // tree.
          self?.announceBlockedPanes()
        }
        self.session = session
        for _ in 0..<carried { session.startLiveUpdates() }
        watchForLoss(coordinator)
      } else {
        // Not connected, so there is no set-up to hold the phase for.
        phase = connectedPhase
      }
    } catch let error as AppError {
      // A cancelled attempt reports no error: the user ended it. A superseded one reports
      // nothing either, but must close what it opened, because `cancelConnect` reaches only a
      // published coordinator.
      guard attempt == currentAttempt else {
        await ownCoordinator?.disconnect()
        return
      }
      clearFailedCoordinator(ownCoordinator)
      phase = Task.isCancelled ? .idle : .failed(error)
    } catch {
      guard attempt == currentAttempt else {
        await ownCoordinator?.disconnect()
        return
      }
      clearFailedCoordinator(ownCoordinator)
      phase =
        Task.isCancelled
        ? .idle
        : .failed(.connectionFailed(host: host.hostname, reason: "Something went wrong."))
    }
  }

  /// Takes down the link a new connection replaces.
  ///
  /// Nothing else would: `NIOSSHTransport` has no `deinit` teardown, because NIO traps on a
  /// promise freed unfulfilled. The socket, its channels and the `herdr` control processes
  /// would stay up on the host until sshd reaps them, about two hours by default. This
  /// matters when a slow probe reports a loss on a link that was still alive.
  ///
  /// Unawaited. Awaiting a NIO close after a teardown can suspend forever, and the link being
  /// retired is the one in doubt, so a new connection must not wait on it. Nothing here learns
  /// whether the close worked. Tests assert it through `FakeSSHTransport.disconnectCount`.
  ///
  /// Guarded on identity so it can never close the coordinator doing the replacing.
  private func retireReplacedLink(
    _ previous: ConnectionCoordinator?,
    replacedBy replacement: ConnectionCoordinator
  ) {
    guard let previous, previous !== replacement else { return }
    Task { await previous.disconnect() }
  }

  /// Unpublishes a failed attempt's coordinator, if it is still the current one.
  ///
  /// Otherwise `run`, `openPTY`, `makeImageUpload` and `bridgeClient` resolve against a dead
  /// link, and the next `retireReplacedLink` spends a teardown on it.
  ///
  /// Only the reference, not the socket: `ConnectionCoordinator.withHandshakeDeadline` already
  /// tears the transport down on any throw, and every `try` after the coordinator exists is
  /// inside it. A second `disconnect()` would double the teardown
  /// (`aFailedAttemptUnpublishesItsCoordinator`).
  ///
  /// Synchronous: the caller writes `phase` next, and an `await` between the identity guard
  /// and that write would reopen the race.
  private func clearFailedCoordinator(_ own: ConnectionCoordinator?) {
    guard let own, coordinator === own else { return }
    coordinator = nil
  }

  /// Ends an attempt whose connected set-up stopped answering.
  ///
  /// Retired like a superseded attempt: the abandoned hop may still return, and nothing it
  /// produces may be published. Everything before the `await` runs synchronously, so a new
  /// Connect cannot start in between and have its `.connecting` overwritten by `.failed`.
  ///
  /// The link goes down, because the handshake succeeded and a real socket exists. The
  /// coordinator is unpublished with it when it is still this attempt's.
  ///
  /// The failure is `herdrDidNotAnswer(host:)`, not `connectionFailed`: the host was reached,
  /// so the message must not send the reader to check the network.
  private func giveUpOnSetUp(_ coordinator: ConnectionCoordinator, attempt: Int) async {
    // A newer attempt already owns the phase; this one only owes its own link.
    guard attempt == currentAttempt else {
      await coordinator.disconnect()
      return
    }
    currentAttempt += 1
    clearFailedCoordinator(coordinator)
    phase = .failed(.herdrDidNotAnswer(host: host.hostname))
    await coordinator.disconnect()
  }

  /// Runs one hop of the connected set-up, and stops waiting after `setUpDeadline`. `nil`
  /// means abandoned, not failed.
  ///
  /// Abandoned rather than cancelled, as in `PaneComposerModel.bounded` and
  /// `TerminalSceneModel.bounded`: nothing under `CLIControl` or the exec channel checks
  /// cancellation. The hop finishes into a model that has retired it, and `currentAttempt`
  /// makes whatever it does land nowhere. Not a task group, because a group waits for every
  /// child, including the one that hung.
  private func bounded<Value: Sendable>(
    _ step: @escaping @MainActor () async -> Value
  ) async -> Value? {
    let running = Task { @MainActor in await step() }
    return await withCheckedContinuation { continuation in
      let race = SetUpRace<Value>(continuation)
      Task { @MainActor in
        race.settle(await running.value)
      }
      race.deadline = Task { @MainActor [setUpDeadline] in
        try? await Task.sleep(for: setUpDeadline)
        guard !Task.isCancelled else { return }
        race.settle(nil)
      }
    }
  }

  /// Runs one ad-hoc command. Never touches `phase`; see `commandFailure`.
  func run(_ command: String) async {
    guard let coordinator else {
      commandFailure = .notConnected(host: host.hostname)
      return
    }
    commandFailure = nil
    do {
      let result = try await coordinator.run(command)
      // Include stderr, or a command that wrote only there would look silent.
      output = result.standardOutput + result.standardError
    } catch let error as AppError {
      commandFailure = error
    } catch {
      commandFailure = .channelFailed(reason: "The command could not be run.")
    }
  }

  /// Opens an interactive shell and hands back a session ready to be rendered.
  ///
  /// Returns `nil` rather than throwing, because the failure is already in `phase`, and a
  /// screen reading both would tell two stories.
  func openTerminal(size: TerminalSize) async -> TerminalSession? {
    guard let coordinator else { return nil }
    do {
      let channel = try await coordinator.openPTY(size: size)
      return TerminalSession(feed: TerminalFeed(channel: channel))
    } catch let error as AppError {
      phase = .failed(error)
      return nil
    } catch {
      phase = .failed(.channelFailed(reason: "The terminal could not be opened."))
      return nil
    }
  }

  /// Opens a herdr pane through the control bridge, rather than a pty.
  ///
  /// A plain shell keeps the pty, which has real local scrollback. A pane has no local
  /// history, so it needs the bridge.
  ///
  /// Returns the bridge, not a `TerminalSession`, because the scene must see the first frame
  /// (to swap out a warm observer) and the `TerminalCloseReason` (another device has the pane,
  /// or the pane closed). Both are hidden once the stream is inside a session.
  ///
  /// - Parameter takeover: evicts whoever controls this pane. `false` except for the Take
  ///   over action a `.refused` open offers.
  /// - Parameter recordsFailure: whether a failure moves the connection into `.failed`.
  ///   `true` for an open the user asked for. `false` for the scene's own reattach, because
  ///   that failure is usually a link already dead with the loss still on its way, and
  ///   recording it would overwrite the loss so the reconnect never starts. `observePane`
  ///   declines for the same reason.
  func openPaneBridge(
    terminalID: String,
    size: TerminalSize,
    takeover: Bool = false,
    recordsFailure: Bool = true
  ) async -> (any PaneBridge)? {
    guard let client = bridgeClient() else { return nil }
    do {
      return try await client.open(terminalID: terminalID, size: size, takeover: takeover)
    } catch let error as AppError {
      if recordsFailure { phase = .failed(error) }
      return nil
    } catch {
      if recordsFailure { phase = .failed(.channelFailed(reason: "The pane could not be opened.")) }
      return nil
    }
  }

  /// Opens a read-only view of a pane, the warm half of the lifetime model.
  ///
  /// An observer never takes herdr's attach token or resizes the pane's PTY, so a scene can
  /// hold several without disturbing the user's desk. A failure is not recorded in `phase`:
  /// a pane nobody is looking at failing to warm up is not the user's concern.
  func observePane(terminalID: String, size: TerminalSize) async -> (any PaneObserver)? {
    guard let client = bridgeClient() else { return nil }
    return try? await client.observe(terminalID: terminalID, size: size)
  }

  /// One image upload on this connection's link, or `nil` with no link.
  ///
  /// The coordinator stays private, so a view or composer cannot hold it past the link's life.
  /// `AppEnvironment.makeImageUpload` chooses the uploader, so a UI run gets a paced fake.
  func makeImageUpload(bytes: Data, fileName: String) -> (any ImageUploading)? {
    guard let coordinator else { return nil }
    return environment.makeImageUpload(coordinator, bytes, fileName)
  }

  private func bridgeClient() -> TerminalBridgeClient? {
    guard let coordinator, let herdr else { return nil }
    return TerminalBridgeClient(
      binaryPath: herdr.binaryPath,
      socketPath: host.herdrSocketPath
    ) { command in
      ExecStreamBridge(stream: try await coordinator.openStream(command: command))
    }
  }

  func disconnect() async {
    // Retire the attempt's identity, as `cancelConnect` does. A set-up hop parked in `bounded`
    // can resume after this and pass its identity check, which was taken before the hop
    // started, then publish under a screen already at `.idle`. `performConnect` checks
    // `Task.isCancelled` only in its `catch` blocks.
    currentAttempt += 1
    connectAttempt?.cancel()
    connectAttempt = nil
    // Stop the watcher before the teardown, so the disconnect is not reported as a loss and
    // the scene does not start reconnecting.
    lossWatch?.cancel()
    lossWatch = nil
    await coordinator?.disconnect()
    coordinator = nil
    session = nil
    herdr = nil
    transcripts = nil
    paneScreens = nil
    composers = nil
    herdrAvailability = nil
    phase = .idle
    output = ""
  }

  /// Turns the coordinator's loss signal into a phase change and one callback.
  ///
  /// One event ends the watch: a connection is lost once, and the next connect watches its
  /// own signal.
  private func watchForLoss(_ coordinator: ConnectionCoordinator) {
    lossWatch?.cancel()
    lossWatch = Task { [weak self] in
      for await error in await coordinator.losses {
        self?.recordLoss(error)
        break
      }
    }
  }

  private func recordLoss(_ error: AppError) {
    // Otherwise this connection is already over, and a late signal must not overwrite the
    // newer state.
    guard phase == .connected else { return }
    // Keep the last tree on screen, so the panes do not look gone. Stop polling, because each
    // tick would open an exec channel on a dead link.
    session?.pausePolling()
    phase = .lost(error)
    onLoss?()
  }

  private func resolveCredential(
    password: String?,
    persistence: PasswordPersistence
  ) async throws -> SSHAuthMethod {
    switch await currentAuthMethod() {
    case .identity(let id):
      return .privateKey(try await environment.identityStore.privateKey(for: id))
    case .password:
      guard let password, !password.isEmpty else {
        // Not `authenticationFailed`: nothing was sent. The button is disabled for this case,
        // so this is the path a reconnect with nothing to offer takes.
        throw AppError.passwordRequired(host: host.hostname)
      }
      // Saved only if the user asked. `PasswordCredentials` owns that rule.
      try await environment.passwordCredentials.remember(
        password,
        for: host.id,
        persistence: persistence
      )
      return .password(password)
    }
  }

  /// How the host logs in, as the host store has it now.
  ///
  /// Not `host.authMethod`: Use This Key can switch a host to a key while this model is live,
  /// and a reconnect would otherwise ask for a password the host no longer uses. The address
  /// still comes from `host`; see `ConnectionRegistry.model(for:environment:)`.
  private func currentAuthMethod() async -> HostAuthMethod {
    let stored = (try? await environment.hostStore.hosts())?.first { $0.id == host.id }
    return stored?.authMethod ?? host.authMethod
  }

  /// A previously saved password, so the field can be pre-filled.
  func savedPassword() async -> String? {
    try? await environment.passwordCredentials.saved(for: host.id)
  }

  /// The key Driverr has trusted for this host, for the confirmation to show before it is
  /// forgotten. The old key, not the one just presented, so the user can check it against
  /// the rebuilt machine.
  func trustedHostKey() async -> SSHHostKey? {
    await environment.knownHostsStore.trustedKey(for: host.hostname)
  }

  /// Forgets this host's trusted key, so the next connect is first contact again.
  ///
  /// The only way past a mismatch. `TOFUHostKeyValidator` refuses a changed key with no
  /// override, because a user cannot tell interception from a rebuild in the moment. The
  /// phase returns to `.idle`, so the mismatch message does not stay under a Connect button.
  func forgetHostKey() async {
    await environment.knownHostsStore.forget(host.hostname)
    if case .failed(.hostKeyMismatch) = phase { phase = .idle }
  }
}

/// Whichever of one set-up hop and its deadline finishes first, resolved exactly once, with
/// the hop's value or `nil` if the deadline won.
///
/// Not shared with `PaneComposerModel.SendRace` and `TerminalSceneModel.StepRace`, because
/// each carries a different result, and this one carries a value. Resolving twice would
/// crash, so the guard is the point of the type.
@MainActor
private final class SetUpRace<Value: Sendable> {
  private var continuation: CheckedContinuation<Value?, Never>?
  var deadline: Task<Void, Never>?

  init(_ continuation: CheckedContinuation<Value?, Never>) {
    self.continuation = continuation
  }

  func settle(_ value: Value?) {
    guard let continuation else { return }
    self.continuation = nil
    deadline?.cancel()
    deadline = nil
    continuation.resume(returning: value)
  }
}
