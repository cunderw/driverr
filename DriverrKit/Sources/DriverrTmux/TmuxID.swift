import Foundation

/// How a tmux pane, window or session is named inside Driverr.
///
/// tmux's own ids are `%3`, `@2` and `$1`: unique on one server, and reset when the server
/// restarts. Driverr prefixes them with `tmux:` so a host that shows tmux beside herdr can route
/// a call by the prefix, as `CorePaneID` does for a core. The sigil stays, so the kind of
/// thing is readable from the id alone.
public enum TmuxID {
  public static let prefix = "tmux:"

  /// What an id names. The raw value is tmux's sigil.
  public enum Kind: Character, Sendable {
    case pane = "%"
    case window = "@"
    case session = "$"
  }

  public static func pane(_ raw: String) -> String { prefix + raw }
  public static func window(_ raw: String) -> String { prefix + raw }
  public static func session(_ raw: String) -> String { prefix + raw }

  public static func isTmux(_ id: String) -> Bool {
    id.hasPrefix(prefix)
  }

  /// tmux's own id inside `id`, or `nil` when `id` is not one of Driverr's tmux ids.
  ///
  /// Only a sigil and digits pass. Everything this module puts into a command comes from here,
  /// so an id that arrives from anywhere else cannot carry a flag or a command with it.
  public static func raw(of id: String) -> String? {
    guard isTmux(id) else { return nil }
    let raw = id.dropFirst(prefix.count)
    guard let sigil = raw.first, Kind(rawValue: sigil) != nil else { return nil }
    let digits = raw.dropFirst()
    guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    return String(raw)
  }

  public static func kind(of id: String) -> Kind? {
    raw(of: id)?.first.flatMap(Kind.init(rawValue:))
  }

  /// The raw id when `id` is a tmux pane, and `nil` for a window, a session or anything else.
  public static func rawPane(of id: String) -> String? {
    kind(of: id) == .pane ? raw(of: id) : nil
  }

  /// A raw id as tmux prints it, `%3`, for a pane. `nil` for a malformed one, so a line tmux
  /// printed that this build cannot read is skipped, not trusted.
  static func validRaw(_ raw: String, kind: Kind) -> String? {
    guard raw.first == kind.rawValue else { return nil }
    let digits = raw.dropFirst()
    guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    return raw
  }
}
