import XCTest

/// The launch and lookup helpers `PaneComposerUITests` and `PaneComposerInputUITests` share.
///
/// A base class and not an `XCTestCase` extension, because other classes carry a
/// `private func require(...)` with the same signature, and an extension makes those illegal
/// overrides (see `waitFor` in `UITestSupport.swift`). It holds no tests.
@MainActor
class PaneComposerUITestCase: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  @discardableResult
  func require(
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

  /// Waits for absence. XCUITest sees a hierarchy mid-transition, so a single
  /// `XCTAssertFalse(exists)` passes or fails on timing.
  func requireGone(
    _ app: XCUIApplication,
    _ identifier: String,
    _ message: String,
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let match = element(app, identifier)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline && match.exists {
      _ = match.waitForExistence(timeout: 0.2)
    }
    XCTAssertFalse(
      match.exists,
      "\(message)\n'\(identifier)' was still there. Tree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
  }

  func connectedHost(_ launchArguments: [String] = []) -> XCUIApplication {
    XCUIDevice.shared.orientation = .portrait
    // Seeded, because neither subclass is about connecting.
    let app = connectedHostApp(launchArguments)
    require(app, "session.workspace", "Expected the session tree")
    return app
  }
}
