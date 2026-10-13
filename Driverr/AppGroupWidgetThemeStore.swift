import DriverrCore
import Foundation

/// Publishes the chosen theme's accent into the App Group the Live Activity widget reads.
///
/// Takes a suite name because `UserDefaults` is not `Sendable`.
///
/// A missing App Group entitlement is silent. `UserDefaults(suiteName:)` can return a working
/// per-process store, so the app writes, the widget reads, and neither sees the other. The
/// check that fails is `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`,
/// which `DriverrTests/AppGroupContainerTests.swift` asserts.
actor AppGroupWidgetThemeStore: WidgetThemeStore {
  private let defaults: UserDefaults?

  init(suiteName: String = WidgetThemeSnapshot.appGroupID) {
    defaults = UserDefaults(suiteName: suiteName)
  }

  func publish(_ snapshot: WidgetThemeSnapshot) async {
    guard let defaults, let data = snapshot.encoded() else { return }
    defaults.set(data, forKey: WidgetThemeSnapshot.defaultsKey)
  }
}
