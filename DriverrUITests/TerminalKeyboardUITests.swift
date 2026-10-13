import UIKit
import XCTest

/// The terminal's keyboard surface: the accessory row, and focus.
///
/// The fake shell echoes control bytes as a tty does (`0x03` as `^C`), so these assert that
/// a key put the right byte on the channel, not only that a button exists.
///
/// Not covered: a physical keyboard's modifier chords against a real shell. The simulator's
/// hardware keyboard cannot be detached, and interrupting a process needs a real one.
///
/// Relaunches per test: each test connects and leaves a terminal open.
@MainActor
final class TerminalKeyboardUITests: XCTestCase {
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

  /// Matched against `terminalText`, which drops the fake shell's `[resized WxH]` notices
  /// that can land between two keystrokes.
  private func waitForTerminalText(
    _ terminal: XCUIElement,
    containing text: String,
    timeout: TimeInterval = 10
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if terminalText(terminal).contains(text) { return true }
      usleep(200_000)
    }
    return terminalText(terminal).contains(text)
  }

  private func capture(_ name: String) {
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }

  private func openTerminal(
    extraLaunchArguments: [String] = []
  ) -> (app: XCUIApplication, terminal: XCUIElement) {
    XCUIDevice.shared.orientation = .portrait
    // Seeded, because this class is not about connecting. Portrait is pinned first, because
    // orientation survives the previous test.
    let app = connectedHostApp(extraLaunchArguments)
    require(app, "connect.terminal", "Expected a way to open a terminal").tap()

    let terminal = require(app, "terminal.view", "Expected the terminal")
    XCTAssertTrue(waitForTerminalText(terminal, containing: "carson@workbox"), "no prompt")
    return (app, terminal)
  }

  /// The row is there without a tap, with every key at least 44 pt.
  func testAccessoryRowIsPresentOnArrival() {
    let (app, _) = openTerminal()
    capture("terminal-accessory-row")

    let keys = ["esc", "tab", "ctrl", "left", "down", "up", "right", "dismiss"]
    var frames: [(String, CGRect)] = []
    for key in keys {
      let button = element(app, "terminal.key.\(key)")
      XCTAssertTrue(
        button.waitForExistence(timeout: 5),
        "Expected a \(key) key on the accessory row.\nTree was:\n\(app.debugDescription)"
      )
      frames.append((key, button.frame))
    }

    // Each key is at least 44 pt, which checks `DriverrKeyboardAccessory`'s insets and gaps
    // against a real row. The sizes are logged, because the width depends on the screen.
    let measured = frames.map { "\($0.0) \($0.1.width)×\($0.1.height)" }.joined(separator: ", ")
    XCTContext.runActivity(named: "measured key sizes") { activity in
      activity.add(XCTAttachment(string: measured))
    }
    print("accessory key sizes: \(measured)")

    for (key, frame) in frames {
      XCTAssertGreaterThanOrEqual(
        frame.height, 44,
        "The \(key) key is \(frame.height) pt tall, under the 44 pt minimum."
      )
      XCTAssertGreaterThanOrEqual(
        frame.width, 44,
        "The \(key) key is \(frame.width) pt wide, under the 44 pt minimum. "
          + "Eight keys across, so this is the row's margins and spacing against the "
          + "screen's width."
      )
    }
  }

  /// The terminal holds keyboard focus on arrival, without a tap. The accessory row implies
  /// focus; this asserts it directly.
  ///
  /// With a hardware keyboard attached the simulator shows no software keyboard, so only
  /// first-responder status is checkable here. The keyboard appearing needs a device.
  func testTerminalTakesKeyboardFocusOnArrival() {
    let (_, terminal) = openTerminal()

    expectation(
      for: NSPredicate(format: "hasKeyboardFocus == true"),
      evaluatedWith: terminal
    )
    waitForExpectations(timeout: 10) { error in
      XCTAssertNil(
        error,
        "Expected the terminal to hold the keyboard on arrival, without a tap."
      )
    }
  }

  /// Waits for the terminal to hold, or not hold, the keyboard.
  ///
  /// `XCTWaiter`, because `waitForExpectations` waits on every outstanding expectation and
  /// this runs more than once per test.
  private func waitForFocus(
    _ terminal: XCUIElement,
    _ focused: Bool,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let waiter = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hasKeyboardFocus == %@", NSNumber(value: focused)),
      object: terminal
    )
    XCTAssertEqual(
      XCTWaiter().wait(for: [waiter], timeout: 10),
      .completed,
      message,
      file: file,
      line: line
    )
  }

  /// The keyboard can be put away and brought back.
  ///
  /// The terminal takes focus on arrival and the keyboard covers about 40% of a phone. The
  /// UIKit terminal gets no scroll-to-dismiss, so this key is the only way to reclaim that
  /// space without leaving.
  func testTheKeyboardCanBePutAwayAndBroughtBack() {
    let (app, terminal) = openTerminal()
    waitForFocus(terminal, true, "Expected the terminal to hold the keyboard on arrival")

    require(app, "terminal.key.dismiss", "Expected a hide-keyboard key").tap()
    waitForFocus(terminal, false, "Expected the hide-keyboard key to put the keyboard away")

    XCTAssertTrue(terminal.exists, "Expected to still be in the terminal")
    // With the keyboard down the last row has to clear the home indicator, which is a pixel
    // question.
    capture("terminal-keyboard-dismissed")

    // A tap brings it back.
    terminal.tap()
    waitForFocus(terminal, true, "Expected a tap on the terminal to bring the keyboard back")
  }

  /// The grid stops above the accessory row, so the rows SwiftTerm reports over `SIGWINCH`
  /// are rows the user can read.
  ///
  /// SwiftTerm sizes its grid from the view's bounds, so the frame and the announced size
  /// are the same fact, and the frame can be checked against a screenshot.
  ///
  /// Both orientations. In landscape the keyboard's end frame starts at the keys, not at the
  /// accessory row, so the grid can run under the row there alone.
  func testTheGridStopsAboveTheKeyboard() throws {
    let (app, terminal) = openTerminal()
    assertGridClearsTheAccessoryRow(app, terminal, "portrait")
    capture("terminal-grid-portrait")

    try rotateToLandscape(app)
    assertGridClearsTheAccessoryRow(app, terminal, "landscape")
    capture("terminal-grid-landscape")

    // Restored here, not in the nonisolated `tearDown`, where touching `XCUIDevice.shared`
    // warns under strict concurrency.
    XCUIDevice.shared.orientation = .portrait
  }

  /// The accessory row's top edge, read off the leftmost key.
  ///
  /// The row is the terminal's `inputAccessoryView`, drawn over the app's content. `esc`
  /// sits 4 pt below the row's top, so this check is lenient by 4 pt.
  private func assertGridClearsTheAccessoryRow(
    _ app: XCUIApplication,
    _ terminal: XCUIElement,
    _ orientation: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let escape = require(app, "terminal.key.esc", "Expected the accessory row in \(orientation)")
    // The keyboard animates in and the grid reflows after it, so poll.
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline && terminal.frame.maxY > escape.frame.minY {
      _ = escape.waitForExistence(timeout: 0.2)
    }
    XCTAssertLessThanOrEqual(
      terminal.frame.maxY,
      escape.frame.minY,
      "In \(orientation) the grid ran under the accessory row, so the rows SwiftTerm "
        + "announced to the far side are not the rows on screen. Terminal was "
        + "\(terminal.frame), the row starts at \(escape.frame.minY).",
      file: file,
      line: line
    )
  }

  /// Rotates, and fails on the scene before anything laid out inside it, naming the cure.
  /// Copied from `PaneSwitchUITests.rotateToLandscape`, which gives the reason.
  private func rotateToLandscape(
    _ app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    XCUIDevice.shared.orientation = .landscapeLeft
    let window = app.windows.firstMatch
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline && window.frame.width <= window.frame.height {
      _ = window.waitForExistence(timeout: 0.2)
    }
    XCTAssertGreaterThan(
      window.frame.width,
      window.frame.height,
      "The scene never rotated — the window is still \(window.frame). That is the "
        + "simulator and not the app: erase this device (`xcrun simctl erase <udid>`) and "
        + "run again.",
      file: file,
      line: line
    )
  }

  func testEscapeKeySendsEscape() {
    let (app, terminal) = openTerminal()

    require(app, "terminal.key.esc", "Expected an Escape key").tap()

    XCTAssertTrue(
      waitForTerminalText(terminal, containing: "^["),
      "Expected Escape to put 0x1b on the channel. Terminal showed: "
        + String(describing: terminal.value)
    )
  }

  /// Control is sticky: it arms the next key rather than being held.
  func testControlArmsTheNextKey() {
    let (app, terminal) = openTerminal()
    // The accessory row is still rising and the open's resize has not landed. See
    // `waitForTerminalToSettle`.
    waitForTerminalToSettle(app, terminal)

    require(app, "terminal.key.ctrl", "Expected a Control key").tap()
    terminal.typeText("c")

    XCTAssertTrue(
      waitForTerminalText(terminal, containing: "^C"),
      "Expected Ctrl then c to put 0x03 on the channel. Terminal showed: "
        + String(describing: terminal.value)
    )
  }

  func testArrowKeySendsACursorSequence() {
    let (app, terminal) = openTerminal()

    require(app, "terminal.key.up", "Expected an up arrow").tap()

    // `ESC [ A` echoes in caret notation as `^[[A`, the normal cursor mode sequence.
    XCTAssertTrue(
      waitForTerminalText(terminal, containing: "^[[A"),
      "Expected the up arrow to send a normal-mode cursor sequence. Terminal showed: "
        + String(describing: terminal.value)
    )
  }

  /// The hardware-keyboard notice renders when the model says to.
  ///
  /// The simulator's hardware keyboard cannot be disconnected from a test, and its
  /// suppression signal does not behave like a device's. So
  /// `-uiTestingHardwareKeyboardNotice` forces the notice on
  /// (`AppEnvironment.isForcingHardwareKeyboardNotice`), and this checks only the rendering.
  /// The state machine is `KeyboardNoticeModelTests`.
  func testHardwareKeyboardNoticeRendersWhenTheModelSaysTo() {
    let (app, _) = openTerminal(extraLaunchArguments: ["-uiTestingHardwareKeyboardNotice"])

    let notice = require(
      app, "terminal.keyboard.hardwareNotice",
      "Expected the notice once the model reports the keyboard is suppressed"
    )
    XCTAssertTrue(
      notice.label.contains("hardware keyboard") && notice.label.contains("Globe"),
      "Expected the notice to explain why and name the Globe/Eject escape hatch. Label was: '\(notice.label)'"
    )
  }

  /// Closing a sheet must give the keyboard back. Without this the terminal looks focused
  /// and silently swallows everything typed at it.
  func testFocusReturnsAfterSettingsCloses() {
    let (app, terminal) = openTerminal()

    require(app, "pane.actions", "Expected the … menu on the terminal").tap()
    require(app, "terminal.settings", "Expected settings from the terminal").tap()
    require(app, "settings.done", "Expected a way out of settings").tap()

    // The row exists before the keyboard finishes sliding in, so a tap can land on nothing.
    // Retry, because the claim is that focus came back, not the animation's timing.
    let escape = require(app, "terminal.key.esc", "Expected the accessory row back")
    var arrived = false
    for _ in 0..<5 {
      if escape.isHittable { escape.tap() }
      if waitForTerminalText(terminal, containing: "^[", timeout: 2) {
        arrived = true
        break
      }
    }
    XCTAssertTrue(
      arrived,
      "Expected the terminal to take keys again after settings closed. Terminal showed: "
        + String(describing: terminal.value)
    )
  }
}
