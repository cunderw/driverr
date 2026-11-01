import XCTest

/// Waits for an element and fails with the tree if it never arrives.
///
/// A free function because several classes carry a `private func require(...)` with this
/// signature, and the same signature in an `XCTestCase` extension makes those illegal
/// overrides. The other free functions here are free for the same reason.
@discardableResult
@MainActor
func waitFor(
  _ app: XCUIApplication,
  _ identifier: String,
  _ message: String,
  timeout: TimeInterval = 10,
  file: StaticString = #filePath,
  line: UInt = #line
) -> XCUIElement {
  let match = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  XCTAssertTrue(
    match.waitForExistence(timeout: timeout),
    "\(message)\nLooked for '\(identifier)'. Tree was:\n\(app.debugDescription)",
    file: file,
    line: line
  )
  return match
}

/// Waits until an element has stopped moving, then lets the caller tap it.
///
/// On `Driverr iPad` a form sheet slides up when the software keyboard finishes appearing,
/// which is after `typeText` returns. The import sheet's Import button moved from y 341.5 to
/// y 180.5 over 1.5 s. A tap inside that window misses, and the failure shows up later as the
/// next element never appearing. Guard every tap that follows typing into a sheet.
///
/// The wait ends when four consecutive reads agree, and reaching the deadline fails the test.
/// An absent element or a zero frame resets the count, because it holds still too.
///
/// Pass `waitingForKeyboard: false` for a control that appears as the keyboard goes away,
/// such as the trust prompt. Otherwise every call sleeps 5 s waiting for a keyboard that
/// never comes.
@MainActor
func waitUntilStill(
  _ app: XCUIApplication,
  _ element: XCUIElement,
  waitingForKeyboard: Bool = true,
  timeout: TimeInterval = 15,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  if waitingForKeyboard {
    let keyboardDeadline = Date().addingTimeInterval(5)
    while Date() < keyboardDeadline && app.keyboards.count == 0 { usleep(200_000) }
  }

  let deadline = Date().addingTimeInterval(timeout)
  var last = CGRect.null
  var agreements = 0
  while Date() < deadline {
    usleep(250_000)
    guard element.exists else {
      last = .null
      agreements = 0
      continue
    }
    let now = element.frame
    guard !now.isEmpty else {
      last = now
      agreements = 0
      continue
    }
    agreements = now == last ? agreements + 1 : 0
    last = now
    if agreements >= 4 { return }
  }
  XCTFail(
    "Waited \(timeout)s and the element never held still. Last frame read: \(last), "
      + "exists: \(element.exists). A wait that reaches its deadline is a sleep, and the "
      + "tap that follows it is not trustworthy.\nTree was:\n\(app.debugDescription)",
    file: file,
    line: line
  )
}

/// Scrolls a row into reach, so the tap or the read that follows lands on it.
///
/// A `Form` builds a row before the row is on screen, so `exists` is true for a row that is
/// still under the window's bottom edge, or under a form sheet's. `isHittable` is true there
/// too. On `Driverr iPad`, `settings.wraplines` at y 995.5 with height 52 reported hittable
/// in a sheet that ends at y 1018, and `setSwitch`'s tap at the row's centre landed on the
/// backdrop and dismissed the sheet. So reach is geometry: the row's whole frame is inside
/// the scroll container that holds it, and inside the window.
///
/// It drags and does not fling. One `swipeUp()` on the app travels most of that sheet's
/// height, and by a different distance on each run, so a fling can carry a row from under
/// the bottom edge to under the navigation bar. A slow drag with a hold moves the form by
/// the distance asked for, less what the pan takes to begin: 10 points measured on
/// `Driverr iPhone 17` and up to 21.5 on `Driverr iPad`. A row that is not built yet takes
/// `step`, and a built row takes the distance it is out by.
///
/// Wait for the screen before calling this. A row below the fold does not exist until it is
/// scrolled to, so an absent row gets one short wait and then a drag. It only scrolls
/// forward, so walk a form in its own order.
///
/// The top edge is not checked. A row under the navigation bar counts as in reach, and
/// `reachableRegion` says why. Call this on a sheet that has just opened and walk forward,
/// so that a row arrives from the bottom edge.
///
/// A row that never comes into reach fails here with both frames. If the form is at its end
/// by then, the app cannot show that row whole, and that is an app defect.
@discardableResult
@MainActor
func scrollIntoReach(
  _ app: XCUIApplication,
  _ identifier: String,
  maxDrags: Int = 12,
  file: StaticString = #filePath,
  line: UInt = #line
) -> XCUIElement {
  let match = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  // "Not arrived yet" is not "below the fold", and only the second is fixed by scrolling.
  if !match.exists { _ = match.waitForExistence(timeout: 1) }

  let step: CGFloat = 300
  // Past the edge by this much, so that what the pan takes to begin still leaves the row
  // clear of the edge.
  let margin: CGFloat = 44
  var reach = CGRect.null
  var frame = CGRect.null
  for drag in 0...maxDrags {
    var distance = step
    if match.exists {
      waitUntilStill(app, match, waitingForKeyboard: false, file: file, line: line)
      frame = match.frame
      reach = reachableRegion(app, holding: identifier)
      // A point of slack, because frames land on half points.
      if reach.insetBy(dx: -1, dy: -1).contains(frame) { return match }
      // Anything but "below the bottom edge" is not cured by scrolling forward.
      guard frame.maxY > reach.maxY, frame.minY >= reach.minY else { break }
      distance = min(step, frame.maxY - reach.maxY + margin)
    }
    guard drag < maxDrags else { break }
    // From the app's centre, which is inside the form on a phone and inside the form sheet
    // on an iPad. `.slow`, because the hold alone does not stop the form: on
    // `Driverr iPhone 17` a 50-point drag at `.default` moved it 300 points, and at `.slow`
    // moved it 40.
    let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    start.press(
      forDuration: 0.1,
      thenDragTo: start.withOffset(CGVector(dx: 0, dy: -distance)),
      withVelocity: .slow,
      thenHoldForDuration: 0.2
    )
  }
  XCTFail(
    "'\(identifier)' never came into reach. "
      + (match.exists
        ? "Its frame is \(frame) and the reach is \(reach)."
        : "It does not exist after scrolling forward.")
      + "\nTree was:\n\(app.debugDescription)",
    file: file,
    line: line
  )
  return match
}

/// Where a row with this identifier can be tapped: the scroll container that holds it, cut
/// to the window. The window alone when no container holds it.
///
/// Not cut to the navigation bar that lies over the container's top. XCUITest also reports
/// the bar of the screen under a sheet, and nothing tells the sheet's own bar from that one.
@MainActor
private func reachableRegion(_ app: XCUIApplication, holding identifier: String) -> CGRect {
  let window = app.windows.firstMatch.frame
  for containers in [app.collectionViews, app.tables, app.scrollViews] {
    let holder = containers.containing(.any, identifier: identifier).firstMatch
    if holder.exists { return window.intersection(holder.frame) }
  }
  return window
}

/// Flips a `Toggle` and asserts that it flipped.
///
/// Tapping a toggle's identifier hits the row, not the switch, and the value silently stays
/// put. This queries `app.switches` and taps the trailing edge, where the control is.
///
/// It settles first because the add-host card on `Driverr iPad` changes height as the
/// keyboard arrives and rows appear, and a coordinate tap lands where the switch used to be.
/// No caller has a keyboard still arriving, so it does not wait for one.
@discardableResult
@MainActor
func setSwitch(
  _ app: XCUIApplication,
  _ identifier: String,
  on: Bool,
  file: StaticString = #filePath,
  line: UInt = #line
) -> XCUIElement {
  let toggle = app.switches[identifier]
  XCTAssertTrue(
    toggle.waitForExistence(timeout: 10),
    "No switch called '\(identifier)'.\nTree was:\n\(app.debugDescription)",
    file: file,
    line: line
  )

  waitUntilStill(app, toggle, waitingForKeyboard: false, file: file, line: line)

  let wanted = on ? "1" : "0"
  if (toggle.value as? String) != wanted {
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
  }

  let predicate = NSPredicate(format: "value == %@", wanted)
  let settled = XCTNSPredicateExpectation(predicate: predicate, object: toggle)
  XCTAssertEqual(
    XCTWaiter().wait(for: [settled], timeout: 5),
    .completed,
    "The switch '\(identifier)' never reached \(wanted). A toggle that silently refuses to "
      + "move is the bug this helper exists for.\nTree was:\n\(app.debugDescription)",
    file: file,
    line: line
  )
  return toggle
}

/// The terminal's rendered text with the fake shell's `[resized WxH]` notices taken out.
///
/// On `Driverr iPad` the software keyboard goes away when XCUITest starts sending key
/// events, so the grid grows mid-`typeText` and a notice can split the echo, as in `who`,
/// `[resized 87x77]`, `ami`. The typing causes that resize, so no wait before the typing
/// can prevent it. The notice is the fake shell answering `SIGWINCH` and is not part of the
/// round trip under test. A caller that wants the notice, such as `announcedColumns`, reads
/// `terminal.value` directly.
///
/// The newline on each side goes too, because the notice sits on its own row and the echo
/// resumes on the next one.
@MainActor
func terminalText(_ terminal: XCUIElement) -> String {
  let raw = (terminal.value as? String) ?? ""
  return raw.replacingOccurrences(
    of: "\n?\\[resized [0-9]+x[0-9]+\\]\n?",
    with: "",
    options: .regularExpression
  )
}

/// Waits for a freshly opened terminal to stop moving before a test taps or types into it.
///
/// Two things move on arrival. The software keyboard is still rising, so a tap on the
/// accessory row can miss, as in `waitUntilStill`. The open's own resize also reaches the
/// far side late, because `TerminalSession` holds the first size for a second so an open
/// costs one `SIGWINCH`. On `Driverr iPad` the notice landed 422 ms after the prompt.
///
/// It does not cover the resize the typing itself causes. `terminalText` handles that one.
/// Reaching the deadline fails the test.
@MainActor
func waitForTerminalToSettle(
  _ app: XCUIApplication,
  _ terminal: XCUIElement,
  timeout: TimeInterval = 10,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  waitUntilStill(app, terminal, timeout: timeout, file: file, line: line)

  let deadline = Date().addingTimeInterval(timeout)
  var last: String?
  var agreements = 0
  while Date() < deadline {
    usleep(250_000)
    // A terminal with no value has not rendered yet. Reset, or three empty reads would agree.
    guard let now = terminal.value as? String else {
      last = nil
      agreements = 0
      continue
    }
    agreements = now == last ? agreements + 1 : 0
    last = now
    if agreements >= 3 { return }
  }
  XCTFail(
    "Waited \(timeout)s and the terminal never stopped being written to, so anything typed "
      + "now can be split by the next write. Last value read: \(String(describing: last))",
    file: file,
    line: line
  )
}

/// Accepts the first-contact trust prompt, after waiting for its card to stop moving.
///
/// The prompt arrives as a form sheet while the password field's keyboard leaves, so it
/// moves, and Trust sits in the card's navigation bar. There is no keyboard to wait for.
///
/// `timeout` is how long to wait for the prompt to arrive. `ScreenshotTourUITests` needs
/// more than the default.
@MainActor
func tapTrustPrompt(
  _ app: XCUIApplication,
  _ message: String = "Expected the trust prompt on first contact",
  timeout: TimeInterval = 10,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  let trust = waitFor(app, "hostkey.trust", message, timeout: timeout, file: file, line: line)
  waitUntilStill(app, trust, waitingForKeyboard: false, file: file, line: line)
  trust.tap()
}

/// The connect flow, seeded rather than tapped, so each class does not pay for the taps.
@MainActor
extension XCTestCase {
  /// A connected host, without the password field or the trust prompt.
  ///
  /// `-uiTestingConnected` seeds the host key and the password. See
  /// `AppEnvironment.isSeedingConnection`. With a saved password the host screen connects on
  /// appearance, so there is no Connect button to tap. A launch that does not auto-connect
  /// fails on `connect.connected`; do not add a fallback tap, because it would hide that.
  ///
  /// **Do not use this in a test about connecting.** `HostConnectUITests`, `ToggleUITests`,
  /// `TerminalReconnectUITests` and `ScreenshotTourUITests` drive the flow by hand, so they
  /// fail if the connect path breaks. Seeding the other classes is safe only because those
  /// four are not seeded.
  ///
  /// - Parameter launchArguments: extra `-uiTesting*` flags for this launch.
  func connectedHostApp(
    _ launchArguments: [String] = [],
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-uiTesting", "-uiTestingSeedHost", "-uiTestingConnected"]
    app.launchArguments += launchArguments
    app.launch()

    waitFor(app, "hosts.row", "Expected the seeded host", file: file, line: line).tap()
    waitFor(
      app,
      "connect.connected",
      "Expected the seeded host to connect on appearance",
      timeout: 15,
      file: file,
      line: line
    )
    return app
  }
}

/// Opens the host list's overflow menu, which holds `keys.open` and `settings.open`.
@MainActor
func openHostsOverflow(
  _ app: XCUIApplication,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  let menu = app.descendants(matching: .any).matching(identifier: "hosts.overflow").firstMatch
  XCTAssertTrue(
    menu.waitForExistence(timeout: 15),
    "Expected the host list's overflow menu.\nTree was:\n\(app.debugDescription)",
    file: file,
    line: line
  )
  menu.tap()
}

/// The Needs-you row for one named pane.
///
/// The section is sorted most recently blocked first, so `firstMatch` depends on when the
/// fake blocked each pane. The panes are not interchangeable: only the Claude one has a
/// readable transcript, so only it opens on `pane.chat`.
@MainActor
func blockedPaneRow(
  _ app: XCUIApplication,
  titled title: String,
  file: StaticString = #filePath,
  line: UInt = #line
) -> XCUIElement {
  // The row's label combines its children into one sentence that includes the title.
  let row = app.descendants(matching: .any)
    .matching(identifier: "session.blockedPane")
    .matching(NSPredicate(format: "label CONTAINS %@", title))
    .firstMatch
  XCTAssertTrue(
    row.waitForExistence(timeout: 15),
    "Expected a blocked pane row for '\(title)'.\nTree was:\n\(app.debugDescription)",
    file: file,
    line: line
  )
  return row
}

/// Waits for `FakeControl`'s second poll to block `w2:p1` ("schema sync") alongside the
/// seeded `w1:p2` ("needs a decision"), so a tap on a Needs-you row does not land mid-resort.
///
/// The fake blocks the second pane about three seconds after connect, and
/// `SessionModel.blockedPanesNewestFirst` then moves it to the top. Two rows is the fake's
/// final state, because `blockingScript` stays on its last snapshot, so it is a stable point
/// to tap from.
///
/// **Only for a launch serving `FakeControl.blockingScript`**, the default. Under
/// `-uiTestingOneBlocked` this times out.
@MainActor
func waitForBothBlockedPanes(
  _ app: XCUIApplication,
  timeout: TimeInterval = 15,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  let rows = app.descendants(matching: .any).matching(identifier: "session.blockedPane")
  let waiter = XCTNSPredicateExpectation(
    predicate: NSPredicate(format: "count == 2"), object: rows)
  XCTAssertEqual(
    XCTWaiter().wait(for: [waiter], timeout: timeout),
    .completed,
    "Expected both blocked panes to appear.\nTree was:\n\(app.debugDescription)",
    file: file,
    line: line
  )
}

/// One named pane's row in the session tree, as opposed to its Needs-you row.
///
/// The Needs-you row opens the pane with the composer focused and the keyboard up. The tree
/// row opens it without, which is what a test about the pane screen's appearance wants.
@MainActor
func treePaneRow(
  _ app: XCUIApplication,
  titled title: String,
  file: StaticString = #filePath,
  line: UInt = #line
) -> XCUIElement {
  let row = app.descendants(matching: .any)
    .matching(identifier: "session.pane")
    .matching(NSPredicate(format: "label CONTAINS %@", title))
    .firstMatch
  // Wait before scrolling. The tree arrives after the screen is up, and only "below the
  // fold" is fixed by swiping, not "not here yet".
  if !row.waitForExistence(timeout: 15) {
    for _ in 0..<6 where !row.exists { app.swipeUp() }
  }
  XCTAssertTrue(
    row.exists,
    "Expected a tree row for the pane '\(title)'.\nTree was:\n\(app.debugDescription)",
    file: file,
    line: line
  )
  // A `Form` publishes rows below the fold, and `.tap()` on one taps a clamped coordinate
  // that silently opens the wrong pane. So require hittable, not only existing.
  for _ in 0..<8 where !row.isHittable { app.swipeUp() }
  XCTAssertTrue(
    row.isHittable,
    "The tree row for '\(title)' never came into reach.\nTree was:\n\(app.debugDescription)",
    file: file,
    line: line
  )
  return row
}

// MARK: - The keyboard the app can see and a test cannot

/// The launch argument that puts `debug.keyboardMetrics` in the tree.
let uiTestingKeyboardMetrics = "-uiTestingKeyboardMetrics"

/// What `TerminalScreen` laid the composer out against, read back out of the app.
struct KeyboardMetrics {
  /// `UIKeyboardFrameEndUserInfoKey`'s top in window coordinates, or `nil` with no keyboard.
  var keyboardTop: Double?
  var surfacesBottom: Double
  /// The slot inside `TerminalScreen.content` that every surface has to fit. Nothing inside
  /// the stack can move it.
  var regionTop: Double
  var regionBottom: Double
  /// With `surfacesBottom`, says whether the surfaces overflow their slot at either end.
  var surfacesTop: Double
  /// The terminals block, outside its own keyboard padding: the frame
  /// `KeyboardNoticeModel.obstruction(forRegionEndingAt:)` is given.
  var terminalTop: Double
  var terminalBottom: Double
  /// The chat surface, when one is showing. Stale from the last time one was.
  var chatTop: Double
  var chatBottom: Double
  /// `PaneComposerBar`'s measured height and card bottom in window coordinates.
  /// `keyboardTop - composerBottom` is the gap between the card and the keyboard. It is zero
  /// on a simulator with no home indicator, so it has to be read on hardware.
  var composerHeight: Double
  var composerBottom: Double
  /// The chat surface's left edge. Non-zero means the surface moved, not the scroll view.
  var chatMinX: Double
  /// The conversation's horizontal content offset. 16, which is `ChatColumn.inset`, is the
  /// sideways drift a re-applied scroll target used to cause. It should be unreachable now,
  /// and a 16 on a device would say otherwise.
  var chatContentOffsetX: Double
  /// Equal widths mean the conversation has no horizontal axis, so no gesture or wide row
  /// explains a non-zero offset.
  var chatContentWidth: Double
  var chatContainerWidth: Double
  /// Says whether the transcript grew across a resume, as opposed to an inset change.
  var chatContentHeight: Double
  /// The conversation's `adjustedContentInset.bottom` and its two inputs. Content resting
  /// under the composer is either too small an inset or an offset that ignored it, and
  /// `chatBoundsHeight - chatSlotHeight` says which.
  var chatInsetBottom: Double
  var chatBoundsHeight: Double
  var chatSlotHeight: Double
  /// How far the reader is from the end of the conversation, in points. Well past
  /// `ChatEndProximity.jumpTolerance` while `chatHasStandingTarget` is true means a stale
  /// target is dragging the reader back on every layout pass.
  var chatDistanceFromEnd: Double
  /// Whether the reader took the content over themselves, rather than a `place` scroll.
  var chatPositionedByUser: Bool
  /// Whether a `ScrollPosition` target is still armed.
  var chatHasStandingTarget: Bool
  /// `columns x rows` as SwiftTerm last reported them to the far side, or `none`.
  var grid: String

  /// The slot itself, which is what an overflow is measured against.
  var regionHeight: Double { regionBottom - regionTop }
  /// How far the surfaces hang past their slot, at either end. Zero is the passing result.
  var surfacesOverflow: Double {
    max(0, regionTop - surfacesTop) + max(0, surfacesBottom - regionBottom)
  }
}

/// Reads `debug.keyboardMetrics`. Requires `uiTestingKeyboardMetrics` in the launch
/// arguments.
///
/// The app has to report the keyboard because `app.keyboards.firstMatch.frame` excludes the
/// candidate row. On `Driverr iPhone 17` it starts 44 pt below where the keyboard is drawn,
/// so a check against it passes when the composer is behind the keys.
@MainActor
func keyboardMetrics(
  _ app: XCUIApplication,
  file: StaticString = #filePath,
  line: UInt = #line
) -> KeyboardMetrics {
  let readout = app.descendants(matching: .any)
    .matching(identifier: "debug.keyboardMetrics").firstMatch
  XCTAssertTrue(
    readout.waitForExistence(timeout: 10),
    "No 'debug.keyboardMetrics' element. Launch the app with \(uiTestingKeyboardMetrics)."
      + "\nTree was:\n\(app.debugDescription)",
    file: file,
    line: line
  )
  var fields: [String: String] = [:]
  for pair in readout.label.split(separator: " ") {
    let halves = pair.split(separator: "=", maxSplits: 1)
    if halves.count == 2 { fields[String(halves[0])] = String(halves[1]) }
  }
  func number(_ key: String) -> Double {
    guard let value = fields[key], let parsed = Double(value) else {
      XCTFail(
        "Could not read '\(key)' out of the metrics label '\(readout.label)'.",
        file: file,
        line: line
      )
      return 0
    }
    return parsed
  }
  return KeyboardMetrics(
    keyboardTop: fields["keyboardTop"] == "nil" ? nil : number("keyboardTop"),
    surfacesBottom: number("surfacesBottom"),
    regionTop: number("regionTop"),
    regionBottom: number("regionBottom"),
    surfacesTop: number("surfacesTop"),
    terminalTop: number("terminalTop"),
    terminalBottom: number("terminalBottom"),
    chatTop: number("chatTop"),
    chatBottom: number("chatBottom"),
    composerHeight: number("composerHeight"),
    composerBottom: number("composerBottom"),
    chatMinX: number("chatMinX"),
    chatContentOffsetX: number("chatContentOffsetX"),
    chatContentWidth: number("chatContentWidth"),
    chatContainerWidth: number("chatContainerWidth"),
    chatContentHeight: number("chatContentHeight"),
    chatInsetBottom: number("chatInsetBottom"),
    chatBoundsHeight: number("chatBoundsHeight"),
    chatSlotHeight: number("chatSlotHeight"),
    chatDistanceFromEnd: number("chatDistanceFromEnd"),
    chatPositionedByUser: fields["chatPositionedByUser"] == "true",
    chatHasStandingTarget: fields["chatHasStandingTarget"] == "true",
    grid: fields["grid"] ?? "none"
  )
}

/// Asserts the composer's field and Send button are wholly above the keyboard as drawn.
///
/// Send is the lowest thing on the card, and its 44 pt tap target overflows the card's
/// bottom edge. A plain non-overlap check passed with the target 1.17 pt short of the keys.
///
/// The 3 pt default is the clearance the layout delivers on `Driverr iPhone 17` in landscape
/// (3.17 pt), so it fails if the layout moves back toward flush. Raising
/// `PaneComposerBar.cardBottomInset` does not raise it one for one, because Send's overflow
/// grows with the inset.
///
/// It prints the geometry on every call so a passing run still records the numbers.
@MainActor
func assertComposerClearsTheDrawnKeyboard(
  _ app: XCUIApplication,
  _ context: String,
  minimumClearance: Double = 3,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  let metrics = keyboardMetrics(app, file: file, line: line)
  guard let keyboardTop = metrics.keyboardTop else {
    XCTFail(
      "The app reports no keyboard in \(context), so there is nothing to clear and this "
        + "assertion cannot fail for the reason it exists. Two causes, in order: something "
        + "took the keyboard away again, or the simulator's software keyboard is off — which "
        + "is what a connected hardware keyboard does.\nTree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
    return
  }
  let field = app.descendants(matching: .any).matching(identifier: "composer.text").firstMatch
  let send = app.descendants(matching: .any).matching(identifier: "composer.send").firstMatch

  let card = app.descendants(matching: .any).matching(identifier: "composer.card").firstMatch
  print(
    "[composer vs keyboard] \(context): drawn keyboard top \(keyboardTop) "
      + "(XCUITest says \(app.keyboards.firstMatch.frame.minY)) "
      + "field \(field.frame) send \(send.frame) "
      + "card \(card.frame) surfacesBottom \(metrics.surfacesBottom) "
      + "composerBottom \(metrics.composerBottom)"
  )

  for (name, element) in [("field", field), ("send button", send)] {
    XCTAssertTrue(element.exists, "Expected the composer's \(name) in \(context).", file: file, line: line)
    XCTAssertLessThanOrEqual(
      Double(element.frame.maxY),
      keyboardTop - minimumClearance,
      """
      The composer's \(name) does not clear the keyboard as drawn in \(context), \
      by the \(minimumClearance) pt this asks for.
      \(name):                \(element.frame)
      keyboard, drawn from:   \(keyboardTop)
      keyboard, XCUITest:     \(app.keyboards.firstMatch.frame)
      clearance:              \(keyboardTop - Double(element.frame.maxY))
      """,
      file: file,
      line: line
    )
  }
}

// MARK: - Leaving a pane scene, whichever route it is on

/// The one control that says a pane scene is on screen, on either route.
///
/// The ⋯ menu (`PaneActionsMenu`) renders for every target, a plain shell included, and
/// nowhere else. It also identifies the scene's navigation bar among the others in the tree,
/// which is how `paneSceneLeaveControl` finds the system back button.
private let paneSceneMarker = "pane.actions"

/// Waits for the pane scene to be up, on either route.
///
/// Asserted on the scene's own chrome. XCUITest sees through a push, and on iPad the host
/// list stays on screen beside the scene, so the host list proves nothing.
@discardableResult
@MainActor
func waitForPaneScene(
  _ app: XCUIApplication,
  _ message: String = "Expected the pane scene's own chrome",
  timeout: TimeInterval = 10,
  file: StaticString = #filePath,
  line: UInt = #line
) -> XCUIElement {
  let marker = app.descendants(matching: .any).matching(identifier: paneSceneMarker).firstMatch
  XCTAssertTrue(
    marker.waitForExistence(timeout: timeout),
    "\(message)\nLooked for '\(paneSceneMarker)', the ⋯ menu every pane scene draws. Tree was:\n"
      + app.debugDescription,
    file: file,
    line: line
  )
  return marker
}

/// The control that takes you out of the pane scene, on either route.
///
/// On regular width it is `terminal.back` in the split view's detail column. On compact it is
/// the system back button of the phone's stack, which carries no identifier.
///
/// So the phone's button is found by position: the first button of the navigation bar that
/// holds `pane.actions`. Not `app.navigationBars.firstMatch`, because the host screen's bar
/// can also be in the tree, and its first button pops to the host list.
///
/// A test about which control is drawn, such as `PaneDetailColumnUITests`, asserts the
/// identifiers by name instead.
@MainActor
private func paneSceneLeaveControl(_ app: XCUIApplication) -> XCUIElement {
  let named = app.descendants(matching: .any).matching(identifier: "terminal.back").firstMatch
  if named.exists { return named }
  let bar = app.navigationBars.containing(.any, identifier: paneSceneMarker).firstMatch
  return bar.exists ? bar.buttons.element(boundBy: 0) : sideToolbarBackButton(app)
}

/// The system back button when the bar's items are drawn in a column at the side.
///
/// iPhone Duo's outer display does that: the navigation bar keeps the title and no button, so
/// `app.navigationBars.buttons` is empty, and the toolbar holds the system's `BackButton`.
@MainActor
func sideToolbarBackButton(_ app: XCUIApplication) -> XCUIElement {
  app.toolbars.buttons["BackButton"].firstMatch
}

/// Leaves the pane scene by whichever control this route offers.
///
/// Use this rather than tapping a control by name. `terminal.back` exists on the iPad only
/// and the phone's back button has no identifier, so a hard-coded tap times out on the other
/// device.
@MainActor
func leavePaneScene(
  _ app: XCUIApplication,
  _ message: String = "Expected a way out of the pane scene",
  file: StaticString = #filePath,
  line: UInt = #line
) {
  waitForPaneScene(app, message, file: file, line: line)
  let leave = paneSceneLeaveControl(app)
  XCTAssertTrue(
    leave.waitForExistence(timeout: 10),
    "\(message)\nNo 'terminal.back' and no back button on the pane scene's navigation bar. "
      + "Tree was:\n" + app.debugDescription,
    file: file,
    line: line
  )
  leave.tap()
}

// MARK: - Reaching a control inside a sheet that has detents

/// Brings a control inside a presented sheet into reach, and fails with the tree if it
/// never arrives.
///
/// **`swipeUp()` is inert on a sheet with `presentationDetents`, and nothing says so.** The
/// sheet's resize gesture takes the flick and the scroll view never sees it. On `Driverr
/// iPad` four kinds of flick left the terminal's Settings sheet unmoved. One
/// `press(forDuration:thenDragTo:)` inside its collection view took the sheet to `.large`
/// and brought `settings.fontsize` into reach. `ContentView`'s Settings sheet has no detents
/// and scrolls under `app.swipeUp()`.
///
/// It waits before it drags, for the reason `treePaneRow` gives, and asserts `isHittable`
/// rather than `exists`, because a tap on a row below the fold hits a clamped coordinate.
@discardableResult
@MainActor
func dragSheetToReveal(
  _ app: XCUIApplication,
  _ identifier: String,
  anchoredAt anchorIdentifier: String,
  _ message: String,
  maxDrags: Int = 8,
  file: StaticString = #filePath,
  line: UInt = #line
) -> XCUIElement {
  let match = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  let anchor = app.descendants(matching: .any).matching(identifier: anchorIdentifier).firstMatch
  return dragSheetToReveal(
    app,
    match,
    describedAs: identifier,
    anchoredAt: anchor,
    message,
    maxDrags: maxDrags,
    file: file,
    line: line
  )
}

/// Same as above, for a caller that already holds the element, such as a tile matched by
/// label among tiles that share `terminal.sheet.pane`. Re-resolving by identifier would
/// return a different tile. `description` names the element in failure messages, because
/// its identifier does not tell it apart.
@discardableResult
@MainActor
func dragSheetToReveal(
  _ app: XCUIApplication,
  _ match: XCUIElement,
  describedAs description: String,
  anchoredAt anchor: XCUIElement,
  _ message: String,
  maxDrags: Int = 8,
  file: StaticString = #filePath,
  line: UInt = #line
) -> XCUIElement {
  if match.waitForExistence(timeout: 2), match.isHittable { return match }

  // The anchor is visible without scrolling, so its container is the one to drag. The frame
  // is read once: the first drag grows the sheet to `.large`, and the starting rect stays
  // inside the sheet either way.
  XCTAssertTrue(
    anchor.waitForExistence(timeout: 10),
    "\(message)\nThe sheet never showed the anchor for '\(description)', so there was "
      + "nothing to drag. Tree was:\n\(app.debugDescription)",
    file: file,
    line: line
  )
  guard let rect = scrollingContainerFrame(app, holding: anchor) else {
    XCTFail(
      "\(message)\nNo scrolling container holds the anchor for '\(description)'. Tree "
        + "was:\n" + app.debugDescription,
      file: file,
      line: line
    )
    return match
  }

  let origin = app.coordinate(withNormalizedOffset: .zero)
  let start = origin.withOffset(CGVector(dx: rect.midX, dy: rect.minY + rect.height * 0.8))
  let end = origin.withOffset(CGVector(dx: rect.midX, dy: rect.minY + rect.height * 0.2))
  for _ in 0..<maxDrags {
    if match.exists, match.isHittable { return match }
    start.press(forDuration: 0.05, thenDragTo: end)
    _ = match.waitForExistence(timeout: 1)
  }

  XCTAssertTrue(
    match.exists && match.isHittable,
    "\(message)\nLooked for '\(description)' after \(maxDrags) drags inside "
      + "\(rect). Tree was:\n\(app.debugDescription)",
    file: file,
    line: line
  )
  return match
}

/// The frame of the scrolling container that holds `anchor`, or `nil` if none does.
///
/// Found by frame containment rather than by index, because on `Driverr iPad` the sidebar's
/// collection view is in the tree too, in no fixed order. The smallest container wins,
/// because on the phone the screen behind a sheet contains every point the sheet does.
@MainActor
private func scrollingContainerFrame(
  _ app: XCUIApplication,
  holding anchor: XCUIElement
) -> CGRect? {
  guard anchor.exists else { return nil }
  let point = CGPoint(x: anchor.frame.midX, y: anchor.frame.midY)
  var best: CGRect?
  // A SwiftUI `Form` is a collection view. The other two types cover a screen that renders
  // differently.
  for type in [XCUIElement.ElementType.collectionView, .table, .scrollView] {
    let candidates = app.descendants(matching: type)
    for index in 0..<candidates.count {
      let candidate = candidates.element(boundBy: index)
      guard candidate.exists else { continue }
      let frame = candidate.frame
      guard frame.contains(point) else { continue }
      if let current = best, current.width * current.height <= frame.width * frame.height {
        continue
      }
      best = frame
    }
  }
  return best
}
