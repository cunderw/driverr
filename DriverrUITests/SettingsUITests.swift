import XCTest

/// One launch for the whole class.
///
/// Every test is read-only: it opens settings, looks, and closes them, so no test leaves
/// state for the next. `tearDown` closes settings, so each test also starts where the last
/// one did. Tests that change settings are in `SettingsMutationUITests`.
@MainActor
final class SettingsUITests: XCTestCase {
  /// Launched on first use and reused. Lazy, because `XCUIApplication` cannot be built
  /// before the test runner is up.
  private static var sharedApp: XCUIApplication?

  private func app() -> XCUIApplication {
    if let existing = Self.sharedApp { return existing }
    let app = XCUIApplication()
    app.launchArguments += ["-uiTesting"]
    app.launch()
    Self.sharedApp = app
    return app
  }

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    // Close settings however the test ended, or the class is order-dependent. `tearDown` is
    // nonisolated, so the whole body, reading the shared app included, runs inside the
    // isolation.
    MainActor.assumeIsolated {
      guard let app = Self.sharedApp else { return }
      let done = app.descendants(matching: .any)
        .matching(identifier: "settings.done").firstMatch
      if done.exists { done.tap() }
    }
    super.tearDown()
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  @discardableResult
  private func require(
    _ app: XCUIApplication,
    _ identifier: String,
    _ message: String,
    timeout: TimeInterval = 10,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> XCUIElement {
    let match = element(app, identifier)
    XCTAssertTrue(
      match.waitForExistence(timeout: timeout),
      "\(message)\nLooked for '\(identifier)'. Tree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
    return match
  }

  /// Opens Settings from the host list's overflow menu.
  private func openSettings() -> XCUIApplication {
    let app = app()
    openHostsOverflow(app)
    require(app, "settings.open", "Expected a way into settings").tap()
    // Preview is the first section, so it is on screen without scrolling on every device.
    require(app, "settings.preview", "Expected the settings screen")
    return app
  }

  /// Eight themes are more rows than the iPad form sheet shows, hence `scrollIntoReach`. The
  /// ids follow `Theme.bundled`'s order, because it only scrolls forward.
  func testSettingsOffersEveryBundledTheme() {
    let app = openSettings()
    let themes = [
      "system", "solarized", "nord", "tokyo-night", "catppuccin", "gruvbox", "dracula",
      "one-dark",
    ]
    for theme in themes {
      XCTAssertTrue(
        scrollIntoReach(app, "settings.theme.\(theme)").exists,
        "Expected the \(theme) theme to be offered"
      )
    }
  }

  func testSettingsOffersEveryBundledFont() {
    let app = openSettings()
    for font in ["jetbrains-mono", "system-mono", "menlo", "courier"] {
      XCTAssertTrue(
        scrollIntoReach(app, "settings.font.\(font)").exists,
        "Expected the \(font) font to be offered"
      )
    }
  }

  func testSettingsOffersAFontSizeControlAndAPreview() {
    let app = openSettings()
    // Preview first, because `scrollIntoReach` only scrolls forward.
    scrollIntoReach(app, "settings.preview")
    scrollIntoReach(app, "settings.fontsize")
  }

  /// A notice, not a setting: it appears when notifications are denied and deep-links to
  /// iOS Settings.
  ///
  /// `AppEnvironment.ephemeral`'s `SilentNotificationCenter` reports `.denied`, so every UI
  /// run shows it. The visibility rule is `NotificationsOffNoticeTests`. Not tapped,
  /// because leaving for iOS Settings would strand the shared launch.
  func testSettingsExplainsThatNotificationsAreOff() {
    let app = openSettings()
    XCTAssertTrue(
      scrollIntoReach(app, "settings.notifications.off").exists,
      "Expected the notifications-are-off row on a launch whose authorization is denied"
    )
  }

  /// The wrap toggle defaults on with a fresh `InMemorySettingsStore`. Never tapped here;
  /// `SettingsMutationUITests` owns the flip.
  func testSettingsOffersTheWrapToggle() {
    let app = openSettings()
    let toggle = scrollIntoReach(app, "settings.wraplines")
    XCTAssertTrue(toggle.exists, "Expected a wrap toggle on the settings screen")
    XCTAssertEqual(
      app.switches["settings.wraplines"].value as? String,
      "1",
      "Wrapping must default on: it is what every pane screen drew before the setting "
        + "existed.\nTree was:\n\(app.debugDescription)"
    )
  }

  /// The Live Activities toggle defaults on with a fresh `InMemorySettingsStore`. Never
  /// tapped here; `SettingsMutationUITests` owns the flip.
  func testSettingsOffersTheLiveActivityToggle() {
    let app = openSettings()
    let toggle = scrollIntoReach(app, "settings.liveactivities")
    XCTAssertTrue(toggle.exists, "Expected a Live Activities toggle on the settings screen")
    XCTAssertEqual(
      app.switches["settings.liveactivities"].value as? String,
      "1",
      "Live Activities must default on: that is what every install draws today, and the "
        + "setting exists to turn them off rather than to turn them on.\nTree was:\n"
        + "\(app.debugDescription)"
    )
  }

  /// Settings are theme, font, size, wrap and Live Activities, and nothing else, so a sixth
  /// section fails a test rather than passing a review.
  func testSettingsOffersNothingElse() {
    let app = openSettings()
    // In the form's order, because the walk only swipes forward.
    for header in ["Preview", "Theme", "Font", "Font Size", "Pane Screen", "Live Activities"] {
      var seen = app.staticTexts[header].exists
      for _ in 0..<5 where !seen {
        app.swipeUp()
        seen = app.staticTexts[header].exists
      }
      XCTAssertTrue(seen, "Expected a '\(header)' section.\nTree was:\n\(app.debugDescription)")
    }
    // Anything a future setting would plausibly be filed under.
    for absent in ["Advanced", "Terminal", "Behavior", "Behaviour", "Bell", "Scrollback"] {
      XCTAssertFalse(
        app.staticTexts[absent].exists,
        "Settings grew a '\(absent)' section. Driverr has five settings, and a "
          + "sixth has to argue its case in its own issue."
      )
    }
  }
}

/// Relaunches per test, because every test changes a setting, and a shared launch would hand
/// the next test the previous one's choice.
@MainActor
final class SettingsMutationUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func launchApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-uiTesting"]
    app.launch()
    return app
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  @discardableResult
  private func require(
    _ app: XCUIApplication,
    _ identifier: String,
    _ message: String,
    timeout: TimeInterval = 10,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> XCUIElement {
    let match = element(app, identifier)
    XCTAssertTrue(
      match.waitForExistence(timeout: timeout),
      "\(message)\nLooked for '\(identifier)'. Tree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
    return match
  }

  /// Opens Settings from the host list's overflow menu.
  private func openSettings(_ app: XCUIApplication) {
    openHostsOverflow(app)
    require(app, "settings.open", "Expected a way into settings").tap()
    require(app, "settings.preview", "Expected the settings screen")
  }

  func testThemeChoicePersistsAcrossSettingsVisits() {
    let app = launchApp()
    openSettings(app)

    element(app, "settings.theme.nord").tap()
    require(app, "settings.done", "Expected a way out of settings").tap()

    openSettings(app)
    let nord = require(app, "settings.theme.nord", "Expected the nord row")
    XCTAssertTrue(
      nord.isSelected,
      "Expected the chosen theme to still be selected. Row was: \(nord.debugDescription)"
    )
  }

  /// The wrap choice is still there on the next visit. `setSwitch`, because tapping a
  /// `Toggle`'s identifier does not flip it. `scrollIntoReach` first, because `setSwitch`
  /// taps a coordinate, and a row that exists under the sheet's bottom edge puts that
  /// coordinate on the backdrop.
  func testWrapChoicePersistsAcrossSettingsVisits() {
    let app = launchApp()
    openSettings(app)

    scrollIntoReach(app, "settings.wraplines")
    setSwitch(app, "settings.wraplines", on: false)
    require(app, "settings.done", "Expected a way out of settings").tap()

    openSettings(app)
    scrollIntoReach(app, "settings.wraplines")
    XCTAssertEqual(
      app.switches["settings.wraplines"].value as? String,
      "0",
      "Expected wrapping to still be off on the way back in.\nTree was:\n"
        + "\(app.debugDescription)"
    )
  }

  /// Live Activities stay off on the next visit, or the app would draw a card for somebody
  /// who said no. `setSwitch`, as above.
  func testLiveActivityChoicePersistsAcrossSettingsVisits() {
    let app = launchApp()
    openSettings(app)

    scrollIntoReach(app, "settings.liveactivities")
    setSwitch(app, "settings.liveactivities", on: false)
    require(app, "settings.done", "Expected a way out of settings").tap()

    openSettings(app)
    scrollIntoReach(app, "settings.liveactivities")
    XCTAssertEqual(
      app.switches["settings.liveactivities"].value as? String,
      "0",
      "Expected Live Activities to still be off on the way back in.\nTree was:\n"
        + "\(app.debugDescription)"
    )
  }
}
