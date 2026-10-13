import Foundation
import UIKit
import XCTest

/// The key screen is reachable and shows what it stored. Generation, parsing and Keychain
/// behaviour are `DriverrKit` and `DriverrTests`.
///
/// Relaunches per test: tests generate keys and add hosts.
@MainActor
final class KeyManagementUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  /// `-uiTesting` swaps the Keychain for an in-memory store, so each run starts empty.
  private func launchApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-uiTesting"]
    app.launch()
    return app
  }

  /// Matches on identifier across every element type, because a `NavigationLink` in a
  /// `List` may surface as a button or a cell.
  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

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

  /// Opens Keys from the host list's overflow menu.
  private func openKeyScreen(_ app: XCUIApplication) {
    openHostsOverflow(app)
    require(app, "keys.open", "Expected a way into key management").tap()
  }

  /// Generate lives behind the toolbar's add menu, so the menu has to be opened first.
  private func generateKey(_ app: XCUIApplication) {
    require(app, "keys.add", "Expected an add-key menu").tap()
    require(app, "keys.generate", "Expected a generate action inside the add menu").tap()
  }

  /// A throwaway passphrase-protected Ed25519 key. It was generated for this test with
  /// `ssh-keygen -t ed25519 -N "revacate lifesome repack broider"`, was never installed on any
  /// host, and is a literal because `Process` does not exist on iOS.
  private static let passphraseProtectedKeyPEM = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABC9AGhnbM
    FtUE6SrlRyj9RJAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIN4gGXPdUiCpua1x
    Vme4FHocQWpyr+RXPtaGmvAU7ZkDAAAAkO6IuHtdNaxj78dXRF0aj+pI+7SFVo7zrMQwL/
    sw9ncXn3VyAdIbw1H5rYayWaeBsf8WYrQhuD7czPy+GUTrch+DBBBo6x+KKuiJX1yodVDR
    zcW+r1aWa/RHoDyevbVu2HSr+IbqR+vDfdWgVBvaC0OrOJehAIB3kXsgKITlPUbgE/bYcm
    XB1ghn2yavDZUAhw==
    -----END OPENSSH PRIVATE KEY-----
    """

  func testGeneratingAKeyAddsItToTheList() {
    let app = launchApp()
    openKeyScreen(app)
    generateKey(app)

    _ = require(app, "keys.row", "Expected the generated key to appear in the list")
    XCTAssertFalse(element(app, "keys.empty").exists, "Empty state should be gone")
  }

  func testAGeneratedKeyShowsACopyablePublicKey() {
    let app = launchApp()
    openKeyScreen(app)
    generateKey(app)

    require(app, "keys.row", "Expected the generated key in the list").tap()

    let publicKey = require(
      app,
      "keys.publicKey",
      "Expected the public key to be shown so it can go in authorized_keys"
    )
    XCTAssertTrue(
      publicKey.label.hasPrefix("ssh-ed25519 "),
      "Expected an authorized_keys line, got: \(publicKey.label)"
    )
    XCTAssertTrue(element(app, "keys.copy").exists, "Expected a copy button")
    XCTAssertTrue(element(app, "keys.share").exists, "Expected a share button beside Copy")
  }

  /// Copy says it worked.
  func testCopyingThePublicKeyShowsATransientConfirmation() {
    let app = launchApp()
    openKeyScreen(app)
    generateKey(app)
    require(app, "keys.row", "Expected the generated key in the list").tap()

    let copy = require(app, "keys.copy", "Expected a copy button")
    XCTAssertEqual(copy.label, "Copy")
    copy.tap()

    let copied = NSPredicate(format: "label == %@", "Copied")
    expectation(for: copied, evaluatedWith: copy)
    waitForExpectations(timeout: 5)
  }

  /// A pushed detail inside the sheet can leave the whole sheet, not only go back to the
  /// list.
  func testDoneOnThePushedKeyDetailLeavesTheWholeSheet() {
    let app = launchApp()
    openKeyScreen(app)
    generateKey(app)
    require(app, "keys.row", "Expected the generated key in the list").tap()

    require(app, "keys.detailDone", "Expected a Done button on the pushed key detail").tap()

    XCTAssertFalse(
      element(app, "keys.publicKey").waitForExistence(timeout: 3),
      "Expected Done to leave the Keys sheet entirely, not just pop back to the list."
        + "\nTree was:\n\(app.debugDescription)"
    )
  }

  func testDeletingAKeyReturnsToTheEmptyState() {
    let app = launchApp()
    openKeyScreen(app)
    generateKey(app)

    require(app, "keys.row", "Expected the generated key in the list").swipeLeft()
    require(app, "keys.delete", "Expected a delete action after swiping").tap()
    require(app, "keys.deleteConfirm", "Expected a confirmation before deleting").tap()

    _ = require(app, "keys.empty", "Expected the empty state back after deleting the only key")
  }

  /// The import sheet states the accepted format before anyone can fail at it.
  func testTheImportSheetStatesTheSupportedFormatBeforeAnyFailure() {
    let app = launchApp()
    openKeyScreen(app)

    require(app, "keys.add", "Expected an add-key menu").tap()
    require(app, "keys.import", "Expected an import action").tap()

    _ = require(
      app,
      "keys.importFormatHint",
      "Expected the supported key format to be stated up front, before any import is attempted"
    )
  }

  /// Opening the import sheet does not read the pasteboard, which would raise the system
  /// paste-permission banner before the user sees the sheet.
  ///
  /// Only the sheet opening empty is checked. The test process's pasteboard content is
  /// foreign to the app, and the simulator's permission answer cannot be driven reliably.
  func testTheImportSheetDoesNotReadThePasteboardUntilPasteIsTapped() {
    UIPasteboard.general.string = "should not appear until Paste is tapped"

    let app = launchApp()
    openKeyScreen(app)
    require(app, "keys.add", "Expected an add-key menu").tap()
    require(app, "keys.import", "Expected an import action").tap()

    let field = require(app, "keys.importField", "Expected the import text field")
    XCTAssertTrue(
      (field.value as? String ?? "").isEmpty,
      "Expected the import sheet to open empty rather than pre-filled from the pasteboard, "
        + "got: \(String(describing: field.value))"
    )
    _ = require(app, "keys.importPaste", "Expected a Paste button inside the sheet")
  }

  /// A refused import shows its error even while the key list is empty. An alert attached
  /// only to the non-empty list would show nothing.
  ///
  /// Typed rather than pasted, to avoid the pasteboard permission. `onImport(pem)` reads
  /// the bound `TextEditor` either way.
  func testImportingAPassphraseProtectedKeyOnAnEmptyListShowsTheError() {
    let app = launchApp()
    openKeyScreen(app)
    _ = require(app, "keys.empty", "Expected to start from the empty key list")

    require(app, "keys.add", "Expected an add-key menu").tap()
    require(app, "keys.import", "Expected an import action").tap()
    require(app, "keys.importField", "Expected the import text field").tap()
    app.typeText(Self.passphraseProtectedKeyPEM)

    let confirm = require(app, "keys.importConfirm", "Expected an import confirm button")
    waitUntilStill(app, confirm)
    confirm.tap()

    let alert = app.alerts["Key Error"]
    XCTAssertTrue(
      alert.waitForExistence(timeout: 10),
      "Expected the key error alert even though the list is still empty."
        + "\nTree was:\n\(app.debugDescription)"
    )
    XCTAssertTrue(
      alert.staticTexts.element(matching: NSPredicate(format: "label CONTAINS[c] 'passphrase'"))
        .exists,
      "Expected a message naming the passphrase problem.\nTree was:\n\(app.debugDescription)"
    )
    // Nothing was half-imported.
    alert.buttons["OK"].tap()
    _ = require(app, "keys.empty", "Expected the key list to still be empty after the failure")
  }

  /// Deleting a key names the hosts that use it, which would otherwise silently lose their
  /// way to authenticate.
  func testDeletingAKeyInUseByAHostNamesThatHostInTheConfirmation() {
    let app = launchApp()
    openKeyScreen(app)
    generateKey(app)
    require(app, "keys.done", "Expected a way out of the keys sheet").tap()

    require(app, "hosts.add", "Expected an add-host button").tap()
    require(app, "host.name", "Expected a name field").tap()
    app.typeText("keybox")
    require(app, "host.hostname", "Expected a hostname field").tap()
    app.typeText("10.1.0.9")
    require(app, "host.username", "Expected a username field").tap()
    app.typeText("carson")
    setSwitch(app, "host.usesKey", on: true)
    _ = require(app, "host.keyPicker", "Expected a key to already be selected")
    // The form sheet can still be moving. `setSwitch` settles before its own tap, but Save
    // is a separate tap.
    let save = require(app, "host.save", "Expected a save button")
    waitUntilStill(app, save)
    save.tap()

    // Wait for the host to land in the list, because a toolbar tap while the form is still
    // dismissing lands on nothing.
    _ = require(app, "hosts.row", "Expected the saved host in the list")

    openKeyScreen(app)
    require(app, "keys.row", "Expected the key in the list").swipeLeft()
    require(app, "keys.delete", "Expected a delete action after swiping").tap()

    let dialog = app.alerts.firstMatch.exists ? app.alerts.firstMatch : app.sheets.firstMatch
    XCTAssertTrue(
      dialog.waitForExistence(timeout: 10),
      "Expected a confirmation before deleting a key in use.\nTree was:\n\(app.debugDescription)"
    )
    XCTAssertTrue(
      dialog.staticTexts.element(matching: NSPredicate(format: "label CONTAINS 'keybox'")).exists,
      "Expected the confirmation to name the host using this key."
        + "\nTree was:\n\(app.debugDescription)"
    )
  }
}
