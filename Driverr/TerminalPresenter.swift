import DriverrCore
import Observation
import SwiftUI

/// Where the app asks for a terminal, so the terminal is presented from the root rather
/// than from the screen that asked.
///
/// The scene is pushed on the phone's stack and drawn in the detail column on iPad, and
/// its lifetime must not depend on the requester.
///
/// **One scene per host, not per pane.** `present` reuses the standing scene for a
/// same-host pick, so a pane switch never tears down SwiftTerm, releases the controller or
/// reopens a channel. A pane is a value inside the scene; see `TerminalSceneModel`.
@MainActor
@Observable
final class TerminalPresenter {
  struct Request: Identifiable {
    /// The scene on screen, made once per host so the warm set survives every switch inside
    /// it.
    let scene: TerminalSceneModel

    var host: DriverrCore.Host { scene.host }

    /// Keyed by host alone; see the type's note. Only tests read it.
    var id: String { scene.host.id.uuidString }
  }

  /// The scene being shown, if there is one.
  ///
  /// `private(set)`, so callers go through the methods that do the scene's open and close
  /// bookkeeping.
  private(set) var request: Request?

  /// The one presenter for the app's lifetime.
  ///
  /// A caller outside the view tree, such as a notification tap or a Siri intent, has no
  /// environment to read, so it needs an object it can name. The environment key returns
  /// this same object, so a pending request cannot land on a presenter nobody drains.
  @MainActor static let shared = TerminalPresenter()

  // MARK: - Opening a host by id

  /// What `open(hostID:paneID:)` needs, handed over once by `ContentView`. Held, because
  /// a notification tap or intent arrives with only ids. `@ObservationIgnored`: nothing
  /// draws them.
  @ObservationIgnored private var hostStore: (any HostStore)?
  @ObservationIgnored private var connections: ConnectionRegistry?
  @ObservationIgnored private var environment: AppEnvironment?
  /// Sets which host's screen sits under the pane scene. A closure, because the selection
  /// belongs to `ContentView`, and a copy here would be a second source of truth.
  @ObservationIgnored private var select: (@MainActor (DriverrCore.Host.ID) -> Void)?

  /// Hands `open` the stores it resolves a host id against. Idempotent. Call it from a
  /// `.task`, not a `body`, because it writes state.
  func configure(
    hostStore: any HostStore,
    connections: ConnectionRegistry,
    environment: AppEnvironment,
    select: @escaping @MainActor (DriverrCore.Host.ID) -> Void
  ) {
    self.hostStore = hostStore
    self.connections = connections
    self.environment = environment
    self.select = select
  }

  /// Opens a host by id, and a pane on it by id. A `nil` pane means the plain shell. See
  /// `open(hostID:intent:)`.
  func open(hostID: DriverrCore.Host.ID, paneID: String? = nil) async {
    await open(hostID: hostID, intent: paneID.map(PendingOpen.Intent.pane) ?? .shell)
  }

  /// The single entry point for notification taps, intents, Live Activity links and the
  /// host list's blocked badge.
  ///
  /// - Before `configure`, the request is held for `drainPendingOpen`.
  /// - An unknown host id is a no-op. A notification can outlive its host, and there is
  ///   no screen the user asked for to show a message on.
  /// - `.pane` and `.shell` select the host before connecting, so the tap visibly does
  ///   something during the handshake. A host that must ask for a password, or a connect
  ///   that fails, leaves the reader on the host screen with no pane scene. Otherwise the
  ///   target is presented.
  /// - `.host` dismisses, selects, and presents nothing, because a "3 panes need you"
  ///   card is answered by the host's tree. Then `resumeRememberedPane` may push the last
  ///   pane on top.
  ///
  /// For `.host`: dismiss before select, or a frame draws the old host's pane over the new
  /// host's screen (`PhoneStackPath` keeps `.pane` while a request stands). The dismissal
  /// ignores the host id, as in `sidebarDidSelect`. It never reaches `present`, so the Live
  /// Activity is not de-escalated, which is right because the panes are still unread.
  func open(hostID: DriverrCore.Host.ID, intent: PendingOpen.Intent) async {
    guard let hostStore, let connections, let environment else {
      pendingOpen = PendingOpen(hostID: hostID, intent: intent)
      return
    }
    guard let hosts = try? await hostStore.hosts(),
      let host = hosts.first(where: { $0.id == hostID })
    else { return }

    let target: TerminalTarget
    switch intent {
    case .host:
      // The host's screen goes up first, with nothing awaited before it. Resolving the
      // remembered pane first would leave the reader on the host list, with no Connecting
      // pill and no Cancel, for the whole handshake.
      dismiss()
      select?(host.id)
      await resumeRememberedPane(
        host: host, connections: connections, environment: environment)
      return
    case .pane(let paneID): target = .pane(id: paneID)
    case .shell: target = .shell
    }

    select?(host.id)

    let model = connections.model(for: host, environment: environment)
    if await model.willConnectWithoutAsking() {
      await model.connectIfCredentialIsAvailable()
    }
    // **Wait for the phase to settle.** `HostDetailView`'s own appearance connect may
    // already be running, so the phase is `.connecting` and `willConnectWithoutAsking()`
    // is `false`. Without the wait, the pane the tap named would be dropped silently.
    await model.settledPhase()
    guard model.phase == .connected else { return }

    present(host: host, model: model, target: target)
  }

  /// Pushes the pane this host was last open on, over the host screen already up.
  ///
  /// Every early return leaves the reader on the host's tree, which is already on screen,
  /// so none reports anything. `BlockedPaneActivityRoute.resumed` owns the rule, tested in
  /// `swift test`. This supplies the remembered pane and the host's current panes.
  ///
  /// It connects, because a cold-launch tap has no session tree to resume from. It uses the
  /// same predicate as `HostDetailView`, so a host that must ask still asks. `settledPhase`
  /// covers `HostDetailView`'s own connect already running, for the reason in `open`.
  ///
  /// The session is refreshed only when its tree is empty, so a warm resume costs no round
  /// trip.
  private func resumeRememberedPane(
    host: DriverrCore.Host, connections: ConnectionRegistry, environment: AppEnvironment
  ) async {
    guard let lastPane = await environment.lastPanes.lastPane(forHost: host.id) else {
      return
    }
    let model = connections.model(for: host, environment: environment)
    if await model.willConnectWithoutAsking() {
      await model.connectIfCredentialIsAvailable()
    }
    await model.settledPhase()
    guard model.phase == .connected, let session = model.session else { return }
    if session.tree.isEmpty { await session.refresh() }
    // Pane id to witness, not a set of ids. herdr reuses pane ids, so an id alone cannot
    // tell the reader's pane from a rebuilt session's stand-in. A pane with no witness is
    // left out, because nothing can confirm it.
    let panesOnHost = Dictionary(
      session.tree.allPanes.compactMap { pane in pane.sessionWitness.map { (pane.id, $0) } },
      uniquingKeysWith: { first, _ in first })
    guard
      case .pane(_, let paneID) = BlockedPaneActivityRoute.resumed(
        .host(hostID: host.id), lastPane: lastPane, panesOnHost: panesOnHost)
    else { return }
    // **Re-checked after the awaits.** A newer request can arrive during the handshake, and
    // the last one asked for must win.
    guard selectedMatches(host.id) else { return }
    present(host: host, model: model, target: .pane(id: paneID))
  }

  /// Whether the host this resume was about is still the one the app is showing.
  ///
  /// The presenter cannot read the selection back, since `ContentView` owns it. A scene on
  /// another host proves a newer request won. No scene is the ordinary case, because this
  /// route dismissed first.
  private func selectedMatches(_ hostID: DriverrCore.Host.ID) -> Bool {
    guard let request else { return true }
    return request.host.id == hostID
  }

  // MARK: - A request that arrives before configure

  /// What was asked for before there was anything to resolve it against.
  struct PendingOpen: Equatable {
    let hostID: DriverrCore.Host.ID
    let intent: Intent

    /// What a request asks to be shown once its host resolves. `.host` is an intent, not a
    /// second pending slot, so the last-request-wins rule covers it.
    enum Intent: Equatable, Sendable {
      case pane(String)
      case shell
      case host
    }

    init(hostID: DriverrCore.Host.ID, intent: Intent) {
      self.hostID = hostID
      self.intent = intent
    }

    /// A pane id, or `nil` for the plain shell.
    init(hostID: DriverrCore.Host.ID, paneID: String?) {
      self.init(hostID: hostID, intent: paneID.map(Intent.pane) ?? .shell)
    }
  }

  /// The one request waiting for `configure`, if there is one.
  ///
  /// One slot, and the last request wins: each asks for the one screen now, so a queue has
  /// nothing to deliver. Observed, so `ContentView` drains a request that arrives while the
  /// app is running.
  private(set) var pendingOpen: PendingOpen?

  /// Asks for a host and pane to be opened, from anywhere, at any time.
  ///
  /// Synchronous, because a notification delegate must return promptly and cannot await a
  /// handshake. `drainPendingOpen` does the work.
  func requestOpen(hostID: DriverrCore.Host.ID, paneID: String? = nil) {
    pendingOpen = PendingOpen(hostID: hostID, paneID: paneID)
  }

  /// The same, with an intent, for `ActivityURLRouter`. Synchronous for the same reason.
  func requestOpen(hostID: DriverrCore.Host.ID, intent: PendingOpen.Intent) {
    pendingOpen = PendingOpen(hostID: hostID, intent: intent)
  }

  /// Honours a request made before `configure` ran, and does nothing otherwise.
  ///
  /// **Clear the slot before the await.** `ContentView` drains from its launch `.task` and
  /// from an `onChange`, so a second drain can arrive during the first one's handshake. With
  /// no suspension between the guard and the clear, the second drain finds the slot empty.
  /// `thePendingRequestIsDrainedOnce` checks the result, not this ordering.
  ///
  /// `hostStore` stands for all of `configure`'s values, which are written together. Do not
  /// widen the guard: returning early after clearing drops the request, and before clearing
  /// leaves the observed slot full, so `onChange` drains for ever.
  func drainPendingOpen() async {
    guard hostStore != nil, let pending = pendingOpen else { return }
    pendingOpen = nil
    await open(hostID: pending.hostID, intent: pending.intent)
  }

  /// The plain shell on a host.
  func present(host: DriverrCore.Host, model: ConnectionModel) {
    present(host: host, model: model, target: .shell)
  }

  /// A herdr pane.
  func present(host: DriverrCore.Host, model: ConnectionModel, pane: Pane) {
    present(host: host, model: model, target: .pane(id: pane.id))
  }

  /// The pane switcher's cross-host pick, on a host that already has a connection.
  ///
  /// It resolves the model from the registry, because `CrossHostPanes.Section` carries only
  /// ids. That keeps this path testable in `DriverrTests`.
  ///
  /// **`existingModel`, never `model(for:environment:)`.** Only connected hosts are offered,
  /// so a miss means the link dropped after the sheet was drawn, and the answer is to do
  /// nothing rather than open an empty terminal and start a handshake.
  func present(hostID: DriverrCore.Host.ID, paneID: String) {
    guard let connections, let model = connections.existingModel(for: hostID) else { return }
    // The sidebar follows the scene, or on iPad the list and the detail column name
    // different hosts. After the guard, so a no-op pick does not move the highlight.
    select?(hostID)
    present(host: model.host, model: model, target: .pane(id: paneID))
  }

  /// Shows `target` on `host`, presenting a scene if this host has none. An already
  /// presented host switches its scene instead, which keeps warm emulators alive.
  func present(host: DriverrCore.Host, model: ConnectionModel, target: TerminalTarget) {
    withdrawNotification(host: host, target: target)
    noteBlockedPaneWasOpened(host: host, target: target)
    model.noteLastPane(for: target)
    if let request, request.host.id == host.id {
      request.scene.select(target)
      return
    }
    // Another host is another presentation. The standing one ends here, not in the view
    // being replaced; see `beginPresentation`.
    endPresentation()
    let scene = TerminalSceneModel(host: host, model: model, initialTarget: target)
    request = Request(scene: scene)
    beginPresentation(scene)
  }

  /// Withdraws the blocked-pane notification for a pane that is now on screen. In
  /// `present(host:model:target:)` because every open goes through it.
  ///
  /// `environment` is `nil` in a unit test that never configured the presenter. `.shell`
  /// names no pane, so it has no notification.
  private func withdrawNotification(host: DriverrCore.Host, target: TerminalTarget) {
    guard let environment, case .pane(let paneID) = target else { return }
    let id = BlockedPaneAlerts.notificationID(hostID: host.id, paneID: paneID)
    Task { await environment.notifications.withdraw(ids: [id]) }
  }

  /// Takes the Live Activity's escalation off a pane that is now on screen, for
  /// `withdrawNotification`'s reason.
  ///
  /// It de-escalates rather than ending, because the card stays up for the connected
  /// session. The opened pane leaves the count, and other blocked panes keep it escalated.
  /// `BlockedPaneActivityPlan.reconcile` owns the rule.
  private func noteBlockedPaneWasOpened(host: DriverrCore.Host, target: TerminalTarget) {
    guard let environment, case .pane(let paneID) = target else { return }
    let driver = environment.blockedPaneActivities
    Task { await driver.notePaneWasOpened(hostID: host.id, paneID: paneID) }
  }

  /// Reply: the pane on its chat side, with the composer asking for the keyboard, so the
  /// reply sits under the conversation it answers.
  ///
  /// **No terminal is attached.** The chat side takes a read-only observer, not herdr's
  /// exclusive attach token, so answering does not lock the pane on the user's desk.
  func reply(host: DriverrCore.Host, model: ConnectionModel, pane: Pane) {
    present(host: host, model: model, pane: pane)
    request?.scene.focusComposer()
  }

  func dismiss() {
    endPresentation()
    request = nil
  }

  /// The sidebar chose a host while a pane owned the detail column. On regular width the
  /// list and the scene are both visible, so the tap must leave the scene.
  ///
  /// **The host id is not consulted.** A sidebar row means "show me this host", which is
  /// its screen even when its pane is up. The parameter states that rule in the signature
  /// for a test to assert.
  ///
  /// Only the user's choice reaches this. `ContentView` calls it from the selection
  /// binding's setter, which SwiftUI calls for a row tap and never for a programmatic
  /// write, so `select?(…)` here cannot dismiss the scene it just presented.
  func sidebarDidSelect(hostID: DriverrCore.Host.ID?) {
    guard request != nil else { return }
    dismiss()
  }

  // MARK: - The presentation's lifetime

  /// What opening a scene holds, taken when the presentation starts, not when a view
  /// appears.
  ///
  /// **Do not move this back to `TerminalScreen`'s `onAppear`/`onDisappear`.** A size-class
  /// flip (Split View, Slide Over, a Pro Max turned landscape) destroys one route's view and
  /// builds the other's, and `onDisappear` would close a scene still on screen. Both halves
  /// of each retain/release pair live here, or the counts leak on every flip.
  ///
  /// `connections` is `nil` in a unit test that never configured the presenter.
  private func beginPresentation(_ scene: TerminalSceneModel) {
    connections?.sceneOpened(for: scene.host.id)
    // The scene is a second consumer of the session's live updates, so the switcher and
    // pane titles stay current whether or not the host screen still holds its own.
    scene.model.session?.startLiveUpdates()
  }

  /// Ends the standing presentation, if there is one.
  ///
  /// `scene.close()` returns the controller and observers and ends the shell. Otherwise a
  /// channel stays open in the background with nothing on screen to close it, and a held
  /// controller locks the pane on the user's desk.
  private func endPresentation() {
    guard let scene = request?.scene else { return }
    connections?.sceneClosed(for: scene.host.id)
    scene.model.session?.stopLiveUpdates()
    scene.close()
  }
}

private struct TerminalPresenterKey: EnvironmentKey {
  /// The same object `ContentView` holds; see `TerminalPresenter.shared`.
  @MainActor static let liveValue = TerminalPresenter.shared
  nonisolated static var defaultValue: TerminalPresenter {
    MainActor.assumeIsolated { liveValue }
  }
}

extension EnvironmentValues {
  var terminalPresenter: TerminalPresenter {
    get { self[TerminalPresenterKey.self] }
    set { self[TerminalPresenterKey.self] = newValue }
  }
}
