import DriverrCore
import Foundation

/// Persists the global settings in `UserDefaults`.
///
/// One blob, not a key per setting: they are read, written and versioned together, and
/// `TerminalSettings`' decoder recovers field by field from an older build's blob.
actor UserDefaultsSettingsStore: SettingsStore {
  private let defaults: UserDefaults
  private let key = "com.cunderw.driverr.settings"

  /// Takes a suite name, not an instance; see `UserDefaultsHostStore.init(suiteName:)`.
  init(suiteName: String? = nil) {
    defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
  }

  func settings() async -> TerminalSettings {
    guard let data = defaults.data(forKey: key) else { return .default }
    // An unreadable blob costs the user their settings, not their app.
    return (try? JSONDecoder().decode(TerminalSettings.self, from: data)) ?? .default
  }

  func save(_ settings: TerminalSettings) async {
    guard let data = try? JSONEncoder().encode(settings) else { return }
    defaults.set(data, forKey: key)
  }
}
