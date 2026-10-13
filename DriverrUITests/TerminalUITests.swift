import XCTest

/// The terminal on screen: bytes from the channel reach the emulator, and typing goes back
/// out over it. How the session behaves is `DriverrKit`'s, against a headless emulator.
///
/// Relaunches per test: tests connect, leave a terminal open, and one changes the font size.
@MainActor
final class TerminalUITests: XCTestCase {
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

  /// Finds a control that may be below the fold at an accessibility text size, where the
  /// cards above the shell action are taller than the screen and the action is not built.
  @discardableResult
  private func requireAfterScrolling(
    _ app: XCUIApplication,
    _ identifier: String,
    _ message: String,
    maxSwipes: Int = 10,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> XCUIElement {
    let match = element(app, identifier)
    for _ in 0..<maxSwipes {
      if match.exists { return match }
      app.swipeUp()
    }
    return require(app, identifier, message, file: file, line: line)
  }

  /// Connects to the seeded host and opens a shell on it.
  private func openTerminal(
    longTranscript: Bool = false,
    extraLaunchArguments: [String] = []
  ) -> (
    app: XCUIApplication, terminal: XCUIElement
  ) {
    // Orientation survives relaunch, so a rotation test could inherit landscape and compare
    // a frame with itself. Pinned here, not in the nonisolated `setUp`.
    XCUIDevice.shared.orientation = .portrait

    // Seeded, because this class is not about connecting.
    let app = connectedHostApp(extraLaunchArguments + (longTranscript ? ["-uiTestingLongTranscript"] : []))

    requireAfterScrolling(app, "connect.terminal", "Expected a way to open a terminal").tap()
    let terminal = require(app, "terminal.view", "Expected the terminal to be on screen")
    return (app, terminal)
  }

  /// The emulator renders on its own schedule, so poll rather than assert once. Matched
  /// against `terminalText`, which drops the fake shell's `[resized WxH]` notices.
  private func waitForTerminalText(
    _ terminal: XCUIElement,
    containing text: String,
    timeout: TimeInterval = 10
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if terminalText(terminal).contains(text) { return true }
      _ = terminal.waitForExistence(timeout: 0.2)
    }
    return terminalText(terminal).contains(text)
  }

  /// Scrollback is reachable by a drag.
  ///
  /// The output arrives in one write from the fake shell (`-uiTestingLongTranscript`,
  /// eighty numbered rows), because XCUITest types one key event per character and typing
  /// enough output is too slow. The precondition, `row 1` already off screen, is asserted
  /// before the swipe.
  func testTheTerminalScrollsBackThroughItsOutput() {
    let (_, terminal) = openTerminal(longTranscript: true)

    XCTAssertTrue(
      waitForTerminalText(terminal, containing: "row 80"),
      "Expected the transcript to have arrived. Terminal showed: \(String(describing: terminal.value))"
    )

    let atBottom = String(describing: terminal.value)
    XCTAssertFalse(
      atBottom.contains("row 1\n"),
      "Expected the first rows to have scrolled off, so there is scrollback to reach.\n"
        + "Terminal showed: \(atBottom)"
    )

    terminal.swipeDown()
    terminal.swipeDown()
    terminal.swipeDown()

    let afterScrolling = String(describing: terminal.value)
    XCTAssertNotEqual(
      afterScrolling,
      atBottom,
      "Dragging down changed nothing on screen — the scrollback is unreachable."
    )
  }

  func testOpeningATerminalRendersWhatTheShellWrote() {
    let (_, terminal) = openTerminal()

    XCTAssertTrue(
      waitForTerminalText(terminal, containing: "carson@workbox"),
      "Expected the shell's prompt to be rendered, terminal showed: "
        + String(describing: terminal.value)
    )
  }

  func testTypingReachesTheChannelAndComesBack() {
    let (app, terminal) = openTerminal()
    XCTAssertTrue(waitForTerminalText(terminal, containing: "carson@workbox"), "no prompt")

    // The prompt is not the end of the arrival. See `waitForTerminalToSettle`.
    waitForTerminalToSettle(app, terminal)

    terminal.tap()
    app.typeText("whoami")

    // The fake channel echoes and the emulator does not echo locally, so seeing the text
    // proves the round trip.
    XCTAssertTrue(
      waitForTerminalText(terminal, containing: "whoami"),
      "Expected typed input to travel over the channel and render, terminal showed: "
        + String(describing: terminal.value)
    )
  }

  /// Polls a condition rather than asserting once, for the things that settle after an
  /// animation rather than at the moment an event fires.
  private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      usleep(200_000)
    }
    return condition()
  }

  /// Attaches a screenshot, so the resize can be looked at as well as asserted.
  private func capture(_ app: XCUIApplication, named name: String) {
    // The screen, not the app. `XCUIApplication.screenshot()` clips a rotated scene to its
    // pre-rotation width.
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// Rotation resizes the channel, not only the view.
  ///
  /// The fake PTY writes its new size back when resized, which a real shell does not. A
  /// terminal that relaid out without telling the far side looks the same on screen.
  func testRotationResizesTheChannel() throws {
    let (app, terminal) = openTerminal()
    XCTAssertTrue(waitForTerminalText(terminal, containing: "carson@workbox"), "no prompt")
    capture(app, named: "terminal-portrait")

    let before = (terminal.value as? String) ?? ""
    let portraitWindow = app.windows.firstMatch.frame
    XCTAssertLessThan(
      portraitWindow.width,
      portraitWindow.height,
      "Expected to start in portrait; the simulator was left in \(portraitWindow)"
    )
    let portraitColumns = announcedColumns(in: before)
    XCUIDevice.shared.orientation = .landscapeLeft

    // Asserted, never skipped, and the failure names the cure. See
    // `PaneSwitchUITests.rotateToLandscape`.
    let rotated = waitUntil(timeout: 10) {
      let frame = app.windows.firstMatch.frame
      return frame.width > frame.height
    }
    XCTAssertTrue(
      rotated,
      "The scene never rotated — the window is still \(app.windows.firstMatch.frame). "
        + "That is the simulator and not the app: erase this device "
        + "(`xcrun simctl erase <udid>`) and run again."
    )

    // The announced column count is the assertion. XCUITest reports a rotated scene's
    // element frames in a space that disagrees with the window's.
    let grew = waitUntil(timeout: 10) {
      guard let now = announcedColumns(in: (terminal.value as? String) ?? "") else {
        return false
      }
      return now > (portraitColumns ?? 0)
    }
    // The channel learns the size mid-animation, so wait for the frame to settle before the
    // screenshot.
    var previous = CGRect.zero
    _ = waitUntil(timeout: 5) {
      let current = terminal.frame
      defer { previous = current }
      return current == previous && current != .zero
    }
    capture(app, named: "terminal-landscape")

    XCTAssertTrue(
      grew,
      "Expected rotating to tell the channel about a wider terminal. Portrait: "
        + String(describing: portraitColumns) + " columns. After: "
        + String(describing: terminal.value)
    )
  }

  /// Pulls the column count out of the fake shell's `[resized 132x30]` line.
  private func announcedColumns(in text: String) -> Int? {
    guard let range = text.range(of: "[resized ", options: .backwards) else { return nil }
    let rest = text[range.upperBound...]
    guard let x = rest.firstIndex(of: "x") else { return nil }
    return Int(rest[..<x])
  }

  /// A font size change reaches a terminal that is already open.
  ///
  /// Asserted through the announced column count, which proves the change reached the view,
  /// the emulator and the PTY, not only a repaint.
  func testFontSizeAppliesToAnOpenTerminal() {
    let (app, terminal) = openTerminal()
    XCTAssertTrue(waitForTerminalText(terminal, containing: "carson@workbox"), "no prompt")

    let before = announcedColumns(in: (terminal.value as? String) ?? "")

    require(app, "pane.actions", "Expected the … menu on the terminal").tap()
    require(app, "terminal.settings", "Expected settings from the terminal").tap()
    // The stepper is below the fold of a detented sheet, where `swipeUp()` is inert. See
    // `dragSheetToReveal`.
    let stepper = dragSheetToReveal(
      app,
      "settings.fontsize",
      anchoredAt: "settings.preview",
      "Expected a font size control"
    )
    for _ in 0..<4 { stepper.buttons.element(boundBy: 1).tap() }
    require(app, "settings.done", "Expected a way out of settings").tap()

    let shrank = waitUntil(timeout: 10) {
      guard let now = announcedColumns(in: (terminal.value as? String) ?? ""),
        let before
      else { return false }
      return now < before
    }
    XCTAssertTrue(
      shrank,
      "Expected a bigger font to leave fewer columns and tell the channel. Before: "
        + String(describing: before) + " After: " + String(describing: terminal.value)
    )
  }

  /// A plain shell terminal can reach Settings through the ⋯ menu. `scene.actions` is `nil`
  /// for a shell, so a menu gated on it would leave no way to change font or theme.
  func testSettingsIsReachableFromAShellTerminal() {
    let (app, _) = openTerminal()

    require(app, "pane.actions", "Expected the … menu on a shell terminal").tap()
    require(app, "terminal.settings", "Expected Settings inside the … menu").tap()

    require(app, "settings.done", "Expected the settings sheet to open").tap()
  }

  /// The grid is inset from the display edge and stays inside it at accessibility sizes.
  ///
  /// A `VStack` is as wide as its widest child, so a row of chrome that cannot fit drags the
  /// terminal off both edges. A clipped column is one the far side was told about. Run at the
  /// accessibility size, where the chrome pushes hardest.
  func testTheGridIsInsetFromTheDisplayEdge() {
    let (app, terminal) = openTerminal(
      extraLaunchArguments: [
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
      ]
    )
    XCTAssertTrue(waitForTerminalText(terminal, containing: "carson@workbox"), "no prompt")
    capture(app, named: "terminal-accessibility-size")

    let window = app.windows.firstMatch.frame
    XCTAssertGreaterThan(
      terminal.frame.minX,
      window.minX,
      "The grid's first column is on the display edge. Terminal was \(terminal.frame) in "
        + "a window of \(window)."
    )
    XCTAssertLessThanOrEqual(
      terminal.frame.maxX,
      window.maxX,
      "The grid is wider than the screen, so its outermost columns are announced to the "
        + "far side and drawn where nobody can read them. Terminal was \(terminal.frame) "
        + "in a window of \(window)."
    )
  }

  func testLeavingTheTerminalReturnsToTheHost() {
    let (app, terminal) = openTerminal()
    XCTAssertTrue(waitForTerminalText(terminal, containing: "carson@workbox"), "no prompt")

    leavePaneScene(app, "Expected a way out of the terminal")

    require(app, "connect.terminal", "Expected to be back on the host screen")
  }
}
