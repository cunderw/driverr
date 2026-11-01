import DriverrCore
import DriverrHerdr
import DriverrSSH
import SwiftUI

/// Connect to one host, see its session, and run a command on it.
struct HostDetailView: View {
  @Environment(\.appEnvironment) private var environment
  @Environment(\.terminalPresenter) private var presenter
  @Environment(\.connectionRegistry) private var connections
  /// This column's width. The question is whether this surface needs a reading measure,
  /// so the column's answer is the right one here.
  @Environment(\.horizontalSizeClass) private var sizeClass
  /// Whether the card is allowed at all, and whether this host is started.
  @Environment(\.settingsModel) private var settingsModel
  @Environment(\.liveActivityPreferences) private var liveActivityPreferences
  /// Continue in Background's one run, and whether it is this host's.
  @Environment(\.backgroundWatch) private var backgroundWatch

  /// The host as the caller had it. A fallback only: `host` prefers the list's live copy, so
  /// an edit made from this screen reaches it without a rebuild.
  private let seed: DriverrCore.Host

  /// The host list, when there is one. Optional only for previews and hosted layout tests.
  /// Edit here then means the same as Edit on the row: one store write, one reload.
  private let hosts: HostListModel?

  /// Asks the root to put the host form up.
  ///
  /// This is the split view's detail column, where a sheet does not present. See CLAUDE.md,
  /// "Never present from inside a presentation". `nil` with no root behind the screen, and
  /// the toolbar button is then hidden rather than doing nothing.
  private let onEdit: ((DriverrCore.Host) -> Void)?

  /// Asks the root to put the hook install sheet up, for `onEdit`'s reason. `nil` hides the
  /// row.
  private let onInstallHooks: ((DriverrCore.Host) -> Void)?

  /// Asks the root to put the key install sheet up, for `onEdit`'s reason. `nil` hides the
  /// row.
  private let onInstallKey: ((DriverrCore.Host) -> Void)?

  /// Whether this screen is up because the user tapped the host's row. Only then did the
  /// user start the connect, and only then may it offer the hooks. A restored launch, a Live
  /// Activity, a notification and a URL connect with nobody having asked.
  private let offersHooksOnConnect: Bool

  init(
    host: DriverrCore.Host,
    hosts: HostListModel? = nil,
    onEdit: ((DriverrCore.Host) -> Void)? = nil,
    onInstallHooks: ((DriverrCore.Host) -> Void)? = nil,
    onInstallKey: ((DriverrCore.Host) -> Void)? = nil,
    offersHooksOnConnect: Bool = false
  ) {
    seed = host
    self.hosts = hosts
    self.onEdit = onEdit
    self.onInstallHooks = onInstallHooks
    self.onInstallKey = onInstallKey
    self.offersHooksOnConnect = offersHooksOnConnect
  }

  /// This host, as the list has it now.
  var host: DriverrCore.Host {
    hosts?.hosts.first { $0.id == seed.id } ?? seed
  }

  /// Taken from the registry, not built here. `@State` keeps the same object while on screen,
  /// and the registry returns the same object on the next visit.
  @State private var model: ConnectionModel?
  @State private var password = ""
  @State private var rememberPassword = false
  @State private var command = "uname -a"
  /// Whether the "this really is a rebuilt server" confirmation is up. At the screen's level,
  /// because the failure row it would hang off disappears when the action runs.
  @State private var isConfirmingForget = false
  /// The key Driverr trusts for this host, read when the confirmation goes up.
  @State private var trustedKey: SSHHostKey?

  /// Whether the connection details are showing, once someone has said.
  ///
  /// `nil` means untouched: open unless connected. The details open themselves for a
  /// password and fold away once there is a session. In memory only.
  @State private var isConnectionExpanded: Bool?

  /// Whether the connect now running was started by this screen rather than by a person.
  ///
  /// Set before the `.task` knows whether there is a connect to start, and cleared when the
  /// attempt ends or is cancelled. While true, the screen shows the collapsed pill it will
  /// settle into, instead of flashing the whole form for the length of a handshake.
  /// `ConnectionDetailsDisclosure` weighs this against the phase and the user's own tap.
  @State private var isUnattendedConnect = false

  var body: some View {
    form
      // A reading measure for the prose on a wide iPad column. Compact width applies nothing,
      // as in `TerminalSceneRoute.readableContentWidth`.
      .readableDetailColumn(isRegularWidth: sizeClass == .regular)
  }

  /// The screen itself, before the column it is set in.
  @ViewBuilder
  private var form: some View {
    Form {
      if let model {
        connectionSection(model)
        if case .connected = model.phase, model.herdrAvailability?.isReady == false {
          shellSection(model)
        }
        if case .connected = model.phase {
          if let session = model.session, model.herdrAvailability?.isReady == true {
            SessionTreeView(
              model: session,
              // The connection's pages, shared with the pane screen, so a row and a chat for
              // the same conversation cost one fetch.
              transcripts: model.transcripts,
              onSelect: { pane in
                // Only which pane. `TerminalSceneModel` resolves how to open it, because it
                // must do so again on every switch inside one presentation.
                presenter.present(host: host, model: model, pane: pane)
              },
              // Opens the pane's own screen with its composer focused. The request goes to the
              // root, which shows the pane scene.
              onReply: { pane in presenter.reply(host: host, model: model, pane: pane) }
            )
            .task {
              session.startLiveUpdates()
            }
            .onDisappear { session.stopLiveUpdates() }
          }
        }
        if let failure = model.failure { failureSection(failure) }
        // Last on the screen, so it does not push "Needs You" below the fold. Not gated on the
        // Live Activities switch, because Continue in Background keeps the connection alive
        // with the switch off. The switch gates the row, not the section.
        if case .connected = model.phase {
          backgroundSection(model)
          // What Driverr can set up on the host, in one section.
          let offersKey = onInstallKey != nil && host.authMethod == .password
          if onInstallHooks != nil || offersKey {
            Section {
              if let onInstallHooks {
                // The menu item's second home, for a reader already on the host.
                Button {
                  onInstallHooks(host)
                } label: {
                  Label("Install Driverr Hooks", systemImage: "puzzlepiece.extension")
                }
                .accessibilityIdentifier("host.installHooks")
              }
              // Only for a host that logs in with a password. The list's copy of the host, so
              // the row goes once Use This Key has saved it with the key.
              if let onInstallKey, offersKey {
                Button {
                  onInstallKey(host)
                } label: {
                  Label("Install a Key", systemImage: "key")
                }
                .accessibilityIdentifier("host.installKey")
              }
            }
          }
        }
      }
    }
    // Reset whenever the connection is not up. Otherwise a person's earlier tap would keep a
    // dropped link's address, password and Reconnect folded behind "Connection lost".
    .onChange(of: model?.phase) { _, phase in
      if phase != .connected { isConnectionExpanded = nil }
    }
    // Pull to refresh. The tree stays visible while it runs.
    .refreshable {
      await model?.session?.refresh()
    }
    .navigationTitle(host.displayName)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      // Edit on the screen the host is on. The root presents the form; see `onEdit`.
      if let onEdit {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            onEdit(host)
          } label: {
            Label("Edit", systemImage: "slider.horizontal.3")
          }
          .accessibilityIdentifier("host.edit")
        }
      }
      // Open Shell in the toolbar, because a shell is a main task here, not plumbing behind
      // the pill. Only when herdr is ready: otherwise `shellSection` already shows the same
      // button in the body.
      if let model, model.phase == .connected, model.herdrAvailability?.isReady == true {
        ToolbarItem(placement: .topBarTrailing) {
          // Not a push. See CLAUDE.md: on iPad, do not push from `HostDetailView`, because a
          // second push from the split view's detail column pops back to the host list.
          Button {
            presenter.present(host: host, model: model)
          } label: {
            // Named for what it opens, because tapping a pane also opens a terminal.
            Label("Open Shell", systemImage: "terminal")
          }
          .accessibilityIdentifier("connect.terminal")
        }
      }
    }
    // Keyed on the host value. An edit from this screen changes `host` without a rebuild, and
    // the registry returns a new `ConnectionModel` for it, so a one-shot `.task` would keep
    // driving the model for the old address.
    .task(id: host) {
      // Asked for here, not in `body`, because this can create one.
      let model = connections.model(for: host, environment: environment)
      // Read everything the first frame depends on before publishing the model. Publishing
      // first draws the section before the reads answer: an empty password field, or an open
      // form for a host about to connect by itself.
      password = await model.savedPassword() ?? ""
      rememberPassword = !password.isEmpty
      // Asked before the attempt, because the phase is still `.idle` in the frames before the
      // handshake starts.
      isUnattendedConnect = await model.willConnectWithoutAsking()
      self.model = model
      // A key host, or one with a saved password, connects without asking. A host that would
      // have to ask is left alone. `connectIfCredentialIsAvailable` draws that line.
      let startedAConnect = isUnattendedConnect
      await model.connectIfCredentialIsAvailable()
      // Only a row tap makes this a connect the user started. See `offersHooksOnConnect`.
      if startedAConnect && offersHooksOnConnect { await model.offerHooksIfNeeded() }
      // The attempt is over. Cancel clears this itself, because a cancelled handshake can
      // stay suspended until its deadline.
      isUnattendedConnect = false
    }
    // The trust prompt is presented by `ContentView`. It belongs to the `ConnectionModel`,
    // which outlives this screen, so the question can arrive after this view is gone. See
    // `ConnectionRegistry.pendingHostKeyPrompt()`.

    // Shows the fingerprint that will be forgotten, so the user can compare it with the
    // rebuilt machine. Confirming trusts nothing; the next connect goes through first contact.
    //
    // An `alert`, not a `confirmationDialog`: from a screen root an action sheet has no
    // source rectangle, falls back to a popover, and a popover drops the Cancel action.
    .alert(
      "Forget the host key for \(host.hostname)?",
      isPresented: $isConfirmingForget
    ) {
      Button("Forget Host Key", role: .destructive) {
        Task { await model?.forgetHostKey() }
      }
      .accessibilityIdentifier("connect.confirmForgetKey")
      Button("Cancel", role: .cancel) {}
        .accessibilityIdentifier("connect.cancelForgetKey")
    } message: {
      Text(forgetKeyMessage)
    }
    // ⌘W's Leave Host does nothing behind this alert. See `PaneCommands`.
    .focusedSceneValue(\.isHostScreenPresenting, isConfirmingForget)
  }

  /// The old key's fingerprint, grouped like the trust prompt's so it can be compared with
  /// that screen and with `ssh-keygen -lf`.
  private var forgetKeyMessage: String {
    let warning = """
      Only do this if you know why the key changed. It could be a rebuilt server, or a \
      new host at this address. Driverr will ask you to trust the new key on the next \
      connection.
      """
    guard let trustedKey else { return warning }
    // The fingerprint goes last. A full stop after the last group reads as part of it.
    return "\(warning)\n\nDriverr currently trusts this key:\n\(groupedFingerprint(trustedKey.fingerprint))"
  }

  /// The host's Live Activity and Continue in Background rows.
  ///
  /// Only while connected. The Live Activity row is hidden, not disabled, while the global
  /// switch is off. It is a retitling `Button`, like `LiveActivityMenuItem`, so the two
  /// surfaces word it the same way.
  @ViewBuilder
  private func backgroundSection(_ model: ConnectionModel) -> some View {
    let isStarted = liveActivityPreferences.isStarted(for: host.id)
    let isWatching = backgroundWatch.isRunning(for: host.id)
    let isBlocked = backgroundWatch.isRunningForAnotherHost(than: host.id)
    let isRowEnabled = BackgroundWatch.isEnabled(
      isConnected: model.phase == .connected, isRunningForAnotherHost: isBlocked)
    // The explanation is the section's `footer:`. As a row it looked like another control.
    Section {
      if settingsModel.settings.liveActivities {
        Button {
          liveActivityPreferences.setStarted(!isStarted, for: host.id)
        } label: {
          Label(
            LiveActivityCopy.hostButtonTitle(isStarted: isStarted),
            systemImage: isStarted ? "bolt.slash" : "bolt")
        }
        // On the `Button`, never the `Section`. See CLAUDE.md, "Test traps".
        .accessibilityIdentifier("host.liveActivity")
      }
      // The same action and `DriverrCore` copy as the pane menu. The subject is the host's
      // name, because no pane was picked to get here.
      Button {
        backgroundWatch.toggle(host: host, subject: host.displayName, session: model)
      } label: {
        Label(
          BackgroundWatchCopy.buttonTitle(isRunning: isWatching),
          systemImage: BackgroundWatchCopy.systemImage(isRunning: isWatching))
      }
      // One run at a time (`BackgroundWatch.isEnabled`). Dimmed, with the reason in the
      // footer, because a vanished row would look like a lost control. The pane menu hides it
      // instead, because a `Menu` has no footer.
      .disabled(!isRowEnabled)
      // `.disabled` alone drops the tint from the text but not the glyph, so the disabled row
      // draws brighter than an enabled one, in two colours. One style for the whole label:
      // `.tint`, which is what the enabled row already uses, or `.secondary`. Never
      // `Color.accentColor`, which ignores `.tint`.
      .foregroundStyle(isRowEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
      .accessibilityIdentifier("host.continueInBackground")
    } header: {
      Text(LiveActivityCopy.hostSectionHeader)
    } footer: {
      // Two paragraphs when both rows are drawn, one when only the second is, so the footer
      // never explains a hidden control.
      VStack(alignment: .leading, spacing: 8) {
        if settingsModel.settings.liveActivities {
          Text(LiveActivityCopy.hostFooter(isStarted: isStarted))
        }
        Text(
          BackgroundWatchCopy.hostFooter(
            isRunning: isWatching, isRunningForAnotherHost: isBlocked))
      }
      // No identifier on this container or either `Text`; the tests find the rows above.
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// The connection, as one pill with everything else folded behind it, so the session tree
  /// can be the screen.
  ///
  /// Inline disclosure, not a sheet: nothing may present from this detail column, and a push
  /// from here pops back to the host list.
  @ViewBuilder
  private func connectionSection(_ model: ConnectionModel) -> some View {
    Section {
      DisclosureGroup(isExpanded: connectionExpanded(model)) {
        LabeledContent("Address", value: "\(host.username)@\(host.hostname):\(host.port)")

        if case .password = host.authMethod, model.phase != .connected {
          SecureField("Password", text: $password)
            // Lets the password manager fill it.
            .textContentType(.password)
            // Return connects, so the keyboard need not be dismissed to reach the button.
            .submitLabel(.go)
            .onSubmit { startConnecting(model) }
            .accessibilityIdentifier("connect.password")
          Toggle("Remember Password", isOn: $rememberPassword)
            .accessibilityIdentifier("connect.remember")
          // Says where the password goes. On its own `Text`, not the `Section` or `Toggle`,
          // because `ToggleUITests` drives `connect.remember` by name.
          Text("Saved in this device’s Keychain. Sent only to this host.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("connect.rememberFooter")
        }

        switch model.phase {
        case .connected:
          Button("Disconnect") { Task { await model.disconnect() } }
            .accessibilityIdentifier("connect.disconnect")
        // A lost connection gets Reconnect. Automatic backoff belongs to the terminal scene;
        // a host with nothing open waits to be asked.
        case .lost:
          Button("Reconnect") { startConnecting(model) }
            .disabled(isMissingAPassword)
            .accessibilityIdentifier("connect.reconnect")
        // No button at all under a key mismatch, not even a disabled one. Retrying is the wrong
        // response to a possible interception. The Problem section offers Forget Host Key.
        case .failed(.hostKeyMismatch):
          EmptyView()
        case .idle, .failed:
          Button("Connect") { startConnecting(model) }
            // Disabled with an empty password, which would otherwise report an authentication
            // refusal for a packet never sent.
            .disabled(isMissingAPassword)
            .accessibilityIdentifier("connect.connect")
        // Cancel is a row of the section, not the disclosure. See below.
        case .connecting, .authenticating:
          EmptyView()
        }

        if case .connected = model.phase {
          commandRows(model)
        }
      } label: {
        connectionPill(model)
      }

      // Every spinner has a way out. The coordinator's deadline is twenty seconds.
      //
      // Beside the pill, not in the details: SwiftUI does not build a collapsed
      // `DisclosureGroup`'s content, so Cancel there would not exist during an unattended
      // connect. `testCancelEndsAConnectThatIsStillRunning` covers this.
      if model.phase == .connecting || model.phase == .authenticating {
        Button("Cancel", role: .cancel) {
          // Cleared on the tap: the cancelled attempt stays suspended in the handshake and the
          // `.task`'s own reset can be a whole deadline away.
          isUnattendedConnect = false
          Task { await model.cancelConnect() }
        }
        .accessibilityIdentifier("connect.cancel")
      }
    }
  }

  /// What the screen offers when the host has no usable herdr.
  ///
  /// The shell does not open by itself. The user may have come to run a command or to see
  /// why herdr is missing, and a scene opened on connect would hide both, and fire again on every
  /// reconnect. The same on iPhone and iPad. `herdrLine` says which kind of "no" it is.
  @ViewBuilder
  private func shellSection(_ model: ConnectionModel) -> some View {
    Section {
      Button {
        presenter.present(host: host, model: model)
      } label: {
        Label(Self.shellActionLabel(for: model.herdrAvailability), systemImage: "terminal")
      }
      .accessibilityIdentifier("connect.shell")
    } footer: {
      Text("No herdr here, so there are no panes to show — but this is still an ordinary SSH host.")
    }
  }

  /// The action named for the state it answers. `HerdrAvailability` has three kinds of "no"
  /// with different next steps.
  private static func shellActionLabel(for availability: HerdrAvailability?) -> String {
    switch availability {
    case .serverNotRunning: "Open Shell to Start herdr"
    // `.statusUnreadable` belongs here: a session is already running, so offering to start
    // one would be the wrong next step.
    case .notInstalled, .tooOld, .ready, .statusUnreadable, .coreReady, .combined,
      .coreIncompatible, .readyWithCoreRefused, nil:
      "Open Shell"
    }
  }

  /// Folded while connected or while the screen connects on its own, open otherwise, and
  /// whatever the user last chose over all of it. The rule is
  /// `DriverrCore.ConnectionDetailsDisclosure`.
  private func connectionExpanded(_ model: ConnectionModel) -> Binding<Bool> {
    Binding(
      get: {
        // `isUnattendedConnect` is read ahead of the phase, because the `.task` sets it before
        // the handshake starts. Every other attempt in flight was started by hand.
        let isRunning = model.phase == .connecting || model.phase == .authenticating
        let attempt: ConnectionDetailsDisclosure.Attempt? =
          isUnattendedConnect ? .unattended : (isRunning ? .user : nil)
        return ConnectionDetailsDisclosure.isShowing(
          isConnected: model.phase == .connected,
          attempt: attempt,
          userChoice: isConnectionExpanded
        )
      },
      set: { isConnectionExpanded = $0 }
    )
  }

  /// The pill: which phase the connection is in and, once up, which herdr is there.
  /// Identifiers are on the two lines, never the `VStack`.
  @ViewBuilder
  private func connectionPill(_ model: ConnectionModel) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      switch model.phase {
      case .connecting, .authenticating:
        HStack(spacing: 6) {
          ProgressView().controlSize(.mini)
          Text(model.phase == .connecting ? "Connecting…" : "Authenticating…")
        }
        .accessibilityIdentifier("connect.progress")
      case .connected:
        // `checkmark.circle` publishes its own element, labelled "Selected" with a trait. One
        // element, the word, and no trait.
        Label("Connected", systemImage: "checkmark.circle")
          .foregroundStyle(.green)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Connected")
          .accessibilityRemoveTraits(.isSelected)
          .accessibilityIdentifier("connect.connected")
        herdrLine(model)
      // Not "Not connected", which means never reached. The user needs to know the session
      // was lost.
      case .lost:
        Label("Connection lost", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
          .accessibilityIdentifier("connect.lost")
        // Why it went: a network change and a host that stopped answering need different
        // responses. On its own `Text`, never the `VStack`.
        if let reason = model.lossReason {
          Text(reason)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("connect.lostReason")
        }
      // A failure is not the resting state either. On a host key mismatch, a grey "Not
      // connected" would contradict the Problem section below.
      case .failed:
        Label("Could not connect", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
          .accessibilityIdentifier("connect.failedPill")
      case .idle:
        Label("Not connected", systemImage: "circle.dashed")
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("connect.disconnected")
      }
    }
  }

  /// Which herdr this host has, or which kind of "none", as the pill's second line.
  ///
  /// Not merged into one message: not installed, installed but not running, too old, and
  /// running but unreadable by this Driverr each have a different answer.
  /// `.statusUnreadable` points at Driverr rather than the host. `HerdrAvailability.message`
  /// says which in full.
  @ViewBuilder
  private func herdrLine(_ model: ConnectionModel) -> some View {
    if let availability = model.herdrAvailability {
      if availability.isReady {
        Text(availability.message)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("herdr.ready")
        // Under the working line, in the same words a lone refused core gets.
        if let refusal = availability.coreRefusal {
          Label(refusal, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.orange)
            .accessibilityIdentifier("herdr.coreRefused")
        }
      } else {
        // A glyph, so the line reads as a problem at a glance under a green "Connected".
        Label(availability.message, systemImage: "exclamationmark.triangle")
          .font(.footnote)
          .foregroundStyle(.orange)
          .accessibilityIdentifier("herdr.unavailable")
      }
    } else {
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("Looking for herdr…").font(.footnote)
      }
      .accessibilityIdentifier("herdr.checking")
    }
  }

  /// "Run a command", as rows behind the pill.
  @ViewBuilder
  private func commandRows(_ model: ConnectionModel) -> some View {
    Text("Run a command")
      .font(.footnote.weight(.medium))
      .foregroundStyle(.secondary)
    TextField("Command", text: $command)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        // Return runs it, by the same call as the Run button.
        .submitLabel(.go)
        .onSubmit { Task { await model.run(command) } }
        .accessibilityIdentifier("connect.command")
      Button("Run") { Task { await model.run(command) } }
      .accessibilityIdentifier("connect.run")

    if !model.output.isEmpty {
      Text(model.output)
        .font(.footnote.monospaced())
        .textSelection(.enabled)
        .accessibilityIdentifier("connect.output")
    }

    // A failed command's error shows here. It does not change the phase, because the link
    // is still healthy.
    if let failure = model.commandFailure {
      Label(failure.errorDescription ?? "The command could not be run.", systemImage: "xmark.octagon")
        .font(.footnote)
        .foregroundStyle(.orange)
        .accessibilityIdentifier("connect.commandError")
    }
  }

  /// What went wrong, and for the one recoverable case the way out.
  ///
  /// No Retry: the pill already offers Connect in `.failed`. A host key mismatch gets no
  /// retry of any kind.
  @ViewBuilder
  private func failureSection(_ failure: AppError) -> some View {
    Section("Problem") {
      Text(failure.errorDescription ?? "Something went wrong.")
        .accessibilityIdentifier("connect.error")

      // The only way past a mismatch; see `ConnectionModel.forgetHostKey()`. The confirmation
      // is at the screen's level; see `isConfirmingForget`.
      if case .hostKeyMismatch = failure {
        Button("Forget Host Key…", role: .destructive) {
          Task {
            trustedKey = await model?.trustedHostKey()
            isConfirmingForget = true
          }
        }
        .accessibilityIdentifier("connect.forgetKey")
      }
    }
  }

  /// Whether this host cannot be connected to with what is on screen.
  ///
  /// Only for a password host: a key host has a credential Driverr holds.
  private var isMissingAPassword: Bool {
    guard case .password = host.authMethod else { return false }
    return password.isEmpty
  }

  private func startConnecting(_ model: ConnectionModel) {
    guard !isMissingAPassword else { return }
    Task {
      await model.connect(
        password: password,
        persistence: rememberPassword ? .remember : .promptEveryTime
      )
      // Connect and Reconnect are connects the user started.
      await model.offerHooksIfNeeded()
    }
  }
}

extension View {
  /// Sets this screen in a column of readable width, on a surface wide enough to need one.
  ///
  /// Uses `TerminalSceneRoute.readableWidth`, the app's one reading measure. Three modifiers:
  /// cap the width, give the capped view the full column to centre in, and paint the strips
  /// either side, or the grouped `Form` looks like it floats. `isRegularWidth` is a parameter
  /// so `HostDetailColumnLayoutTests` can drive both answers.
  @ViewBuilder
  func readableDetailColumn(isRegularWidth: Bool) -> some View {
    if isRegularWidth {
      frame(maxWidth: CGFloat(TerminalSceneRoute.readableWidth))
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    } else {
      self
    }
  }
}

#if DEBUG

  /// The whole host screen, on the connect form with the password filled.
  ///
  /// Connect in the canvas really connects, through `FakeSSHTransport` and `FakeControl`,
  /// so each later phase is the real code path. It does not connect on its own; see
  /// `PreviewSupport.environment()`.
  private struct PreviewHostDetail: View {
    @State private var environment: AppEnvironment?

    var body: some View {
      Group {
        if let environment {
          NavigationStack {
            HostDetailView(host: PreviewSupport.host)
          }
          .environment(\.appEnvironment, environment)
        } else {
          ProgressView()
        }
      }
      // Async because `InMemoryPasswordStore` is an actor. Rendering before the store is
      // seeded would race the screen's own `.task`.
      .task { environment = await PreviewSupport.environment() }
    }
  }

  #Preview("Host screen") {
    PreviewHostDetail()
  }

  #Preview("Host screen — dark") {
    PreviewHostDetail()
      .preferredColorScheme(.dark)
  }

  /// The screen at the largest accessibility text size, where it has to scroll.
  #Preview("Host screen — accessibility XXXL") {
    PreviewHostDetail()
      .environment(\.dynamicTypeSize, .accessibility3)
  }

#endif
