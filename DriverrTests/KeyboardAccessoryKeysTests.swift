import Foundation
import SwiftTerm
import Testing
import UIKit

@testable import DriverrTerm

/// The key row's Ctrl and Tab keys: what armed Ctrl tells UIKit and VoiceOver, and what Tab
/// sends.
///
/// Armed Ctrl must not set the button's `isSelected`. On a `.system` button UIKit then draws
/// its own tinted selection box over the inverted fill, and the label vanished in dark mode.
/// VoiceOver still gets the `.selected` trait and the "on"/"off" value, set by hand.
///
/// Tab sends Tab on a tap. A hold sends back-tab, and so does the "Shift Tab" custom action.
/// The hold itself is in `TerminalKeyboardUITests`, because no in-process API drives a
/// long-press recogniser.
///
/// Hosted, because `DriverrKeyboardAccessory` is a UIKit view and the Kit tier does not build
/// it. The row holds its terminal weakly, so each test keeps the terminal alive itself.
@MainActor
@Suite("DriverrKeyboardAccessory keys")
struct KeyboardAccessoryKeysTests {
  /// Records what the terminal hands its delegate, synchronously.
  private final class RecordingDelegate: TerminalViewDelegate {
    var sent: [[UInt8]] = []

    func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(Array(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
  }

  private static func button(_ identifier: String, in view: UIView) -> UIButton? {
    if let button = view as? UIButton, button.accessibilityIdentifier == identifier {
      return button
    }
    for subview in view.subviews {
      if let found = button(identifier, in: subview) { return found }
    }
    return nil
  }

  @Test("armed Ctrl reads as selected to VoiceOver without setting isSelected, and clears")
  func armedControlIsSelectedForVoiceOverOnly() throws {
    let terminal = TerminalView(frame: .zero)
    let row = DriverrKeyboardAccessory(terminalView: terminal, idiom: .phone)
    let ctrl = try #require(Self.button("terminal.key.ctrl", in: row))

    ctrl.sendActions(for: .touchUpInside)

    #expect(terminal.controlModifier)
    #expect(ctrl.accessibilityTraits.contains(.selected))
    #expect(ctrl.accessibilityValue == "on")
    #expect(!ctrl.isSelected)

    // SwiftTerm clears the modifier after the armed key and posts its reset notification.
    terminal.controlModifier = false

    #expect(!ctrl.accessibilityTraits.contains(.selected))
    #expect(ctrl.accessibilityValue == "off")
    #expect(!ctrl.isSelected)
    withExtendedLifetime((terminal, row)) {}
  }

  @Test("a tap on Tab sends a horizontal tab")
  func tabTapSendsTab() throws {
    let terminal = TerminalView(frame: .zero)
    let delegate = RecordingDelegate()
    terminal.terminalDelegate = delegate
    let row = DriverrKeyboardAccessory(terminalView: terminal, idiom: .phone)
    let tab = try #require(Self.button("terminal.key.tab", in: row))

    tab.sendActions(for: .touchUpInside)

    #expect(delegate.sent == [[0x09]])
    withExtendedLifetime((terminal, row)) {}
  }

  @Test("the Shift Tab custom action sends back-tab, ESC [ Z")
  func shiftTabActionSendsBackTab() throws {
    let terminal = TerminalView(frame: .zero)
    let delegate = RecordingDelegate()
    terminal.terminalDelegate = delegate
    let row = DriverrKeyboardAccessory(terminalView: terminal, idiom: .phone)
    let tab = try #require(Self.button("terminal.key.tab", in: row))
    let action = try #require(tab.accessibilityCustomActions?.first { $0.name == "Shift Tab" })
    let handler = try #require(action.actionHandler)

    #expect(handler(action))

    #expect(delegate.sent == [[0x1B, 0x5B, 0x5A]])
    withExtendedLifetime((terminal, row)) {}
  }
}
