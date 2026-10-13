import DriverrCore
import SwiftUI
import UserNotifications

@main
struct DriverrApp: App {
  /// Resolved once at launch: the real Keychain, or an in-memory store for a UI test.
  private let environment: AppEnvironment

  /// Owned here so the app has exactly one. A model rebuilt by a view's body would give the
  /// settings screen and the terminal two objects that do not see each other's changes.
  @State private var settingsModel: SettingsModel

  /// The per-host Start/Stop, owned here for the reason `settingsModel` is.
  @State private var liveActivityPreferences: LiveActivityPreferencesModel

  /// Turns a notification tap into an open pane.
  ///
  /// Held for the app's lifetime because `UNUserNotificationCenter.delegate` is `weak`.
  private let notificationTaps: NotificationTapRouter?

  /// What a `BGAppRefreshTask` runs when the system launches Driverr in the background.
  /// Held for the app's lifetime because the handler registered in `init` captures it.
  private let backgroundRefresh: BackgroundRefreshRunner?

  /// Continue in Background: the one run, and the state both surfaces read.
  ///
  /// Built on every launch, including a UI run, because the pane menu and the host screen
  /// read it. A UI run stays safe because `AppEnvironment.ephemeral` supplies
  /// `SilentBackgroundWatchScheduler`.
  @State private var backgroundWatch: BackgroundWatchRunner

  init() {
    let environment = AppEnvironment.forLaunch
    self.environment = environment
    _settingsModel = State(
      initialValue: SettingsModel(
        store: environment.settingsStore,
        // From the environment, so a test can pass a store that never writes to the shared
        // container.
        widgetTheme: environment.widgetTheme))
    _liveActivityPreferences = State(
      initialValue: LiveActivityPreferencesModel(store: environment.liveActivityPreferences))
    let watch = BackgroundWatchRunner(environment: environment)
    _backgroundWatch = State(initialValue: watch)

    // Set from `init`, before any body runs, so a tap that cold-launches the app is delivered.
    // Not set under `-uiTesting`, where nothing can post a notification.
    if AppEnvironment.isUITesting {
      notificationTaps = nil
    } else {
      let router = NotificationTapRouter(presenter: TerminalPresenter.shared)
      notificationTaps = router
      UNUserNotificationCenter.current().delegate = router
    }

    // Registered from `init` because `BGTaskScheduler` requires every handler before launch
    // finishes. A task with no handler is never launched, silently. Skipped under
    // `-uiTesting`, as a second guard beside the silent scheduler.
    if AppEnvironment.isUITesting {
      backgroundRefresh = nil
    } else {
      let runner = BackgroundRefreshRunner(environment: environment)
      backgroundRefresh = runner
      environment.backgroundRefresh.register { await runner.run() }
    }

    // Continued-processing registrations are exempt from that rule, but registering here
    // costs nothing. This runs under `-uiTesting` too, because only the scheduler's `submit`
    // must stay silent. `debug.backgroundWatch.register` reports the answer.
    watch.register()

    #if DEBUG
    // `-uiTestingOpen <paneID>` is requested from `init`, before any body runs, so
    // `LaunchUITests` drives the same pre-configure route a notification tap takes. The seed
    // host has a fixed UUID, so no store read is needed.
    if let paneID = AppEnvironment.launchPaneID {
      TerminalPresenter.shared.requestOpen(
        hostID: DriverrCore.Host.uiTestSeed.id,
        paneID: paneID
      )
    }

    // `-uiTestingOpenURL <url>`, for the same reason: a Live Activity tap cold-launches the
    // app. It goes through the same `ActivityURLRouter` as `onOpenURL` below.
    if let url = AppEnvironment.launchOpenURL {
      ActivityURLRouter.route(url: url, to: TerminalPresenter.shared)
    }
    #endif
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        #if DEBUG
        .blockedPaneActivityCapture(settings: settingsModel)
        .blockedPaneActivityProbe()
        .backgroundWatchProbe(runner: backgroundWatch)
        #endif
        .environment(\.appEnvironment, environment)
        .environment(\.settingsModel, settingsModel)
        .environment(\.liveActivityPreferences, liveActivityPreferences)
        .environment(\.backgroundWatch, backgroundWatch)
        // The theme's ANSI 4 drives the app accent. Set here because an environment value
        // does not reach a sheet attached above it, and every sheet is attached below
        // `ContentView`'s own modifiers.
        .themeAccent(from: settingsModel)
        // A Live Activity tap arrives as a URL, because the widget runs in another process.
        // `BlockedPaneActivityRoute` defines both ends.
        .onOpenURL { ActivityURLRouter.route(url: $0, to: TerminalPresenter.shared) }
        .task { await settingsModel.load() }
    }
    // The pane scene's keys, listed in the iPadOS menu bar.
    .commands { PaneCommands() }
  }
}
