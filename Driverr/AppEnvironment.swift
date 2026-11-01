import DriverrCore
import DriverrHC
import DriverrHerdr
import DriverrSSH
import DriverrTranscript
import SwiftUI
import UIKit

/// The app's live dependencies, injected through the SwiftUI environment.
///
/// A plain struct, so a test or preview substitutes fakes by building a different environment.
struct AppEnvironment {
  var identityStore: any IdentityStore
  var passwordStore: any PasswordStore
  var knownHostsStore: any KnownHostsStore
  var hostStore: any HostStore
  var settingsStore: any SettingsStore
  /// A factory: each connection gets its own transport, and a UI test gets a fake.
  var makeTransport: @Sendable () -> any SSHTransport
  /// How to drive herdr on a connected host. A factory over the transport, like
  /// `makeTransport`, so a UI test can supply `FakeControl`.
  var makeHerdrControl: @Sendable (any SSHTransport) async -> any HerdrControl
  /// How to read a pane's agent session file on a connected host.
  ///
  /// The live reader runs POSIX commands over an exec channel. The UI-test fake answers
  /// `TranscriptReader`'s two commands from `FakeTranscriptHost`, because both carry values
  /// built on the far side and cannot be keyed by exact string.
  var makeTranscriptReader: @Sendable (any SSHTransport) -> TranscriptReader
  /// Where a blocked pane becomes a notification. An instance, not a factory: there is one
  /// notification centre per app.
  var notifications: any NotificationScheduling
  /// The panes each host has already been announced, kept across launches. Here because a
  /// `BGAppRefreshTask` builds its own notifier from cold and must read the last set.
  var announcedPanes: any AnnouncedPaneStore
  /// Which pane each host was last opened on, so a Live Activity tap can resume it. It must
  /// outlive the process, because the tap that matters most launches the app from cold.
  var lastPanes: any LastPaneStore
  /// Where the fifteen-minute background refresh is registered and queued. A `-uiTesting`
  /// launch must register nothing; see `SilentBackgroundRefreshScheduler`.
  var backgroundRefresh: any BackgroundRefreshScheduling
  /// Where Continue in Background registers its handler and submits its request. A UI run
  /// must never submit, but `register` stays live; see `SilentBackgroundWatchScheduler`.
  var backgroundWatch: any BackgroundWatchScheduling
  /// Where a blocked pane becomes a Live Activity.
  ///
  /// One per process: the foreground poll and the background refresh reconcile against the
  /// same system list, and two drivers could each request a card for one host.
  var blockedPaneActivities: any BlockedPaneActivityDriving

  /// Where the per-host Start/Stop is kept, in its own blob. See
  /// `LiveActivityPreferenceStore`.
  var liveActivityPreferences: any LiveActivityPreferenceStore

  /// Where the chosen theme's accent is published for the Live Activity widget.
  ///
  /// Live in `ephemeral` too, unlike every other seam here. The widget runs in another
  /// process, so a capture of the real Lock Screen card is the only evidence the channel
  /// works, and a silent store would make that capture unable to fail. The cost is one key in
  /// the shared container, rewritten from stored settings on the next ordinary launch.
  var widgetTheme: any WidgetThemeStore

  /// One image upload on a live connection.
  ///
  /// Live, it is `DriverrSSH.ImageUploader` over an exec channel. A UI run needs a fake that
  /// takes its time, or the progress row is never on screen. Takes the coordinator because an
  /// uploader is built per upload, on whichever link is up; see
  /// `ConnectionModel.makeImageUpload(bytes:fileName:)`.
  var makeImageUpload:
    @Sendable (ConnectionCoordinator, Data, String) -> any ImageUploading

  /// What Driverr remembers about offering its agent hooks to each host.
  var hookOffers: any HookOfferStore

  /// The runners the hook check and install send their commands through. Per link, like
  /// `makeImageUpload`. A UI run gets `FakeHookHost`, because the fake transport has no `sh`.
  var makeHookRunners: @Sendable (ConnectionCoordinator) -> HookInstallRunners

  /// The runner the key install sends its command through. Per link. A UI run gets
  /// `FakeAuthorizedKeysHost`.
  var makeKeyInstallRunner: @Sendable (ConnectionCoordinator) -> CommandRunner

  /// Consent lives here, not at each call site, so nothing can save a password around it.
  var passwordCredentials: PasswordCredentials { PasswordCredentials(store: passwordStore) }

  /// The real thing: secrets in the Keychain, hosts on disk, SSH over the network.
  static let live = AppEnvironment(
    identityStore: KeychainIdentityStore(),
    passwordStore: KeychainPasswordStore(),
    knownHostsStore: UserDefaultsKnownHostsStore(),
    hostStore: UserDefaultsHostStore(),
    settingsStore: UserDefaultsSettingsStore(),
    makeTransport: { NIOSSHTransport() },
    // Discover the binary: an exec channel runs a non-login shell, whose PATH may lack
    // Homebrew's prefix or `~/.local/bin`. A host without herdr gets a control bound to the bare
    // name, whose first command reports `herdrNotInstalled`.
    //
    // herdr-core stays out of Release until #21, because every push to `main` uploads to
    // TestFlight and a core host cannot yet do everything a pane offers.
    makeHerdrControl: { transport in
      let run: CommandRunner = { try await transport.execChannel(command: $0) }
      #if DEBUG
      async let tui = CLIControl.discovering(run: run)
      async let core = CoreControl.discovering(transport: transport)
      return await CombinedControl.joining(tui: tui, core: core) ?? CLIControl(run: run)
      #else
      return await CLIControl.discovering(run: run) ?? CLIControl(run: run)
      #endif
    },
    makeTranscriptReader: { TranscriptReader(transport: $0) },
    notifications: LiveNotificationCenter(),
    announcedPanes: UserDefaultsAnnouncedPaneStore(),
    lastPanes: UserDefaultsLastPaneStore(),
    backgroundRefresh: LiveBackgroundRefreshScheduler(),
    backgroundWatch: LiveBackgroundWatchScheduler(),
    blockedPaneActivities: LiveBlockedPaneActivityDriver(),
    liveActivityPreferences: UserDefaultsLiveActivityPreferenceStore(),
    widgetTheme: AppGroupWidgetThemeStore(),
    makeImageUpload: { coordinator, bytes, fileName in
      ImageUploader(coordinator: coordinator, bytes: bytes, fileName: fileName)
    },
    hookOffers: UserDefaultsHookOfferStore(),
    // The read goes through `run(_:standardInput:)` with no input, for its idle deadline.
    // `run(_:)` has none, and the install sheet cannot be left while an install is out. The
    // connect-time check and the sheet's own check use the same runner. Unlike `run(_:)`,
    // it ends when its caller is cancelled, so leaving the host screen during the
    // connect-time check ends the check, and that connect makes no offer.
    makeHookRunners: { coordinator in
      HookInstallRunners(
        run: { try await coordinator.run($0, standardInput: Data()) },
        write: { try await coordinator.run($0, standardInput: $1) }
      )
    },
    // With no input, for the same deadline: the key install sheet cannot be left while it
    // is busy either. The install command reads nothing from its standard input.
    makeKeyInstallRunner: { coordinator in
      { try await coordinator.run($0, standardInput: Data()) }
    }
  )

  // From here to the `#else`, everything exists for UI tests, look passes, previews and the
  // screenshot tour. A Release build compiles none of it and reads no launch argument.
  #if DEBUG
  /// Everything in memory and no network, so each launch starts from a known state.
  ///
  /// The fake transport answers `uname -a` so the connect screen has something to render.
  /// Every other command returns a shell's 127, like the real one.
  static var ephemeral: AppEnvironment {
    AppEnvironment(
      identityStore: InMemoryIdentityStore(),
      // Seeded together, or not at all — see `isSeedingConnection`.
      passwordStore: InMemoryPasswordStore(seeded: seededPasswords),
      knownHostsStore: InMemoryKnownHostsStore(seeded: seededKnownHosts),
      // Empty unless a test asks for the seed. `LaunchUITests` asserts on the empty state.
      hostStore: InMemoryHostStore(seeded: seededHosts),
      settingsStore: InMemorySettingsStore(seededSettings),
      makeTransport: {
        let transport = FakeSSHTransport(
          responses: [
            "uname -a": CommandResult(
              standardOutput: "Linux workbox 6.6.0 #1 SMP aarch64 GNU/Linux\n",
              standardError: "",
              exitStatus: 0
            )
          ],
          // Refused while the launch's simulated outage lasts; see `outage`. Always `true`
          // otherwise.
          acceptsCredentials: !outage.isOn,
          // A key the install added and sshd does not accept. See `isKeyLoginRefused`.
          acceptsPrivateKeys: !isKeyLoginRefused,
          // A fake shell writes a prompt as soon as its PTY opens, as a real one does.
          ptyGreeting: ptyGreeting,
          // So a rotation test can see the channel was resized, not only the view. Off for the
          // store tour, where `[resized 55x50]` would look like leftover debug output.
          announcesResizes: !isDemoTranscript,
          // A tty echoes control bytes as `^C`, so a UI test can see the accessory row's Escape
          // and Control keys put real bytes on the channel.
          echoesControlAsCaret: true,
          // Off for the store tour, where the attach command's echo would land after the seeded
          // transcript. Tests keep it.
          echoesInput: !isDemoTranscript,
          // A host that accepts the connection and then says nothing. See `stalledHandshake`.
          handshakeStall: stalledHandshake,
          // The app supplies herdr-shaped frames, because `DriverrSSH` must not learn herdr's
          // protocol, and the bridge command carries `--cols`/`--rows`, so it cannot be keyed.
          // Observers answer too, or a warm pane would look like a cold open when switched to.
          streamResponder: { command in
            guard command.contains("terminal session control")
              || command.contains("terminal session observe")
            else { return nil }
            return AppEnvironment.bridgeFrame(for: command)
          }
        )
        AppEnvironment.armTheDrop(on: transport)
        AppEnvironment.armTheStreamEnd(on: transport)
        AppEnvironment.armTheHerdrShutdown(on: transport)
        AppEnvironment.armTheBridgeExitFailure(on: transport)
        AppEnvironment.armTheWorkingRow(on: transport)
        AppEnvironment.armTheGrowth(on: transport)
        AppEnvironment.armTheAnswerGrowth(on: transport)
        return transport
      },
      // The seeded session: three workspaces, a blocked agent that is not first, and two shell
      // panes. Scripted, so the second snapshot flips an idle pane to blocked and a UI test can
      // watch the sidebar update. Deterministic, so screenshots stay stable.
      makeHerdrControl: { _ in
        // A host that finished the handshake and then stalled on set-up. See `stalledSetUp`.
        if let stall = stalledSetUp { try? await Task.sleep(for: stall) }
        // An ordinary SSH host with no herdr.
        if isHerdrMissing { return FakeControl(tree: .empty, availability: .notInstalled) }
        // A core with no terminals. See `isEmptyCore`.
        if isEmptyCore {
          return FakeControl(
            tree: .empty,
            availability: .coreReady(version: "0.1.15"),
            canStartTerminal: true,
            startFailure: emptyCoreStartFailure
          )
        }
        if isFirstMessage { return firstMessageControl }
        // A new session herdr has named and Claude has not written yet.
        if isUnwrittenSession { return FakeControl(tree: FakeControl.treeWithUnwrittenSession) }
        // The same session with its agent working, which draws the fault.
        if isUnwrittenSessionWorking {
          return FakeControl(tree: FakeControl.treeWithUnwrittenSessionWorking)
        }
        // An agent that starts working while the reader is already in its chat.
        if isAgentStartsWorking { return agentStartsWorkingControl }
        // A session that stays at one blocked pane — see `isOneBlocked`.
        if isOneBlocked { return FakeControl(tree: FakeControl.seededTree) }
        // The seeded session with its blocked pane removed, so a calm card gets real counts
        // through the production path. See `isNothingBlocked`.
        if isNothingBlocked {
          return FakeControl(tree: FakeControl.treeWithoutTheBlockedPane)
        }
        // One agent failed and nothing blocked. See `isAgentError`.
        if isAgentError { return FakeControl(tree: FakeControl.treeWithAFailedAgent) }
        // A tree that does not move: a status change is a refresh trigger, so a scripted flip
        // would re-read through a different path.
        if isTranscriptGrowing { return FakeControl(tree: FakeControl.seededTree) }
        // A pane herdr reports as working while its file already carries the question.
        // Unscripted, so no flip to `blocked` supplies the chips instead.
        if isAskingWhileWorking { return FakeControl(tree: FakeControl.treeWithAWorkingAsker) }
        // The question is on the blocked pane's screen and not in its file. Unscripted, so the
        // pane stays blocked.
        if isScreenQuestion {
          return FakeControl(
            tree: FakeControl.seededTree, screen: FakeControl.askUserQuestionScreen)
        }
        // herdr drops the open pane from one poll and reports it again.
        if isPaneVanishingOnce { return FakeControl(script: FakeControl.vanishingPaneScript) }
        // The store tour's larger session, so its pane switcher shot is a full grid. The
        // seed's panes and its blocked pair are unchanged inside it.
        if isDemoTranscript { return FakeControl(script: FakeControl.storeTourScript) }
        return FakeControl(script: FakeControl.blockingScript)
      },
      makeTranscriptReader: { _ in
        TranscriptReader(run: AppEnvironment.launchRunner)
      },
      // Nothing from a UI run reaches the system notification centre. See
      // `SilentNotificationCenter`.
      notifications: SilentNotificationCenter(),
      // In memory, so one test's announced set cannot reach the next launch and make tests
      // order-dependent.
      announcedPanes: InMemoryAnnouncedPaneStore(),
      // In memory, and seeded, because a UI run has no earlier process that opened a pane.
      // `-uiTestingLastPane <paneID>` supplies the record.
      lastPanes: InMemoryLastPaneStore(seeded: seededLastPanes),
      // Registers no handler and queues nothing. See `SilentBackgroundRefreshScheduler`.
      backgroundRefresh: SilentBackgroundRefreshScheduler(),
      // Registers and never submits. See `SilentBackgroundWatchScheduler`.
      backgroundWatch: SilentBackgroundWatchScheduler(),
      // Silent unless the run asks for the real driver (`isLiveActivityDriven`). A Live
      // Activity outlives the process and the first request raises a consent sheet.
      blockedPaneActivities: isLiveActivityDriven
        ? LiveBlockedPaneActivityDriver() : SilentBlockedPaneActivityDriver(),
      // In memory, so one test's Stop cannot reach the next launch.
      liveActivityPreferences: InMemoryLiveActivityPreferenceStore(),
      // The live store, deliberately. See `widgetTheme`.
      widgetTheme: AppGroupWidgetThemeStore(),
      // Never the real uploader in a UI run: bytes sent are visible only while an upload is
      // running, so the fake is paced. See `PacedImageUpload`.
      makeImageUpload: { _, bytes, fileName in
        PacedImageUpload(
          totalBytes: bytes.count,
          fileName: fileName,
          step: isUploadStalled
            ? .seconds(5) : (isUploadSlow ? .milliseconds(400) : .milliseconds(20)),
          failure: isUploadFailing
            ? .commandFailed(exitStatus: 1, standardError: "No space left on device") : nil
        )
      },
      // In memory, so a decline cannot reach the next launch.
      hookOffers: InMemoryHookOfferStore(),
      makeHookRunners: { _ in hookFixture.runners },
      makeKeyInstallRunner: { _ in keyFixture.run }
    )
  }

  // MARK: - Installing a key

  /// `-uiTestingKeyInstallFails`: the host's `~/.ssh` is on a read-only file system, so the
  /// install fails with the message a real host gives.
  static var isKeyInstallFailing: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingKeyInstallFails")
  }

  /// `-uiTestingKeyLoginRefused`: the fake transport refuses every private key but accepts
  /// the password, so the install works and the key login does not.
  static var isKeyLoginRefused: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingKeyLoginRefused")
  }

  /// `-uiTestingSlowKeyInstall`: the fake host takes 1.5 s to answer, so a capture can show
  /// the installing state.
  static var isKeyInstallSlow: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingSlowKeyInstall")
  }

  /// One fake `authorized_keys` for the whole process, holding one key from another device.
  static let keyFixture = FakeAuthorizedKeysHost(
    lines: ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeLaptopKeyForUITestsOnly laptop"],
    failure: isKeyInstallFailing ? (74, "sh: line 9: /home/uitest/.ssh/authorized_keys: Read-only file system") : nil,
    delay: isKeyInstallSlow ? .milliseconds(1500) : .zero
  )

  // MARK: - Driverr's agent hooks

  /// `-uiTestingHookOffer`: the host lacks Driverr's hooks, so a connect offers them.
  /// Otherwise the fake host has them, so the offer sheet stays off every class that connects.
  static var isHookOffered: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingHookOffer")
  }

  /// `-uiTestingHookChangedOnce`: the settings file changes between the first read and its
  /// write, as when Claude Code rewrites it mid-install. The first install fails and Try
  /// Again succeeds.
  static var isHookChangedOnce: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingHookChangedOnce")
  }

  /// The fake host's settings file before an install. It carries a secret-shaped value so a
  /// UI test can assert the file never reaches the screen.
  static let hookFixtureSettings = """
    {
      "env": {
        "EXAMPLE_API_KEY": "\(hookFixtureSecret)"
      },
      "hooks": {
        "SessionStart": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "herdr hook session-start"
              }
            ]
          }
        ]
      }
    }

    """

  static let hookFixtureSecret = "sk-uitest-NOT-A-REAL-KEY-644"

  /// One fake host for the whole process, so an install is seen by the next check.
  static let hookFixture: FakeHookHost = {
    let integration = AgentIntegration.claudeCode
    let installed = (try? integration.installing(into: hookFixtureSettings)) ?? hookFixtureSettings
    return FakeHookHost(
      integration: integration,
      text: isHookOffered ? hookFixtureSettings : installed,
      changeBeforeWrite: isHookChangedOnce ? hookFixtureSettings + "\n" : nil
    )
  }()

  /// `-uiTestingSlowUpload`: the fake takes about 3.2 seconds.
  ///
  /// Slower than XCUITest's own element lookups, or the upload finishes before the assertion
  /// reads the byte count. Without the flag the fake is still paced, so the row exists for at
  /// least a frame.
  static var isUploadSlow: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingSlowUpload")
  }

  /// `-uiTestingStalledUpload`: an upload that does not finish on its own.
  ///
  /// For the cancel test, whose lookups before Remove can outlast the paced upload. Slowing the
  /// shared fixture instead would make every other test wait and only move the race. Only the
  /// test that cancels asks for this.
  static var isUploadStalled: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingStalledUpload")
  }

  /// `-uiTestingUploadFails`: the fake reports progress and then the host refuses, so the
  /// inline failure is reachable without an unreachable host.
  static var isUploadFailing: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingUploadFails")
  }

  /// `-uiTestingPickedImage`: the bytes Photos would have handed over.
  ///
  /// XCUITest cannot drive the out-of-process Photos picker, so the composer is handed these
  /// bytes, exercising everything after the pick. Generated rather than bundled, because an
  /// asset means a `project.pbxproj` change. 2400×1600, so it exceeds the 1568 px cap and the
  /// downscale runs.
  static var seededPickedImage: Data? {
    guard isUITesting,
      ProcessInfo.processInfo.arguments.contains("-uiTestingPickedImage")
    else { return nil }
    let size = CGSize(width: 2400, height: 1600)
    let renderer = UIGraphicsImageRenderer(size: size)
    let image = renderer.image { context in
      // Fixed components, never a semantic colour: `systemTeal` differs in dark mode, which
      // would make every byte count depend on the appearance.
      UIColor(red: 0.13, green: 0.77, blue: 0.79, alpha: 1).setFill()
      context.fill(CGRect(origin: .zero, size: size))
      UIColor(red: 0.35, green: 0.34, blue: 0.84, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
    }
    return image.pngData()
  }

  /// The fixture's runner, optionally slowed to a real host's speed.
  ///
  /// `FakeTranscriptHost` answers instantly, so the chat is `.ready` on its first frame. On a
  /// phone the transcript arrives after the view is up. `-uiTestingSlowTranscript` makes the
  /// fake take its time, so a UI test runs the device's path.
  private static var fixtureRunner: CommandRunner {
    let run = transcriptFixture.run
    guard isTranscriptSlow else { return run }
    return { command in
      try await Task.sleep(for: .milliseconds(900))
      return try await run(command)
    }
  }

  /// Which runner this launch serves transcript reads through, chosen in one place.
  private static var launchRunner: CommandRunner {
    if isFirstMessage { return firstMessageRunner }
    if isTranscriptGrowing { return growingRunner }
    if isScreenQuestionHandover { return handoverRunner }
    if isAnswerGrowing { return growingAnswerRunner }
    return fixtureRunner
  }

  // MARK: - A conversation that grows while you read it

  /// Whether this launch's session file gains a turn a few seconds after the reader arrives.
  ///
  /// Every other transcript fixture is fixed, so a chat that never re-read would pass them.
  /// This one changes with nobody touching the phone. The herdr tree stays still, serving the
  /// unscripted `seededTree`, because a status change is already a refresh trigger and would
  /// prove nothing about the watcher.
  static var isTranscriptGrowing: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingGrowingTranscript")
  }

  /// How long after the pane's stream opens the extra turn appears.
  ///
  /// Measured from the stream, not from the first transcript read, which happens when the
  /// workspace appears. A delay from there would eat into the margin on a slow machine and fail
  /// the test's precondition. Eight seconds leaves the open and the slow-fixture read finished
  /// first.
  private static let growthDelay: Duration = .seconds(8)

  /// The pane whose chat the growth test opens, and the terminal it streams: `w1:p2`, the one
  /// pane with an `agent_session`. Not `armTheWorkingRow`'s pane, or each fixture would arm on
  /// the other's stream.
  private static let growingPaneTerminalID = "term_w1p2"

  /// One arming per launch, not per connection: `makeTransport` runs again on every reconnect.
  private static let growthIsArmed = OneShot()

  /// Whether the file has grown yet. Read by the transcript runner, opened by `armTheGrowth`.
  private static let growth = GrowthGate()

  /// Arms the extra turn, if this launch asked for one.
  ///
  /// Hooked on the pane's stream, because opening the pane is the only thing that sends
  /// `herdr terminal session observe term_w1p2`. The deadline only makes a build that never
  /// streams the pane fail on the test's assertion instead of hanging here.
  private static func armTheGrowth(on transport: FakeSSHTransport) {
    guard isTranscriptGrowing || isScreenQuestionHandover, growthIsArmed.take() else { return }
    Task {
      let deadline = ContinuousClock.now + .seconds(60)
      while ContinuousClock.now < deadline {
        let opened = await transport.streamedCommands.contains {
          $0.contains(growingPaneTerminalID)
        }
        if opened { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      try? await Task.sleep(for: growthDelay)
      await growth.open()
    }
  }

  /// The seeded conversation, then the same conversation with one more answer.
  ///
  /// Built from `seededTranscript`'s turns, so the earlier turns keep their record ids and the
  /// re-read is a longer conversation, not a different one.
  static let grownTranscript = FakeTranscriptHost(
    sessionID: "3f8c1d20-0000-4000-8000-000000000002",
    turns: (seededTranscript.sessions.first?.turns ?? [])
      + [
        .init(
          speaker: .assistant,
          text: "Migration done. Both call sites now await the pool.",
          secondsAgo: 1
        )
      ]
  )

  /// Serves the seeded conversation, and the grown one once `armTheGrowth` has opened. No herdr
  /// hook: only the chat asking can bring the new turn to the screen.
  private static var growingRunner: CommandRunner {
    { command in
      let grown = await growth.isOpen
      if isTranscriptSlow { try await Task.sleep(for: .milliseconds(900)) }
      return try await (grown ? grownTranscript : seededTranscript).run(command)
    }
  }

  // MARK: - An answer that grows in place while you read it

  /// Whether this launch's final answer gets longer a few seconds after the reader arrives,
  /// keeping its record id.
  ///
  /// Unlike the growing transcript, which appends a turn with a new id, this replaces the last
  /// turn at the same index. `FakeTranscriptHost` ids are `"\(sessionID)-\(index)"`, so the id
  /// is unchanged and only the text differs. A snapshot diff cannot see that;
  /// `ChatCollectionView.Coordinator.apply` has to find it through `turnsByID`.
  static var isAnswerGrowing: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingGrowingAnswer")
  }

  /// One arming per launch, as with `growthIsArmed`.
  private static let answerGrowthIsArmed = OneShot()

  /// Whether the answer has grown yet. Read by the transcript runner, opened by
  /// `armTheAnswerGrowth`.
  private static let answerGrowth = GrowthGate()

  /// Arms the growing answer, if this launch asked for one. Anchored to the pane's stream and
  /// delayed by `growthDelay`, for the reasons on those two.
  private static func armTheAnswerGrowth(on transport: FakeSSHTransport) {
    guard isAnswerGrowing, answerGrowthIsArmed.take() else { return }
    Task {
      let deadline = ContinuousClock.now + .seconds(60)
      while ContinuousClock.now < deadline {
        let opened = await transport.streamedCommands.contains {
          $0.contains(growingPaneTerminalID)
        }
        if opened { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      try? await Task.sleep(for: growthDelay)
      await answerGrowth.open()
    }
  }

  /// The final answer as this launch first serves it.
  ///
  /// It opens with `seededTranscript`'s own two lines, which `SessionTreeUITests` quotes, so the
  /// grown turn is recognisably the same one. The paragraphs after them make the conversation
  /// taller than one viewport; otherwise a drag moves nothing and the reader cannot be scrolled
  /// back, which the test needs.
  private static let answerBeforeGrowth = """
    The pool is async now. Migrating the two call sites changes the public API.
    Proceed with the migration?

    While you decide, here is what the migration touches. The first call site is the session \
    opener, which acquires a connection and holds it for the life of the request. It is the one \
    that blocked, and it is the reason the pool was written synchronously in the first place.

    The second call site is the health check. It takes a connection, runs a single statement and \
    gives it straight back, so it never held one long enough to matter — but it shares the \
    acquire path, so it changes with the first one whether or not anybody wanted it to.

    Both of them are public, which is what makes this an API change rather than an implementation \
    detail. Anything calling them has to await, and anything awaiting has to be in an async \
    context of its own, so the change walks outward until it reaches something that already was.
    """

  /// The same answer once it has grown, built by concatenation so everything already read is
  /// still there in order. Taller than the viewport, so a chat that never moved cannot pass.
  private static let answerAfterGrowth =
    answerBeforeGrowth + "\n\n"
    + """
      The tests are the part that will take the longest. There are forty of them across the two \
      modules, and about half construct a pool inline and use it in the same expression, which \
      does not survive the change without being split into two statements.

      The migration is mechanical after that. The type signatures carry the whole of it, so the \
      compiler names every site that has to move and nothing is left to be found at run time.

      There is one case the compiler will not name. The pool is also used from a \
      completion-handler API that predates the async work, and that one has to bridge rather than \
      await, which is a different change with a different shape.

      I have left that one alone. Bridging it here would mean two migrations in one change, and \
      the second one has a question of its own about who owns the continuation.

      There is no hurry on it either. The completion-handler API is used by one caller, it is not \
      on the path this change is about, and leaving it synchronous costs nothing until somebody \
      wants to await it.

      Say the word and I will start with the session opener.
      """

  /// The conversation served before the answer grows: `seededTranscript` with the final turn
  /// replaced at the same index, so every record id is unchanged. See `isAnswerGrowing`.
  static let preGrownAnswerTranscript = FakeTranscriptHost(
    sessionID: "3f8c1d20-0000-4000-8000-000000000002",
    turns: Array((seededTranscript.sessions.first?.turns ?? []).dropLast())
      + [
        .init(
          speaker: .assistant,
          text: answerBeforeGrowth,
          secondsAgo: 240,
          durationMs: 15_228
        )
      ]
  )

  /// The same conversation after the answer has grown, with the same record ids throughout.
  static let grownAnswerTranscript = FakeTranscriptHost(
    sessionID: "3f8c1d20-0000-4000-8000-000000000002",
    turns: Array((seededTranscript.sessions.first?.turns ?? []).dropLast())
      + [
        .init(
          speaker: .assistant,
          text: answerAfterGrowth,
          secondsAgo: 240,
          durationMs: 15_228
        )
      ]
  )

  /// Serves the answer short, then long once `armTheAnswerGrowth` has opened. No herdr hook,
  /// for `growingRunner`'s reason.
  private static var growingAnswerRunner: CommandRunner {
    { command in
      let grown = await answerGrowth.isOpen
      if isTranscriptSlow { try await Task.sleep(for: .milliseconds(900)) }
      return try await (grown ? grownAnswerTranscript : preGrownAnswerTranscript).run(command)
    }
  }

  // MARK: - An agent that starts working while you read

  /// Whether this launch flips the chat's own pane from idle to working a few seconds after
  /// the chat opens.
  ///
  /// The working line is the transcript's last row, so an agent that starts while the reader
  /// rests at the end puts a short row just under the fold, inside
  /// `ChatEndProximity.jumpTolerance`. No other fixture produces that.
  ///
  /// Not a `FakeControl` script, which indexes by snapshot count and would race the connect.
  /// The flip is driven off the pane's terminal stream; see `armTheWorkingRow`.
  static var isAgentStartsWorking: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingAgentStartsWorking")
  }

  /// The herdr fake this launch uses, held here because `armTheWorkingRow` advances it. One
  /// instance for every host, never reset: fine for one seeded host and a fresh process per
  /// test.
  static let agentStartsWorkingControl = FakeControl(tree: FakeControl.treeWithIdleAgent)

  /// The pane whose chat these tests open, and the terminal it streams. Opening that pane is
  /// the only thing that sends `herdr terminal session observe term_w1p1`.
  private static let chatPaneTerminalID = "term_w1p1"

  /// One flip per launch, not per connection: `makeTransport` runs again on every reconnect.
  private static let workingRowIsArmed = OneShot()

  /// Arms the idle-to-working flip, if this launch asked for one.
  ///
  /// Anchored to the pane's own stream. The first transcript read is the wrong hook: the
  /// Needs-you row reads it when the workspace appears, long before the pane opens, and both
  /// panes share a directory so the command cannot tell them apart.
  /// `FakeSSHTransport.streamedCommands` records the stream opening, as `armTheDrop` uses.
  ///
  /// Ten seconds after the stream opens, so the open and the slow-fixture read finish first.
  /// With the three-second poll, the row appears 10 to 13 seconds after the pane opens. Six
  /// was too close to a test's own idle check. The deadline only makes a build that never
  /// streams the pane fail on the test's assertion instead of hanging.
  private static func armTheWorkingRow(on transport: FakeSSHTransport) {
    guard isAgentStartsWorking, workingRowIsArmed.take() else { return }
    Task {
      let deadline = ContinuousClock.now + .seconds(30)
      while ContinuousClock.now < deadline {
        let opened = await transport.streamedCommands.contains {
          $0.contains(chatPaneTerminalID)
        }
        if opened { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      try? await Task.sleep(for: .seconds(10))
      await agentStartsWorkingControl.update(to: FakeControl.seededTree)
    }
  }

  /// Whether this launch's herdr session holds exactly one blocked pane, and keeps it.
  ///
  /// The ordinary `FakeControl.blockingScript` flips a second agent to blocked a poll or two
  /// in, so the badge would read 1 and then 2 and `SessionTree.loneBlockedPane` would go `nil`
  /// on a timing race. This serves the unscripted `seededTree`, whose one blocked pane is
  /// `w1:p2`.
  static var isOneBlocked: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingOneBlocked")
  }

  /// Whether this launch's herdr session holds nothing blocked, and keeps it that way
  /// (`-uiTestingNothingBlocked`).
  ///
  /// The calm card's fixture. `treeWithoutTheBlockedPane` is `seededTree` minus `w1:p2`, so the
  /// card's working, idle and shell counts are the seeded session's.
  static var isNothingBlocked: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingNothingBlocked")
  }

  /// Whether one agent in this launch's herdr session has failed, with nothing blocked
  /// (`-uiTestingAgentError`), so a capture can show the `error` badge.
  static var isAgentError: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingAgentError")
  }

  /// Whether the fixture should answer at a real host's speed rather than instantly.
  static var isTranscriptSlow: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingSlowTranscript")
  }

  /// Whether herdr drops the open pane from exactly one snapshot and reports it again.
  ///
  /// A tree without the pane turns `TerminalScreen.isShowingChat` false for one poll, so the
  /// chat is destroyed and rebuilt under the reader. See `FakeControl.vanishingPaneScript`.
  static var isPaneVanishingOnce: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingPaneVanishesOnce")
  }

  // MARK: - A pane nobody has spoken to yet

  /// Whether this launch serves a pane whose agent has never been messaged.
  ///
  /// The agent reports no `agent_session` and the directory holds no session file, so the chat
  /// shows `.noSessionFiles`. The first reply brings both into existence, as with a real agent,
  /// which writes the file before herdr reports the session.
  static var isFirstMessage: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingFirstMessage")
  }

  /// The herdr fake this launch uses, held here so the transcript runner can see what was
  /// sent. `FakeControl` records every send, so the two fakes agree on whether the first reply
  /// went without a second flag.
  ///
  /// One instance for every host, never reset within a process. That holds for every launch
  /// using the flag: one seeded host, a fresh process per test.
  static let firstMessageControl = FakeControl(tree: FakeControl.treeWithUnstartedAgent)

  /// Whether this launch serves a pane whose agent has named a new session with no file yet.
  ///
  /// The directory holds only the older session, so `w1:p2`'s chat shows
  /// `.reportedSessionMissing` and the wait notice. Nothing arrives later; a hosted test
  /// covers the file landing.
  static var isUnwrittenSession: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingUnwrittenSession")
  }

  /// `isUnwrittenSession` with the agent working. A working agent has had its first prompt, so
  /// the chat shows the missing-file fault instead of the wait.
  static var isUnwrittenSessionWorking: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingUnwrittenSessionWorking")
  }

  /// Serves an empty directory until the first reply lands, then the conversation it started,
  /// and moves the tree on at the same moment.
  ///
  /// The tree is advanced from here because `FakeControl` has no send hook and the transcript
  /// is re-read after every send (`PaneTranscriptModel.recordSend`). That is one round trip
  /// later than real herdr, which widens the window this fixture reproduces.
  private static var firstMessageRunner: CommandRunner {
    { command in
      let hasReplied = await !firstMessageControl.sent.isEmpty
      if hasReplied { await firstMessageControl.update(to: FakeControl.seededTree) }
      if isTranscriptSlow { try await Task.sleep(for: .milliseconds(900)) }
      let host =
        hasReplied
        ? seededTranscript
        : FakeTranscriptHost(sessions: [])
      return try await host.run(command)
    }
  }

  /// Whether this launch pretends the host has no herdr. Specifically `.notInstalled`, because
  /// each kind of absence has its own message and a generic one would test nothing.
  static var isHerdrMissing: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingNoHerdr")
  }

  /// Whether this launch pretends the host is a core with no terminals (`-uiTestingEmptyCore`),
  /// so the empty state offers New Terminal.
  static var isEmptyCore: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingEmptyCore")
  }

  /// What that core says to a start, under `-uiTestingEmptyCoreRefuses`, so a capture can show
  /// the failure in the core's own words.
  static var emptyCoreStartFailure: AppError? {
    guard ProcessInfo.processInfo.arguments.contains("-uiTestingEmptyCoreRefuses") else {
      return nil
    }
    return .herdrCommandFailed(
      reason: #"cannot start "/bin/zsh": No such file or directory (os error 2)"#)
  }

  /// UI tests must not touch the real Keychain or the network. The Keychain persists across
  /// runs, so "the list is empty" would depend on an earlier run.
  static var forLaunch: AppEnvironment {
    isUITesting ? .ephemeral : .live
  }

  /// Whether a run wants the Continue in Background readout on screen.
  ///
  /// Its own flag, like `isLiveActivityDriven`, so the caption stays out of other captures. It
  /// shows whether the plain continued-processing identifier registers; see
  /// `BackgroundWatchProbe`.
  static var isBackgroundWatchProbed: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingBackgroundWatchProbe")
  }

  /// Whether this process is a UI run. `DriverrApp` reads it to skip installing the
  /// notification delegate.
  static var isUITesting: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTesting")
  }

  /// The settings a UI run or a `scripts/look.sh` pass starts with.
  ///
  /// The theme is seedable because the default theme's ANSI 4 is the system blue, so an accent
  /// that follows the theme cannot be seen changing on it. `Theme.bundled(id:)` resolves a
  /// misspelled name to the default theme rather than crashing; the settings screen shows
  /// which theme is active.
  ///
  /// `-uiTestingWrapOff` exists because `scripts/look.sh` taps identifiers, and tapping a
  /// `Toggle`'s identifier does not flip it (see `setSwitch`), so a look pass cannot turn
  /// wrapping off.
  static var seededSettings: TerminalSettings {
    let arguments = ProcessInfo.processInfo.arguments
    let wraps = !arguments.contains("-uiTestingWrapOff")
    guard let flag = arguments.firstIndex(of: "-uiTestingTheme"),
      arguments.index(after: flag) < arguments.endIndex
    else { return TerminalSettings(wrapsScreenLines: wraps) }
    return TerminalSettings(
      themeID: Theme.bundled(id: arguments[arguments.index(after: flag)]).id,
      wrapsScreenLines: wraps
    )
  }

  /// Whether this launch starts with a host already in the list, so tests not about the
  /// add-host form skip it. Each test still gets a fresh process and identical state.
  static var isSeedingHost: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingSeedHost")
  }

  /// Whether this launch starts with a second host in the list, which the pane switcher needs.
  ///
  /// Only beside `-uiTestingSeedHost`, so the list is workbox then beta and
  /// `connectedHostApp`'s `hosts.row` `firstMatch` still lands on workbox.
  static var isSeedingASecondHost: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingSecondHost")
  }

  /// The hosts this launch starts with, in list order.
  private static var seededHosts: [DriverrCore.Host] {
    seededHosts(
      seedsHost: isSeedingHost,
      seedsSecondHost: isSeedingASecondHost,
      isStoreTour: isDemoTranscript
    )
  }

  /// `seededHosts` for one set of flags, so a test can check that the store tour's hosts reach
  /// no other launch. workbox is always first, because `hosts.row` `firstMatch` must land on
  /// it.
  static func seededHosts(
    seedsHost: Bool,
    seedsSecondHost: Bool,
    isStoreTour: Bool
  ) -> [DriverrCore.Host] {
    guard seedsHost else { return [] }
    var hosts: [DriverrCore.Host] = [.uiTestSeed]
    if seedsSecondHost { hosts.append(.uiTestSecondSeed) }
    if isStoreTour { hosts += storeTourHosts }
    return hosts
  }

  /// The hosts the store tour lists under workbox, so its `hosts` capture is a list and not
  /// one row.
  /// Never connected: they have no password and no host key.
  static let storeTourHosts: [DriverrCore.Host] = [
    DriverrCore.Host(
      id: UUID(uuidString: "00000000-0000-0000-0000-00000000D7A1")!,
      name: "studio",
      hostname: "10.1.0.12",
      username: "carson"
    ),
    DriverrCore.Host(
      id: UUID(uuidString: "00000000-0000-0000-0000-00000000D7A2")!,
      name: "homelab",
      hostname: "10.1.0.30",
      username: "carson"
    ),
  ]

  /// The passwords `-uiTestingConnected` saves; see `isSeedingConnection`. Both seeded hosts,
  /// so the second connects on appearance like the first instead of stopping at a password
  /// field.
  private static var seededPasswords: [UUID: String] {
    guard isSeedingConnection else { return [:] }
    var seeded = [DriverrCore.Host.uiTestSeed.id: "hunter2"]
    if isSeedingASecondHost { seeded[DriverrCore.Host.uiTestSecondSeed.id] = "hunter2" }
    return seeded
  }

  /// The witness `seededLastPanes` uses for a pane id no fixture tree reports. No tree reports
  /// it, so the resume fails on both the pane id and the witness, the stale-record fallback.
  private static let syntheticLastPaneWitness = "term_uiTestingNoSuchPane"

  /// The record `-uiTestingLastPane <paneID>` puts on the seeded host.
  ///
  /// A UI run's `LastPaneStore` is in memory, so there is no earlier process to have opened a
  /// pane; without a seed only the fallback route could be tested. Keyed to the seeded host,
  /// the host `-uiTestingOpenURL` names. Read positionally and gated on `-uiTesting`, like
  /// `launchPaneID`.
  ///
  /// The witness comes from `FakeControl.seededTree`, never from the flag, so a test cannot
  /// seed a witness the tree disagrees with. A pane id no fixture answers to still seeds a
  /// record, carrying `syntheticLastPaneWitness`, because that stale record is what
  /// `testAHostURLWhoseRememberedPaneIsGoneLandsOnTheTree` drives.
  private static var seededLastPanes: [UUID: LastPaneRecord] {
    let arguments = ProcessInfo.processInfo.arguments
    guard arguments.contains("-uiTesting"),
      let flag = arguments.firstIndex(of: "-uiTestingLastPane"),
      arguments.index(after: flag) < arguments.endIndex
    else { return [:] }
    let paneID = arguments[arguments.index(after: flag)]
    guard !paneID.isEmpty else { return [:] }
    let witness =
      FakeControl.seededTree.pane(id: paneID)?.sessionWitness ?? syntheticLastPaneWitness
    return [DriverrCore.Host.uiTestSeed.id: LastPaneRecord(paneID: paneID, witness: witness)]
  }

  /// Whether this launch restores the host the last one was left on.
  ///
  /// On in production, off under `-uiTesting` unless a test asks. Otherwise a selection saved
  /// by the previous test would open a host screen where other classes expect the host list.
  /// Writing the selection is not gated, because the relaunch test needs its first launch to
  /// record one.
  static var isRestoringSelection: Bool {
    let arguments = ProcessInfo.processInfo.arguments
    guard arguments.contains("-uiTesting") else { return true }
    return arguments.contains("-uiTestingRestoreSelection")
  }

  /// Whether this launch drives the real Live Activity driver (`-uiTestingLiveActivity`).
  ///
  /// Off by default. With `-uiTestingSeedHost -uiTestingConnected -uiTestingOneBlocked
  /// -uiTestingLiveActivity`, the app connects on appearance and the one blocked pane reaches
  /// the real foreground feed, which requests a real card. Unlike `-debugBlockedActivity`, it
  /// exercises the production path. Gated on `-uiTesting`.
  static var isLiveActivityDriven: Bool {
    let arguments = ProcessInfo.processInfo.arguments
    return arguments.contains("-uiTesting") && arguments.contains("-uiTestingLiveActivity")
  }

  /// Whether the terminal keeps its key row with a hardware keyboard attached.
  ///
  /// Off in production, on under `-uiTesting`. The simulator's hardware keyboard is the Mac's,
  /// so `GCKeyboard.coalesced` is never nil during a run, and the hiding rule would remove the
  /// row from every UI test. The hidden branch is covered by `KeyboardNoticeModelTests` and by
  /// hand on a device.
  static var keepsKeyboardAccessoryRow: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTesting")
  }

  /// The pane `-uiTestingOpen <paneID>` asked this launch to open.
  ///
  /// The way a UI test drives `TerminalPresenter.open(hostID:paneID:)`. With
  /// `-uiTestingConnected` it covers resolving the id, connecting and presenting. Read from
  /// `DriverrApp.init`, before the presenter is configured, which is the route a notification
  /// tap takes. Gated on `-uiTesting` and read positionally; `w1:p1` is stable in
  /// `FakeControl`.
  static var launchPaneID: String? {
    let arguments = ProcessInfo.processInfo.arguments
    guard arguments.contains("-uiTesting"),
      let flag = arguments.firstIndex(of: "-uiTestingOpen"),
      arguments.index(after: flag) < arguments.endIndex
    else { return nil }
    return arguments[arguments.index(after: flag)]
  }

  /// The URL `-uiTestingOpenURL <url>` asked this launch to route.
  ///
  /// XCUITest cannot tap a Lock Screen card or the Dynamic Island, so a launch argument is the
  /// only way in. It does not cover SwiftUI's URL delivery, `CFBundleURLTypes` or
  /// LaunchServices; an `xcrun simctl openurl` capture covers those. Read from `DriverrApp.init`
  /// so it takes the pre-configure route a card tap takes. Gated and read like `launchPaneID`.
  static var launchOpenURL: URL? {
    let arguments = ProcessInfo.processInfo.arguments
    guard arguments.contains("-uiTesting"),
      let flag = arguments.firstIndex(of: "-uiTestingOpenURL"),
      arguments.index(after: flag) < arguments.endIndex
    else { return nil }
    return URL(string: arguments[arguments.index(after: flag)])
  }

  /// Whether this launch starts with the seeded host's key trusted and its password saved.
  ///
  /// Removes the connect ceremony from tests not about connecting, as `isSeedingHost` removes
  /// the form. It seeds what `PreviewSupport.environment()` seeds: the key, or TOFU would raise
  /// a prompt, and the password, which `HostDetailView` fills from the store. The validator
  /// still runs; only the prompt goes.
  ///
  /// A seeded password means `HostDetailView` connects on appearance, so
  /// `XCTestCase.connectedHostApp` waits for `connect.connected` and taps nothing. Not for
  /// tests about connecting: `HostConnectUITests` and `ToggleUITests` drive the flow by hand.
  static var isSeedingConnection: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingConnected")
  }

  /// How long the fake sits in the handshake before answering, when a launch asks.
  ///
  /// Without it, Cancel under "Connecting…" is on screen for no frames and no test can reach
  /// it. Thirty seconds outlasts any test and also
  /// `ConnectionCoordinator.defaultHandshakeDeadline`, so an untouched launch ends on the
  /// deadline rather than hanging.
  static var stalledHandshake: Duration? {
    ProcessInfo.processInfo.arguments.contains("-uiTestingSlowHandshake") ? .seconds(30) : nil
  }

  /// How long the fake sits in the connected set-up before answering, when a launch asks.
  ///
  /// The set-up is `command -v herdr` and `herdr --version` after the handshake. This opens
  /// the window where the host is reached but not answering, when Connecting and Cancel must
  /// still show. Sixty seconds, longer than `setUpDeadline`, so only Cancel or the deadline can
  /// end it and the test never races the fixture.
  static var stalledSetUp: Duration? {
    ProcessInfo.processInfo.arguments.contains("-uiTestingStalledSetUp") ? .seconds(60) : nil
  }

  /// Whether this launch starts with the wrong key trusted for the seeded host.
  ///
  /// The only way to reach a host-key mismatch on a simulator: `FakeSSHTransport` always
  /// presents `defaultHostKey`, so the stale side has to be the store's, which is also what a
  /// rebuilt server looks like. Not combined with `-uiTestingConnected`, which seeds the same
  /// dictionary with another key. The mismatch test enters the password by hand.
  static var isSeedingAChangedHostKey: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingHostKeyChanged")
  }

  /// A stale, obviously-different key for the changed-key fixture.
  static let staleHostKey = SSHHostKey(
    algorithm: "ssh-ed25519",
    blob: Data("driverr-fake-host-key-before-the-rebuild".utf8)
  )

  private static var seededKnownHosts: [String: SSHHostKey] {
    let hostname = DriverrCore.Host.uiTestSeed.hostname
    if isSeedingAChangedHostKey { return [hostname: staleHostKey] }
    guard isSeedingConnection else { return [:] }
    var seeded = [hostname: FakeSSHTransport.defaultHostKey]
    // The store is keyed by hostname, so the second seed has its own address (see
    // `Host.uiTestSecondSeed`). Without this the second host would raise a TOFU prompt.
    if isSeedingASecondHost {
      seeded[DriverrCore.Host.uiTestSecondSeed.hostname] = FakeSSHTransport.defaultHostKey
    }
    return seeded
  }

  /// Whether this launch replays a demo session instead of a bare prompt.
  ///
  /// For the App Store screenshot tour. The test shell prints a two-line prompt and
  /// `[resized WxH]` lines, which look like leftover debug output in store art. A separate
  /// flag, because `TerminalUITests` parses those resize lines and reads `carson@workbox` from
  /// the greeting.
  static var isDemoTranscript: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingDemoTranscript")
  }

  /// The conversation every Claude pane in the seeded session holds.
  ///
  /// One fixture covers both provenance tiers. Its `sessionID` is the seeded tree's
  /// `agent_session`, so `w1:p2` resolves tier 1, reported by herdr. Other Claude panes have no
  /// reported session and resolve tier 2 from their directory. The Gemini pane resolves
  /// neither and gets the unsupported-agent sentence; the Codex pane uses
  /// `seededCodexRollout`.
  ///
  /// The same conversation as `demoTranscript`. The store tour shoots the terminal and the chat
  /// on one launch, and its chat is `storeTourTranscript`, which is built from this one.
  /// Timestamps are relative to when the command runs, so the header always reads "written 4m
  /// ago".
  static let seededTranscript = FakeTranscriptHost(
    // `w1:p2`'s `AgentSession` in `FakeControl.seededTree`. If that changes, this silently
    // exercises tier 2 instead, which is why the UI test asserts on the header's words.
    sessionID: "3f8c1d20-0000-4000-8000-000000000002",
    turns: [
      .init(speaker: .human, text: "make the connection pool async", secondsAgo: 900),
      // More calls than kinds, so the closed row says "7 tool calls · Read ×5 · …". The calls
      // are the ones `demoTranscript` shows, in order.
      .init(
        speaker: .tools([
          ToolCall(name: "Read", target: "Cargo.toml"),
          ToolCall(name: "Read", target: "main.rs"),
          ToolCall(name: "Read", target: "mod.rs"),
          ToolCall(name: "Read", target: "pool.rs"),
          ToolCall(name: "Bash", target: "cargo test"),
          ToolCall(name: "Grep", target: "open_session"),
          ToolCall(name: "Read", target: "session.rs"),
        ]),
        secondsAgo: 480
      ),
      // A turn with bold, inline code and a fenced block, so a raw-markdown regression shows.
      // Before the final turn, so the Needs-you quote `SessionTreeUITests` matches is
      // untouched.
      .init(
        speaker: .assistant,
        text: """
          Found it — **`Pool::acquire`** was still blocking. Fixed in `pool.rs`:

          ```rust
          pub async fn acquire(&self) -> Connection {
              self.wait_for_slot().await
          }
          ```

          Running the tests now.
          """,
        secondsAgo: 300,
        // Elapsed time on the default fixture, because it belongs to the chat's ordinary state.
        // Over ten minutes, so the `Xm Ys` form is the one shown.
        durationMs: 590_000
      ),
      // Two lines, exactly the Needs-you row's quote bound, so nothing is truncated.
      .init(
        speaker: .assistant,
        text: """
          The pool is async now. Migrating the two call sites changes the public API.
          Proceed with the migration?
          """,
        secondsAgo: 240,
        durationMs: 15_228
      ),
    ],
    codexSessions: [seededCodexRollout]
  )

  /// The rollout behind `w3:p1`, the seeded session's Codex pane.
  ///
  /// Its `cwd` is the pane's `directory` exactly, because Codex records the literal working
  /// directory in line 1. No reported session, so it resolves tier 2, the ordinary Codex path.
  ///
  /// A different conversation from `seededTranscript`'s, so a Codex pane read from Claude's
  /// file would change what `PaneChatUITests` reads back. One run of tool calls, because a
  /// Codex `custom_tool_call` carries raw shell text where Claude's carries JSON.
  static let seededCodexRollout = FakeTranscriptHost.CodexSession(
    id: "01a00000-1111-7222-8333-444455556666",
    // `w3:p1`'s `directory` in `FakeControl.seededTree`. If that changes, the pane resolves
    // `noSessionFiles`, which is why the UI test asserts on a line of the conversation.
    cwd: "~/wiki",
    turns: [
      .init(speaker: .human, text: "rebuild the search index", secondsAgo: 720),
      .init(
        speaker: .tools([
          ToolCall(name: "exec", target: "ls pages"),
          ToolCall(name: "exec", target: "python3 scripts/build_index.py"),
        ]),
        secondsAgo: 540
      ),
      .init(
        speaker: .assistant,
        text: "The search index is rebuilt. 41 pages indexed, two broken links fixed.",
        secondsAgo: 420
      ),
    ]
  )

  /// The same conversation, in a file that stops mid-record. Its own flag, because it is a
  /// failure. The one chat failure drawn under turns that did parse.
  static let truncatedTranscript = FakeTranscriptHost(
    sessionID: "3f8c1d20-0000-4000-8000-000000000002",
    turns: [
      .init(speaker: .human, text: "make the connection pool async", secondsAgo: 900),
      .init(
        speaker: .assistant,
        text: "Reading the pool module now.",
        secondsAgo: 480
      ),
    ],
    endsMidRecord: true
  )

  /// Whether this launch should serve a session file that stops mid-record.
  static var isTranscriptTruncated: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingTruncatedTranscript")
  }

  /// Two live sessions in one directory, which the resolver refuses to choose between.
  ///
  /// Its own flag, because it is the refusal. Both files are recent, and each opens with a
  /// different first line, because the picker is keyed on it. Neither session id matches the
  /// seeded tree's `agent_session`. The UI test opens `w1:p1`, because on `w1:p2` herdr's own
  /// answer would be missing, not ambiguous.
  static let ambiguousTranscript = FakeTranscriptHost(
    sessions: [
      .init(
        sessionID: "0a1b2c3d-0000-4000-8000-000000000001",
        turns: [
          .init(speaker: .human, text: "review the diff on the focus branch", secondsAgo: 300),
          .init(speaker: .assistant, text: "Reading the diff now.", secondsAgo: 4),
        ]
      ),
      .init(
        sessionID: "4e5f6a7b-0000-4000-8000-000000000002",
        turns: [
          .init(speaker: .human, text: "start on the pane-focus bug", secondsAgo: 600),
          .init(speaker: .assistant, text: "Looking at the focus retry policy.", secondsAgo: 21),
        ]
      ),
    ]
  )

  /// Whether this launch should serve a directory Driverr refuses to resolve.
  static var isTranscriptAmbiguous: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingAmbiguousTranscript")
  }

  /// The conversation this launch's reader serves, chosen in one place.
  private static var transcriptFixture: FakeTranscriptHost {
    // The catalogue is chosen separately from the conversation: the flag wraps whichever
    // conversation fixture applies, instead of doubling the fixtures.
    guard !isSkillCatalog else { return conversationFixture.offering(installedSkills) }
    return conversationFixture
  }

  private static var conversationFixture: FakeTranscriptHost {
    if isTranscriptTruncated { return truncatedTranscript }
    if isTranscriptAmbiguous { return ambiguousTranscript }
    if isTranscriptPaged { return pagedTranscript }
    if isTranscriptBusy { return busyTranscript }
    if isTranscriptStalled { return stalledTranscript }
    if isTranscriptBounded { return boundedTurnTranscript }
    if isTranscriptRich { return richTranscript }
    if isTranscriptImages { return imageTranscript }
    if isTranscriptSlashCommands { return slashCommandTranscript }
    if isTranscriptPending { return pendingCallTranscript }
    if isTranscriptMultiQuestion { return multiQuestionTranscript }
    if isTranscriptAnsweredQuestion { return answeredQuestionTranscript }
    if isTranscriptDescribedQuestion { return describedQuestionTranscript }
    if isScreenQuestion { return screenQuestionTranscript }
    if isTranscriptAgentEvents { return agentEventTranscript }
    if isTranscriptOrchestrator { return orchestratorTranscript }
    if isTranscriptTaskState { return taskStateTranscript }
    if isTranscriptManySubagents { return manySubagentTranscript }
    if isTranscriptSubagents { return subagentTranscript }
    if isTranscriptUsageLimited { return usageLimitedTranscript }
    if isTranscriptUsageLimitReset { return usageLimitResetTranscript }
    if isTranscriptServerError { return serverErrorTranscript }
    return defaultConversation(isStoreTour: isDemoTranscript)
  }

  /// The conversation a launch with no transcript flag serves, so a test can check that the
  /// store tour's conversation reaches no other launch.
  static func defaultConversation(isStoreTour: Bool) -> FakeTranscriptHost {
    isStoreTour ? storeTourTranscript : seededTranscript
  }

  /// The conversation the store tour's chat shows: `seededTranscript` with four more turns,
  /// including a shorter reply, and one more call, which waits for an answer. The person asks
  /// to be asked before the handlers change, and the last words ask exactly that.
  ///
  /// The added turns are there so the iPad's chat reaches the composer. With the keyboard
  /// down it is about twice the phone's height, and the seeded conversation filled two
  /// thirds of it. The waiting call is the edit `demoTranscript` ends on asking about. `w1:p2` is
  /// `blocked`, so the chat draws Approve and Deny under it, and they send the `y` and `n`
  /// the terminal's `(y/n)` takes.
  ///
  /// The last words are `seededTranscript`'s own, so the Needs-you row quotes the same two
  /// lines, and the call is written at four minutes, so the header still reads "written 4m
  /// ago". They carry no elapsed time here: on the 6.9-inch phone that line pushes the turn's
  /// name under the chat's header.
  static let storeTourTranscript: FakeTranscriptHost = {
    let seeded = seededTranscript.sessions.first?.turns ?? []
    return FakeTranscriptHost(
      sessionID: "3f8c1d20-0000-4000-8000-000000000002",
      turns: Array(seeded.prefix(2))
        + [
          .init(
            speaker: .assistant,
            text: """
              The pool holds a mutex across every checkout, so `acquire` blocks the runtime \
              under load. Making it async changes `open_session` too, and two handlers call \
              that.
              """,
            secondsAgo: 450
          ),
          .init(
            speaker: .human,
            text: "start with the pool, and ask me before you touch the handlers",
            secondsAgo: 420
          ),
          .init(
            speaker: .tools([
              ToolCall(name: "Edit", target: "pool.rs"),
              ToolCall(name: "Bash", target: "cargo test"),
              ToolCall(name: "Read", target: "routes/session.rs"),
            ]),
            secondsAgo: 360
          ),
          .init(
            speaker: .assistant,
            text: """
              **`Pool::acquire`** was still blocking. Fixed in `pool.rs`:

              ```rust
              pub async fn acquire(&self) -> Connection {
                  self.wait_for_slot().await
              }
              ```
              """,
            secondsAgo: 330
          ),
          .init(
            speaker: .assistant,
            text: """
              Both handlers in `routes/session.rs` already run inside async routes, so only \
              their signatures change. Anything outside this crate that calls them would see it.
              """,
            secondsAgo: 300
          ),
        ]
        + [
          .init(speaker: .assistant, text: seeded.last?.text ?? "", secondsAgo: 250),
          .init(
            speaker: .tools([ToolCall(name: "Edit", target: "session.rs", outcome: .pending)]),
            secondsAgo: 240
          )
        ],
      codexSessions: [seededCodexRollout]
    )
  }()

  /// A conversation with two runs and more turns than fit on a phone: the fixture that shows
  /// whether opening a run moves the reader.
  ///
  /// - a forty-call run, so the opened row names six calls and counts thirty-four;
  /// - a three-call run, which must open to three rows and no remainder line;
  /// - enough turns to scroll, or opening a run could not move anyone.
  ///
  /// The last six calls are named individually, because an opened run lists them and the UI
  /// test reads them back.
  static let busyTranscript = FakeTranscriptHost(
    sessionID: "3f8c1d20-0000-4000-8000-000000000002",
    turns: [
      .init(speaker: .human, text: "make the connection pool async", secondsAgo: 1800),
      // The short run, high up, so reaching it takes a scroll.
      .init(
        speaker: .tools([
          ToolCall(name: "Read", target: "Cargo.toml"),
          ToolCall(name: "Read", target: "src/pool/mod.rs"),
          ToolCall(name: "Grep", target: "open_session"),
        ]),
        secondsAgo: 1700
      ),
      .init(
        speaker: .assistant,
        text: """
          The pool holds a mutex across every checkout, so making it async means every \
          call site changes with it. Two of them hold the guard across an await already, \
          which is what the deadlock under load was.
          """,
        secondsAgo: 1500
      ),
      .init(speaker: .human, text: "go ahead, and keep the tests passing", secondsAgo: 1200),
      // The long run, near the newest turn, where a reader who opens the chat is looking.
      .init(speaker: .tools(longRun), secondsAgo: 900),
      .init(
        speaker: .assistant,
        text: """
          The pool hands out futures now and the suite still passes, once the two tests \
          that spawned their own runtime were rewritten to use the shared one. It runs in \
          about nine seconds, down from forty, because nothing waits on a lock it will \
          never get.
          """,
        secondsAgo: 600
      ),
      .init(
        speaker: .assistant,
        text: """
          The pool is async now. Migrating the two call sites changes the public API.
          Proceed with the migration?
          """,
        secondsAgo: 240
      ),
    ]
  )

  /// Forty calls, of which the last six are what an opened run names. Repetitive, like a real
  /// long autonomous stretch.
  private static let longRun: [ToolCall] =
    (1...12).map { ToolCall(name: "Read", target: "src/pool/mod\($0).rs") }
    + (1...9).map { ToolCall(name: "Edit", target: "src/pool/mod\($0).rs") }
    + (1...7).map { _ in ToolCall(name: "Bash", target: "cargo check") }
    + (1...6).map { ToolCall(name: "Grep", target: "open_session_\($0)") }
    + [
      ToolCall(name: "Read", target: "src/pool/session.rs"),
      ToolCall(name: "Edit", target: "src/pool/pool.rs"),
      ToolCall(name: "Bash", target: "cargo test"),
      ToolCall(name: "Grep", target: "open_session"),
      ToolCall(name: "Read", target: "src/pool/pool.rs"),
      ToolCall(name: "Edit", target: "src/pool/session.rs"),
    ]

  /// Whether this launch should serve the conversation with two runs of tool calls in it.
  static var isTranscriptBusy: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingBusyTranscript")
  }

  /// A page the reader stopped growing before it held the turns it asked for.
  ///
  /// Three turns in a file that claims 300 MB, above the six-turn ladder's top rung, so every
  /// rung is a tail and the climb ends with three turns of six. That is
  /// `TranscriptWindow.stoppedShort`. The fake honours only the record bound, so this takes
  /// the no-gain path; `TranscriptReaderTests` covers the exhaustion path.
  static let stalledTranscript = FakeTranscriptHost(
    sessionID: "3f8c1d20-0000-4000-8000-000000000002",
    turns: [
      .init(speaker: .human, text: "why is the pool leaking sessions?", secondsAgo: 900),
      .init(speaker: .tools(longRun), secondsAgo: 600),
      .init(
        speaker: .assistant,
        text: "The pool never closes a session whose handshake failed, so every retry "
          + "leaks one. I moved the close into the defer.",
        secondsAgo: 60
      ),
    ],
    fileSizeInBytes: 300_000_000
  )

  /// Whether this launch should serve the page the reader stopped growing.
  static var isTranscriptStalled: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingStalledTranscript")
  }

  /// The busy conversation again, in a file that claims to be far larger than what came back.
  ///
  /// A fixture sized to its body is read to its front on the first rung, so no pager appears.
  /// 40 MB matches a real session file, and ninety turns satisfy the first rung, so the page
  /// stays a tail.
  static let pagedTranscript = FakeTranscriptHost(
    // The seeded tree's `agent_session`. Another id would resolve as a missing reported
    // session, a different screen.
    sessionID: "3f8c1d20-0000-4000-8000-000000000002",
    turns: longConversation,
    fileSizeInBytes: 40_000_000
  )

  /// Ninety turns, because `TranscriptReader.ladder` bounds a six-turn request at
  /// `max(60, turns * 6)` records. Under sixty, the first page is the whole file and paging
  /// prepends nothing. Ninety puts the first page (60) short of the file and the second (120)
  /// past it.
  private static let longConversation: [FakeTranscriptHost.Turn] =
    (1...45).flatMap { index -> [FakeTranscriptHost.Turn] in
      let age = TimeInterval((46 - index) * 120)
      return [
        .init(speaker: .human, text: "step \(index): what changed here?", secondsAgo: age),
        .init(
          speaker: .assistant,
          text: "Step \(index): the guard moved above the await, so the lock is released first.",
          secondsAgo: age - 30
        ),
      ]
    }

  /// Whether this launch should serve a conversation with more of the file behind it.
  static var isTranscriptPaged: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingPagedTranscript")
  }

  /// A command turn, a long turn that is not the newest, and an equally long turn that is.
  /// Equal lengths, so position is the only variable when the newest is left unbounded.
  static let boundedTurnTranscript = FakeTranscriptHost(
    sessionID: "3f8c1d20-0000-4000-8000-000000000002",
    turns: [
      .init(speaker: .command, text: "/run-tests", secondsAgo: 600),
      .init(speaker: .assistant, text: thirtyLineMessage, secondsAgo: 300),
      .init(speaker: .assistant, text: thirtyLineMessage, secondsAgo: 60),
    ]
  )

  /// Thirty lines, past the 24-line bound for a turn that is not the newest, so measurement
  /// has to catch it.
  private static let thirtyLineMessage = (1...30).map { "Line \($0) of the investigation." }
    .joined(separator: "\n")

  /// A conversation ending on Claude Code's usage-limit record.
  ///
  /// The real shape: `isApiErrorMessage`, `error: "rate_limit"`, 429, and `resetsAt` two hours
  /// after launch, so the notice is live whenever the test runs. The text gives the reset in
  /// the host's zone, as a real record does; the chat hides that turn while the notice stands.
  static let usageLimitedTranscript = usageLimited(resetsAt: Date().addingTimeInterval(2 * 3_600))

  /// The same limit, reset an hour before launch: the "Usage limit reset" state.
  static let usageLimitResetTranscript = usageLimited(
    resetsAt: Date().addingTimeInterval(-3_600))

  private static func usageLimited(resetsAt: Date) -> FakeTranscriptHost {
    var style = Date.FormatStyle(
      locale: Locale(identifier: "en_US_POSIX"), timeZone: TimeZone(identifier: "America/Chicago")!)
    style = style.hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits)
    // `5:40pm`, as Claude Code writes it, without the narrow no-break space `FormatStyle` adds.
    let hostClock = resetsAt.formatted(style)
      .filter { !$0.isWhitespace }
      .lowercased()
    return FakeTranscriptHost(
      sessionID: "3f8c1d20-0000-4000-8000-000000000002",
      turns: stoppedConversation + [
        .init(
          speaker: .apiError(error: "rate_limit", status: 429, resetsAt: resetsAt),
          text: "You've hit your session limit · resets \(hostClock) (America/Chicago)",
          secondsAgo: 300
        )
      ]
    )
  }

  /// Whether this launch should serve the usage-limit fixture.
  static var isTranscriptUsageLimited: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingUsageLimited")
  }

  /// Whether this launch should serve the usage-limit fixture past its reset.
  static var isTranscriptUsageLimitReset: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingUsageLimitReset")
  }

  /// The same conversation ending on a `server_error`, with a real message's text, so the
  /// notice's verbatim detail can be checked.
  static let serverErrorTranscript = FakeTranscriptHost(
    sessionID: "3f8c1d20-0000-4000-8000-000000000002",
    turns: stoppedConversation + [
      .init(
        speaker: .apiError(error: "server_error", status: nil, resetsAt: nil),
        text: "API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)",
        secondsAgo: 300
      )
    ]
  )

  /// Whether this launch should serve the failed-request fixture.
  static var isTranscriptServerError: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingServerError")
  }

  /// What the agent said before it stopped, for both stop fixtures.
  private static let stoppedConversation: [FakeTranscriptHost.Turn] = [
    .init(speaker: .human, text: "run the migration and tell me what broke", secondsAgo: 600),
    .init(
      speaker: .assistant,
      text: "The migration ran. Two tests fail in `PoolTests`; I am looking at the first.",
      secondsAgo: 420
    ),
  ]

  /// Whether this launch should serve the command/bounded-turn fixture.
  static var isTranscriptBounded: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingBoundedTranscript")
  }


  /// Every markdown construct the chat draws, plus a real unified diff, in one turn.
  ///
  /// Separate from `seededTranscript`, which the screenshot tour's conversation is built from
  /// and `SessionTreeUITests` quotes. The patch is a real `git diff` with a preamble the card
  /// drops, a hunk header, and a line long enough to need horizontal scrolling.
  static let richTranscript = FakeTranscriptHost(
    sessionID: "3f8c1d20-0000-4000-8000-000000000002",
    turns: [
      .init(speaker: .human, text: "make the pool async and show me the change", secondsAgo: 300),
      .init(
        speaker: .assistant,
        text: """
          ## What changed

          `Pool::acquire` was still **blocking** the executor. Two things moved:

          1. the wait now yields instead of parking the thread
          2. the slot count is reserved up front

          Notes:

          - the guard is dropped before the `await`, which is what fixes the deadlock
          - `wait_for_slot` is the only new public item

          ```rust
          pub async fn acquire(&self) -> Connection {
              self.wait_for_slot().await
          }
          ```

          diff --git a/src/pool.rs b/src/pool.rs
          index 1a2b3c4..5d6e7f8 100644
          --- a/src/pool.rs
          +++ b/src/pool.rs
          @@ -12,7 +12,9 @@ impl Pool {
               pub fn new(capacity: usize) -> Self {
          -        Self { conns: Vec::new(), waiters: VecDeque::new(), capacity, closed: false }
          +        Self {
          +            conns: Vec::with_capacity(capacity),
          +            waiters: VecDeque::new(),
          +            capacity,
          +            closed: false,
          +        }
               }

          See the [pool docs](https://example.invalid/pool) for the rest.
          """,
        secondsAgo: 60
      ),
    ]
  )

  /// Whether this launch should serve the markdown-and-diff fixture.
  static var isTranscriptRich: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingRichTranscript")
  }

  /// A conversation whose human turns carry real images.
  ///
  /// Four human turns, each a case the strip and label handle differently:
  ///
  /// - text plus one image: one large thumbnail;
  /// - an image and nothing else (`isImageOnly`);
  /// - four images beside text: three small thumbnails and a `+1` badge;
  /// - one image with no payload: no strip, only the `1 image` label. Without it, a build that
  ///   draws no images would still pass every count.
  ///
  /// Two assistant turns break up the bubbles, and the last says why its image is missing.
  /// Separate from `seededTranscript`, as `richTranscript` is.
  ///
  /// The session id must be `FakeControl`'s `agent_session`, or the chat shows the reported
  /// session missing refusal instead of the conversation.
  static let imageTranscript = FakeTranscriptHost(
    sessionID: "3f8c1d20-0000-4000-8000-000000000002",
    turns: [
      .init(
        speaker: .human,
        text: "here is what the strip looks like on my phone",
        secondsAgo: 900,
        attachedImages: 1,
        imagePayloads: [FakeTranscriptHost.tinyPNG]
      ),
      .init(
        speaker: .assistant,
        text: "Got it — the second row is the one that is 8 points out.",
        secondsAgo: 840
      ),
      .init(
        speaker: .human,
        secondsAgo: 600,
        attachedImages: 1,
        imagePayloads: [FakeTranscriptHost.tinyPNG]
      ),
      .init(
        speaker: .human,
        text: "before and after",
        secondsAgo: 420,
        attachedImages: 4,
        imagePayloads: [
          FakeTranscriptHost.tinyPNG,
          FakeTranscriptHost.tinyPNG,
          FakeTranscriptHost.tinyPNG,
          FakeTranscriptHost.tinyPNG,
        ]
      ),
      .init(
        speaker: .human,
        text: "and this one never made it off the box",
        secondsAgo: 240,
        attachedImages: 1
      ),
      .init(
        speaker: .assistant,
        text: "That last attachment has no payload in the session file, so I cannot see it.",
        secondsAgo: 120
      ),
    ]
  )

  /// Whether this launch should serve the image fixture.
  static var isTranscriptImages: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingImageTranscript")
  }

  /// Six distinct commands and one repeat: the `/` autocomplete's fixture.
  ///
  /// - six distinct commands, one over `SlashCommandMatcher.maximumSuggestions`, so `/` shows
  ///   the cap;
  /// - `/code-review` and `/commit` share `/co`, so a prefix narrows the list;
  /// - `/run-tests` twice, oldest and newest, so recency order is visible;
  /// - `/code-review high --fix` has an argument, so a completion that carried arguments
  ///   through would show.
  ///
  /// Each command is answered, so the conversation reads as one.
  static let slashCommandTranscript = FakeTranscriptHost(
    // The seeded tree's `agent_session`.
    sessionID: "3f8c1d20-0000-4000-8000-000000000002",
    turns: [
      .init(speaker: .command, text: "/run-tests", secondsAgo: 3600),
      .init(speaker: .assistant, text: "Two tests fail, both in the retry path.", secondsAgo: 3560),
      .init(speaker: .command, text: "/read-docs", secondsAgo: 3000),
      .init(speaker: .assistant, text: "Read the tokio timeout documentation.", secondsAgo: 2960),
      .init(speaker: .command, text: "/commit", secondsAgo: 2400),
      .init(speaker: .assistant, text: "Committed the retry fix and its tests.", secondsAgo: 2360),
      .init(speaker: .command, text: "/code-review high --fix", secondsAgo: 1800),
      .init(speaker: .assistant, text: "Two findings, both applied.", secondsAgo: 1760),
      .init(speaker: .command, text: "/lint", secondsAgo: 1200),
      .init(speaker: .assistant, text: "The build log is clean.", secondsAgo: 1160),
      .init(speaker: .command, text: "/push", secondsAgo: 600),
      .init(speaker: .assistant, text: "Pushed the branch.", secondsAgo: 560),
      .init(speaker: .command, text: "/run-tests", secondsAgo: 120),
      .init(speaker: .assistant, text: "Every test passes.", secondsAgo: 60),
    ]
  )

  /// Whether this launch should serve the slash-command fixture.
  static var isTranscriptSlashCommands: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingSlashCommandTranscript")
  }

  /// Whether this launch's host reports installed skills and commands.
  ///
  /// Every other fixture answers the skills command with nothing, so the `/` list falls back to
  /// recents. Usable alone: without `-uiTestingSlashCommandTranscript` the conversation has no
  /// command turns, which is the fresh-session case.
  static var isSkillCatalog: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingSkillCatalog")
  }

  /// What the fixture host has installed. Five entries, each for a shape:
  ///
  /// - `/deploy-preview`, described in a folded block, whose marker line carries none of the
  ///   text. Most real user skills do this.
  /// - `/format`, a plain one-line description.
  /// - `/schema-sync`, a project skill, so the pane's directory scope is used.
  /// - `/analyze`, a project command with no description, which must render with no second
  ///   line.
  /// - `/acme:sync-files`, a namespaced plugin skill. A bare name would not exist on the
  ///   far side.
  static let installedSkills: [FakeTranscriptHost.Skill] = [
    .init(
      name: "deploy-preview",
      description: "Build the branch and put it on a preview host, then report the URL and "
        + "what changed since the last deploy. Use before asking anybody to look at a "
        + "change that is easier to see than to describe.",
      isFolded: true,
      scope: .user
    ),
    .init(
      name: "format",
      description: "Format the files this branch changed.",
      scope: .user
    ),
    .init(
      name: "schema-sync",
      description: "Pull the schema from the running service and regenerate the models.",
      scope: .project
    ),
    .init(name: "analyze", scope: .command),
    .init(
      name: "acme:sync-files",
      description: "Copy the build output to the shared folder.",
      scope: .plugin
    ),
  ]

  /// A conversation ending on an unanswered tool call, the commonest blocked state. `.pending`
  /// writes no result line, so the real parser computes `Transcript.pendingToolCall` as it would
  /// on a live permission prompt.
  static let pendingCallTranscript = FakeTranscriptHost(
    sessionID: "3f8c1d20-0000-4000-8000-000000000002",
    turns: [
      .init(speaker: .human, text: "run the test suite before we merge", secondsAgo: 60),
      .init(
        speaker: .tools([ToolCall(name: "Bash", target: "cargo test", outcome: .pending)]),
        secondsAgo: 10
      ),
    ]
  )

  /// Whether this launch should serve the pending-tool-call fixture.
  static var isTranscriptPending: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingPendingTranscript")
  }

  /// A conversation ending on an `AskUserQuestion` with two questions.
  ///
  /// The questions go in as the tool's own input, so the chat parses them through
  /// `TranscriptParser.replyQuestions(of:)` like a real file. Two questions fail a single-group
  /// parse. Distinct labels, so each chip has a unique identifier. The second question is
  /// multi-select.
  static let multiQuestionTranscript = FakeTranscriptHost(
    sessionID: "3f8c1d20-0000-4000-8000-000000000002",
    turns: [
      .init(speaker: .human, text: "get the release branch ready", secondsAgo: 90),
      .init(
        speaker: .tools([
          ToolCall(
            name: "AskUserQuestion",
            outcome: .pending,
            questions: multiQuestions()
          )
        ]),
        secondsAgo: 10
      ),
    ]
  )

  /// The two questions `multiQuestionTranscript` asks, with a header and per-option
  /// descriptions as a real call carries them, and `answers` for `answeredQuestionTranscript`.
  private static func multiQuestions(answers: [String]? = nil) -> [PendingQuestion] {
    [
      PendingQuestion(
        question: "Which branch?",
        options: ["main", "release"],
        header: "Branch",
        optionDescriptions: [
          "Cut the release from main as it stands.",
          "Use the release branch, which has the version bump.",
        ],
        answer: answers?[0]
      ),
      PendingQuestion(
        question: "Who reviews it?",
        options: ["Ann", "Bo"],
        allowsMultiple: true,
        header: "Review",
        optionDescriptions: ["Owns the release notes.", "Owns the build."],
        answer: answers?[1]
      ),
    ]
  }

  /// Whether this launch should serve the two-question fixture.
  static var isTranscriptMultiQuestion: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingMultiQuestionTranscript")
  }

  /// `multiQuestionTranscript` after the person answered it. The reply record carries
  /// `toolUseResult.answers`, so the answers go through the real parse. The run is the last
  /// thing in the conversation, as right after an answer.
  static let answeredQuestionTranscript = FakeTranscriptHost(
    sessionID: "3f8c1d20-0000-4000-8000-000000000002",
    turns: [
      .init(speaker: .human, text: "get the release branch ready", secondsAgo: 90),
      .init(
        speaker: .tools([
          ToolCall(
            name: "AskUserQuestion",
            outcome: .succeeded,
            questions: multiQuestions(answers: ["release", "Ann, Bo"])
          )
        ]),
        secondsAgo: 10
      ),
    ]
  )

  /// One question with four described options: the tallest band one question can draw, for
  /// checking at larger text sizes.
  static let describedQuestionTranscript = FakeTranscriptHost(
    sessionID: "3f8c1d20-0000-4000-8000-000000000002",
    turns: [
      .init(speaker: .human, text: "fix the export of large files", secondsAgo: 90),
      .init(
        speaker: .tools([
          ToolCall(
            name: "AskUserQuestion",
            outcome: .pending,
            questions: [
              PendingQuestion(
                question: "The export fails on files over 2 GB. What should it do with a file that large?",
                options: ["Stream it", "Split it", "Raise the limit", "Leave it"],
                header: "Export",
                optionDescriptions: [
                  "Write the file in chunks, so memory use stays flat at any size.",
                  "Write several numbered parts, each one under the present limit.",
                  "Move the limit to 8 GB and keep the present code path.",
                  "Keep the limit and say so in the error message.",
                ]
              )
            ]
          )
        ]),
        secondsAgo: 10
      ),
    ]
  )

  /// Whether this launch should serve the four-option fixture.
  static var isTranscriptDescribedQuestion: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingDescribedQuestionTranscript")
  }

  /// Whether this launch should serve the answered two-question fixture.
  static var isTranscriptAnsweredQuestion: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingAnsweredQuestionTranscript")
  }

  /// A conversation ending on the prompt that asked for a question. With no hook, Claude Code
  /// keeps a waiting `AskUserQuestion` on the pane's screen (`FakeControl.askUserQuestionScreen`)
  /// and not in the file.
  ///
  /// Earlier exchanges make it taller than the chat on iPad too, so the chat rests at its end
  /// and the handover scrolls the conversation instead of pushing the chips down. In a
  /// conversation shorter than the chat, the chips move about 106 pt at the handover, which is
  /// accepted.
  static let screenQuestionTranscript = FakeTranscriptHost(
    sessionID: "3f8c1d20-0000-4000-8000-000000000002",
    turns: [
      .init(speaker: .human, text: "where should the smoothie stand go?", secondsAgo: 900),
      .init(
        speaker: .assistant,
        text: """
          The corner by the market gate is the best spot. Everyone who comes in walks past \
          it, and it has shade until about eleven, which keeps the fruit cold.

          The spot by the car park gets more people at lunch, but it has no shade and no \
          power for the blender. You would need to bring a battery, and the one we have \
          lasts about two hours.
          """,
        secondsAgo: 890
      ),
      .init(speaker: .human, text: "what do we charge for a cup?", secondsAgo: 700),
      .init(
        speaker: .assistant,
        text: """
          The other stands at the market charge between four and six dollars. I suggest:

          1. Small, 8 ounces, for four dollars.
          2. Medium, 12 ounces, for five dollars.
          3. Large, 16 ounces, for six dollars.

          The fruit costs about a dollar for each small cup, so every size leaves a margin \
          after the cups and the ice.
          """,
        secondsAgo: 690
      ),
      .init(speaker: .human, text: "who is running it on Saturday?", secondsAgo: 500),
      .init(
        speaker: .assistant,
        text: """
          Sam opens at seven and runs the blender until noon. Alex takes the money and \
          covers the afternoon. Nobody is on the list after three, so the stand closes \
          then unless somebody else signs up this week.
          """,
        secondsAgo: 490
      ),
      .init(speaker: .human, text: "what do we still need for the smoothie stand?", secondsAgo: 300),
      .init(
        speaker: .assistant,
        text: """
          Three things are still open:

          1. The cups arrive on Friday, so the stand can open on Saturday morning.
          2. The price list needs a second look, because the large size costs less per \
          ounce than the medium one.
          3. Nobody has chosen the fruit for the first batch yet.
          """,
        secondsAgo: 290
      ),
      .init(speaker: .human, text: "ask me which fruit goes in the smoothie", secondsAgo: 30),
    ]
  )

  /// Whether this launch serves a question from the pane's screen only. The handover fixture
  /// below starts the same way.
  static var isScreenQuestion: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingScreenQuestion")
      || isScreenQuestionHandover
  }

  /// Whether the session file gains the pending `AskUserQuestion` eight seconds after the pane
  /// opens, while the screen still shows it: the transcript taking a question over from the
  /// screen. The chips must not move. Timed by `armTheGrowth`.
  static var isScreenQuestionHandover: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingScreenQuestionHandover")
  }

  /// `screenQuestionTranscript` once Claude Code has written the question: the waiting call,
  /// with the words the screen capture shows. `FakeTranscriptHost` writes the question text
  /// as the agent's turn, as a real session file carries it.
  static let screenQuestionAskedTranscript = FakeTranscriptHost(
    sessionID: "3f8c1d20-0000-4000-8000-000000000002",
    turns: (screenQuestionTranscript.sessions.first?.turns ?? []) + [
      .init(
        speaker: .tools([
          ToolCall(
            name: "AskUserQuestion",
            outcome: .pending,
            questions: [
              PendingQuestion(
                question: "Pick a fruit",
                options: ["Apple", "Banana", "Cherry"],
                header: "Fruit",
                optionDescriptions: [
                  "A crisp, sweet red or green fruit",
                  "A soft, creamy yellow tropical fruit",
                  "A small, tart red stone fruit",
                ]
              )
            ]
          )
        ]),
        secondsAgo: 1
      ),
    ]
  )

  /// Serves the screen-only conversation, then the one carrying the question once
  /// `armTheGrowth` has opened.
  private static var handoverRunner: CommandRunner {
    { command in
      let grown = await growth.isOpen
      if isTranscriptSlow { try await Task.sleep(for: .milliseconds(900)) }
      return try await (grown ? screenQuestionAskedTranscript : screenQuestionTranscript).run(
        command)
    }
  }

  /// Whether the asking pane is reported working rather than blocked.
  ///
  /// Independent of which conversation is served, like `isSkillCatalog`: herdr's status and
  /// the file's pending call are separate facts, and this is where they disagree. With
  /// `-uiTestingMultiQuestionTranscript`, it is a live `AskUserQuestion` on a pane herdr has
  /// not called blocked.
  static var isAskingWhileWorking: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingAskingWhileWorking")
  }

  /// A conversation with inter-agent traffic in it.
  ///
  /// Four events, each a case that can fail:
  ///
  /// - a markdown message with a summary, the longest line and the only body worth opening;
  /// - an idle notification with no summary, the commonest record, so the fallback wording
  ///   shows;
  /// - a record carrying two blocks, so a parse that takes only the first draws one line;
  /// - a `.message` summary with an apostrophe. It arrives XML-escaped as `&apos;` in the
  ///   tag's `summary` attribute, so an undecoded entity would show. An `.idleNotification`'s
  ///   summary is a JSON field and would prove nothing.
  ///
  /// The events sit between real turns, because where they land matters.
  static let agentEventTranscript = FakeTranscriptHost(
    sessionID: "3f8c1d20-0000-4000-8000-000000000002",
    turns: [
      .init(speaker: .human, text: "get the parser change reviewed", secondsAgo: 900),
      .init(
        speaker: .assistant,
        text: "Sent it to the verifier and the tester. I'll report back.",
        secondsAgo: 860
      ),
      .init(
        speaker: .teammate([
          .init(
            sender: "ver-6",
            summary: "Review done: two small fixes, nothing blocking",
            body: "## Review\n\n**Fix**\n\n- The summary attribute isn't unescaped, "
              + "so `&apos;` reaches the screen.\n- A two-block record loses its second "
              + "block.\n\nNothing blocking. Both are in the parser, not the view.",
            shape: .message
          )
        ]),
        secondsAgo: 700
      ),
      .init(speaker: .teammate([.init(sender: "ver-6", shape: .idleNotification)]), secondsAgo: 690),
      .init(
        speaker: .assistant,
        text: "Both are fixed and pushed. Waiting on the tester.",
        secondsAgo: 400
      ),
      .init(
        speaker: .teammate([
          .init(
            sender: "qa-6",
            // The apostrophe arrives as `&apos;` and must read as an apostrophe. See above.
            summary: "The line's machinery, which is right",
            body: "Light and dark both look right. The line sits at caption size in the "
              + "secondary colour and never reads as somebody speaking.",
            shape: .message
          ),
          .init(
            sender: "qa-6",
            summary: "[to main] tester's report is in",
            body: "Approved with no changes.",
            shape: .idleNotification
          ),
        ]),
        secondsAgo: 180
      ),
      .init(speaker: .human, text: "good — merge it", secondsAgo: 60),
    ]
  )

  /// Whether this launch should serve the inter-agent-event fixture.
  static var isTranscriptAgentEvents: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingAgentEventTranscript")
  }

  /// A session driving a team of agents.
  ///
  /// `agentEventTranscript` is traffic relayed into a session; this is what the session
  /// itself does, read off `tool_use` blocks: spawns, stops and messages out. The relayed
  /// reply is here too, so both shapes share a screen. Runs are sized for the closed row: a
  /// five-call run is three rows and `+2 more`, a one-call run is one row.
  static let orchestratorTranscript = FakeTranscriptHost(
    // The seeded tree's `agent_session`. Another id would open the picker instead.
    sessionID: "3f8c1d20-0000-4000-8000-000000000002",
    turns: [
      .init(speaker: .command, text: "/milestone 0.5", secondsAgo: 1500),
      .init(
        speaker: .assistant,
        text: "Reading the release plan first, then one agent per task.",
        secondsAgo: 1480
      ),
      // Five ordinary calls: three rows closed, `+2 more` under them.
      .init(
        speaker: .tools([
          ToolCall(name: "Bash", target: "Read the 0.5 release plan"),
          ToolCall(name: "Bash", target: "List the open tasks"),
          ToolCall(name: "Read", target: "/repo/docs/release-0.5.md"),
          ToolCall(name: "Bash", target: "Check for stale branches"),
          ToolCall(name: "Grep", target: "feat/async-pool"),
        ]),
        secondsAgo: 1400
      ),
      // Two spawns in one record, as the main session starts a team, to catch a parse that
      // folds them into a run.
      .init(
        speaker: .toolBlocks([
          // Teammates: they message back, receive messages and are stopped by name, which is
          // where their state is read from.
          .spawn(
            subagentType: "analyst",
            name: "analyst-1",
            description: "Plan the async pool migration",
            launch: .teammate
          ),
          .spawn(
            subagentType: "engineer",
            name: "engineer-2",
            description: "Implement the session timeout",
            launch: .teammate
          ),
        ]),
        secondsAgo: 1200
      ),
      .init(
        speaker: .teammate([
          .init(
            sender: "analyst-1",
            summary: "Plan ready: two steps, the pool trait and its call sites",
            body: "Step 1 makes the pool trait async. Step 2 migrates the two call sites.",
            shape: .message
          )
        ]),
        secondsAgo: 900
      ),
      // A message out, then an ordinary call in the same record: event, then run.
      .init(
        speaker: .toolBlocks([
          .send(
            to: "engineer-2",
            summary: "Hold the build until the pool migration lands",
            message: "Do not start a build until I say so."
          ),
          .call(ToolCall(name: "ScheduleWakeup", target: "Fallback while the engineer works")),
        ]),
        secondsAgo: 700
      ),
      // `verifier-3` was spawned before the window, so its stop line shows the bare id.
      .init(
        speaker: .toolBlocks([.stop(taskID: "analyst-1"), .stop(taskID: "verifier-3")]),
        secondsAgo: 400
      ),
      .init(
        speaker: .assistant,
        text: "The analyst is done and the engineer is holding the build. The pool migration is next.",
        secondsAgo: 120
      ),
    ]
  )

  /// A session whose spawned work is in every state a line can show: async spawns finished,
  /// failed and running, a teammate idle and one running, and background commands finished,
  /// running and stopped. The ends are written as the host's task lines, so the real parse
  /// produces the states.
  static let taskStateTranscript = FakeTranscriptHost(
    sessionID: "3f8c1d20-0000-4000-8000-000000000002",
    turns: [
      .init(speaker: .command, text: "/milestone 0.6", secondsAgo: 2400),
      .init(
        speaker: .toolBlocks([
          .spawn(
            subagentType: "analyst", name: "analyst-4",
            description: "Plan the rate limiter",
            launch: .async(agentID: "a0000000000000001", end: .init(secondsAgo: 2100))),
          .spawn(
            subagentType: "finder", name: "finder-4",
            description: "Survey the open rate-limit reports",
            launch: .async(agentID: "a0000000000000002", end: .init(status: "failed", secondsAgo: 2280))),
        ]),
        secondsAgo: 2340
      ),
      .init(
        speaker: .toolBlocks([
          .spawn(
            subagentType: "engineer", name: "engineer-4",
            description: "Implement the rate limiter",
            launch: .teammate),
          .spawn(
            subagentType: "verifier", name: "verifier-4",
            description: "Review the rate limiter",
            launch: .teammate),
        ]),
        secondsAgo: 1800
      ),
      .init(
        speaker: .teammate([
          .init(
            sender: "verifier-4", summary: "Report sent to main",
            shape: .idleNotification)
        ]),
        secondsAgo: 1500
      ),
      .init(
        speaker: .toolBlocks([
          .background(
            command: "cargo bench --bench limiter", description: "Benchmark the limiter",
            end: .init(secondsAgo: 700)),
          .background(command: "cargo test", description: "Run the test suite"),
          .background(
            command: "cargo test -- --ignored", description: "Run the slow tests",
            end: .init(status: "killed", secondsAgo: 800)),
        ]),
        secondsAgo: 900
      ),
      .init(
        speaker: .toolBlocks([
          .spawn(
            subagentType: "claude-code-guide", name: "guide-4",
            description: "Look up the Retry-After header",
            launch: .async(agentID: "a0000000000000003"))
        ]),
        secondsAgo: 420
      ),
      .init(
        speaker: .assistant,
        text: "The analyst is done and the engineer is still working. One lookup is running.",
        secondsAgo: 120
      ),
    ]
  )

  /// A session with two spawn lines that open their sub-agent's own chat, and a third
  /// sub-agent whose spawn is not on the page.
  ///
  /// A finished spawn linked by its `tool_use` id, and a running teammate linked by name. Each
  /// has a `SubagentFixture`, so a tap runs the real link command, read and sub-agent parse.
  /// The analyst's `toolUseID` is the fake's id for turn 1's first block, `toolu_1_0`.
  ///
  /// The lookup was spawned hours before the page starts, so only the chat's sub-agent list,
  /// which reads meta files, can show it. The list reads `3 sub-agents · 1 running`.
  static let subagentTranscript = FakeTranscriptHost(
    sessionID: "3f8c1d20-0000-4000-8000-000000000002",
    turns: [
      .init(speaker: .human, text: "plan and review the config loader", secondsAgo: 1800),
      .init(
        speaker: .toolBlocks([
          .spawn(
            subagentType: "analyst", name: "analyst-7",
            description: "Plan the config loader",
            launch: .async(agentID: "aanalyst7", end: .init(secondsAgo: 1200)))
        ]),
        secondsAgo: 1700
      ),
      .init(
        speaker: .toolBlocks([
          .spawn(
            subagentType: "verifier", name: "verifier-7",
            description: "Review the config loader",
            launch: .teammate)
        ]),
        secondsAgo: 1000
      ),
      .init(
        speaker: .assistant,
        text: "The analyst is done. The verifier is still reading the diff.",
        secondsAgo: 60
      ),
    ]
  ).serving([
    FakeTranscriptHost.SubagentFixture(
      agentID: "aanalyst7",
      toolUseID: "toolu_1_0",
      name: "analyst-7",
      secondsAgo: 1200,
      prompt: "Plan the config loader. Read the loader and its tests, then return a short plan.",
      turns: [
        .init(speaker: .assistant, text: "Reading the loader and its tests first.", secondsAgo: 1650),
        .init(
          speaker: .tools([
            ToolCall(name: "Read", target: "src/config/loader.rs"),
            ToolCall(name: "Read", target: "src/config/tests.rs"),
          ]),
          secondsAgo: 1600
        ),
        .init(
          speaker: .assistant,
          text: "The plan: parse into one typed struct and report every missing key at once.",
          secondsAgo: 1250
        ),
      ],
      description: "Plan the config loader",
      agentType: "analyst",
      spawnedSecondsAgo: 1700
    ),
    FakeTranscriptHost.SubagentFixture(
      agentID: "averifier7",
      name: "verifier-7",
      isTeammate: true,
      secondsAgo: 30,
      prompt: "Review the config loader on the latest commit and send your findings to the main session.",
      turns: [
        .init(speaker: .assistant, text: "Checking out the latest commit.", secondsAgo: 900),
        .init(
          speaker: .tools([ToolCall(name: "Bash", target: "Read the diff")]),
          secondsAgo: 60
        ),
      ],
      description: "Review the config loader",
      agentType: "verifier",
      spawnedSecondsAgo: 1000
    ),
    // Spawned before the page's first turn, so no spawn line opens it.
    FakeTranscriptHost.SubagentFixture(
      agentID: "a0lookup0000000001",
      toolUseID: "toolu_earlier_lookup",
      secondsAgo: 9000,
      prompt: "Find every caller of load_config and list the file and line of each.",
      turns: [
        .init(
          speaker: .tools([ToolCall(name: "Grep", target: "load_config")]),
          secondsAgo: 8950
        ),
        .init(
          speaker: .assistant,
          text: "Four callers: main.rs, cli.rs, server.rs and the loader's own tests.",
          secondsAgo: 8900
        ),
      ],
      description: "Find the config loader's callers",
      agentType: "Explore",
      isFinished: true,
      spawnedSecondsAgo: 9400
    ),
  ])

  /// `subagentTranscript` with 57 more finished lookups behind it, 60 in all, so the open
  /// list reaches its height cap, scrolls inside it, and ends on the host's cap of 50.
  static let manySubagentTranscript = subagentTranscript.serving(
    subagentTranscript.subagents
      + (1...57).map { index in
        FakeTranscriptHost.SubagentFixture(
          agentID: "a0many\(index)",
          toolUseID: "toolu_many_\(index)",
          secondsAgo: 10_000 + Double(index) * 60,
          prompt: "Survey module \(index) and report its public types.",
          description: "Survey module \(index)",
          agentType: "Explore",
          isFinished: true,
          spawnedSecondsAgo: 10_100 + Double(index) * 60
        )
      })

  /// Whether this launch should serve the session with sixty sub-agents.
  static var isTranscriptManySubagents: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingManySubagents")
  }

  /// Whether this launch should serve the session whose spawn lines open sub-agents.
  static var isTranscriptSubagents: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingSubagents")
  }

  /// Whether this launch should serve the session whose spawned work is in every state.
  static var isTranscriptTaskState: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingTaskStateTranscript")
  }

  /// Whether this launch should serve the session that is driving a team.
  static var isTranscriptOrchestrator: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingOrchestratorTranscript")
  }

  /// One `terminal.frame` record, as herdr's control bridge would send it. Names its terminal,
  /// so a UI test can prove the right pane was opened.
  ///
  /// The store tour's frame is `demoTranscript` instead, because a pane's terminal shows this
  /// frame and not the PTY greeting, and one line naming a terminal is not store art.
  static func bridgeFrame(for command: String, isDemo: Bool = isDemoTranscript) -> Data {
    let words = command.split(separator: " ")
    let terminalID =
      words
      .drop { $0 != "control" && $0 != "observe" }
      .dropFirst()
      .first
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) } ?? "unknown"
    let payload = isDemo ? demoTranscript : "herdr pane \(terminalID)\r\n"
    let encoded = Data(payload.utf8).base64EncodedString()
    let record = """
      {"type":"terminal.frame","seq":1,"full":true,"encoding":"ansi",\
      "width":80,"height":24,"bytes":"\(encoded)"}
      """
    return Data((record + "\n").utf8)
  }

  /// Whether this launch prints far more than one screen when the PTY opens, for the
  /// scrollback test. Typing it would send one key event per character, which took minutes
  /// and crashed the runner; this is one write.
  static var isLongTranscript: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingLongTranscript")
  }

  /// Whether this launch drops the link once a terminal is on screen.
  ///
  /// Triggered by the tap that opens a pane, not a timer, which would race the test. It
  /// exercises the banner, the reconnect and the pane returning, which a fake transport is the
  /// only way to reach.
  static var isDroppingOnPaneOpen: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingDropOnPaneOpen")
  }

  /// Whether this launch drops the link shortly after it comes up, with no terminal on
  /// screen. The host becomes `.lost` and its row must say so. Nothing retries, because the
  /// backoff belongs to a terminal scene.
  static var isDroppingAfterConnect: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingDropAfterConnect")
  }

  /// Whether this launch drops the link once a shell is on screen.
  ///
  /// `isDroppingOnPaneOpen` waits on `streamedCommands`, and a herdr-less host opens no exec
  /// stream, so it never fires. `isDroppingAfterConnect` fires before a terminal can open.
  /// This reaches a shell terminal on a host with no herdr, with the link down.
  static var isDroppingOnShellOpen: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingDropOnShellOpen")
  }

  /// One drop per launch, not per connection. `makeTransport` runs again on every reconnect,
  /// so arming each transport would drop the link on every reconnect, forever.
  private static let dropIsArmed = OneShot()

  /// Arms the launch's one link failure, if this launch asked for one. A `Task` over the
  /// fake's public record, so the fake stays a fake and the timing policy stays here.
  private static func armTheDrop(on transport: FakeSSHTransport) {
    let onPaneOpen = isDroppingOnPaneOpen
    let onShellOpen = isDroppingOnShellOpen
    guard onPaneOpen || onShellOpen || isDroppingAfterConnect, dropIsArmed.take() else { return }
    Task {
      if onPaneOpen {
        while await transport.streamedCommands.isEmpty {
          try? await Task.sleep(for: .milliseconds(25))
        }
        // Then wait for the terminal to lay out on that stream. A fixed timer dropped the link
        // before SwiftTerm rendered, so the test never saw a terminal. A `terminal.resize` on
        // the bridge means the view has a grid, since a phone's grid is never the 80×24 a
        // stream opens at. The deadline only makes a build that sends no resize fail on the
        // test's assertion instead of hanging.
        let deadline = ContinuousClock.now + .seconds(6)
        while ContinuousClock.now < deadline {
          let laidOut = await transport.streamLog.contains { $0.contains("terminal.resize") }
          if laidOut { break }
          try? await Task.sleep(for: .milliseconds(25))
        }
        // A beat more, so the test has seen it: XCUITest reads the screen about once a second.
        try? await Task.sleep(for: .seconds(2))
      } else if onShellOpen {
        // A PTY, with the same two-step wait: open, then laid out. `lastPTYSize` changes on the
        // first resize, which means the terminal is on screen.
        var openedAt: TerminalSize?
        while openedAt == nil {
          openedAt = await transport.lastPTYSize
          if openedAt == nil { try? await Task.sleep(for: .milliseconds(25)) }
        }
        // The deadline only makes a build that sends no resize fail on the assertion.
        let deadline = ContinuousClock.now + .seconds(6)
        while ContinuousClock.now < deadline {
          if await transport.lastPTYSize != openedAt { break }
          try? await Task.sleep(for: .milliseconds(25))
        }
        // A beat more, so the test has seen the terminal.
        try? await Task.sleep(for: .seconds(2))
      } else {
        while await transport.authenticationAttempts.isEmpty {
          try? await Task.sleep(for: .milliseconds(25))
        }
        // `drop()` before the handshake finishes does nothing, so wait out the connect. Four
        // seconds, so "Connected" stays on screen long enough for XCUITest to see it.
        try? await Task.sleep(for: .seconds(4))
      }
      // The link stays away for a while, or the reconnect would succeed before anyone saw the
      // banner.
      //
      // Eight seconds, from `ReconnectSchedule`: attempts at 0, 1, 3, 7 and 15 seconds, so the
      // first four fall inside the outage and the banner is up for fifteen. Three seconds lost
      // the race to the first look at the screen.
      outage.begin(seconds: 8)
      await transport.drop()
    }
  }

  /// How long the launch's simulated outage still has to run.
  private static let outage = Outage()

  /// Whether this launch ends one pane's bridge stream with the link left up.
  ///
  /// No other flag reaches this. The link is fine and herdr has sent no `terminal.closed`;
  /// one stream just stopped, as when herdr restarts or a control process dies. It must not
  /// be reported as the pane closing.
  static var isEndingPaneStream: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingEndPaneStream")
  }

  /// One stream end per launch. The reattach opens a new stream on the same pane, so an
  /// unlatched arm would end every one of them.
  private static let streamEndIsArmed = OneShot()

  /// Arms the launch's one bare stream end, if this launch asked for one.
  private static func armTheStreamEnd(on transport: FakeSSHTransport) {
    guard isEndingPaneStream, streamEndIsArmed.take() else { return }
    Task {
      // First, wait for a pane bridge to open.
      while await transport.streamedCommands.contains(where: Self.isPaneBridge) == false {
        try? await Task.sleep(for: .milliseconds(25))
      }
      // Then wait for the pane to render on it, as in `armTheDrop`. The chat surface never
      // sends `terminal.resize`, because an observer must not reflow the pane, so a pane opened
      // on its chat waits out the whole deadline. Hence a short one.
      let deadline = ContinuousClock.now + .seconds(3)
      while ContinuousClock.now < deadline {
        let laidOut = await transport.streamLog.contains { $0.contains("terminal.resize") }
        if laidOut { break }
        try? await Task.sleep(for: .milliseconds(25))
      }
      // A beat more, so the test has seen the healthy pane.
      try? await Task.sleep(for: .seconds(2))
      await transport.endStreams(matching: Self.isPaneBridge)
    }
  }

  /// Whether this launch has herdr announce its own shutdown on the pane's bridge.
  ///
  /// For a capture of the notice bar. `TerminalBridge.closeReason(from:)` and
  /// `TerminalEndDisposition` are covered by `swift test`; only a capture shows whether
  /// "herdr stopped on the host." fits on one line.
  static var isAnnouncingHerdrShutdown: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingHerdrShutdown")
  }

  /// One shutdown per launch, like `dropIsArmed`.
  private static let herdrShutdownIsArmed = OneShot()

  /// Arms the launch's one herdr shutdown, if asked. As `armTheStreamEnd`: wait for a pane
  /// bridge, then its layout, then a beat, then send the record.
  private static func armTheHerdrShutdown(on transport: FakeSSHTransport) {
    guard isAnnouncingHerdrShutdown, herdrShutdownIsArmed.take() else { return }
    Task {
      while await transport.streamedCommands.contains(where: Self.isPaneBridge) == false {
        try? await Task.sleep(for: .milliseconds(25))
      }
      let deadline = ContinuousClock.now + .seconds(3)
      while ContinuousClock.now < deadline {
        let laidOut = await transport.streamLog.contains { $0.contains("terminal.resize") }
        if laidOut { break }
        try? await Task.sleep(for: .milliseconds(25))
      }
      try? await Task.sleep(for: .seconds(2))
      // herdr's own wording, so the capture shows the mapping that ships.
      let record = "{\"type\":\"terminal.closed\",\"reason\":\"server is shutting down\"}\n"
      await transport.emitOnStreams(Data(record.utf8), matching: Self.isPaneBridge)
    }
  }

  /// Whether this launch has the pane's bridge process exit nonzero with a line on stderr.
  ///
  /// For a capture of the notice bar, like `-uiTestingHerdrShutdown`. The mapping
  /// (`TerminalFrameDecoder.herdrMessage(fromStandardError:)`) and `TerminalEndDisposition` are
  /// covered by `swift test`.
  static var isFailingBridgeProcess: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingBridgeExitFailure")
  }

  /// One failure per launch, like `dropIsArmed`.
  private static let bridgeExitFailureIsArmed = OneShot()

  /// Arms the launch's one bridge-process failure, if asked. As `armTheHerdrShutdown`, but
  /// with an exit status and a stderr line.
  private static func armTheBridgeExitFailure(on transport: FakeSSHTransport) {
    guard isFailingBridgeProcess, bridgeExitFailureIsArmed.take() else { return }
    Task {
      while await transport.streamedCommands.contains(where: Self.isPaneController) == false {
        try? await Task.sleep(for: .milliseconds(25))
      }
      let deadline = ContinuousClock.now + .seconds(3)
      while ContinuousClock.now < deadline {
        let laidOut = await transport.streamLog.contains { $0.contains("terminal.resize") }
        if laidOut { break }
        try? await Task.sleep(for: .milliseconds(25))
      }
      try? await Task.sleep(for: .seconds(2))
      // herdr's own stderr shape and its status for a server error, so the capture shows the
      // mapping that ships.
      await transport.failStreams(
        matching: Self.isPaneController,
        exitStatus: 1,
        standardError: "herdr: failed to request terminal attach: pane not found\n"
      )
    }
  }

  /// The controller stream only, unlike `isPaneBridge`.
  ///
  /// An agent pane opens on its chat, so the observe stream exists first. Arming on it fires
  /// while the user is still switching to Terminal, and the bar shows over a controller that
  /// opened fine. Waiting for the controller also lets the `terminal.resize` wait end when the
  /// view is up, since an observer never resizes.
  private static let isPaneController: @Sendable (String) -> Bool = { command in
    command.contains("terminal session control")
  }

  /// Whether a streamed command is one of the two pane bridges, which carry a pane's frames.
  private static let isPaneBridge: @Sendable (String) -> Bool = { command in
    command.contains("terminal session control") || command.contains("terminal session observe")
  }

  /// Whether this launch forces `TerminalScreen`'s hardware-keyboard notice on.
  ///
  /// The simulator's hardware keyboard is the Mac's and cannot be disconnected from a test.
  /// `TerminalKeyboardUITests` uses this only to check that the notice renders. The state
  /// machine is covered by `KeyboardNoticeModelTests` with injected events.
  static var isForcingHardwareKeyboardNotice: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTestingHardwareKeyboardNotice")
  }

  /// Eighty numbered lines, more than any simulator's grid. Numbered, so a test can tell
  /// scrolling from redrawing.
  static let longTranscript: String =
    (1...80).map { "row \($0)" }.joined(separator: "\r\n") + "\r\n"

  /// What the fake shell prints when its PTY opens.
  private static var ptyGreeting: String {
    if isLongTranscript { return longTranscript }
    if isDemoTranscript { return demoTranscript }
    // U+F09B and U+E0B0 are Nerd Font glyphs, so a capture shows whether the bundled face draws
    // them, with bold, italic and bold italic words. Off the prompt line, which tests match.
    return "driverr fake shell \u{1B}[44;97m main \u{1B}[0;34m\u{E0B0}\u{1B}[0m \u{F09B}git "
      + "\u{1B}[1mbold\u{1B}[0m \u{1B}[3mitalic\u{1B}[0m \u{1B}[1;3mboth\u{1B}[0m\r\ncarson@workbox:~$ "
  }

  /// A plausible agent session, sized to fill a terminal on both store devices.
  ///
  /// Every line is under 48 columns, because the 6.9-inch portrait terminal is 55 wide and a
  /// wrapped line looks like a bug. It is longer than either device's terminal with the
  /// keyboard down, because the iPad then shows about 68 rows and the phone about 44, and a
  /// terminal shows its tail, so both devices end on the same lines with no blank rows under
  /// them. It ends on a question, which is what the app is about.
  static let demoTranscript = [
    "carson@workbox:~/api$ herdr attach api-refactor",
    "[herdr] attached to pane 3 (claude)",
    "",
    "● Task: make the connection pool async",
    "",
    "● Reading Cargo.toml",
    "● Reading src/main.rs",
    "  driverr-api v0.4.1, tokio 1.38, sqlx 0.7",
    "",
    "● Reading src/db/mod.rs",
    "● Reading src/db/pool.rs",
    "  Pool::open_session is the only sync entry",
    "  point left in the module.",
    "",
    "● Reading src/db/config.rs",
    "  max_connections = 16, idle_timeout = 30s",
    "",
    "● Grep \"spawn_blocking\" (2 files)",
    "  src/db/pool.rs:41",
    "  src/jobs/cleanup.rs:19",
    "",
    "● Reading src/jobs/cleanup.rs",
    "  The cleanup job holds a connection across",
    "  a sleep. It can use the async pool as is.",
    "",
    "● Reading src/routes/health.rs",
    "  The health check pings the pool directly.",
    "  It already awaits.",
    "",
    "● Ran tests: 41 passed, 0 failed",
    "  Baseline is green.",
    "",
    "● Grep \"open_session\" (3 files)",
    "  src/db/pool.rs:88",
    "  src/routes/session.rs:12",
    "  src/routes/session.rs:47",
    "",
    "● Reading src/routes/session.rs",
    "  Both call sites are inside handlers that",
    "  are already async.",
    "",
    "● Edited src/db/pool.rs",
    "  -  pub fn open_session(&self)",
    "  +  pub async fn open_session(&self)",
    "",
    "● Edited src/jobs/cleanup.rs",
    "  -  let conn = pool.get()?;",
    "  +  let conn = pool.acquire().await;",
    "",
    "● cargo check",
    "   Compiling driverr-api v0.4.1",
    "    Finished dev [unoptimized] in 4.21s",
    "",
    "● cargo clippy",
    "    Checking driverr-api v0.4.1",
    "    Finished dev [unoptimized] in 2.87s",
    "  No warnings.",
    "",
    "● Ran tests: 39 passed, 2 failed",
    "  session::opens_a_session",
    "  session::rejects_a_bad_token",
    "",
    "● Reading tests/session.rs",
    "  Both failures call open_session from a",
    "  sync test. They need #[tokio::test].",
    "",
    "● The pool is async now. Migrating the two",
    "  call sites changes the public API.",
    "",
    "  Proceed with the migration? (y/n)",
    "",
  ].joined(separator: "\r\n")
  #else
  // What a launch with no `-uiTesting` argument gets from the members above, for the callers
  // that are not `DEBUG` only themselves. A caller of any other member belongs inside
  // `#if DEBUG`, and only a Release build reports one that is not.

  static var forLaunch: AppEnvironment { .live }
  static var isUITesting: Bool { false }
  static var isRestoringSelection: Bool { true }
  static var keepsKeyboardAccessoryRow: Bool { false }
  static var isDemoTranscript: Bool { false }
  static var isForcingHardwareKeyboardNotice: Bool { false }
  static var seededPickedImage: Data? { nil }
  #endif
}

#if DEBUG
/// A window during which the fake host refuses to authenticate. A lock rather than an actor,
/// because `makeTransport` is a synchronous `@Sendable` closure that cannot await.
private final class Outage: @unchecked Sendable {
  private let lock = NSLock()
  private var endsAt: Date?

  func begin(seconds: TimeInterval) {
    lock.withLock { endsAt = Date().addingTimeInterval(seconds) }
  }

  var isOn: Bool {
    lock.withLock {
      guard let endsAt else { return false }
      return Date() < endsAt
    }
  }
}

/// Whether the growing session file has grown yet.
///
/// An actor, because both sides are already `async`. A latch rather than a clock, because the
/// start is the pane's stream opening, which only `armTheGrowth` knows. See
/// `armTheWorkingRow`.
private actor GrowthGate {
  private(set) var isOpen = false

  func open() { isOpen = true }
}

/// A latch that can be taken exactly once, for the life of the process. A lock rather than an
/// actor, because `makeTransport` is a synchronous `@Sendable` closure that cannot await.
private final class OneShot: @unchecked Sendable {
  private let lock = NSLock()
  private var taken = false

  func take() -> Bool {
    lock.withLock {
      if taken { return false }
      taken = true
      return true
    }
  }
}

/// What the paced fake last did, where XCUITest can read it.
///
/// The row clearing and the transfer stopping are two claims, and the generation guard in
/// `PaneAttachmentModel` clears the row either way. So the fake records where it was
/// cancelled, and the composer draws it as a 1x1 accessibility element with no identified
/// ancestor. Behind `-uiTestingPickedImage` only.
@MainActor
@Observable
final class UploadProbe {
  static let shared = UploadProbe()

  /// Empty until an upload is cancelled. Read as the element's accessibility label.
  private(set) var note = ""

  func record(cancelledAt sent: Int, of total: Int) {
    note = "cancelled at \(sent) of \(total)"
  }

  func reset() {
    note = ""
  }
}

/// An upload that never touches a socket and deliberately takes its time.
///
/// Paced, because a fake with no far side would finish before the composer redrew, and the
/// bytes-sent row would never be on screen. The progress stream is created in `init`, as in
/// `ImageUploader`, so no early event is lost.
final class PacedImageUpload: ImageUploading, Sendable {
  let progress: AsyncStream<ImageUploadProgress>

  private let signal: AsyncStream<ImageUploadProgress>.Continuation
  private let totalBytes: Int
  private let fileName: String
  private let step: Duration
  /// What the host refuses with, or `nil` for an upload that lands.
  private let failure: ImageUploadFailure?

  /// Eight, so the number moves visibly rather than jumping to done.
  private static let steps = 8

  init(totalBytes: Int, fileName: String, step: Duration, failure: ImageUploadFailure?) {
    self.totalBytes = totalBytes
    self.fileName = fileName
    self.step = step
    self.failure = failure
    let (stream, continuation) = AsyncStream.makeStream(of: ImageUploadProgress.self)
    progress = stream
    signal = continuation
  }

  func upload() async throws -> ImageUploadOutcome {
    signal.yield(ImageUploadProgress(bytesSent: 0, totalBytes: totalBytes))
    var sent = 0
    for completed in 1...Self.steps {
      do {
        // `try`, never `try?`: `try?` swallows the `CancellationError`, and the fake would run
        // on after Remove. `ImageUploader` does stop on cancellation.
        try await Task.sleep(for: step)
        try Task.checkCancellation()
      } catch {
        // Hopped, because this type is not main-actor and the probe is an `@Observable` the
        // composer reads.
        let stopped = sent
        let total = totalBytes
        Task { @MainActor in UploadProbe.shared.record(cancelledAt: stopped, of: total) }
        signal.finish()
        throw CancellationError()
      }
      // A failure lands part-way through, as a real one does when the host runs out of room.
      if failure != nil, completed > Self.steps / 2 { break }
      sent = totalBytes * completed / Self.steps
      signal.yield(ImageUploadProgress(bytesSent: sent, totalBytes: totalBytes))
    }
    signal.finish()
    if let failure { throw failure }
    // The shape the real command prints: `$HOME` expanded by the host, then the inbox.
    return ImageUploadOutcome(
      hostPath: "/home/carson/.driverr/inbox/" + fileName, bytesSent: totalBytes)
  }
}
#endif

private struct AppEnvironmentKey: EnvironmentKey {
  // Live in Release, where `ephemeral` does not exist: a view that misses its injection
  // gets the real stores there, and the in-memory ones in a preview or a test.
  #if DEBUG
  static let defaultValue = AppEnvironment.ephemeral
  #else
  static let defaultValue = AppEnvironment.live
  #endif
}

extension EnvironmentValues {
  var appEnvironment: AppEnvironment {
    get { self[AppEnvironmentKey.self] }
    set { self[AppEnvironmentKey.self] = newValue }
  }
}
