import DriverrCore
import Foundation
import Observation
import SwiftUI

/// The Live Activity preferences: the global switch and the per-host Start/Stop.
///
/// Injected through the environment, like `SettingsModel`, so a preview or a UI test builds
/// its own. The global switch is owned by `TerminalSettings` and pushed in by `ContentView`,
/// so this type persists only the per-host overrides.
@MainActor
@Observable
final class LiveActivityPreferencesModel {
  private(set) var preferences = LiveActivityPreferences()

  @ObservationIgnored private let store: any LiveActivityPreferenceStore

  init(store: any LiveActivityPreferenceStore) {
    self.store = store
  }

  func load() async {
    preferences.hostOverrides = await store.hostOverrides()
  }

  /// The global switch moved, or was read at launch.
  func setEnabled(_ enabled: Bool) {
    preferences.isEnabled = enabled
  }

  /// Whether this host's own Start/Stop reads as started, ignoring the global switch.
  func isStarted(for hostID: UUID) -> Bool { preferences.isStarted(for: hostID) }

  func setStarted(_ started: Bool, for hostID: UUID) {
    update { $0.set(started, for: hostID) }
  }

  /// Removes a deleted host's entry.
  func forget(_ hostID: UUID) {
    guard preferences.hostOverrides[hostID.uuidString] != nil else { return }
    update { $0.forget(hostID) }
  }

  /// Writes go to memory at once and to the store in the background, so a menu item retitles
  /// without waiting on `UserDefaults`.
  private func update(_ change: (inout LiveActivityPreferences) -> Void) {
    var next = preferences
    change(&next)
    guard next != preferences else { return }
    preferences = next
    let overrides = next.hostOverrides
    Task { [store] in await store.save(overrides) }
  }
}

/// Persists the per-host overrides in `UserDefaults`.
///
/// Its own key, not the settings blob's, so an unreadable blob loses the theme and not the
/// Start/Stop decisions, and the reverse.
actor UserDefaultsLiveActivityPreferenceStore: LiveActivityPreferenceStore {
  private let defaults: UserDefaults
  private let key = "com.cunderw.driverr.liveActivityHosts"

  /// Takes a suite name because `UserDefaults` is not `Sendable`.
  init(suiteName: String? = nil) {
    defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
  }

  func hostOverrides() async -> [String: Bool] {
    guard let data = defaults.data(forKey: key) else { return [:] }
    return (try? JSONDecoder().decode([String: Bool].self, from: data)) ?? [:]
  }

  func save(_ hostOverrides: [String: Bool]) async {
    guard let data = try? JSONEncoder().encode(hostOverrides) else { return }
    defaults.set(data, forKey: key)
  }
}

private struct LiveActivityPreferencesModelKey: EnvironmentKey {
  // Live in Release, for the reason `SettingsModelKey` gives and with the same hazard: a view
  // that misses its injection there would save over the stored Start/Stop decisions.
  #if DEBUG
  @MainActor static let fallback = LiveActivityPreferencesModel(
    store: InMemoryLiveActivityPreferenceStore())
  #else
  @MainActor static let fallback = LiveActivityPreferencesModel(
    store: AppEnvironment.live.liveActivityPreferences)
  #endif
  nonisolated static var defaultValue: LiveActivityPreferencesModel {
    MainActor.assumeIsolated { fallback }
  }
}

extension EnvironmentValues {
  var liveActivityPreferences: LiveActivityPreferencesModel {
    get { self[LiveActivityPreferencesModelKey.self] }
    set { self[LiveActivityPreferencesModelKey.self] = newValue }
  }
}
