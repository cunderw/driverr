import DriverrCore
import DriverrTerm
import PhotosUI
import SwiftUI
import UIKit

/// The composer's way into Photos, attached at `ContentView`'s root.
///
/// Not in `PaneComposerBar`: `PhotosPicker` presents, and on iPad the bar is inside the split
/// view's detail column, where nothing may present. The bar sets a flag on the scene, and
/// this presents.
///
/// A `ViewModifier` because the same modifiers inline made `ContentView.body` too slow to
/// type-check. It reads no `@Environment` of its own; the presenter is passed in. See
/// CLAUDE.md, "Two environment rules".
private struct ComposerPhotosPicker: ViewModifier {
  let presenter: TerminalPresenter
  @Binding var item: PhotosPickerItem?

  func body(content: Content) -> some View {
    content
      .photosPicker(
        isPresented: Binding(
          get: { presenter.request?.scene.isShowingPhotoPicker ?? false },
          set: { isShowing in
            guard !isShowing else { return }
            presenter.request?.scene.hidePhotoPicker()
          }
        ),
        selection: $item,
        matching: .images
      )
      // Cleared before the load. Otherwise picking the same asset again is not a change and
      // the picker does nothing.
      .onChange(of: item) { _, picked in
        guard let picked, let scene = presenter.request?.scene else { return }
        item = nil
        Task {
          guard let data = try? await picked.loadTransferable(type: Data.self) else { return }
          scene.attachPickedImage(data)
        }
      }
  }
}

/// Which host the form is for. `host == nil` is a new one. A type rather than an optional
/// `Host`, because "adding" and "not showing the form" are different states.
private struct HostFormRequest: Identifiable {
  let host: DriverrCore.Host?
  var id: String { host?.id.uuidString ?? "new" }
}

/// Which host the hook install sheet is for, and how it was opened.
private struct HookSheetRequest: Identifiable {
  let hostID: DriverrCore.Host.ID
  let hostName: String
  let integration: AgentIntegration
  let source: HookInstallSource
  var id: String { "\(hostID.uuidString).\(integration.agent)" }
}

/// Which host the key install sheet is for.
private struct KeySheetRequest: Identifiable {
  let host: DriverrCore.Host
  var id: DriverrCore.Host.ID { host.id }
}

/// The host list, and the way into everything else.
struct ContentView: View {
  @Environment(\.appEnvironment) private var environment
  @Environment(\.scenePhase) private var scenePhase
  /// Read here only to tell the Live Activity driver whether it may draw at all. See
  /// `BlockedPaneActivityDriving.preferencesChanged`.
  @Environment(\.settingsModel) private var settingsModel
  /// The per-host half of that answer. Pushed down with the global switch as one value,
  /// because the reconciler needs both.
  @Environment(\.liveActivityPreferences) private var liveActivityPreferences
  /// The window's horizontal size class, which decides where a pane scene is drawn. Read at
  /// the split view's root, because its columns get their own traits. See
  /// `TerminalSceneRoute`.
  @Environment(\.horizontalSizeClass) private var sizeClass

  @State private var model: HostListModel?
  @State private var isShowingKeys = false
  /// The host form, when it is up, and which host it is for.
  ///
  /// `.sheet(item:)`, not `.sheet(isPresented:)` beside a separate value: with `isPresented`
  /// the content can read the value before the button has written it, and Edit opened a
  /// blank Add Host form (`testEditFromTheHostScreenOpensTheForm`).
  @State private var hostForm: HostFormRequest?
  /// The app's one presenter. A notification tap calls `TerminalPresenter.shared` from outside
  /// the view tree, so it has to be this object for the request to be drained here.
  @State private var terminalPresenter = TerminalPresenter.shared
  /// Every host's connection, for the life of the process. See `ConnectionRegistry`.
  @State private var connections = ConnectionRegistry()
  @State private var isShowingSettings = false
  /// The host a delete gesture has asked about, not yet confirmed. At the root, because the
  /// confirmation is presented here and must outlive the row it removes.
  @State private var hostPendingDeletion: DriverrCore.Host?
  /// The hook install sheet opened from a menu. The connect-time offer is read from the
  /// registry instead, like the trust prompt.
  @State private var hookSheet: HookSheetRequest?
  /// The key install sheet, opened from the host screen.
  @State private var keySheet: KeySheetRequest?
  /// The hook sheet on screen now, however it was opened. The dismiss setter reads it,
  /// because a waiting trust prompt makes `pendingHookOffer` return `nil`.
  @State private var shownHookSheet: HookSheetRequest?
  /// Which host the detail column shows, and the sidebar's own selection.
  ///
  /// A value, not a `NavigationLink` destination, so the chosen host survives the list
  /// rebuilding under it while the tree polls.
  ///
  /// Persisted across launches in `UserDefaults`, not `@SceneStorage`: iOS discards scene
  /// state on a force-quit, which is when a restored selection matters. Multi-window is off,
  /// so per-scene storage buys nothing.
  @State private var selectedHostID: DriverrCore.Host.ID?
  /// Whether `selectedHostID` came from the user's own row tap. Only then may the host
  /// screen's connect offer the hooks. Written by the two tap setters, cleared by `.onChange`.
  @State private var hostPick = HostPick()
  /// Whether this launch has already applied its starting selection. `.task` runs once per
  /// appearance, and a second restore would override the user's later choice.
  @State private var didApplyLaunchSelection = false
  /// Keeps the app running for a moment after it leaves the screen.
  @State private var backgroundAssertion = BackgroundAssertion()

  /// What the Photos picker last handed back. Cleared as soon as the change handler has it,
  /// so picking the same photo twice is still a change.
  @State private var pickedImageItem: PhotosPickerItem?

  /// The sidebar's width, scaled by the reader's text size.
  ///
  /// `@ScaledMetric` scales `SidebarColumnWidth.base` like body text.
  /// `SidebarColumnWidth.ideal(scaledBase:)` then clamps it, in `DriverrCore`, where it is
  /// tested. Unclamped, 320 pt reaches about 900 at the largest size.
  @ScaledMetric(relativeTo: .body) private var scaledSidebarBase = SidebarColumnWidth.base

  var body: some View {
    // The phone authors its own `NavigationStack` and the iPad keeps the split view (CLAUDE.md).
    // The root changes type across the size-class boundary, so a rotation rebuilds both
    // containers. `ContentView`'s `@State` survives, and so does the scene, which
    // `TerminalPresenter.beginPresentation` owns. The list's scroll offset does not.
    Group {
      if sizeClass == .regular {
        splitView
      } else {
        phoneStack
      }
    }
    // Settings and Keys are presented from the root, not the sidebar. On iPad the sidebar can
    // be a popover, and a sheet presented from inside it never appears.
    .sheet(isPresented: $isShowingSettings) {
      SettingsView()
    }
    .sheet(isPresented: $isShowingKeys) {
      KeyManagementView()
    }
    // The host form, for all five things that open it: the toolbar's plus, the empty state,
    // the row's swipe and context-menu Edit, and `HostDetailView.onEdit`. At the root for the
    // reason Settings is.
    //
    // `isRegularWidth` is resolved here from the window, because an iPad form sheet reports
    // compact from inside itself.
    .sheet(item: $hostForm) { request in
      AddHostView(existing: request.host, isRegularWidth: sizeClass == .regular) { host in
        Task { await model?.save(host) }
      }
    }
    // The first-contact trust prompt, for whichever connection is waiting. The question
    // belongs to the connection (`ConnectionModel.prompt`), which outlives any screen, so the
    // root asks the registry and answers on that model. It can appear over any screen,
    // because nothing else can resume the suspended handshake.
    //
    // The binding is read-only: `answer(_:)` clears `pending`, which is the only thing that
    // may take this sheet down.
    .sheet(
      item: Binding(get: { connections.pendingHostKeyPrompt() }, set: { _ in })
    ) { pending in
      HostKeyPromptView(
        hostname: pending.request.hostname,
        key: pending.request.key,
        isRegularWidth: sizeClass == .regular
      ) { trusted in
        pending.model.prompt.answer(trusted)
      }
    }
    // Driverr's hooks, offered on connect or requested from a menu. At the root for the trust
    // prompt's reason. A menu request wins over an offer, and the offer waits while anything
    // else is up. A swipe down records it as asked, not declined (`hookOfferDismissed`).
    .sheet(
      item: Binding(
        get: { hookSheet ?? pendingHookOffer },
        set: { request in
          guard request == nil else { return }
          let shown = shownHookSheet
          shownHookSheet = nil
          if hookSheet != nil {
            hookSheet = nil
          } else if let shown, shown.source == .offer,
            let model = connections.existingModel(for: shown.hostID)
          {
            model.clearHookOffer()
            Task { await model.hookOfferDismissed(shown.integration) }
          }
        }
      )
    ) { request in
      HookInstallSheet(
        model: HookInstallModel(
          hostID: request.hostID,
          hostName: request.hostName,
          integration: request.integration,
          store: environment.hookOffers,
          runners: { [connections] in connections.existingModel(for: request.hostID)?.hookRunners() }
        ),
        source: request.source,
        isRegularWidth: sizeClass == .regular
      )
      .onAppear { shownHookSheet = request }
    }
    // Install a Key, at the root because its entry is in the iPad's detail column. It counts
    // in `hasRootPresentation` and holds back the hook offer.
    .sheet(item: $keySheet) { request in
      if let model {
        KeyInstallSheet(
          model: KeyInstallModel(
            hostID: request.host.id,
            hostName: request.host.displayName,
            identityStore: environment.identityStore,
            hosts: model,
            credentials: environment.passwordCredentials,
            runner: { [connections] in connections.existingModel(for: request.host.id)?.keyInstallRunner() },
            checkLogin: { [environment] identity in
              await KeyLoginCheck.run(host: request.host, identity: identity, environment: environment)
            }
          ),
          isRegularWidth: sizeClass == .regular
        )
      }
    }
    // Deleting a host asks first and says what else goes. At the root, because the row is
    // gone by the time it is confirmed.
    //
    // An `alert`, not a `confirmationDialog`: from here an action sheet has no source rect,
    // falls back to a popover, and a popover drops the Cancel action. Anchoring it in the
    // sidebar would be presenting from a popover on iPad.
    .alert(
      hostPendingDeletion.map { "Delete \($0.displayName)?" } ?? "Delete this host?",
      isPresented: Binding(
        get: { hostPendingDeletion != nil },
        set: { if !$0 { hostPendingDeletion = nil } }
      ),
      presenting: hostPendingDeletion
    ) { host in
      Button("Delete Host", role: .destructive) {
        hostPendingDeletion = nil
        delete(host)
      }
      .accessibilityIdentifier("hosts.confirmDelete")
      // Identified, because `app.buttons["Cancel"]` matches an identifier, not a label.
      Button("Cancel", role: .cancel) { hostPendingDeletion = nil }
        .accessibilityIdentifier("hosts.cancelDelete")
    } message: { host in
      // Another saved host with this hostname keeps the shared key, so promise only what
      // `HostListModel.delete` will do.
      if (model?.hosts ?? []).sharesHostname(with: host) {
        Text("Driverr will also remove its saved password from this device.")
      } else {
        Text(
          "Driverr will also forget \(host.hostname)’s host key and remove its saved "
            + "password from this device."
        )
      }
    }
    .environment(\.terminalPresenter, terminalPresenter)
    .environment(\.connectionRegistry, connections)
    // The pane scene's two sheets, attached here for both routes. See `TerminalSceneSheets`.
    .terminalSceneSheets(
      scene: terminalPresenter.request?.scene,
      route: terminalRoute,
      // Passed in, not read from the environment. See `TerminalSceneSheets`.
      connections: connections,
      presenter: terminalPresenter
    )
    // The composer's Photos picker. See `ComposerPhotosPicker`.
    .modifier(
      ComposerPhotosPicker(presenter: terminalPresenter, item: $pickedImageItem)
    )
    // Returning to the foreground is when Driverr learns what backgrounding cost: a link that
    // died while suspended announced nothing. Nothing is torn down on the way out, because a
    // short suspension usually leaves the connection alive.
    .onChange(of: scenePhase) { _, phase in
      // The notification rule's gate: a pane that blocks while someone is looking is not a
      // notification. `.inactive` counts as away.
      connections.isAppActive = phase == .active
      switch phase {
      case .active:
        backgroundAssertion.end()
        Task { await connections.probeConnections() }
      case .background:
        backgroundAssertion.begin()
        // The assertion buys under 30 seconds; this requests a check in fifteen minutes. Also
        // submitted from each run, but a fresh install needs its first request from here.
        environment.backgroundRefresh.schedule()
      default:
        break
      }
    }
    // Persist the selection here, not at each setter, so no route can skip it.
    .onChange(of: selectedHostID) { _, id in
      rememberSelection(id)
      hostPick.selectionChanged(to: id)
    }
    // A request that arrives while the app is running. The launch case is drained by the
    // `.task` below.
    //
    // `.onChange` with an unstructured `Task`, not `.task(id:)`: `drainPendingOpen` clears the
    // slot before it awaits `open`, so under `.task(id:)` it would change its own id and
    // SwiftUI would cancel it mid-handshake with the request already consumed.
    .onChange(of: terminalPresenter.pendingOpen) { _, pending in
      guard pending != nil else { return }
      Task { await terminalPresenter.drainPendingOpen() }
    }
    // The switch must reach the driver even with nothing connected, because the card is on
    // the Lock Screen. `DriverrApp` loads the stored settings, so the first value here is the
    // stored one.
    .onChange(of: settingsModel.settings.liveActivities) { _, enabled in
      liveActivityPreferences.setEnabled(enabled)
      pushLiveActivityPreferences()
    }
    // A per-host Start or Stop. The driver holds one value, so a Stop reaches a card that is
    // already up, as the global switch does.
    .onChange(of: liveActivityPreferences.preferences.hostOverrides) { _, _ in
      pushLiveActivityPreferences()
    }
    .task {
      if model == nil {
        model = HostListModel(
          store: environment.hostStore,
          // A deletion takes the host's trusted key and Keychain password too. See
          // `HostListModel.delete`.
          knownHosts: environment.knownHostsStore,
          credentials: environment.passwordCredentials,
          // And its resume record.
          lastPanes: environment.lastPanes,
          // And its hook offer record.
          hookOffers: environment.hookOffers,
          // And the panes it was already alerted about.
          announcedPanes: environment.announcedPanes
        )
      }
      // What `TerminalPresenter.open(hostID:paneID:)` resolves an id against. Here because
      // `\.appEnvironment` cannot be read before a body has run.
      terminalPresenter.configure(
        hostStore: environment.hostStore,
        connections: connections,
        environment: environment,
        select: { selectedHostID = $0 }
      )
      await model?.load()

      // The launch value. `.onChange` fires only on a transition, so a stored `off` loaded
      // before this ran would never reach the driver and a stale card would stand.
      await liveActivityPreferences.load()
      liveActivityPreferences.setEnabled(settingsModel.settings.liveActivities)
      await environment.blockedPaneActivities
        .preferencesChanged(liveActivityPreferences.preferences)

      // Where an authoritative pass lands. Set here because the registry cannot read
      // `\.appEnvironment`.
      connections.onLiveActivityInputChanged = { observations, canRequest in
        Task {
          await environment.blockedPaneActivities.observed(
            observations, scope: .everyConnectedHost, canRequest: canRequest)
        }
      }
      // One pass on launch, before anything connects. A card outlives its process, so a build
      // killed while connected leaves one standing. With no models yet, the reconciler ends it.
      connections.pushLiveActivityObservations()

      // An `if`, not an early `return`, so the drain below always runs. The restore must run
      // once (see `didApplyLaunchSelection`), but a request made earlier waits on the drain.
      if !didApplyLaunchSelection {
        didApplyLaunchSelection = true
        applyRestoredSelection()
      }

      // Anything requested before `configure` ran, such as `-uiTestingOpen` or a notification
      // tap. Last, because the handshake it may start takes seconds, and a drain before
      // `load()` would hold the host list at its spinner.
      await terminalPresenter.drainPendingOpen()
    }
    // ⌘W with no pane scene up. See `RootKeyActions`.
    .focusedSceneValue(
      \.rootKeyActions,
      RootKeyActions(
        hasSelectedHost: selectedHostID != nil,
        isPresenting: hasRootPresentation,
        leaveHost: { selectedHostID = nil }
      )
    )
  }

  /// Whether a sheet or alert attached at this root is up.
  ///
  /// The Pane menu is scene-wide, so it would act on the pane from behind any of these.
  /// `TerminalScreen` uses this to disable it. The scene's own sheets are not counted.
  private var hasRootPresentation: Bool {
    isShowingSettings || isShowingKeys || hostForm != nil || hostPendingDeletion != nil
      || connections.pendingHostKeyPrompt() != nil || hookSheet != nil
      || pendingHookOffer != nil || keySheet != nil
  }

  // MARK: - Driverr's hooks

  /// The connect-time offer to show now, if nothing else is up at the root.
  private var pendingHookOffer: HookSheetRequest? {
    let scene = terminalPresenter.request?.scene
    let isRootPresenting =
      isShowingSettings || isShowingKeys || hostForm != nil || hostPendingDeletion != nil
      || keySheet != nil || scene?.isShowingPaneSheet == true || scene?.isShowingSettings == true
      || scene?.isShowingPhotoPicker == true
    guard let offer = connections.pendingHookOffer(isRootPresenting: isRootPresenting) else { return nil }
    return HookSheetRequest(
      hostID: offer.model.host.id,
      hostName: offer.model.host.displayName,
      integration: offer.integration,
      source: .offer
    )
  }

  /// Install Driverr Hooks, from the row's context menu or the host screen.
  private func requestHookInstall(for host: DriverrCore.Host) {
    guard let integration = AgentIntegration.catalog.first else { return }
    hookSheet = HookSheetRequest(
      hostID: host.id, hostName: host.displayName, integration: integration, source: .menu)
  }

  // MARK: - The iPad's split view

  /// The host list beside the detail column. Regular width only; `phoneStack` serves compact.
  private var splitView: some View {
    NavigationSplitView {
      hostListScreen
        // The column grows with the text size. At the default size this applies nothing,
        // because the platform's sidebar width differs by device. See `SidebarColumnWidth`.
        .sidebarColumnWidth(SidebarColumnWidth.ideal(scaledBase: scaledSidebarBase))
    } detail: {
      // On regular width the pane scene replaces the host screen in this column, so there is
      // no second level to push and the host list stays beside it.
      //
      // No `NavigationStack` around it. The column is already a navigation container, and a
      // second stack broke the chat's keyboard handling: typing one character dropped the
      // composer and the conversation by about 300 pt
      // (`testTheComposerGrowingKeepsTheEndOfTheAnswerOnScreen`).
      //
      // No environment is injected: the column descends from the root's `.environment` lines.
      if terminalRoute == .detailColumn, let request = terminalPresenter.request {
        TerminalScreen(
          scene: request.scene, route: .detailColumn,
          isBehindRootPresentation: hasRootPresentation
        )
      }
      // The host screen for the selected id, or a placeholder below when nothing is chosen.
      else if let model, let selectedHostID,
        let host = model.hosts.first(where: { $0.id == selectedHostID })
      {
        // `.id(host.id)` matters on iPad. The detail column persists, so SwiftUI would reuse
        // this `HostDetailView` for another host and keep the first host's `@State`. A new
        // identity per host fixes that. The connection lives in `ConnectionRegistry`, so
        // switching hosts leaves both connections up.
        HostDetailView(
          host: host,
          hosts: model,
          onEdit: { edited in
            // The detail column cannot present this itself. See `HostDetailView.onEdit`.
            hostForm = HostFormRequest(host: edited)
          },
          onInstallHooks: { requestHookInstall(for: $0) },
          onInstallKey: { keySheet = KeySheetRequest(host: $0) },
          offersHooksOnConnect: hostPick.offersHooksOnConnect(for: host.id)
        )
        .id(host.id)
      }
      // Two placeholders: "Select a host" is advice nobody can take when the list is empty.
      else if model?.hosts.isEmpty ?? true {
        ContentUnavailableView(
          "No Hosts",
          systemImage: "server.rack",
          description: Text("Add a host to connect over SSH.")
        )
        .accessibilityIdentifier("detail.empty")
      } else {
        ContentUnavailableView(
          "No Host Selected",
          systemImage: "terminal",
          description: Text("Select a host to connect.")
        )
        .accessibilityIdentifier("detail.empty")
      }
    }
    // ⌘, on a zero-size button behind the split view, not on `settings.open`, which is inside
    // a `Menu` and not built until the menu opens. It does not reach the phone's stack; see
    // `phoneStack`. Empty on iPad; see `KeyCommand.settings`.
    .background { settingsShortcut }
  }

  // MARK: - The phone's stack

  /// The host list, the host screen pushed on it, and the pane scene pushed on that.
  ///
  /// Neither level owns state. Level one derives from `selectedHostID`, level two from
  /// `TerminalPresenter.request`. `PhoneStackPath` in `DriverrCore` holds the rule, so
  /// `swift test` covers it. A push is not a presentation, so everything here inherits the
  /// root's `.environment` values normally.
  ///
  /// This route binds no ⌘,. Under XCUITest no placement delivers the key behind a
  /// `NavigationStack`, although ⌘N works. `PaneKeyCommandUITests`' class comment lists the
  /// placements tried.
  private var phoneStack: some View {
    NavigationStack(path: phonePath) {
      hostListScreen
        // Both levels resolved here, from one typed path. See CLAUDE.md and
        // `PhoneStackPath.Route`: a pane level declared inside the host screen loses the pane
        // on a cross-host pick.
        .navigationDestination(for: PhoneStackPath.Route.self) { route in
          switch route {
          case .host(let id): hostScreen(for: id)
          case .pane: paneScene
          }
        }
    }
  }

  /// The host screen, level one of the phone's stack. `.id(host.id)` as in the detail column,
  /// so the two routes cannot drift apart.
  @ViewBuilder
  private func hostScreen(for id: DriverrCore.Host.ID) -> some View {
    if let model, let host = model.hosts.first(where: { $0.id == id }) {
      HostDetailView(
        host: host,
        hosts: model,
        onEdit: { edited in
          // Presented at the root. See `HostDetailView.onEdit`.
          hostForm = HostFormRequest(host: edited)
        },
        onInstallHooks: { requestHookInstall(for: $0) },
        onInstallKey: { keySheet = KeySheetRequest(host: $0) },
        offersHooksOnConnect: hostPick.offersHooksOnConnect(for: host.id)
      )
      .id(host.id)
    }
  }

  /// The pane scene, level two. It reads the request rather than a host in the path, so a
  /// cross-host pick changes the content of a level that stays pushed.
  @ViewBuilder
  private var paneScene: some View {
    if let request = terminalPresenter.request {
      TerminalScreen(
        scene: request.scene, route: .stack, isBehindRootPresentation: hasRootPresentation
      )
    }
  }

  // MARK: - The host list, on both routes

  /// The list, its title and its toolbar: the sidebar on iPad, the stack's root on the phone.
  /// One definition, so a toolbar control cannot reach only one device.
  @ViewBuilder
  private var hostListScreen: some View {
    Group {
      if let model {
        hostList(model)
      } else {
        ProgressView()
      }
    }
    // "Hosts", not "Driverr": the app's name says nothing the reader does not know.
    .navigationTitle("Hosts")
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      // Two controls. Keys and Settings share an overflow menu, because neither is why the
      // user came here, but Keys has no other way in.
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button {
            isShowingKeys = true
          } label: {
            Label("Keys", systemImage: "key")
          }
          .accessibilityIdentifier("keys.open")

          Button {
            isShowingSettings = true
          } label: {
            Label("Settings", systemImage: "gearshape")
          }
          .accessibilityIdentifier("settings.open")
        } label: {
          // On the label, never the `Menu`: a container's identifier would overwrite the
          // settings and keys identifiers the tests query.
          Label("More", systemImage: "ellipsis.circle")
            .accessibilityIdentifier("hosts.overflow")
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          hostForm = HostFormRequest(host: nil)
        } label: {
          Label("Add Host", systemImage: "plus")
        }
        // ⌘N on the real toolbar button, which is always in the view tree, so key and tap are
        // one action.
        .keyboardShortcut(KeyCommand.addHost.shortcut)
        .accessibilityIdentifier("hosts.add")
      }
    }
  }

  // MARK: - Hardware keys

  /// ⌘, opens Driverr's Settings on an iPhone. On an iPad the system keeps the key for its
  /// own Settings item.
  ///
  /// Only while no pane scene is up. `TerminalScreen` binds ⌘, too, and two identical key
  /// commands in one responder chain have no defined winner. The 1 pt frame and near-zero
  /// opacity are needed for the key to reach it; see `TerminalScreen.keyCommands`.
  ///
  /// Attached behind `splitView` only, because the key does not reach the phone's stack
  /// (see `phoneStack`). So it works on an iPhone wide enough for the split view.
  /// `KeyCommand.isSettingsBound` holds the device rule.
  @ViewBuilder
  private var settingsShortcut: some View {
    if KeyCommand.isSettingsBound, terminalRoute == .none {
      Button(KeyCommand.settings.title) { isShowingSettings = true }
        .keyboardShortcut(KeyCommand.settings.shortcut)
        .frame(width: 1, height: 1)
        .opacity(0.01)
        .accessibilityHidden(true)
    }
  }

  // MARK: - Where the pane scene is drawn

  /// The route this window is on. The rule is `TerminalSceneRoute` in `DriverrCore`, tested
  /// by `TerminalSceneRouteTests`.
  private var terminalRoute: TerminalSceneRoute {
    TerminalSceneRoute.route(
      hasRequest: terminalPresenter.request != nil,
      isRegularWidth: sizeClass == .regular
    )
  }

  /// The phone stack's path: the chosen host, and the pane scene on top of it.
  ///
  /// Derived, never stored. A second copy of `selectedHostID` in a `NavigationPath` would
  /// disagree with it the first time a notification tap wrote one. The rule is
  /// `PhoneStackPath`.
  ///
  /// The setter runs `dismiss()` on a pop (back button, edge swipe, long press), or the host
  /// screen would return with a pane still presented behind it. Do not move this to
  /// `onDisappear`, which would close the scene on a route flip.
  ///
  /// The setter must not guard on the route. `ContentView` is a struct, so the `Binding`'s
  /// closures capture the `self` value from when the stack was built, and a
  /// `terminalRoute == .stack` guard would read `.stack` forever. A path is a source of truth,
  /// not a presentation's echo, so a rotation across the size-class boundary does not write
  /// here (`PaneRouteFlipUITests`).
  private var phonePath: Binding<[PhoneStackPath.Route]> {
    Binding(
      get: {
        PhoneStackPath.path(
          selectedHostID: selectedHostID,
          hasRequest: terminalPresenter.request != nil
        )
      },
      set: { newPath in
        switch PhoneStackPath.effect(
          ofWrite: newPath,
          hadRequest: terminalPresenter.request != nil
        ) {
        case .none, .deselect:
          break
        case .endScene, .endSceneAndDeselect:
          terminalPresenter.dismiss()
        }
        // SwiftUI writes the path only for the user's own push or pop.
        let selection = PhoneStackPath.selection(inWrite: newPath)
        hostPick.userPicked(selection)
        selectedHostID = selection
      }
    )
  }

  /// Removes the host, and the connection nothing on screen could otherwise close.
  private func delete(_ host: DriverrCore.Host) {
    guard let model else { return }
    // Clear the selection with the host. The detail column would show the placeholder
    // anyway, but the sidebar would keep a selection for a row that is gone.
    if selectedHostID == host.id { selectedHostID = nil }
    Task { await model.delete(host) }
    // Remove its Start/Stop override too.
    liveActivityPreferences.forget(host.id)
    // Nothing else could close this host's connection once the row is gone. A separate task,
    // so removing the row does not wait on an SSH teardown.
    Task { await connections.forget(host.id) }
  }

  // MARK: - The host this launch starts on

  /// Where the chosen host is remembered between launches.
  ///
  /// Namespaced, because `UserDefaults.standard` is shared with the other stores.
  /// `BackgroundRefreshRunner` reads it too, so the host the app returns to and the host it
  /// checks in the background are the same.
  static let selectedHostDefaultsKey = "driverr.contentView.selectedHostID"

  /// Which host a launch should start on, given what was stored and what still exists.
  ///
  /// Static and pure so `DriverrTests` can assert it without a window, including a host
  /// deleted since the last launch. `nil` for a missing value, an unparseable one, or a host
  /// that is gone. The caller then drops the stored key silently.
  static func restoredSelection(
    stored: String?,
    hosts: [DriverrCore.Host]
  ) -> DriverrCore.Host.ID? {
    guard let stored, let id = UUID(uuidString: stored) else { return nil }
    return hosts.contains(where: { $0.id == id }) ? id : nil
  }

  /// Hands the driver both halves of the preference value at once.
  private func pushLiveActivityPreferences() {
    let preferences = liveActivityPreferences.preferences
    Task { await environment.blockedPaneActivities.preferencesChanged(preferences) }
    // A Start turns a host back on, and nothing would ask for its card until the next poll.
    connections.pushLiveActivityObservations()
  }

  /// Applies the stored selection, once, if this launch restores at all.
  private func applyRestoredSelection() {
    guard AppEnvironment.isRestoringSelection, selectedHostID == nil else { return }
    let stored = UserDefaults.standard.string(forKey: Self.selectedHostDefaultsKey)
    guard let id = Self.restoredSelection(stored: stored, hosts: model?.hosts ?? []) else {
      if stored != nil {
        UserDefaults.standard.removeObject(forKey: Self.selectedHostDefaultsKey)
      }
      return
    }
    selectedHostID = id
  }

  /// Records the chosen host, or forgets it when there is none.
  private func rememberSelection(_ id: DriverrCore.Host.ID?) {
    guard let id else {
      UserDefaults.standard.removeObject(forKey: Self.selectedHostDefaultsKey)
      return
    }
    UserDefaults.standard.set(id.uuidString, forKey: Self.selectedHostDefaultsKey)
  }

  @ViewBuilder
  private func hostList(_ model: HostListModel) -> some View {
    if model.hosts.isEmpty {
      // The identifier goes on the `Label`: `ContentUnavailableView` would propagate it to
      // every leaf, and `LaunchUITests` finds this state by `app.images["hosts.empty"]`.
      ContentUnavailableView {
        Label("No Hosts", systemImage: "server.rack")
          .accessibilityIdentifier("hosts.empty")
      } description: {
        // What to do first, then what a host needs, so the form holds no surprises.
        Text(
          "Add a machine to reach over SSH. You need its address, a username, and "
            + "either a password or an SSH key."
        )
      } actions: {
        // Prominent, because on a first launch this is the only action. `ProminentButtonLabel`
        // because the prominent style's fixed white label is under 4.5:1 on most bundled
        // themes; `\.themeAccentForeground` clears it on all of them.
        Button {
          hostForm = HostFormRequest(host: nil)
        } label: {
          ProminentButtonLabel("Add Host")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityIdentifier("hosts.emptyAdd")
      }
    } else {
      // `List(selection:)` makes the chosen host a value, and on iPad highlights the row the
      // detail column belongs to.
      List(selection: sidebarSelection) {
        // Without this row, a failed save, load or delete would look like a gesture that did
        // nothing.
        if let message = model.errorMessage {
          Section {
            Label(message, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
              .accessibilityIdentifier("hosts.error")
          }
        }
        Section {
          hostRows(model)
        } footer: {
          // On the footer's `Text`, never the `Section`, whose identifier would rename every
          // row.
          Text(connections.summary(of: model.hosts).text)
            .accessibilityIdentifier("hosts.summary")
        }
      }
    }
  }

  /// The sidebar's selection, ending the pane scene on the way through.
  ///
  /// A custom binding rather than `$selectedHostID` with `.onChange`, because SwiftUI writes
  /// through a selection binding only for the user's tap. `TerminalPresenter.select` also
  /// moves the selection, for a notification tap or a cross-host pick, and an `.onChange`
  /// would tear down the scene that pick had just presented. The binding also sees a tap on
  /// the already-selected host, which leaves the scene; `.onChange` would not fire for it.
  private var sidebarSelection: Binding<DriverrCore.Host.ID?> {
    Binding(
      get: { selectedHostID },
      set: { id in
        // Regular width only, the one place a sidebar row and a pane scene are on screen
        // together. On compact no tap can reach a row while the scene is up.
        if terminalRoute == .detailColumn {
          terminalPresenter.sidebarDidSelect(hostID: id)
        }
        // A tap, by this binding's design.
        hostPick.userPicked(id)
        selectedHostID = id
      }
    )
  }

  @ViewBuilder
  private func hostRows(_ model: HostListModel) -> some View {
    ForEach(model.hosts) { host in
      // `NavigationLink(value:)` on both routes, with the route's own value type. On regular
      // width the value is the host id, which the link writes into the list's selection. On
      // the phone it is the stack's `Route`, and the path setter writes `selectedHostID` from
      // it, so one selection drives both devices. A `Button` would lose the disclosure chevron
      // and row treatment on the phone.
      if sizeClass == .regular {
        hostRowLink(host, value: host.id)
      } else {
        hostRowLink(host, value: PhoneStackPath.Route.host(host.id))
      }
    }
  }

  /// One row, as a link carrying whichever value this route's path takes.
  @ViewBuilder
  private func hostRowLink<Value: Hashable>(
    _ host: DriverrCore.Host,
    value: Value
  ) -> some View {
    NavigationLink(value: value) {
      hostRow(host)
    }
    .accessibilityIdentifier("hosts.row")
    .swipeActions {
      // UIKit draws a swipe pill's label white whatever the fill, so both pills take a fixed
      // colour, not the theme accent. See `SwipeActionTint`.
      Button("Delete", role: .destructive) { hostPendingDeletion = host }
        .accessibilityIdentifier("hosts.delete")
        .tint(SwipeActionTint.destructive.swiftUIColor)

      Button("Edit") {
        hostForm = HostFormRequest(host: host)
      }
      .accessibilityIdentifier("hosts.edit")
      .tint(SwipeActionTint.neutral.swiftUIColor)
    }
    // The same actions from a long press, for users who do not know the swipe. Delete goes
    // through the same confirmation.
    .contextMenu {
      Button {
        hostForm = HostFormRequest(host: host)
      } label: {
        Label("Edit", systemImage: "pencil")
      }
      .accessibilityIdentifier("hosts.menuEdit")

      // Available at any time, including after a declined offer.
      Button {
        requestHookInstall(for: host)
      } label: {
        Label("Install Driverr Hooks", systemImage: "puzzlepiece.extension")
      }
      .accessibilityIdentifier("hosts.menuInstallHooks")

      Button(role: .destructive) {
        hostPendingDeletion = host
      } label: {
        Label("Delete", systemImage: "trash")
      }
      .accessibilityIdentifier("hosts.menuDelete")
    }
  }

  /// One host, answering "is anything waiting on me?" before it is opened. Every word comes
  /// from `DriverrCore.HostStatus`, where `swift test` covers it.
  @ViewBuilder
  private func hostRow(_ host: DriverrCore.Host) -> some View {
    let status = connections.status(for: host)
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(host.displayName)
        Text(status.subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      connectionDot(status)
      if let badge = status.badge, let spoken = status.badgeAccessibilityLabel {
        blockedBadge(host, badge: badge, spoken: spoken)
      }
      // Draws nothing. Keeps the count above live. See `SessionPollHold`.
      if let session = connections.existingModel(for: host.id)?.session {
        SessionPollHold(session: session)
      }
    }
  }

  /// Whether Driverr is holding this host's connection, as a dot.
  ///
  /// The label matters, not the colour: one element that says the word, without the trait
  /// a symbol can bring. Three shapes, because a dropped link must not look like a host never
  /// reached. `HostConnectionState.glyphRole` decides which kind; the view picks symbol and
  /// colour.
  private func connectionDot(_ status: HostStatus) -> some View {
    Image(systemName: Self.glyph(for: status.connection.glyphRole))
      .font(.caption2)
      .foregroundStyle(Self.tint(for: status.connection.glyphRole))
      .accessibilityLabel(status.connectionAccessibilityLabel)
      .accessibilityRemoveTraits(.isSelected)
      .accessibilityIdentifier(Self.identifier(for: status.connection))
  }

  private static func glyph(for role: HostConnectionGlyphRole) -> String {
    switch role {
    case .none: "circle"
    case .ok: "circle.fill"
    // A filled circle, not a triangle: the other states here are `circle` and `circle.fill`,
    // and a triangle carries more ink, so one lost host would outweigh ten connected ones. The
    // detail pill keeps the triangle.
    case .warning: "exclamationmark.circle.fill"
    }
  }

  private static func tint(for role: HostConnectionGlyphRole) -> Color {
    switch role {
    case .none: .secondary
    case .ok: .green
    case .warning: .orange
    }
  }

  private static func identifier(for connection: HostConnectionState) -> String {
    switch connection {
    case .idle: "hosts.disconnected"
    case .connected: "hosts.connected"
    case .lost: "hosts.lost"
    }
  }

  /// How many of this host's panes are waiting on a human.
  ///
  /// Red and filled, like `AgentStatus.blocked`, because it is the one thing that wants you.
  /// Spoken as "2 panes need you".
  ///
  /// A button when it names one pane, a label when it counts several: with two there is no
  /// single destination (`SessionTree.loneBlockedPane` is `nil`). `.buttonStyle(.borderless)`
  /// stops the enclosing `NavigationLink` row from taking the tap.
  @ViewBuilder
  private func blockedBadge(
    _ host: DriverrCore.Host,
    badge: String,
    spoken: String
  ) -> some View {
    // Read through the optional: the registry may forget the host between reading the status
    // and this line.
    if let model = connections.existingModel(for: host.id),
      let pane = model.session?.tree.loneBlockedPane
    {
      Button {
        // Through `open`, the entry point notification taps use. The host is connected, so
        // `open` presents at once. `open`, not `reply`: the badge says something is waiting,
        // not that you are answering.
        Task { await terminalPresenter.open(hostID: host.id, paneID: pane.id) }
      } label: {
        badgeCapsule(badge)
      }
      // A 44 x 44 hit area on 20 x 20 of layout; keep these three modifiers in this order.
      // A plain 44 pt `frame` would make these rows taller than their neighbours. `frame`
      // sizes the hit box, `contentShape` makes all of it hittable, and the negative padding
      // returns the layout space. `contentShape` before `frame` shapes only the capsule, and
      // padding before `contentShape` shrinks the shape.
      .frame(width: 44, height: 44)
      .contentShape(Rectangle())
      .padding(-12)
      .buttonStyle(.borderless)
      // The count, then what a tap does. `spoken` is already a sentence.
      .accessibilityLabel("\(spoken). Opens \(pane.title).")
      .accessibilityIdentifier("hosts.blocked")
    } else {
      badgeCapsule(badge)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier("hosts.blocked")
    }
  }

  /// The badge itself, with nothing said about whether it does anything.
  private func badgeCapsule(_ badge: String) -> some View {
    Text(badge)
      .font(.caption2.weight(.semibold))
      .monospacedDigit()
      .foregroundStyle(.white)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Color.red, in: Capsule())
  }
}

extension View {
  /// Asks the split view for a sidebar this wide, or asks for nothing.
  ///
  /// `nil` applies no modifier, because any modifier replaces the platform's per-device width
  /// even when asking for the same value. See `SidebarColumnWidth`. The floor stays at the
  /// platform's 320, and the ceiling is the rule's.
  @ViewBuilder
  func sidebarColumnWidth(_ ideal: Double?) -> some View {
    if let ideal {
      navigationSplitViewColumnWidth(
        min: CGFloat(SidebarColumnWidth.base),
        ideal: CGFloat(ideal),
        max: CGFloat(SidebarColumnWidth.maximum)
      )
    } else {
      self
    }
  }
}

/// Keeps one connected host's session polling while its row is on screen, so the badge count
/// stays live. `SessionModel` counts its holders, so several screens can hold it.
///
/// A view of its own, not `.task`/`.onDisappear` on the row, so retain and release always
/// balance. `stopLiveUpdates` clamps at zero, so an unmatched release would silently drop
/// another screen's hold. The cost is the host screen's own poll, only for hosts already
/// connected.
private struct SessionPollHold: View {
  let session: SessionModel

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
      .task { session.startLiveUpdates() }
      .onDisappear { session.stopLiveUpdates() }
  }
}

/// The one background-task assertion Driverr takes.
///
/// Without it, the poll stops within a few seconds of leaving the app. `beginBackgroundTask`
/// grants about 27 seconds, and polling stops at expiry rather than failing. It is not a
/// background mode and needs no `UIBackgroundModes` key.
///
/// It covers the seconds after the phone goes in a pocket, on an open connection. The
/// `BGAppRefreshTask` in `BackgroundRefresh.swift` covers the time after that.
///
/// A class, because the expiration handler must end its own assertion, and a closure
/// capturing a `View` struct to reach its `@State` would act on a stale copy.
@MainActor
final class BackgroundAssertion {
  private var identifier: UIBackgroundTaskIdentifier = .invalid

  /// Takes one, unless one is already held. `scenePhase` can report a phase twice, and a
  /// second assertion would leak.
  func begin() {
    guard identifier == .invalid else { return }
    identifier = UIApplication.shared.beginBackgroundTask(withName: "driverr.blocked-panes") {
      [weak self] in
      // The documented contract: an assertion the system has to revoke terminates the app.
      self?.end()
    }
  }

  /// Hands it back, on the way to `.active` or on expiry.
  func end() {
    guard identifier != .invalid else { return }
    UIApplication.shared.endBackgroundTask(identifier)
    identifier = .invalid
  }
}
