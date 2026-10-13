import DriverrCore
import Observation
import SwiftUI

/// The live settings, shared by the settings screen, every terminal and every captured pane
/// screen.
///
/// One instance, injected through the environment, so a preview or UI test builds its own.
/// Writes update memory at once and the store in the background, so a font-size step
/// redraws without waiting on `UserDefaults`.
@MainActor
@Observable
final class SettingsModel {
  private(set) var settings: TerminalSettings = .default

  @ObservationIgnored private let store: any SettingsStore

  /// Where the theme's accent goes for the Live Activity widget. A separate store, because
  /// the widget is another process and reads the shared app-group container.
  @ObservationIgnored private let widgetTheme: any WidgetThemeStore

  init(store: any SettingsStore, widgetTheme: any WidgetThemeStore) {
    self.store = store
    self.widgetTheme = widgetTheme
  }

  func load() async {
    settings = await store.settings()
    // On launch too, because the container can be empty while settings are not, for
    // example after a reinstall.
    publishWidgetTheme()
  }

  func select(theme: Theme) {
    update { $0.themeID = theme.id }
  }

  func select(font: TerminalFont) {
    update { $0.fontID = font.id }
  }

  func setFontSize(_ size: Double) {
    update { $0.setFontSize(size) }
  }

  /// Which layout every captured pane screen is drawn in. `PaneScreenView` reads it from
  /// `settings`.
  func setWrapsScreenLines(_ on: Bool) {
    update { $0.wrapsScreenLines = on }
  }

  /// Whether Driverr may draw a Live Activity. `ContentView` watches this and tells the
  /// driver, which ends a card already on the Lock Screen.
  func setLiveActivities(_ on: Bool) {
    update { $0.liveActivities = on }
  }

  func growFont() { update { $0.growFont() } }
  func shrinkFont() { update { $0.shrinkFont() } }

  private func update(_ change: (inout TerminalSettings) -> Void) {
    var next = settings
    change(&next)
    guard next != settings else { return }
    // Only a theme change publishes the widget theme.
    let themeChanged = next.themeID != settings.themeID
    settings = next
    Task { [store] in await store.save(next) }
    if themeChanged { publishWidgetTheme() }
  }

  /// **A card already on the Lock Screen keeps its old colour until its next content
  /// update**, up to `BackgroundRefreshPolicy.interval`. The accent is not in
  /// `ContentState`, and forcing an `Activity.update` for a colour would spend the update
  /// budget that `BlockedPaneActivityPlan.refreshFloor` protects.
  private func publishWidgetTheme() {
    let snapshot = WidgetThemeSnapshot(theme: settings.theme)
    Task { [widgetTheme] in await widgetTheme.publish(snapshot) }
  }
}

private struct SettingsModelKey: EnvironmentKey {
  // Live in Release, where the in-memory stores do not exist, as `AppEnvironmentKey` is.
  // **Nothing loads this model**, so a view that misses its injection there would save the
  // default settings over the stored ones on its first change. Every reader descends from
  // `DriverrApp`'s `.environment(\.settingsModel, …)`. A new reader must too.
  #if DEBUG
  @MainActor static let fallback = SettingsModel(
    store: InMemorySettingsStore(), widgetTheme: InMemoryWidgetThemeStore())
  #else
  @MainActor static let fallback = SettingsModel(
    store: AppEnvironment.live.settingsStore, widgetTheme: AppEnvironment.live.widgetTheme)
  #endif
  nonisolated static var defaultValue: SettingsModel {
    MainActor.assumeIsolated { fallback }
  }
}

extension EnvironmentValues {
  var settingsModel: SettingsModel {
    get { self[SettingsModelKey.self] }
    set { self[SettingsModelKey.self] = newValue }
  }
}
