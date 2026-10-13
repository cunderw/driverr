/// A monospace face the terminal can be drawn in.
///
/// A bundled set, not a font picker. Every face ships in the app or with iOS, so nothing
/// renders as fallback glyphs.
///
/// The default is JetBrains Mono NL Nerd Font Mono, bundled in four styles under OFL 1.1 in
/// `Driverr/Fonts` and registered through `UIAppFonts`. It has the Nerd Font icons prompts
/// draw in the private use area. The Mono variant, because the plain one's icons are
/// double-width. All four styles ship, because renderers pick bold and italic by trait and a
/// missing style draws as Regular.
public struct TerminalFont: Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  /// The PostScript name for `UIFont(name:size:)`, or `nil` for the system's SF Mono, which
  /// has no stable name and must come from `monospacedSystemFont`.
  public let systemFontName: String?

  public init(id: String, name: String, systemFontName: String?) {
    self.id = id
    self.name = name
    self.systemFontName = systemFontName
  }

  /// The whole bundled set. A new face has to argue its case.
  public static let bundled: [TerminalFont] = [.jetbrainsMono, .system, .menlo, .courier]

  public static let `default`: TerminalFont = .jetbrainsMono

  public static func bundled(id: String) -> TerminalFont {
    bundled.first { $0.id == id } ?? .default
  }

  public static let jetbrainsMono = TerminalFont(
    id: "jetbrains-mono",
    name: "JetBrains Mono",
    systemFontName: "JetBrainsMonoNLNFM-Regular"
  )
  /// Stored as `system-mono`, not `system`. `system` was once the default and cannot tell a
  /// deliberate pick from an install that never chose, so a stored `system` falls through
  /// `bundled(id:)` to the current default.
  public static let system = TerminalFont(
    id: "system-mono",
    name: "System Mono",
    systemFontName: nil
  )
  public static let menlo = TerminalFont(id: "menlo", name: "Menlo", systemFontName: "Menlo")
  public static let courier = TerminalFont(
    id: "courier",
    name: "Courier",
    systemFontName: "Courier"
  )
}
