/// Every hardware-keyboard shortcut Driverr binds, with the title the system shows for it.
///
/// Driverr has no shortcuts screen, so the system's hold-⌘ overlay and the iPadOS menu bar
/// are the only reference, and both list a command by its title. An untitled binding is a
/// blank row or no row. Kept here so `KeyCommandTests` checks that every binding is titled
/// and no titles or keys collide. `KeyCommand+SwiftUI.swift` maps to SwiftUI's types.
///
/// Titles follow the platform's menu style: title-case verb phrases, with an ellipsis only on
/// Settings, which opens a screen.
public enum KeyCommand: Hashable, Sendable {
  /// ⌘N, on the host list's Add Host button, which has its own visible `Label`. Listed for
  /// the tests.
  case addHost
  /// ⌘, for Settings. Not bound on iPad, where the system's "Driverr Settings…" menu item
  /// takes the key and opens the Settings app. The rule is the device, not the width, so a
  /// large iPhone in landscape keeps it (`KeyCommand.isSettingsBound`). Two sites bind it and
  /// only one is live at a time: `ContentView.settingsShortcut` on the split view with no
  /// pane scene, and `TerminalScreen.keyCommands` over a pane scene.
  case settings
  /// ⌘1 … ⌘9: the switcher's places, one-based. See `PaneStripModel.target(atShortcutIndex:)`.
  case goToPlace(Int)
  /// ⌘⇧]: the next place, wrapping.
  case nextPane
  /// ⌘⇧[: the previous place, wrapping.
  case previousPane
  /// ⌘⇧T while the chat is showing.
  case showTerminal
  /// ⌘⇧T while the terminal is showing.
  case showChat
  /// ⌘W: leaves the pane scene. The pane keeps running on the host, so the title is not
  /// "Close".
  case leavePane
  /// ⌘W while the pane switcher is up over the scene: closes the switcher.
  case closeSwitcher
  /// ⌘W while the scene's Settings sheet is up: closes it.
  case closeSettings
  /// ⌘W while the Photos picker is up: closes it.
  case closePhotos
  /// ⌘W on the host screen with no pane scene: back to the host list. The connection stays
  /// up, hence "Leave". See `commandWWithoutAScene(hasSelectedHost:)`.
  case leaveHost
  /// ⌘W with no pane scene and no host selected: does nothing, so the key never reaches
  /// iPadOS.
  case close
  /// Escape: closes whatever the scene has open over it. Bound only when something is open;
  /// see `TerminalScreen.escapeAction`.
  case dismiss
  /// ⌘↩ in the composer. Titled `PaneComposerCopy.send`, the string VoiceOver reads for the
  /// image button.
  case send

  /// The key, apart from its modifiers.
  public enum Key: Hashable, Sendable {
    case character(Character)
    case escape
    case `return`
  }

  /// The modifiers held with `key`. Only the two Driverr uses.
  public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = Modifiers(rawValue: 1 << 0)
    public static let shift = Modifiers(rawValue: 1 << 1)
  }

  /// Every command, in the order a reader would want to meet them.
  public static let all: [KeyCommand] =
    [.addHost, .settings]
    + (1...9).map { KeyCommand.goToPlace($0) }
    + [.nextPane, .previousPane, .showTerminal, .showChat]
    + [.leavePane, .closeSwitcher, .closeSettings, .closePhotos, .leaveHost, .close]
    + [.dismiss, .send]

  /// What the system lists for this command.
  public var title: String {
    switch self {
    case .addHost: "Add Host"
    case .settings: "Settings…"
    case .goToPlace(let index): "Go to Pane \(index)"
    case .nextPane: "Show Next Pane"
    case .previousPane: "Show Previous Pane"
    case .showTerminal: "Show Terminal"
    case .showChat: "Show Chat"
    case .leavePane: "Leave Pane"
    case .closeSwitcher: "Close Switcher"
    case .closeSettings: "Close Settings"
    case .closePhotos: "Close Photos"
    case .leaveHost: "Leave Host"
    case .close: "Close"
    case .dismiss: "Dismiss"
    case .send: PaneComposerCopy.send
    }
  }

  public var key: Key {
    switch self {
    case .addHost: .character("n")
    case .settings: .character(",")
    case .goToPlace(let index): .character(Character("\(index)"))
    case .nextPane: .character("]")
    case .previousPane: .character("[")
    case .showTerminal, .showChat: .character("t")
    case .leavePane, .closeSwitcher, .closeSettings, .closePhotos, .leaveHost, .close:
      .character("w")
    case .dismiss: .escape
    case .send: .return
    }
  }

  public var modifiers: Modifiers {
    switch self {
    case .nextPane, .previousPane, .showTerminal, .showChat: [.command, .shift]
    case .dismiss: []
    default: .command
    }
  }

  /// Commands that share one key on purpose, because exactly one of each group is bound at
  /// a time.
  ///
  /// ⌘⇧T is one key whose title follows the surface it will show. ⌘W closes whatever the
  /// scene has up over itself, and leaves the pane only when there is nothing up; see
  /// `commandW(isShowingPaneSheet:isShowingSettings:isShowingPhotoPicker:)`.
  public static let exclusiveGroups: [Set<KeyCommand>] = [
    [.showTerminal, .showChat],
    [.leavePane, .closeSwitcher, .closeSettings, .closePhotos, .leaveHost, .close],
  ]

  /// What ⌘W does in a pane scene right now: the frontmost thing closes, and the pane is left
  /// only when nothing is over it.
  ///
  /// The Pane menu sees the scene through a scene-wide `focusedSceneValue`, so without this
  /// ⌘W left the pane from behind an open sheet. Never disable the item instead: with no
  /// enabled ⌘W command, iPadOS closes the app's window. The order matches
  /// `TerminalScreen.escapeAction`.
  public static func commandW(
    isShowingPaneSheet: Bool,
    isShowingSettings: Bool,
    isShowingPhotoPicker: Bool
  ) -> KeyCommand {
    if isShowingPaneSheet { return .closeSwitcher }
    if isShowingSettings { return .closeSettings }
    if isShowingPhotoPicker { return .closePhotos }
    return .leavePane
  }

  /// What ⌘W does with no pane scene up: leave the host screen when a host is selected,
  /// otherwise Close, which does nothing. Enabled either way, because a disabled or missing
  /// ⌘W item lets iPadOS close the app's only window
  /// (`testCommandWLeavesTheHostScreenAndKeepsTheWindow`).
  public static func commandWWithoutAScene(hasSelectedHost: Bool) -> KeyCommand {
    hasSelectedHost ? .leaveHost : .close
  }
}
