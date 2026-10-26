import XCTest

/// The App Store screenshot tour: a deterministic walk through the app, capturing one
/// full-screen image at each stop. A UI test is the only way to get pixel-accurate output
/// at the sizes App Store Connect requires.
///
/// Everything comes from `FakeControl`'s seeded session, so every run captures the same
/// content. `scripts/screenshots.sh` runs it on the store sizes, copies the captures into
/// `docs/app-store-assets/raw/`, and frames them for the store with
/// `scripts/frame-screenshots.swift`, which also sets the store order. The capture names
/// here are what that script looks for.
///
/// Hand-driven on purpose: it types the password and accepts the trust prompt rather than
/// seeding the connection, so it also fails if the connect path breaks. It is one test on
/// one launch.
@MainActor
final class ScreenshotTourUITests: XCTestCase {
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
    timeout: TimeInterval = 20,
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

  /// Taps `tap` until `opens` appears, up to three times.
  ///
  /// It retries only a tap whose effect is a screen appearing, and still fails if the screen
  /// never arrives, so the tour cannot capture the wrong screen.
  ///
  /// `opening` names a menu to open before each attempt, because a missed tap may have
  /// dismissed the menu.
  private func tapUntil(
    _ app: XCUIApplication,
    opening menu: String? = nil,
    tap identifier: String,
    opens target: String,
    _ what: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    for attempt in 1...3 {
      if let menu {
        require(app, menu, "Expected the menu holding \(what)", file: file, line: line).tap()
      }
      require(app, identifier, "Expected a way into \(what)", file: file, line: line).tap()
      if element(app, target).waitForExistence(timeout: attempt == 1 ? 8 : 20) { return }
    }
    XCTFail(
      "\(what) never opened after 3 taps on '\(identifier)'.\nTree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
  }

  /// `XCUIScreen`, not `XCUIApplication.screenshot()`, which can render at a stale width.
  /// The screen capture is what the device shows.
  private func capture(_ name: String) {
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// Fails unless the screen shows something inside `element`'s frame.
  ///
  /// An element can be in the accessibility tree, hittable and at the right frame, and still
  /// not be in a capture. On `Driverr iPad`, after `typeText` into the password field, the
  /// terminal's key row is like that until the app has been to the background and back.
  /// Measured under the Escape key: a drawn key reads 0.92, an undrawn one 0.0.
  ///
  /// The number is the gap between the lightest and darkest pixel, as luminance from 0 to 1.
  private func assertDrawn(
    _ element: XCUIElement,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let frame = element.frame
    let image = XCUIScreen.main.screenshot().image
    guard let source = image.cgImage else {
      XCTFail("The screen gave no image to read. \(message)", file: file, line: line)
      return
    }
    let scale = CGFloat(source.width) / image.size.width
    let rect = CGRect(
      x: frame.minX * scale, y: frame.minY * scale,
      width: frame.width * scale, height: frame.height * scale
    ).integral
    guard let crop = source.cropping(to: rect), crop.width > 0, crop.height > 0 else {
      XCTFail("Nothing of \(frame) is on the screen. \(message)", file: file, line: line)
      return
    }
    var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
    let context = CGContext(
      data: &pixels, width: crop.width, height: crop.height, bitsPerComponent: 8,
      bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    context?.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
    var lowest = 1.0
    var highest = 0.0
    for index in stride(from: 0, to: pixels.count, by: 4) {
      let luminance =
        (0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1])
          + 0.0722 * Double(pixels[index + 2])) / 255
      lowest = min(lowest, luminance)
      highest = max(highest, luminance)
    }
    XCTAssertGreaterThan(
      highest - lowest, 0.25,
      "\(message)\nThe element is at \(frame) in the accessibility tree, and the screen there is "
        + "one flat colour (luminance range \(highest - lowest)). It is laid out and not drawn.",
      file: file,
      line: line
    )
  }

  /// Enters the password by tapping the software keyboard's keys when it has every one of
  /// them, and with `typeText` when it does not.
  ///
  /// `typeText` into a secure field leaves the terminal's key row out of every later capture
  /// on the iPad: the row stays in the accessibility tree, hittable, and is not drawn. Keys
  /// tapped one by one do not do that. The iPad keyboard has a number row, so it has every
  /// key of the password. The phone's first plane has no digit, so the phone still types, and
  /// its row is drawn either way. `assertDrawn` before the terminal capture checks both.
  private func enterPassword(_ app: XCUIApplication, _ password: String) {
    _ = app.keyboards.firstMatch.waitForExistence(timeout: 10)
    let keys = password.map { app.keyboards.keys[String($0)] }
    if keys.allSatisfy(\.exists) {
      for key in keys { key.tap() }
      print("tour: entered the password by tapping keys")
    } else {
      app.typeText(password)
      print("tour: entered the password with typeText")
    }
  }

  /// Lets animations and the terminal's redraw settle, because a store screenshot caught
  /// mid-transition looks like a rendering bug.
  private func settle(_ app: XCUIApplication) {
    _ = app.wait(for: .runningForeground, timeout: 2)
    usleep(700_000)
  }

  /// Scrolls `form` until `identifier`'s bottom edge rests a little above the form's bottom
  /// edge, so it is the last thing on screen and nothing below it is.
  ///
  /// By slow drags that hold before they lift, because a swipe flings the form to its end.
  /// Each drag is measured again, because the drag's first points are spent recognising it.
  /// A form builds its rows lazily, so a row below the fold may not exist yet, and the first
  /// drag is then half the form's height.
  private func scroll(
    _ form: XCUIElement,
    toRest identifier: String,
    in app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let target = element(app, identifier)
    let bounds = form.frame
    // The row's bottom edge is wanted between these two.
    let lowest = bounds.maxY - 24
    let highest = bounds.maxY - 120
    for _ in 0..<5 {
      let distance: CGFloat
      if target.exists {
        let bottom = target.frame.maxY
        if bottom <= lowest && bottom >= highest { return }
        distance = bottom - (lowest + highest) / 2
      } else {
        distance = bounds.height / 2
      }
      // Up for a positive distance, down for a negative one, inside the form either way.
      let travel = min(abs(distance), bounds.height - 80)
      // From the app, with the form's frame read once, because the row that found the form
      // can scroll out of the tree.
      let low = app.coordinate(withNormalizedOffset: .zero)
        .withOffset(CGVector(dx: bounds.midX, dy: bounds.maxY - 40))
      let high = low.withOffset(CGVector(dx: 0, dy: -travel))
      let (from, to) = distance > 0 ? (low, high) : (high, low)
      from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.4)
    }
    XCTFail(
      "'\(identifier)' did not come to rest at the bottom of the form, it is at "
        + "\(target.frame) in \(bounds).\nTree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
  }

  /// Scrolls until the top edge of `identifier`'s row meets the bottom edge of `bar`, so the
  /// shot has no row cut in half under the bar.
  ///
  /// A row's edge, not its label's: the row is the cell holding the identifier when there is
  /// one. A drag moves the content by less than the finger, because the first points are
  /// spent recognising it, so each round measures what the last drag lost and adds it. A gap
  /// smaller than that loss first moves the other way, so the next drag is long enough to
  /// count.
  private func align(
    _ identifier: String,
    under bar: XCUIElement,
    in app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    func rowTop() -> CGFloat {
      let cell = app.cells.containing(.any, identifier: identifier).firstMatch
      return cell.exists ? cell.frame.minY : element(app, identifier).frame.minY
    }
    let origin = app.coordinate(withNormalizedOffset: .zero)
    let x = bar.frame.midX
    let barBottom = bar.frame.maxY
    var lost: CGFloat = 0
    for _ in 0..<8 {
      let before = rowTop()
      var gap = before - barBottom
      print("tour: '\(identifier)' row top \(before), bar bottom \(barBottom), gap \(gap)")
      if abs(gap) <= 0.5 { return }
      if abs(gap) < 30 { gap += gap > 0 ? -60 : 60 }
      // Up for a positive gap, down for a negative one, in the middle of the screen.
      let travel = abs(gap) + lost
      let start = origin.withOffset(CGVector(dx: x, dy: barBottom + 260))
      let end = start.withOffset(CGVector(dx: 0, dy: gap > 0 ? -travel : travel))
      start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
      let moved = abs(before - rowTop())
      if moved > 0 { lost = max(0, travel - moved) }
    }
    XCTFail(
      "The '\(identifier)' row's top edge is at \(rowTop()), and the bar ends at \(barBottom).\n"
        + "Tree was:\n\(app.debugDescription)",
      file: file,
      line: line
    )
  }

  /// Whether the host list is on screen beside the connected host's screen, which is the
  /// split view at regular width. Read from the layout, so it follows the app and not the
  /// device's name.
  ///
  /// `isHittable`, not `exists`, because XCUITest sees through a push: on the phone the list
  /// still exists under the host's screen.
  private func showsTheHostListBesideTheHost(_ app: XCUIApplication) -> Bool {
    let row = element(app, "hosts.row")
    let needsYou = element(app, "session.needsYou")
    return row.exists && row.isHittable && needsYou.exists && needsYou.isHittable
  }

  /// Goes back to the host list with the host still connected. For the stack only: in the
  /// split view the list never went away.
  private func returnToHostList(_ app: XCUIApplication) {
    let back = app.navigationBars.buttons.element(boundBy: 0)
    XCTAssertTrue(
      back.waitForExistence(timeout: 10),
      "Expected a back button on the host screen. Tree was:\n\(app.debugDescription)"
    )
    back.tap()
    // The badge arrives with the first poll after the list is back on screen.
    require(app, "hosts.blocked", "Expected the connected host's badge on the list")
    XCTAssertTrue(
      element(app, "hosts.row").isHittable,
      "Expected the host list on screen. Tree was:\n\(app.debugDescription)"
    )
  }

  /// Opens the connected host again after `returnToHostList`.
  private func returnToTheHost(_ app: XCUIApplication) {
    require(app, "hosts.row", "Expected the seeded host").tap()
    let needsYou = element(app, "session.needsYou")
    XCTAssertTrue(
      needsYou.waitForExistence(timeout: 20) && needsYou.isHittable,
      "Expected the connected host's screen. Tree was:\n\(app.debugDescription)"
    )
  }

  /// Waits for the software keyboard to leave. It leaves with an animation, so a check
  /// straight after the tap can still find it.
  private func requireKeyboardGone(
    _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
  ) {
    let gone = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
    XCTAssertEqual(
      XCTWaiter().wait(for: [gone], timeout: 10), .completed,
      "The keyboard did not go down. Tree was:\n\(app.debugDescription)", file: file, line: line)
  }

  /// Opens the pane switcher over the chat, captures it with its top in view, and closes it.
  ///
  /// Over the chat, not the terminal, because the terminal's caret shows below the iPad's
  /// sheet. The iPad's sheet is page-sized and shows every pane. The phone's opens at its
  /// medium detent, and a drag on its title bar takes it to large without scrolling the list,
  /// so the shot starts at the first workspace and runs on below the fold.
  ///
  /// Two `settle`s before the shot, because each tile's picture is grey bars until the first
  /// screen read answers, and nothing in the accessibility tree says when it has: the tile's
  /// label is set explicitly and hides the picture's text. Check the capture for grey tiles.
  private func captureThePaneSwitcher(
    _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
  ) {
    require(app, "terminal.panes", "Expected the panes button", file: file, line: line).tap()
    let done = require(
      app, "terminal.sheet.done", "Expected the pane switcher", file: file, line: line)
    let title = app.navigationBars.staticTexts["Panes on workbox"]
    let screen = app.windows.firstMatch.frame
    let origin = app.coordinate(withNormalizedOffset: .zero)
    for _ in 0..<3 where done.frame.minY > screen.height * 0.2 {
      // The title is in the sheet's bar, outside the list, so the drag resizes the sheet.
      let grip = title.exists ? title.frame.midY : done.frame.midY
      let start = origin.withOffset(CGVector(dx: screen.midX, dy: grip))
      let end = origin.withOffset(CGVector(dx: screen.midX, dy: screen.minY + 40))
      start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
    }
    XCTAssertLessThanOrEqual(
      done.frame.minY, screen.height * 0.2,
      "The switcher is not at full height. Tree was:\n\(app.debugDescription)",
      file: file, line: line)
    // The first workspace's header too, so the list starts at its top.
    XCTAssertTrue(
      element(app, "terminal.sheet.workspace").isHittable,
      "The switcher's first workspace is off screen. Tree was:\n\(app.debugDescription)",
      file: file, line: line)
    settle(app)
    settle(app)
    capture("pane-switcher")
    done.tap()
    XCTAssertTrue(
      done.waitForNonExistence(timeout: 30),
      "The switcher did not close. Tree was:\n\(app.debugDescription)", file: file, line: line)
  }

  func testTheTour() {
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments += ["-uiTesting", "-uiTestingSeedHost", "-uiTestingDemoTranscript"]
    app.launch()

    // Seeded, because an empty list shows nothing.
    require(app, "hosts.row", "Expected the seeded host")

    // The session, with a blocked agent lifted to the top. Connected by hand.
    require(app, "hosts.row", "Expected the seeded host").tap()
    require(app, "connect.password", "Expected a password field").tap()
    // By tapping keys where the keyboard has them, because `typeText` into the secure field
    // leaves the terminal's key row out of every later capture on the iPad.
    enterPassword(app, "hunter2")
    require(app, "connect.connect", "Expected a connect button").tap()
    tapTrustPrompt(app, "Expected the trust prompt", timeout: 20)
    require(app, "session.needsYou", "Expected the Needs you section")
    require(app, "session.workspace", "Expected the session tree")
    // Both, because the second blocked pane can arrive a poll after the first, and the shot
    // would then say "Needs You · 1" beside a badge that says 2.
    waitForBothBlockedPanes(app)
    settle(app)
    capture("needs-you")

    // The host list, captured after the session so it shows a connected host and its badge.
    //
    // Not in the split view. The list is the sidebar there and is already in the session
    // shot, so this shot would be that one again, pixel for pixel. The iPad has no `hosts`.
    if !showsTheHostListBesideTheHost(app) {
      returnToHostList(app)
      settle(app)
      capture("hosts")
      returnToTheHost(app)
    }

    // The chat, with the composer under it and no keyboard. Through the session tree, because
    // the Needs-you row opens the chat with the composer focused, and the keyboard then
    // covers half of the conversation. Named, not by position, because store art of the
    // wrong pane would ship.
    treePaneRow(app, titled: "needs a decision").tap()
    require(app, "composer.text", "Expected the composer")
    settle(app)
    XCTAssertFalse(
      app.keyboards.firstMatch.exists,
      "The chat shot would ship with the keyboard over the conversation. Tree was:\n"
        + app.debugDescription
    )
    capture("chat")
    captureThePaneSwitcher(app)
    leavePaneScene(app, "Expected a way out of the pane screen")

    // The terminal, attached to the same pane, named for the same reason. The keyboard
    // stays up, because the key row above it is in the listing's copy. An agent pane
    // opens on its chat, so the tour asks for the terminal.
    waitForBothBlockedPanes(app)
    blockedPaneRow(app, titled: "needs a decision").tap()
    require(app, "pane.surface.terminal", "Expected the Terminal segment").tap()
    require(app, "terminal.view", "Expected the terminal")
    settle(app)
    // The key row is in the listing's copy, and it can be in the tree without being in the
    // picture. See `assertDrawn`.
    assertDrawn(
      require(app, "terminal.key.esc", "Expected the terminal's key row"),
      "The terminal capture would ship without the key row."
    )
    // The software keyboard too, by one of its letter keys on screen. A simulator can report
    // a hardware keyboard, and then the phone keeps the keys in the tree below the screen's
    // bottom edge and draws a banner in their place, and the iPad has no keys at all. A
    // `Keyboard` element is in the iPad's tree either way.
    let letter = app.keyboards.keys["a"]
    XCTAssertTrue(
      letter.waitForExistence(timeout: 10) && letter.isHittable
        && !element(app, "terminal.keyboard.hardwareNotice").exists,
      "The terminal capture would ship without the software keyboard. Is the simulator "
        + "reporting a hardware keyboard? Tree was:\n\(app.debugDescription)"
    )
    capture("terminal")

    // The pane's controls, open, over the terminal with the keyboard down, so the menu is
    // not drawn over the keys.
    require(app, "terminal.key.dismiss", "Expected the key row's keyboard key").tap()
    requireKeyboardGone(app)
    require(app, "pane.actions", "Expected the pane actions menu").tap()
    require(app, "pane.rename", "Expected the menu to be open")
    settle(app)
    capture("pane-actions")
    // Dismiss the menu without choosing anything, and leave the terminal tidy.
    app.tap()
    leavePaneScene(app, "Expected a way out of the terminal")

    // Settings, last, because it changes the theme, and the theme tints every screen after
    // it. Settings live in memory under `-uiTesting`, so the next launch starts on System
    // again. From the host list, with workbox connected, so the list behind the sheet agrees
    // with the shots before it. Through a retry, because this tap sometimes fails to open the
    // sheet, and a failed tour costs a full slow re-run.
    let isSplitView = showsTheHostListBesideTheHost(app)
    if !isSplitView { returnToHostList(app) }
    tapUntil(
      app,
      opening: "hosts.overflow",
      tap: "settings.open",
      opens: "settings.preview",
      "settings"
    )
    // Scrolled down to Font Size, which the caption names, so the shot holds the lower theme
    // rows, the fonts and the size. Dracula, because its row is on screen there and its
    // purple accent shows the choice took effect.
    //
    // The iPad's form sheet is short, so there the chosen theme is scrolled to the top
    // instead, its row edge against the bar. Font Size still fits under it.
    let form = app.collectionViews.containing(.any, identifier: "settings.theme.system").firstMatch
    // Read now, because the System row that finds the form scrolls out of the tree.
    let sheetBottom = form.frame.maxY
    scroll(form, toRest: "settings.fontsize.value", in: app)
    if isSplitView {
      align("settings.theme.dracula", under: app.navigationBars["Settings"], in: app)
      let size = require(app, "settings.fontsize.value", "Expected the Font Size row")
      XCTAssertTrue(
        size.isHittable && size.frame.maxY <= sheetBottom,
        "Font Size is below the sheet with Dracula at the top. Tree was:\n"
          + app.debugDescription
      )
    }
    let dracula = require(app, "settings.theme.dracula", "Expected the Dracula theme row")
    XCTAssertTrue(
      dracula.isHittable,
      "The Dracula row is not on screen, so the shot would not show a chosen theme. Tree was:\n"
        + app.debugDescription
    )
    dracula.tap()
    settle(app)
    capture("settings")
    require(app, "settings.done", "Expected a way out of settings").tap()
  }
}
