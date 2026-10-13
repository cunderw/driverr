import DriverrCore
import SwiftUI
import UIKit

/// `DriverrCore.KeyCommand` in SwiftUI's own types.
///
/// The catalogue is in `DriverrCore` so `swift test` can check its titles.
extension KeyCommand {
  /// Whether this device binds `KeyCommand.settings`: every device except an iPad. See
  /// `KeyCommand.settings` for why. `ContentView.settingsShortcut` and
  /// `TerminalScreen.keyCommands` both read this.
  @MainActor static var isSettingsBound: Bool {
    UIDevice.current.userInterfaceIdiom != .pad
  }

  var shortcut: KeyboardShortcut {
    KeyboardShortcut(keyEquivalent, modifiers: eventModifiers)
  }

  private var keyEquivalent: KeyEquivalent {
    switch key {
    case .character(let character): KeyEquivalent(character)
    case .escape: .escape
    case .return: .return
    }
  }

  private var eventModifiers: EventModifiers {
    var result: EventModifiers = []
    if modifiers.contains(.command) { result.insert(.command) }
    if modifiers.contains(.shift) { result.insert(.shift) }
    return result
  }
}
