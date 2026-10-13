import DriverrCore
import SwiftUI

/// What the Pane menu acts on, published by the pane scene on screen.
///
/// `TerminalScreen` publishes it through `focusedSceneValue`. It is `nil` with no scene up,
/// and every item is then disabled except ⌘W, which `RootKeyActions` holds.
///
/// The value is scene-wide, so it is still published while the scene presents the pane
/// sheet, Settings or the Photos picker. The pane's keys are then disabled, and ⌘W closes the
/// presentation (`KeyCommand.commandW`). ⌘W is never disabled: a disabled ⌘W lets iPadOS
/// close the app's window.
struct PaneKeyActions {
  let goToPlace: (Int) -> Void
  let nextPane: () -> Void
  let previousPane: () -> Void
  /// `.showTerminal` or `.showChat`, whichever ⌘⇧T does now, or `nil` when the pane has
  /// one surface.
  let surfaceCommand: KeyCommand?
  let toggleSurface: () -> Void
  /// Whether the scene has a sheet or the Photos picker up over itself.
  let isPresenting: Bool
  /// Whether `ContentView` has a sheet or alert up at the root, over the scene. Every item but
  /// ⌘W is disabled then, and ⌘W does nothing, because the trust sheet holds a decision a key
  /// must not make. ⌘W is a no-op, not disabled, because a disabled item lets iPadOS close
  /// the window (`testPaneKeysDoNothingBehindARootSheet`).
  let isBehindRootPresentation: Bool
  /// What ⌘W does now: `.leavePane`, or the close command for what is up.
  let commandW: KeyCommand
  let performCommandW: () -> Void
}

/// What ⌘W acts on with no pane scene up, published by `ContentView`.
///
/// The item stays enabled, or iPadOS closes the app's window. "Leave Host" goes back to the
/// host list, and with no host selected "Close" does nothing. See
/// `KeyCommand.commandWWithoutAScene(hasSelectedHost:)`.
struct RootKeyActions {
  let hasSelectedHost: Bool
  /// Whether `ContentView` has a sheet or alert up. ⌘W is then an enabled no-op, as it is
  /// over a pane; see `PaneKeyActions.isBehindRootPresentation`. The host screen's own
  /// alert is `isHostScreenPresenting`, published by `HostDetailView`.
  let isPresenting: Bool
  let leaveHost: () -> Void
}

extension FocusedValues {
  @Entry var paneKeyActions: PaneKeyActions?
  @Entry var rootKeyActions: RootKeyActions?
  /// Whether `HostDetailView` has its Forget Host Key alert up, so ⌘W does not leave the host
  /// behind it. Published by the screen, which owns the alert's state.
  @Entry var isHostScreenPresenting: Bool?
}

/// The Pane menu: the scene's keys, titled, in the iPadOS menu bar.
///
/// Only `.commands` reaches the menu bar. Each button here is also the key command for its
/// key, so the scene has no hidden duplicates; two identical key commands have no rule for
/// which wins.
///
/// Two keys stay as hidden buttons in `TerminalScreen.keyCommands`:
/// - ⌘, is bound on every device except an iPad (see `KeyCommand.settings`). An iPhone has
///   no menu bar, and `CommandGroup(replacing: .appSettings)` did not deliver the key under
///   XCUITest on the phone.
/// - Escape is bound only while something is open over the scene, so the terminal keeps it
///   otherwise. It is not documented whether a disabled menu item lets a key through.
///
/// ⌘W is in this menu, not File > Close, where iPadOS puts Close Window. Test against that
/// item before moving it.
struct PaneCommands: Commands {
  @FocusedValue(\.paneKeyActions) private var actions
  @FocusedValue(\.rootKeyActions) private var rootActions
  @FocusedValue(\.isHostScreenPresenting) private var isHostScreenPresenting

  var body: some Commands {
    CommandMenu("Pane") {
      item(.previousPane) { $0.previousPane() }
      item(.nextPane) { $0.nextPane() }
      // The title follows the surface the key will show. With one surface there is nothing
      // to switch to, so the item keeps the Show Terminal title and is disabled.
      item(actions?.surfaceCommand ?? .showTerminal, enabled: actions?.surfaceCommand != nil) {
        $0.toggleSurface()
      }
      Divider()
      ForEach(1...9, id: \.self) { index in
        item(.goToPlace(index)) { $0.goToPlace(index) }
      }
      Divider()
      // Enabled over a presentation too: it closes what the scene has up, and does nothing
      // behind a root presentation. With no scene up it is Leave Host or Close. See
      // `PaneKeyActions` and `RootKeyActions`.
      Button((actions?.commandW ?? rootCommandW ?? .leavePane).title) {
        if let actions {
          guard !actions.isBehindRootPresentation else { return }
          actions.performCommandW()
        } else if let rootActions, rootCommandW == .leaveHost {
          guard !rootActions.isPresenting, isHostScreenPresenting != true else { return }
          rootActions.leaveHost()
        }
      }
      .keyboardShortcut(KeyCommand.leavePane.shortcut)
      .disabled(actions == nil && rootCommandW == nil)
    }
  }

  /// ⌘W with no pane scene up: Leave Host, or Close with no host selected. `nil` only
  /// before `ContentView` has published anything.
  private var rootCommandW: KeyCommand? {
    guard let rootActions else { return nil }
    return KeyCommand.commandWWithoutAScene(hasSelectedHost: rootActions.hasSelectedHost)
  }

  private func item(
    _ command: KeyCommand,
    enabled: Bool = true,
    perform: @escaping (PaneKeyActions) -> Void
  ) -> some View {
    Button(command.title) {
      if let actions { perform(actions) }
    }
    .keyboardShortcut(command.shortcut)
    .disabled(!isLive(enabled: enabled))
  }

  private func isLive(enabled: Bool) -> Bool {
    guard let actions, enabled else { return false }
    return !actions.isPresenting && !actions.isBehindRootPresentation
  }
}
