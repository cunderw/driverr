import DriverrCore
import Foundation
import Testing

@testable import Driverr

/// The app half of the App Group. `DriverrTests` is app-hosted, so these carry the app's
/// entitlements. The widget half has no automated gate: SpringBoard draws it and XCUITest
/// reaches none of it, so only a `scripts/look.sh` capture of the Lock Screen card proves it.
@Suite("App Group container", .serialized, .timeLimit(.minutes(1)))
struct AppGroupContainerTests {
  /// The probe that fails when the entitlement is missing. Without it,
  /// `UserDefaults(suiteName:)` can return a working per-process store, so app and widget read
  /// different files with no error. `containerURL(forSecurityApplicationGroupIdentifier:)`
  /// returns `nil`.
  @Test("The app can reach the shared container")
  func theContainerExists() {
    let url = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: WidgetThemeSnapshot.appGroupID)
    #expect(
      url != nil,
      """
      No container for \(WidgetThemeSnapshot.appGroupID). Driverr/Driverr.entitlements is \
      missing, empty, or not wired into CODE_SIGN_ENTITLEMENTS on EB01/EB02.
      """)
  }

  /// What the store writes has to be readable by a freshly constructed `UserDefaults` under the
  /// documented key, as the widget reads it on every render.
  @Test("A published snapshot is readable back out of the suite")
  func aPublishedSnapshotIsReadableBack() async throws {
    let suite = try #require(UserDefaults(suiteName: WidgetThemeSnapshot.appGroupID))
    let key = WidgetThemeSnapshot.defaultsKey
    // A UI capture run publishes into this container, so put back what was here.
    let previous = suite.data(forKey: key)
    defer {
      if let previous {
        suite.set(previous, forKey: key)
      } else {
        suite.removeObject(forKey: key)
      }
    }

    await AppGroupWidgetThemeStore().publish(WidgetThemeSnapshot(theme: .gruvbox))

    let reread = try #require(UserDefaults(suiteName: WidgetThemeSnapshot.appGroupID))
    let decoded = try #require(
      WidgetThemeSnapshot.decode(reread.data(forKey: key)),
      "Nothing decodable at \(key) after a publish")
    #expect(decoded.themeID == "gruvbox")
    #expect(decoded.dark.accent == Theme.gruvbox.accent(for: .dark))
    #expect(decoded.dark.accentForeground == Theme.gruvbox.accent(for: .dark).readableForeground)
  }

  /// The live environment publishes; a model built without a store does not, so a preview or
  /// unit test does not write into the container it shares with the shipped app.
  @Test("The live environment carries the App Group store and ephemeral does too")
  func bothEnvironmentsPublishForReal() {
    #expect(AppEnvironment.live.widgetTheme is AppGroupWidgetThemeStore)
    // Deliberate; see the property in `AppEnvironment`. A silent store here would make the
    // Lock Screen capture a fixture that cannot fail.
    #expect(AppEnvironment.ephemeral.widgetTheme is AppGroupWidgetThemeStore)
  }

  @MainActor
  @Test("Loading settings publishes the stored theme, and only a theme change republishes")
  func publishesOnLoadAndOnThemeChangeOnly() async throws {
    let published = RecordingWidgetThemeStore()
    let model = SettingsModel(
      store: InMemorySettingsStore(TerminalSettings(themeID: "nord")),
      widgetTheme: published
    )

    await model.load()
    try await expectPublished(["nord"], on: published)

    // A font step must not write a colour. Asserted after the theme change below is observed,
    // so a write that had not landed cannot pass as no write.
    model.growFont()

    model.select(theme: .dracula)
    try await expectPublished(["nord", "dracula"], on: published)
  }

  /// Waits for the publish, driven by the publish. `SettingsModel` publishes from an
  /// unstructured `Task`, so a single `Task.yield()` is not enough.
  ///
  /// `RecordingWidgetThemeStore.publish` signals the shared waker, and `published` is actor
  /// state, so this is `waitUntilSignalled`. A spurious write makes the exact list unreachable;
  /// the suite's `.timeLimit` ends the wait, and the `#expect` after it prints what was
  /// published.
  @MainActor
  private func expectPublished(
    _ expected: [String],
    on store: RecordingWidgetThemeStore
  ) async throws {
    await waitUntilSignalled("the published themes never became \(expected)") {
      await store.published.map(\.themeID) == expected
    }
    #expect(await store.published.map(\.themeID) == expected)
  }
}

/// A `WidgetThemeStore` that records what was published and says so.
///
/// `DriverrCore.InMemoryWidgetThemeStore` records but cannot signal a waiter in this target,
/// and a hook for that does not belong in a shipped module. Otherwise identical.
actor RecordingWidgetThemeStore: WidgetThemeStore {
  private(set) var published: [WidgetThemeSnapshot] = []

  func publish(_ snapshot: WidgetThemeSnapshot) async {
    published.append(snapshot)
    Waker.signalShared()
  }
}
