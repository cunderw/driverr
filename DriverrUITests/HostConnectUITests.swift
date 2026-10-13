import XCTest

/// Covers the connect flow's wiring and its error surfaces. The protocol behaviour is
/// proven against a real SSH server in `DriverrKit`; this shows that a user can add a host,
/// reach it, and see what happened.
///
/// Most tests are hand-driven on purpose, through the add-host form, the password field and
/// the trust prompt. They are what fails if the connect path breaks, so seeding them would
/// delete their subject. The slow-handshake and stalled set-up tests seed the password so
/// the connecting state starts on appearance, and the Background-section tests use
/// `connectedHostApp`. Relaunches per test, because tests add hosts and record trust
/// decisions.
@MainActor
final class HostConnectUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func launchApp(
    seedingHost: Bool = false,
    droppingAfterConnect: Bool = false,
    withAChangedHostKey: Bool = false,
    /// Any other launch flags a test needs.
    extraArguments: [String] = []
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-uiTesting"] + extraArguments
    // One host already in the list, so a test that needs two drives the form once.
    if seedingHost { app.launchArguments += ["-uiTestingSeedHost"] }
    // The fake drops the link a moment after it authenticates, like a phone changing
    // networks, at a point a test can wait for.
    if droppingAfterConnect { app.launchArguments += ["-uiTestingDropAfterConnect"] }
    // The seeded host's stored key is wrong, as a rebuilt server looks. See
    // `AppEnvironment.isSeedingAChangedHostKey`.
    if withAChangedHostKey { app.launchArguments += ["-uiTestingHostKeyChanged"] }
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

  /// Finds a row that may be below the fold. The session tree pushes "Run a command"
  /// off-screen on a phone, where SwiftUI has not built it yet.
  @discardableResult
  private func scrollTo(
    _ app: XCUIApplication,
    _ identifier: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> XCUIElement {
    let match = element(app, identifier)
    for _ in 0..<6 {
      if match.exists { return match }
      app.swipeUp()
    }
    XCTAssertTrue(
      match.exists,
      "Expected '\(identifier)' after scrolling.\nTree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
    return match
  }

  /// Adds a host through the real form, which is also what proves the form works.
  private func addHost(
    _ app: XCUIApplication,
    name: String = "workbox",
    hostname: String = "10.1.0.9",
    username: String = "carson"
  ) {
    require(app, "hosts.add", "Expected an add-host button").tap()

    require(app, "host.name", "Expected a name field").tap()
    app.typeText(name)
    require(app, "host.hostname", "Expected a hostname field").tap()
    app.typeText(hostname)
    require(app, "host.username", "Expected a username field").tap()
    app.typeText(username)

    // This tap follows typing into a form sheet, which can still be moving. See
    // `waitUntilStill`.
    let save = require(app, "host.save", "Expected a save button")
    waitUntilStill(app, save)
    save.tap()
  }

  /// Scrolls until an element is hittable, then taps it. A `Form` publishes rows below the
  /// fold, and `.tap()` on one silently hits a clamped coordinate.
  private func tapAfterScrolling(
    _ app: XCUIApplication,
    _ identifier: String,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let match = require(app, identifier, message, file: file, line: line)
    for _ in 0..<8 where !match.isHittable { app.swipeUp() }
    XCTAssertTrue(
      match.isHittable,
      "'\(identifier)' never came into reach.\nTree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
    match.tap()
  }

  /// Swipes to the bottom of the host screen's form, where the `Background` section is.
  /// Bounded and silent on a miss, because the caller asserts.
  private func scrollToLiveActivityControl(_ app: XCUIApplication) {
    for _ in 0..<6 where !element(app, "host.liveActivity").exists {
      app.swipeUp()
    }
  }

  /// The host-list row naming `name`, wherever the split view has put the list.
  private func hostRow(_ app: XCUIApplication, named name: String) -> XCUIElement {
    all(app, "hosts.row").matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
  }

  private func all(_ app: XCUIApplication, _ identifier: String) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: identifier)
  }

  /// Gets back to the host list. On iPhone the list is behind a back button. On iPad the
  /// sidebar never went away.
  private func returnToHostList(_ app: XCUIApplication, expecting name: String) {
    guard !hostRow(app, named: name).exists else { return }
    let back = app.navigationBars.buttons.element(boundBy: 0)
    if back.exists { back.tap() }
  }

  /// Choosing a second host shows that host's connection, not the first one's.
  ///
  /// On iPad the detail column persists and SwiftUI reuses one `HostDetailView` with a new
  /// `host`, so its `@State` can keep the first host's connection. Asserted on the phase,
  /// because the address row reads `host` directly and passes either way.
  func testChoosingASecondHostDoesNotInheritTheFirstsConnection() {
    let app = launchApp()
    addHost(app, name: "workbox")
    addHost(app, name: "otherbox", hostname: "10.1.0.99", username: "root")

    hostRow(app, named: "workbox").tap()
    require(app, "connect.password", "Expected a password field").tap()
    app.typeText("hunter2")
    require(app, "connect.connect", "Expected a connect button").tap()
    tapTrustPrompt(app, "Expected the trust prompt on first contact")
    require(app, "connect.connected", "Expected the first host to connect")

    returnToHostList(app, expecting: "otherbox")
    hostRow(app, named: "otherbox").tap()

    // The second host has never been connected, so it must say so.
    require(
      app,
      "connect.disconnected",
      "Expected the second host to start disconnected rather than inheriting a connection"
    )
    let stillConnected = element(app, "connect.connected")
    XCTAssertFalse(
      stillConnected.exists,
      "The second host is showing the first host's connection.\nTree was:\n\(app.debugDescription)"
    )
  }

  /// A connection outlives the screen that opened it, so switching machines does not mean
  /// reconnecting.
  ///
  /// Two hosts, because on iPad re-tapping the same row need not rebuild the detail view.
  /// Visiting another host in between forces the rebuild on both devices.
  func testAHostStaysConnectedWhileYouVisitAnother() {
    let app = launchApp(seedingHost: true)
    addHost(app, name: "edge-01", hostname: "10.1.0.99", username: "root")

    hostRow(app, named: "workbox").tap()
    require(app, "connect.password", "Expected a password field").tap()
    app.typeText("hunter2")
    require(app, "connect.connect", "Expected a connect button").tap()
    tapTrustPrompt(app, "Expected the trust prompt on first contact")
    require(app, "connect.connected", "Expected the first host to connect")

    returnToHostList(app, expecting: "edge-01")
    hostRow(app, named: "edge-01").tap()
    require(app, "connect.disconnected", "Expected the second host to start disconnected")

    returnToHostList(app, expecting: "workbox")
    hostRow(app, named: "workbox").tap()

    // Nothing is tapped: the connection must already be up.
    require(
      app,
      "connect.connected",
      "Expected the first host to still be connected after visiting another"
    )
    XCTAssertFalse(
      element(app, "connect.connect").exists,
      "The host is offering Connect again, so its connection was torn down."
        + "\nTree was:\n\(app.debugDescription)"
    )
  }

  func testAddingAHostPutsItInTheList() {
    let app = launchApp()
    addHost(app)

    let row = require(app, "hosts.row", "Expected the new host in the list")
    XCTAssertTrue(row.label.contains("workbox"), "Expected the host's name, got: \(row.label)")
  }

  func testFirstConnectionAsksToTrustTheHostKey() {
    let app = launchApp()
    addHost(app)
    require(app, "hosts.row", "Expected the new host").tap()

    require(app, "connect.password", "Expected a password field").tap()
    app.typeText("hunter2")
    require(app, "connect.connect", "Expected a connect button").tap()

    // Trust on first use: an unknown host's fingerprint is shown before anything proceeds.
    let fingerprint = require(
      app,
      "hostkey.fingerprint",
      "Expected the host key fingerprint on first contact"
    )
    XCTAssertTrue(
      fingerprint.label.hasPrefix("SHA256:"),
      "Expected an ssh-keygen-style fingerprint, got: \(fingerprint.label)"
    )
    // SwiftUI hyphenates a word it has to wrap, which adds a hyphen that is not in the
    // fingerprint. Space-joined blocks never need one.
    XCTAssertFalse(
      fingerprint.label.contains("-"),
      "Expected the fingerprint to contain no hyphen, got: \(fingerprint.label)"
    )
    XCTAssertTrue(
      fingerprint.label.contains(" "),
      "Expected the fingerprint's base64 to be grouped into space-joined blocks, "
        + "got: \(fingerprint.label)"
    )
    XCTAssertTrue(element(app, "hostkey.trust").exists, "Expected a way to accept the key")
    XCTAssertTrue(element(app, "hostkey.cancel").exists, "Expected a way to decline")
  }

  func testConnectingRunsACommandAndShowsItsOutput() {
    let app = launchApp()
    addHost(app)
    require(app, "hosts.row", "Expected the new host").tap()

    require(app, "connect.password", "Expected a password field").tap()
    app.typeText("hunter2")
    require(app, "connect.connect", "Expected a connect button").tap()

    tapTrustPrompt(app, "Expected the trust prompt on first contact")

    // Once connected the pill folds its details away, and "Run a command" is behind it.
    require(app, "connect.connected", "Expected to reach a connected state").tap()

    scrollTo(app, "connect.run").tap()
    let output = scrollTo(app, "connect.output")
    XCTAssertTrue(
      output.label.contains("Linux"),
      "Expected the command's stdout, got: \(output.label)"
    )
  }

  /// Connect is disabled with an empty password. Otherwise a blank attempt would be reported
  /// as the server refusing a password it never received.
  func testConnectIsDisabledUntilThereIsAPasswordToSend() {
    let app = launchApp()
    addHost(app)
    require(app, "hosts.row", "Expected the new host").tap()

    let connect = require(app, "connect.connect", "Expected a connect button")
    XCTAssertFalse(
      connect.isEnabled,
      "Connect must be disabled with an empty password.\nTree was:\n\(app.debugDescription)"
    )

    require(app, "connect.password", "Expected a password field").tap()
    app.typeText("hunter2")
    XCTAssertTrue(
      connect.isEnabled,
      "Connect must come back the moment there is something to send."
        + "\nTree was:\n\(app.debugDescription)"
    )

    XCTAssertFalse(
      element(app, "connect.error").exists,
      "No packet left the device, so there is nothing to report a failure about."
    )
  }

  /// A changed host key offers Forget Host Key, behind a confirmation, and the next connect
  /// is ordinary first contact.
  ///
  /// `TOFUHostKeyValidator` refuses a changed key with no override, because a user cannot
  /// tell an interception from a rebuild in the moment. Forgetting is the deliberate way
  /// back from a rebuilt server.
  func testAChangedHostKeyOffersForgetAndComesBackToTheTrustPrompt() {
    let app = launchApp(seedingHost: true, withAChangedHostKey: true)

    hostRow(app, named: "workbox").tap()
    require(app, "connect.password", "Expected a password field").tap()
    app.typeText("hunter2")
    require(app, "connect.connect", "Expected a connect button").tap()

    let error = require(app, "connect.error", "Expected the mismatch to be reported")
    XCTAssertTrue(
      error.label.contains("Forget Host Key"),
      "The mismatch has to name the action that gets out of it, got: \(error.label)"
    )
    // Never Retry, which is the wrong response to a possible interception.
    XCTAssertFalse(
      element(app, "connect.retry").exists,
      "A key mismatch must not offer Retry"
    )

    tapAfterScrolling(app, "connect.forgetKey", "Expected a way to forget the old key")
    require(app, "connect.confirmForgetKey", "Expected a confirmation first")
    // ⌘W is Leave Host on this screen, and it must not act from behind the alert. See
    // `isHostScreenPresenting` in `PaneCommands`.
    app.typeKey("w", modifierFlags: .command)
    Thread.sleep(forTimeInterval: 2)
    XCTAssertEqual(app.state, .runningForeground, "Expected ⌘W to keep the app's window")
    XCTAssertTrue(
      element(app, "connect.confirmForgetKey").exists,
      "Expected ⌘W to leave the Forget Host Key alert up.\nTree was:\n\(app.debugDescription)"
    )
    XCTAssertTrue(
      element(app, "connect.error").exists,
      "Expected ⌘W to leave the host screen behind the alert"
    )
    // Both buttons. As a `confirmationDialog` this was an anchorless popover, and UIKit
    // dropped the cancel action. See `ContentView`'s delete alert.
    require(app, "connect.cancelForgetKey", "A destructive confirmation needs a way out")
    require(app, "connect.confirmForgetKey", "Expected a confirmation first").tap()

    // The mismatch is about a key that no longer exists.
    XCTAssertFalse(
      element(app, "connect.error").waitForExistence(timeout: 3),
      "The mismatch outlived the key it was about.\nTree was:\n\(app.debugDescription)"
    )

    // The next connection is ordinary first contact.
    tapAfterScrolling(app, "connect.connect", "Expected Connect to be offered again")
    require(app, "hostkey.fingerprint", "Expected first contact to ask again")
    tapTrustPrompt(app, "Expected a way to accept the new key")
    require(app, "connect.connected", "Expected the rebuilt host to connect")
  }

  /// A link lost with no terminal open says so on the host screen and the host row, and
  /// offers Reconnect. Nothing retries without a terminal. "Not connected" would read like a
  /// host nobody had reached.
  func testALostConnectionSaysSoAndOffersReconnect() {
    let app = launchApp(seedingHost: true, droppingAfterConnect: true)

    hostRow(app, named: "workbox").tap()
    require(app, "connect.password", "Expected a password field").tap()
    app.typeText("hunter2")
    require(app, "connect.connect", "Expected a connect button").tap()
    tapTrustPrompt(app, "Expected the trust prompt on first contact")
    require(app, "connect.connected", "Expected the host to connect")

    require(
      app,
      "connect.lost",
      "Expected the pill to say the connection was lost, not merely that it is not up",
      timeout: 20
    )
    // The details should reopen on their own, but that is the `DisclosureGroup`'s to honour.
    // A tap on the pill is tolerated, because this test is about the word and the button.
    if !element(app, "connect.reconnect").waitForExistence(timeout: 3) {
      element(app, "connect.lost").tap()
    }
    require(app, "connect.reconnect", "Expected Reconnect where Connect used to be")
    XCTAssertFalse(
      element(app, "connect.connected").exists,
      "The pill still claims a connection that has gone.\nTree was:\n\(app.debugDescription)"
    )
    // Why it went, because that decides between Reconnect and walking over to the machine.
    require(app, "connect.lostReason", "Expected the pill to say what happened")

    // The list says it too, because that is where somebody is when a link drops with no
    // terminal open.
    returnToHostList(app, expecting: "workbox")
    require(app, "hosts.lost", "Expected the row to show the host as lost, not as idle")
    XCTAssertTrue(
      hostRow(app, named: "workbox").label.contains("Connection lost"),
      "Expected the row's subtitle to say the connection was lost, got: "
        + hostRow(app, named: "workbox").label
    )
  }

  /// The host screen's Edit opens the form, filled in with this host.
  ///
  /// The screen is the iPad split view's detail column, where a sheet it owns fails, so
  /// `ContentView` presents the form through `HostDetailView.onEdit`. Nothing else taps
  /// `host.edit`.
  func testEditFromTheHostScreenOpensTheForm() {
    let app = launchApp(seedingHost: true)

    hostRow(app, named: "workbox").tap()
    require(app, "host.edit", "Expected Edit in the host screen's toolbar").tap()

    require(app, "host.save", "Expected the host form")
    let hostname = require(app, "host.hostname", "Expected the address field")
    XCTAssertEqual(
      hostname.value as? String,
      "10.1.0.9",
      "Edit opened an empty form rather than this host's.\nTree was:\n\(app.debugDescription)"
    )
  }

  /// A host that connects on appearance does not show the connection form while it does.
  ///
  /// `-uiTestingSlowHandshake` stalls the handshake for thirty seconds. Against the ordinary
  /// fake the connect ends before a frame is drawn, so the form's flash cannot be seen.
  /// The seeded password makes `willConnectWithoutAsking()` true, so nothing is tapped.
  func testAnImmediateConnectDoesNotShowTheConnectionForm() {
    let app = XCUIApplication()
    app.launchArguments += [
      "-uiTesting", "-uiTestingSeedHost", "-uiTestingConnected", "-uiTestingSlowHandshake",
    ]
    app.launch()

    hostRow(app, named: "workbox").tap()

    require(app, "connect.progress", "Expected the connecting pill")

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "immediate-connect"
    shot.lifetime = .keepAlways
    add(shot)

    // Named, not counted, because the footer has no control of its own to count.
    for identifier in ["connect.password", "connect.remember", "connect.rememberFooter"] {
      XCTAssertFalse(
        element(app, identifier).exists,
        "'\(identifier)' is on screen during an immediate connect — the settings form is "
          + "still being flashed.\nTree was:\n\(app.debugDescription)"
      )
    }

    // Cancel is a row of the section, not of the disclosure, so it survives the fold.
    let cancel = require(app, "connect.cancel", "Expected Cancel beside the collapsed pill")

    // Ending the attempt hands the form back, so a stale saved password can be corrected.
    cancel.tap()
    require(app, "connect.password", "Expected the password field back after a cancel")
    require(app, "connect.connect", "Expected Connect back after a cancel")
  }

  /// The host screen offers Start and Stop Live Activity while connected, and the choice is
  /// remembered. The retitle is the assertion, since the item existing proves only that it
  /// is drawn.
  func testTheHostScreenStartsAndStopsItsLiveActivity() {
    // Seeded. This test is about the card a connection draws, not about connecting.
    let app = connectedHostApp()

    // The section is last in the form, below the session tree. A `Form` is a collection
    // view, so a cell below the fold is not in the tree until a swipe builds it.
    scrollToLiveActivityControl(app)

    let item = require(app, "host.liveActivity", "Expected Start/Stop Live Activity")
    XCTAssertEqual(
      item.label, "Stop Live Activity",
      "A host nobody has touched follows the global setting, which is on.\nTree was:\n"
        + app.debugDescription)
    item.tap()
    XCTAssertEqual(
      require(app, "host.liveActivity", "Expected the item after stopping").label,
      "Start Live Activity",
      "Stopping this host must be remembered.\nTree was:\n\(app.debugDescription)")

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "host-background-section"
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// A host that is not connected offers no Live Activity control.
  func testAnUnconnectedHostOffersNoLiveActivityControl() {
    let app = launchApp(seedingHost: true)

    hostRow(app, named: "workbox").tap()
    require(app, "connect.connect", "Expected the host screen")
    // Scrolled as in the connected case, so absent means absent, not below the fold.
    scrollToLiveActivityControl(app)

    XCTAssertFalse(
      element(app, "host.liveActivity").exists,
      "A host Driverr has not reached has no card to start.\nTree was:\n"
        + app.debugDescription)
  }

  /// Continue in Background on the host screen retitles itself on each tap.
  ///
  /// No real continued-processing task is submitted. `SilentBackgroundWatchScheduler` accepts
  /// the request and sends nothing.
  func testTheHostScreenContinuesInBackground() {
    let app = connectedHostApp()

    scrollToLiveActivityControl(app)

    let item = require(app, "host.continueInBackground", "Expected Continue in Background")
    XCTAssertEqual(
      item.label, "Continue in Background",
      "A host with no run up offers to start one.\nTree was:\n\(app.debugDescription)")
    item.tap()

    XCTAssertEqual(
      require(app, "host.continueInBackground", "Expected the item after the tap").label,
      "Stop Continuing in Background",
      "The row has to say a run is up from the moment of the tap.\nTree was:\n"
        + app.debugDescription)

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "host-background-section-continuing"
    shot.lifetime = .keepAlways
    add(shot)

    require(app, "host.continueInBackground", "Expected the item to still be there").tap()
    XCTAssertEqual(
      require(app, "host.continueInBackground", "Expected the item after stopping").label,
      "Continue in Background",
      "Stopping must put the row back.\nTree was:\n\(app.debugDescription)")
  }

  /// The plain continued-processing identifier registers with `BGTaskScheduler`. Continue in
  /// Background has no mechanism without it, and nothing else would say so.
  ///
  /// The answer comes from the real scheduler in a real app process.
  /// `-uiTestingBackgroundWatchProbe` puts it in the accessibility tree, and the test runner
  /// prints it. Only `register` is live under `-uiTesting`; `submit` goes to
  /// `SilentBackgroundWatchScheduler`. This answers for the simulator, not a device.
  func testThePlainContinuedProcessingIdentifierRegisters() {
    let app = launchApp(seedingHost: true, extraArguments: ["-uiTestingBackgroundWatchProbe"])

    let readout = require(
      app, "debug.backgroundWatch.register", "Expected the register readout")
    print("BGTaskScheduler.register — \(readout.label)")
    XCTAssertTrue(
      readout.label.contains("com.cunderw.driverr.watch"),
      "The readout must name the identifier it registered.\nTree was:\n\(app.debugDescription)")
    XCTAssertTrue(
      readout.label.contains("returned true"),
      "The plain identifier did not register. Continue in Background has no mechanism "
        + "without it, and the next thing to try is the wildcard form the plist already "
        + "permits.\nReadout was: \(readout.label)")
  }

  /// A host that is not connected has no connection to continue, so no Background section.
  func testAnUnconnectedHostOffersNoBackgroundSectionAtAll() {
    let app = launchApp(seedingHost: true)

    hostRow(app, named: "workbox").tap()
    require(app, "connect.connect", "Expected the host screen")
    scrollToLiveActivityControl(app)

    XCTAssertFalse(
      element(app, "host.continueInBackground").exists,
      "A host Driverr has not reached has no connection to continue.\nTree was:\n"
        + app.debugDescription)
  }

  /// A connect in progress can be cancelled before its twenty-second deadline, and cancelling
  /// reports no failure.
  ///
  /// `-uiTestingSlowHandshake` (`AppEnvironment.stalledHandshake`) holds the attempt open.
  /// The seeded password starts it on appearance, so nothing taps Connect.
  func testCancelEndsAConnectThatIsStillRunning() {
    let app = XCUIApplication()
    app.launchArguments += [
      "-uiTesting", "-uiTestingSeedHost", "-uiTestingConnected", "-uiTestingSlowHandshake",
    ]
    app.launch()

    hostRow(app, named: "workbox").tap()
    require(app, "connect.progress", "Expected the connecting pill")
    let cancel = require(app, "connect.cancel", "Expected a way out of the spinner")

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "connect-cancel"
    shot.lifetime = .keepAlways
    add(shot)

    cancel.tap()

    // Back to Connect, not to an error, because the user ended the attempt.
    require(app, "connect.connect", "Expected Connect to come back after a cancel")
    XCTAssertFalse(
      element(app, "connect.progress").exists,
      "The spinner is still running after Cancel.\nTree was:\n\(app.debugDescription)"
    )
    XCTAssertFalse(
      element(app, "connect.error").exists,
      "A cancelled attempt reported a failure.\nTree was:\n\(app.debugDescription)"
    )
  }

  /// The set-up after the handshake still reads Connecting, with Cancel.
  ///
  /// Two exec round trips (`command -v herdr` and `herdr --version`) follow the handshake,
  /// and `ConnectionModel` holds `.connecting` until they finish. `-uiTestingStalledSetUp`
  /// (`AppEnvironment.stalledSetUp`) parks them for sixty seconds.
  ///
  /// The window is bounded by the twelve-second `setUpDeadline`, not by the stall, so the
  /// elapsed check makes sure the assertions ran with most of it left.
  func testASetUpThatIsStillRunningDoesNotSayConnected() {
    let app = XCUIApplication()
    app.launchArguments += [
      "-uiTesting", "-uiTestingSeedHost", "-uiTestingConnected", "-uiTestingStalledSetUp",
    ]
    app.launch()

    let started = Date()
    hostRow(app, named: "workbox").tap()

    let pill = require(app, "connect.progress", "Expected the connecting pill during the set-up")
    let cancel = require(app, "connect.cancel", "Expected Cancel to still be offered")

    // The word itself, since the pill is also there while authenticating. The identifier
    // sits on an `HStack`, which can swallow its children's, so static texts are read too.
    let saysConnecting =
      pill.label.contains("Connecting")
      || app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Connecting"))
        .count > 0
    XCTAssertTrue(
      saysConnecting,
      "The pill does not read Connecting during the set-up."
        + "\nTree was:\n\(app.debugDescription)"
    )

    // The claim: the handshake is done, and the screen does not yet say so.
    XCTAssertFalse(
      element(app, "connect.connected").exists,
      "The pill said Connected while the set-up was still running."
        + "\nTree was:\n\(app.debugDescription)"
    )

    // Reaching here inside six seconds leaves half the window. A slower run fails as a
    // timing problem, not as a wrong pill.
    let elapsed = Date().timeIntervalSince(started)
    XCTAssertLessThan(
      elapsed,
      6,
      "The set-up window took \(elapsed)s to reach, against a 12s setUpDeadline — the "
        + "assertions above were racing the deadline rather than testing the phase."
    )

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "connect-stalled-setup"
    shot.lifetime = .keepAlways
    add(shot)

    cancel.tap()

    require(app, "connect.connect", "Expected Connect to come back after a cancel")
    XCTAssertFalse(
      element(app, "connect.progress").exists,
      "The spinner is still running after Cancel.\nTree was:\n\(app.debugDescription)"
    )
    XCTAssertFalse(
      element(app, "connect.error").exists,
      "A cancelled set-up reported a failure.\nTree was:\n\(app.debugDescription)"
    )
  }
}
