import Foundation

/// Which of a pane's two surfaces is being looked at.
///
/// Only a pane with an agent has two. A shell opens straight into the terminal.
///
/// `String` raw values, because `TerminalSettings.panesOpenOn` stores one. A rename changes
/// what an old blob decodes to.
public enum PaneSurface: String, Hashable, Sendable, Codable, CaseIterable {
  case chat
  case terminal

  /// The other one, which ⌘⇧T switches to. A `switch`, so a third surface fails to compile
  /// here instead of making inline ternaries wrong.
  public var toggled: PaneSurface {
    switch self {
    case .chat: .terminal
    case .terminal: .chat
    }
  }

  /// The surface a pane shows when it opens: the first-open rule.
  ///
  /// A pane with no chat surface always opens on the terminal. Otherwise the surface the
  /// pane was last left on wins, and a pane never switched opens where the setting says.
  /// Memory is state and outranks the setting, so a pane switched by hand keeps its choice
  /// when the setting changes.
  public static func opening(
    hasChatSurface: Bool,
    remembered: PaneSurface?,
    setting: PaneSurface
  ) -> PaneSurface {
    guard hasChatSurface else { return .terminal }
    return remembered ?? setting
  }
}

/// Everything the "Open Panes In" setting says. Here, as `TmuxResizeCopy` is, so `swift test`
/// covers it.
public enum PanesOpenOnCopy {
  public static let header = "Open Panes In"

  public static func title(for surface: PaneSurface) -> String {
    switch surface {
    case .chat: "Chat"
    case .terminal: "Terminal"
    }
  }

  public static let footer =
    "A pane you change between chat and terminal opens where you left it. A pane without "
    + "an agent always opens in the terminal."
}
