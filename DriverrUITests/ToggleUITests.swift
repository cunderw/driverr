import XCTest

/// The host form's toggles, and the key-auth flow they drive.
///
/// Tapping a `Toggle`'s identifier taps the row, and the value silently stays put; a host
/// once saved with password auth that way. `setSwitch` flips the switch and asserts it moved.
///
/// Hand-driven on purpose: the key-auth tests generate a key, fill in the add-host form and
/// connect, so they fail if that path breaks. Seeding would delete their subject. Relaunches
/// per test, because tests add hosts and keys and record trust decisions.
///
/// A very slow run on `Driverr iPad` has been a simulator stall on
/// `App animations complete notification not received`, not this code. Read the log first.
@MainActor
final class ToggleUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
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

  private func launch(seedHost: Bool = false) -> XCUIApplication {
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments += ["-uiTesting"] + (seedHost ? ["-uiTestingSeedHost"] : [])
    app.launch()
    return app
  }

  func testTheAuthToggleActuallyMoves() {
    let app = launch()
    require(app, "hosts.add", "Expected an add-host button").tap()

    setSwitch(app, "host.usesKey", on: true)

    // The form reacts: with no keys yet, the "no keys" notice appears only if the binding
    // changed.
    require(app, "host.noKeys", "Expected the form to react to key auth being turned on")

    setSwitch(app, "host.usesKey", on: false)
    XCTAssertFalse(
      element(app, "host.noKeys").exists,
      "Expected the key section to go away when the toggle goes back off"
    )
  }

  /// With key auth on and no key, Save is disabled rather than falling back to password
  /// auth. The form's Generate button then selects the new key and enables Save.
  func testGeneratingAKeyFromTheFormSelectsItAndEnablesSave() {
    let app = launch()
    require(app, "hosts.add", "Expected an add-host button").tap()

    require(app, "host.name", "Expected a name field").tap()
    app.typeText("keybox")
    require(app, "host.hostname", "Expected a hostname field").tap()
    app.typeText("10.1.0.9")
    require(app, "host.username", "Expected a username field").tap()
    app.typeText("carson")

    setSwitch(app, "host.usesKey", on: true)
    require(app, "host.noKeys", "Expected no keys yet")

    // `app.buttons`, not an `.any` match. A toolbar `.confirmationAction` button sits in
    // wrapper views with the same identifier, and the first match depth-first is a wrapper
    // that always reports enabled. A tap still lands; only `.isEnabled` reads it wrong.
    let save = app.buttons["host.save"]
    XCTAssertTrue(
      save.waitForExistence(timeout: 10),
      "Expected a save button.\nTree was:\n\(app.debugDescription)"
    )
    XCTAssertFalse(
      save.isEnabled,
      "Save must be disabled with key auth on and no key picked"
    )

    // Typing and the toggle both move the content-sized card on `Driverr iPad`.
    let generate = require(app, "host.generateKey", "Expected a way to generate a key")
    waitUntilStill(app, generate, waitingForKeyboard: false)
    generate.tap()

    require(app, "host.keyPicker", "Expected the newly generated key to be selectable")
    XCTAssertFalse(
      element(app, "host.noKeys").exists,
      "Expected the 'no keys' notice to go away once a key was generated"
    )
    XCTAssertTrue(
      save.isEnabled,
      "Generating a key from the form must select it and enable Save"
    )

    // The card can still be moving. See `waitUntilStill`.
    waitUntilStill(app, save, waitingForKeyboard: false)
    save.tap()
    require(app, "hosts.row", "Expected the new host").tap()
    XCTAssertFalse(
      element(app, "connect.password").waitForExistence(timeout: 3),
      "A key-auth host must not ask for a password.\nTree was:\n\(app.debugDescription)"
    )
  }

  /// A key-auth host needs nothing from the user, so it connects on appearance with no
  /// Connect tap. The host key prompt still shows, because it is consent to a machine's
  /// identity, not a credential.
  func testAKeyAuthHostConnectsOnAppearanceWithoutATap() {
    let app = launch()

    // A key has to exist before the form can point at one.
    openHostsOverflow(app)
    require(app, "keys.open", "Expected a way into key management").tap()
    require(app, "keys.add", "Expected an add-key menu").tap()
    require(app, "keys.generate", "Expected a generate action").tap()
    require(app, "keys.row", "Expected the generated key", timeout: 20)
    require(app, "keys.done", "Expected a way out of the keys sheet").tap()

    require(app, "hosts.add", "Expected an add-host button").tap()
    require(app, "host.name", "Expected a name field").tap()
    app.typeText("keybox")
    require(app, "host.hostname", "Expected a hostname field").tap()
    app.typeText("10.1.0.9")
    require(app, "host.username", "Expected a username field").tap()
    app.typeText("carson")
    setSwitch(app, "host.usesKey", on: true)
    require(app, "host.keyPicker", "Expected a key to pick, now that one exists")
    let save = require(app, "host.save", "Expected a save button")
    waitUntilStill(app, save, waitingForKeyboard: false)
    save.tap()

    require(app, "hosts.row", "Expected the new host").tap()

    // Saved as `.identity`, because only a password host shows a password field.
    XCTAssertFalse(
      element(app, "connect.password").waitForExistence(timeout: 3),
      "A key-auth host must not ask for a password.\nTree was:\n\(app.debugDescription)"
    )

    // Nothing is tapped to connect. First contact still asks about the host key.
    tapTrustPrompt(app, "Expected first contact to still ask about the host key")
    require(
      app,
      "connect.connected",
      "Expected a key-auth host to connect on appearance",
      timeout: 15
    )
    XCTAssertFalse(
      element(app, "connect.connect").exists,
      "A host that needs nothing from the user must not be asking for a tap."
        + "\nTree was:\n\(app.debugDescription)"
    )
  }

  func testTheRememberPasswordToggleUsesTheSameHandle() {
    // `connect.remember` has the auth toggle's shape, so it needs `setSwitch` too.
    let app = launch(seedHost: true)

    require(app, "hosts.row", "Expected the seeded host").tap()

    setSwitch(app, "connect.remember", on: true)
    setSwitch(app, "connect.remember", on: false)
  }
}
