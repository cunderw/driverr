import DriverrCore
import DriverrSSH
import Observation
import SwiftUI
import UIKit

/// Every host Driverr has connected to this launch, and the connection it made.
///
/// The connection lives here, not in view state, so `HostDetailView`'s `.id(host.id)` can
/// give each host its own view identity without dropping the connection on every switch.
///
/// There is no idle timeout. A connection lives until Disconnect or a memory warning, which
/// drops only hosts with no terminal scene on screen. Backgrounding disconnects nothing: a
/// short suspension often leaves the link alive, and a dead one is found on the way back by
/// `probeConnections()`.
@MainActor
@Observable
final class ConnectionRegistry {
  /// One model per host id, made on first ask and kept for the life of the process.
  ///
  /// Not replaced after a disconnect, or a screen holding the old model would drive an orphan
  /// while the next screen got a different one. `forget` removes a deleted host.
  private var models: [DriverrCore.Host.ID: ConnectionModel] = [:]

  /// How many terminal scenes are on screen, per host.
  ///
  /// Counted, not a flag: switching panes builds the new scene before the old one's
  /// `onDisappear` runs. A flag cleared by the old scene would report no terminal on screen,
  /// and a memory warning would then disconnect the host being typed into.
  private var scenes: [DriverrCore.Host.ID: Int] = [:]

  /// The memory-warning observer, removed when this registry goes.
  ///
  /// `nonisolated(unsafe)` because `deinit` is not main-actor isolated and the token is not
  /// `Sendable`. It is written once in `init` and read once in `deinit`. A block observer,
  /// not an `AsyncSequence`, so observation starts inside `init` and a warning right after
  /// launch is not missed.
  @ObservationIgnored private nonisolated(unsafe) var memoryWarnings: (any NSObjectProtocol)?

  /// Kept so `deinit` unregisters from the same centre. A `Sendable` `let`, so the
  /// nonisolated `deinit` can read it.
  @ObservationIgnored private let notifications: NotificationCenter

  /// - Parameter notifications: `.default` in the app. Injectable so a test can post a
  ///   memory warning without every other registry in the process reacting. A warning is
  ///   app-wide, so concurrent tests would otherwise evict each other's state.
  init(notifications: NotificationCenter = .default) {
    self.notifications = notifications
    memoryWarnings = notifications.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      Task { @MainActor in await self?.disconnectHostsWithoutAScene() }
    }
  }

  deinit {
    if let memoryWarnings { notifications.removeObserver(memoryWarnings) }
  }

  /// This host's connection, made now if it is the first ask.
  ///
  /// The environment is passed per call because the registry is built as `ContentView`'s
  /// `@State`, before `\.appEnvironment` can be read.
  ///
  /// Call from a `.task`, never from a `body`: this mutates observed state.
  ///
  /// An edited host gets a new model, because the model captures the `Host` it was built
  /// with and would keep connecting to the old address. It is replaced only while settled
  /// (idle, failed or lost). A connecting or connected model owns a live session, so an edit
  /// to a connected host takes effect after the next disconnect.
  func model(for host: DriverrCore.Host, environment: AppEnvironment) -> ConnectionModel {
    if let existing = models[host.id] {
      guard existing.host != host, Self.isSettled(existing.phase) else { return existing }
    }
    let model = ConnectionModel(host: host, environment: environment)
    // One answer for every host. See `isAppActive`.
    model.isAppActive = { [weak self] in self?.isAppActive ?? true }
    // One card covers every host, so any change on this host triggers a pass over all of them.
    model.onLiveActivityInputChanged = { [weak self] in self?.pushLiveActivityObservations() }
    models[host.id] = model
    pushLiveActivityObservations()
    return model
  }

  // MARK: - The Live Activity's input

  /// Where an authoritative pass goes, set by `ContentView`'s root.
  ///
  /// A closure, for the same reason `model(for:environment:)` takes the environment per call.
  /// The second argument is `isAppActive`, passed so the far end need not hold the registry.
  @ObservationIgnored var onLiveActivityInputChanged:
    (@MainActor ([HostActivityObservation], Bool) -> Void)?

  /// Every host this registry holds a model for, as the card's input.
  ///
  /// Starts no reads: the trees come from the host list's existing polling. Uses `host.name`,
  /// not `displayName`, so the card names every host one way.
  func liveActivityObservations(now: Date = .now) -> [HostActivityObservation] {
    models.values.map { model in
      let tree = model.session?.tree ?? .empty
      return HostActivityObservation(
        hostID: model.host.id,
        hostName: model.host.name,
        isConnected: model.phase == .connected,
        blockedPanes: tree.blockedPanes,
        counts: tree.agentStatusCounts,
        observedAt: now
      )
    }
  }

  /// One authoritative pass, now.
  ///
  /// The request is also gated on the app being in front. A reconnect backoff can reach
  /// `.connected` with the app away, where `Activity.request` is refused. The next
  /// foreground pass requests instead.
  func pushLiveActivityObservations() {
    onLiveActivityInputChanged?(liveActivityObservations(), isAppActive)
  }

  /// Whether the app is in front, as `ContentView`'s `scenePhase` last reported it.
  ///
  /// Kept here because the polling models have no window to ask. `@ObservationIgnored`
  /// because nothing draws it, and observing it would redraw every row on every app switch.
  /// Starts `true`, because `scenePhase` reports only transitions, and a run that never
  /// leaves the foreground never sets it.
  @ObservationIgnored var isAppActive = true

  /// Whether this connection is holding nothing that replacing it would strand.
  private static func isSettled(_ phase: ConnectionPhase) -> Bool {
    switch phase {
    case .idle, .failed, .lost: true
    case .connecting, .authenticating, .connected: false
    }
  }

  /// This host's connection if it already has one. Never creates one.
  ///
  /// The host list asks about every saved host on every redraw. Creating a model on each ask
  /// would fill the registry with connections nobody opened, kept until `forget`.
  func existingModel(for hostID: DriverrCore.Host.ID) -> ConnectionModel? {
    models[hostID]
  }

  /// Every host this registry holds a model for, as the pane switcher's input.
  ///
  /// Starts no reads: the trees come from the host list's existing polling. Unfiltered and
  /// unsorted, because `DriverrCore.CrossHostPanes` decides which hosts to offer and in what
  /// order, where `swift test` covers it.
  func paneSwitcherHosts() -> [PaneSwitcherHost] {
    models.values.map { model in
      PaneSwitcherHost(
        id: model.host.id,
        name: model.host.displayName,
        isConnected: model.phase == .connected,
        tree: model.session?.tree ?? .empty
      )
    }
  }

  /// What the host list can say about this host without opening it.
  ///
  /// The facts are gathered here. Every word made from them is in `DriverrCore.HostStatus`.
  ///
  /// `.lost` keeps a dropped link from reading like a host never reached, on the screen the
  /// user is on when it happens. Automatic reconnect runs only while a terminal is open.
  ///
  /// The full counts are passed, not only the blocked one, so the badge and any calm summary
  /// derive from one value and cannot disagree.
  func status(for host: DriverrCore.Host) -> HostStatus {
    guard let model = models[host.id] else { return HostStatus(hostname: host.hostname) }
    let connection: HostConnectionState =
      switch model.phase {
      case .connected: .connected
      case .lost: .lost
      case .idle, .connecting, .authenticating, .failed: .idle
      }
    return HostStatus(
      hostname: host.hostname,
      connection: connection,
      herdrVersion: model.herdrVersion,
      // As of the last poll. See `ContentView.SessionPollHold`.
      agentStatusCounts: model.session?.tree.agentStatusCounts ?? AgentStatusCounts()
    )
  }

  /// A host-key question that is waiting on the user, and the connection that asked it.
  ///
  /// The request carries what the sheet shows. The model is what the answer must reach,
  /// because the suspended handshake belongs to that connection's `prompt`. `id` is the
  /// request's, so a second question from the same host is a new sheet.
  struct PendingHostKeyPrompt: Identifiable {
    let model: ConnectionModel
    let request: InteractiveHostKeyPrompt.Request
    var id: InteractiveHostKeyPrompt.Request.ID { request.id }
  }

  /// The one connection waiting on a trust decision, if any is.
  ///
  /// Here because the prompt is presented at the root, which has the registry and no host.
  /// See CLAUDE.md, "Never present from inside a presentation".
  ///
  /// Sorted by host id because `models` is a dictionary. Two hosts can wait at once, and
  /// unstable order could swap the fingerprint under the reader on an unrelated redraw.
  /// The second question shows once the first is answered.
  func pendingHostKeyPrompt() -> PendingHostKeyPrompt? {
    for id in models.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
      guard let model = models[id], let request = model.prompt.pending else { continue }
      return PendingHostKeyPrompt(model: model, request: request)
    }
    return nil
  }

  /// A hook install offer waiting to be shown, and the connection that made it.
  struct PendingHookOffer: Identifiable {
    let model: ConnectionModel
    let integration: AgentIntegration
    var id: String { "\(model.host.id.uuidString).\(integration.agent)" }
  }

  /// The one offer to show now, if any, sorted like `pendingHostKeyPrompt()`.
  ///
  /// `nil` while anything else is up at the root, because a presentation is never raised
  /// from inside another. The root reports its own through `isRootPresenting`. The offer
  /// waits on its model until the other presentation is gone.
  func pendingHookOffer(isRootPresenting: Bool) -> PendingHookOffer? {
    guard !isRootPresenting, pendingHostKeyPrompt() == nil else { return nil }
    for id in models.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
      guard let model = models[id], let integration = model.pendingHookOffer else { continue }
      return PendingHookOffer(model: model, integration: integration)
    }
    return nil
  }

  /// The list's footer, over the hosts the list is actually showing.
  func summary(of hosts: [DriverrCore.Host]) -> HostListSummary {
    HostListSummary(statuses: hosts.map { status(for: $0) })
  }

  /// A terminal scene for this host is on screen.
  func sceneOpened(for hostID: DriverrCore.Host.ID) {
    scenes[hostID, default: 0] += 1
  }

  /// One of this host's terminal scenes has gone.
  func sceneClosed(for hostID: DriverrCore.Host.ID) {
    guard let count = scenes[hostID], count > 1 else {
      scenes[hostID] = nil
      return
    }
    scenes[hostID] = count - 1
  }

  /// Asks every warm connection whether it is still there, on return to the foreground.
  ///
  /// A link that died while suspended announces nothing. A host found dead here becomes
  /// `.lost`. Whether that starts a reconnect is the terminal scene's decision.
  ///
  /// In series: a probe on a dead connection fails at once, and each host's `.lost` reaches
  /// the screen as soon as it is asked.
  func probeConnections() async {
    for model in models.values {
      await model.probe()
    }
  }

  /// Drops the host's connection and its model, for a deleted host.
  ///
  /// Its row is gone, so nothing could disconnect it later. The model goes too, so a host
  /// added again under the same id cannot resume the old connection.
  func forget(_ hostID: DriverrCore.Host.ID) async {
    scenes[hostID] = nil
    guard let model = models.removeValue(forKey: hostID) else {
      pushLiveActivityObservations()
      return
    }
    await model.disconnect()
    pushLiveActivityObservations()
  }

  /// The response to a memory warning: keep hosts with a terminal on screen, drop the rest.
  func disconnectHostsWithoutAScene() async {
    for (id, model) in models where scenes[id, default: 0] == 0 {
      await model.disconnect()
    }
  }
}

/// The registry, for whoever needs a host's connection.
///
/// Injected on `ContentView`'s root chain, like `\.terminalPresenter`; pushed screens and the
/// detail column inherit it. A sheet does not, so the pane scene's sheets get the registry as
/// an argument (`TerminalSceneSheets`). See CLAUDE.md, "Two environment rules". A view that
/// resolved the default would hold its scene open on a registry nobody else sees.
private struct ConnectionRegistryKey: EnvironmentKey {
  @MainActor static let liveValue = ConnectionRegistry()
  nonisolated static var defaultValue: ConnectionRegistry {
    MainActor.assumeIsolated { liveValue }
  }
}

extension EnvironmentValues {
  var connectionRegistry: ConnectionRegistry {
    get { self[ConnectionRegistryKey.self] }
    set { self[ConnectionRegistryKey.self] = newValue }
  }
}
