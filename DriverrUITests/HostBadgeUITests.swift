import XCTest

/// The host list's red badge, and the list's selection.
///
/// Which pane a badge names is `SessionTreeTests.loneBlockedPaneNeedsExactlyOne`. This
/// covers that a tap on the badge reaches that pane, since a `Button` inside a
/// `NavigationLink`'s label can hand every tap to the row, and that the chosen host survives
/// the list rebuilding under it.
///
/// Relaunches per test: connecting records a trust decision and leaves a connection up.
@MainActor
final class HostBadgeUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func all(_ app: XCUIApplication, _ identifier: String) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: identifier)
  }

  /// Gets back to the host list. On iPhone the list is behind a back button. On iPad the
  /// sidebar never went away.
  private func returnToHostList(_ app: XCUIApplication) {
    guard !element(app, "hosts.row").exists else { return }
    let back = app.navigationBars.buttons.element(boundBy: 0)
    if back.exists { back.tap() }
  }

  /// A tap on a badge naming exactly one blocked pane opens that pane.
  ///
  /// `-uiTestingOneBlocked` keeps one blocked pane (`AppEnvironment.isOneBlocked`). The
  /// ordinary fixture blocks a second pane, and `loneBlockedPane` would go `nil` under the tap.
  func testTappingABadgeThatNamesOnePaneOpensThatPane() {
    let app = connectedHostApp(["-uiTestingOneBlocked"])

    // The badge is on the list, and the row knows what is blocked only while the session
    // polls. See `SessionPollHold` in `ContentView.swift`.
    returnToHostList(app)
    let badge = waitFor(
      app,
      "hosts.blocked",
      "Expected a red badge on the connected host's row",
      timeout: 20
    )

    // The row did not grow for the badge's 44 pt target. Rows measure 64.7 pt on
    // `Driverr iPhone 17` and 58.5 on `Driverr iPad`, and the grown row 74.0, so one bound
    // covers both devices.
    let row = element(app, "hosts.row").frame
    print("hosts.row height: \(row.height) pt, hosts.connected minX: "
      + "\(element(app, "hosts.connected").frame.minX) pt")
    XCTAssertLessThan(
      row.height,
      70,
      "The badge's tap target grew the host row to \(row.height) pt. The negative padding "
        + "in ContentView.blockedBadge is what hands that height back to the layout."
    )

    // Tapped 18 pt up and left of centre, outside the drawn capsule (about 19 by 17 pt) and
    // inside the 44 pt target. `ContentView.blockedBadge` grows the hit area with a
    // `contentShape` and hands the space back with negative padding.
    //
    // Both the frame and the tap are checked. The accessibility frame reads 44 by 44 even
    // without `contentShape`, which leaves the corners dead; only a tap there catches that.
    let target = badge.frame
    print("hosts.blocked frame: \(target.width) x \(target.height) pt")
    XCTAssertTrue(
      target.width >= 44 && target.height >= 44,
      "The badge's tap target is \(target.width) x \(target.height) pt, under the 44 x 44 "
        + "minimum.\nTree was:\n\(app.debugDescription)"
    )

    badge
      .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .withOffset(CGVector(dx: -18, dy: -18))
      .tap()

    // The pane scene, not the host screen, which is where a row that ate the tap would go.
    waitForPaneScene(app, "Expected the badge to open the pane scene", timeout: 20)

    // The pane the badge counted: `w1:p2`, a Claude pane, which opens on its chat.
    XCTAssertTrue(
      app.navigationBars["needs a decision"].waitForExistence(timeout: 20),
      "The badge opened something other than the blocked pane.\nTree was:\n\(app.debugDescription)"
    )
    waitFor(app, "pane.chat", "Expected the blocked pane's conversation", timeout: 20)
  }

  /// Choosing a host survives the tree changing under the list.
  ///
  /// The rows redraw on every poll, and a link that carries its destination is rebuilt with
  /// its row. `List(selection:)` with `NavigationLink(value:)` holds the host as an id. The
  /// fake's second snapshot blocks `w2:p1` while the host screen is up, forcing a rebuild.
  func testTheChosenHostSurvivesTheTreeRebuildingUnderIt() {
    let app = connectedHostApp()

    let blockedRows = all(app, "session.blockedPane")
    let grew = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "count == 2"),
      object: blockedRows
    )
    XCTAssertEqual(
      XCTWaiter().wait(for: [grew], timeout: 30),
      .completed,
      "The fixture never blocked its second pane, so nothing rebuilt the list.\n"
        + "Tree was:\n\(app.debugDescription)"
    )

    // Still on the chosen host. A lost selection shows the placeholder and no pill.
    XCTAssertTrue(
      element(app, "connect.connected").exists,
      "The tree rebuild lost the chosen host.\nTree was:\n\(app.debugDescription)"
    )
    XCTAssertFalse(
      element(app, "detail.empty").exists,
      "The detail column fell back to its placeholder while a host was chosen.\n"
        + "Tree was:\n\(app.debugDescription)"
    )
  }
}
