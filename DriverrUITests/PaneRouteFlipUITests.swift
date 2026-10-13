import XCTest

/// A size-class flip keeps the pane scene, on the one device that can cross the boundary.
///
/// Rotating a phone across the boundary once ended the pane scene, because a `Binding`
/// closure captured a stale `self`. `ContentView.phonePath`'s setter calls `dismiss()` and
/// cannot guard on the route, so only a run on such a device shows that the flip writes no
/// shorter path.
///
/// A class of its own, because it needs the opposite guard to `PaneDetailColumnUITests`: a
/// window compact one way and regular the other. Only `Driverr iPhone 17 Pro Max` qualifies,
/// so on the gate simulators this skips.
///
/// Relaunches per test: it connects and rotates the device.
@MainActor
final class PaneRouteFlipUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  /// Waits for an element to stop existing. Right after a route change the old screen is
  /// often still in the tree, so a single `XCTAssertFalse(exists)` samples too early.
  private func requireGone(
    _ app: XCUIApplication,
    _ identifier: String,
    _ message: String,
    timeout: TimeInterval = 10,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let waiter = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"),
      object: element(app, identifier)
    )
    guard XCTWaiter().wait(for: [waiter], timeout: timeout) == .completed else {
      XCTFail(
        "\(message)\n'\(identifier)' was still there after \(timeout)s.\nTree was:\n"
          + app.debugDescription,
        file: file,
        line: line
      )
      return
    }
  }

  /// The width above which the window is regular. See
  /// `PaneDetailColumnUITests.requireRegularWidth`.
  private static let regularWidth: CGFloat = 900

  /// Turns the device and waits for the interface to follow, failing with the erase remedy
  /// as `PaneSwitchUITests.rotateToLandscape` does. Returns the settled window width, from
  /// which the caller decides the route.
  @discardableResult
  private func rotate(
    _ app: XCUIApplication,
    to orientation: UIDeviceOrientation,
    expectingLandscape landscape: Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> CGFloat {
    XCUIDevice.shared.orientation = orientation
    let window = app.windows.firstMatch
    let deadline = Date().addingTimeInterval(10)
    func settled() -> Bool {
      landscape
        ? window.frame.width > window.frame.height : window.frame.height > window.frame.width
    }
    while Date() < deadline && !settled() {
      _ = window.waitForExistence(timeout: 0.2)
    }
    XCTAssertTrue(
      settled(),
      Self.neverRotated(toLandscape: landscape, window: window.frame),
      file: file,
      line: line
    )
    return window.frame.width
  }

  /// What a rotation that never happened fails with. The teardown block uses it too.
  private static func neverRotated(toLandscape landscape: Bool, window: CGRect) -> String {
    """
    The scene never rotated to \(landscape ? "landscape" : "portrait") — the window is \
    still \(window). That is the simulator and not the app: erase this device \
    (`xcrun simctl erase <udid>`) and run again.
    """
  }

  /// The flip both ways keeps the scene.
  ///
  /// The markers are the pane's title and its conversation, which go when the scene closes.
  /// The host list proves nothing, because the detail route keeps it on screen.
  ///
  /// `terminal.back` is asserted absent, present, then absent, because it is the one control
  /// that differs between the routes. Its presence in landscape proves the detail column is
  /// the route in use.
  func testRotatingAcrossTheSizeClassBoundaryKeepsTheScene() throws {
    XCUIDevice.shared.orientation = .portrait
    let app = connectedHostApp()

    let portraitWidth = app.windows.firstMatch.frame.width
    try XCTSkipUnless(
      portraitWidth < Self.regularWidth,
      """
      This device is \(portraitWidth) pt wide in portrait, so it is regular in both \
      orientations and cannot cross the boundary. PaneDetailColumnUITests covers it.
      """
    )

    treePaneRow(app, titled: "needs a decision").tap()
    waitFor(app, "pane.chat", "Expected the pane's conversation", timeout: 20)
    waitFor(app, "pane.chat.turn.assistant", "Expected the agent's turn", timeout: 20)
    waitFor(app, "pane.actions", "Expected the pane scene's own ⋯ menu on the stack route")
    requireGone(app, "terminal.back", "No named back control belongs on the phone's stack")

    let title = app.navigationBars["needs a decision"]
    XCTAssertTrue(
      title.waitForExistence(timeout: 10),
      "Expected the pane's title on the pushed scene.\nTree was:\n\(app.debugDescription)"
    )

    // Orientation outlives the process, and a failure after the rotation leaves before the
    // rotation back. A teardown block runs on that exit. Not `setUp` or `tearDown`, which are
    // nonisolated.
    addTeardownBlock { @MainActor in
      XCUIDevice.shared.orientation = .portrait
      let window = XCUIApplication().windows.firstMatch
      let upright = Date().addingTimeInterval(10)
      // `exists` first each time, because reading the frame of a window that is gone records
      // a failure of its own, and a dead app has already failed the test.
      while Date() < upright && window.exists && window.frame.height <= window.frame.width {
        _ = window.waitForExistence(timeout: 0.2)
      }
      guard window.exists else { return }
      let frame = window.frame
      // The next class does not pin portrait, so a device left in landscape fails here and
      // not there. XCTest records nothing raised here after an `XCTSkip`, which is why the
      // skip below rotates back before it is thrown.
      XCTAssertGreaterThan(
        frame.height,
        frame.width,
        PaneRouteFlipUITests.neverRotated(toLandscape: false, window: frame)
      )
    }

    // The rotation is asserted before the width decides whether to skip, so a device that
    // failed to rotate fails rather than skipping.
    let landscapeWidth = rotate(app, to: .landscapeLeft, expectingLandscape: true)
    // Back before the skip, while a device that stays in landscape can still fail the test.
    if landscapeWidth < Self.regularWidth {
      rotate(app, to: .portrait, expectingLandscape: false)
    }
    try XCTSkipUnless(
      landscapeWidth >= Self.regularWidth,
      """
      This device is \(landscapeWidth) pt wide in landscape, so it is compact in both \
      orientations and never reaches the detail column. Run this on \
      Driverr iPhone 17 Pro Max.
      """
    )

    waitFor(app, "terminal.back", "The flip to regular width lost the pane scene", timeout: 15)
    XCTAssertTrue(
      element(app, "pane.chat").exists,
      "The flip closed the scene — the conversation is gone.\nTree was:\n"
        + app.debugDescription
    )
    XCTAssertTrue(
      app.navigationBars["needs a decision"].exists,
      "The flip lost the pane; the bar no longer names it.\nTree was:\n\(app.debugDescription)"
    )
    XCTAssertTrue(
      element(app, "hosts.row").exists,
      "The detail route has to keep the host list beside the scene.\nTree was:\n"
        + app.debugDescription
    )

    // And back, which proves nothing was merely deferred.
    rotate(app, to: .portrait, expectingLandscape: false)

    waitFor(app, "pane.chat", "The flip back lost the pane scene", timeout: 15)
    requireGone(app, "terminal.back", "No named back control belongs on the phone's stack")
    XCTAssertTrue(
      element(app, "pane.chat").exists,
      "The flip back closed the scene — the conversation is gone.\nTree was:\n"
        + app.debugDescription
    )
    XCTAssertTrue(
      app.navigationBars["needs a decision"].exists,
      "The flip back lost the pane.\nTree was:\n\(app.debugDescription)"
    )

    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "route-flip-back-to-the-stack"
    shot.lifetime = .keepAlways
    add(shot)
  }
}
