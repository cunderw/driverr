import Foundation

/// The colours the app hands the Live Activity widget across the App Group.
///
/// The widget runs in a separate process with no access to the app's `\.themeAccent`, so the
/// App Group container is the only channel. It carries resolved colours rather than a theme
/// id, so an unknown or dropped theme falls back to the widget's fixed colours instead of
/// silently becoming `Theme.default`. `themeID` rides along for debugging.
///
/// Versioned: `decode(_:)` returns `nil` for any other `version`, so an old widget meeting a
/// newer payload uses its fixed colours. A v2 takes a new `defaultsKey` and a new `version`,
/// leaving the v1 key for widgets not yet updated.
public struct WidgetThemeSnapshot: Codable, Hashable, Sendable {
  /// Bumped whenever the payload's shape changes.
  public static let currentVersion = 1

  /// The App Group both targets' entitlements name. `Driverr/Driverr.entitlements` and
  /// `DriverrWatch/DriverrWatch.entitlements` carry exactly this string; change all three
  /// together.
  public static let appGroupID = "group.com.cunderw.driverr"

  /// The `UserDefaults` key in that group. The `.v1` suffix lets a v2 payload use its own key.
  public static let defaultsKey = "com.cunderw.driverr.widgetTheme.v1"

  /// One appearance's accent and the foreground that reads on it. Always the pair, because a
  /// fixed white on the default accent is only 3.42:1.
  public struct Half: Codable, Hashable, Sendable {
    public let accent: TerminalColor
    public let accentForeground: TerminalColor

    /// The foreground is derived from the accent, so no caller can write a pair that fails
    /// contrast.
    public init(accent: TerminalColor) {
      self.accent = accent
      self.accentForeground = accent.readableForeground
    }
  }

  public let version: Int
  public let themeID: String
  public let light: Half
  public let dark: Half

  /// Both halves, though the card reads only `dark`: the Lock Screen and Dynamic Island draw
  /// on a dark ground in both appearances. The light half lets a future surface use it
  /// without a version bump.
  public init(theme: Theme) {
    version = Self.currentVersion
    themeID = theme.id
    light = Half(accent: theme.accent(for: .light))
    dark = Half(accent: theme.accent(for: .dark))
  }

  public func encoded() -> Data? { try? JSONEncoder().encode(self) }

  /// `nil` for every failure (no container, no key yet, empty or truncated data, unknown
  /// version), because each means the same thing to the widget: draw the fixed colours.
  public static func decode(_ data: Data?) -> WidgetThemeSnapshot? {
    guard let data, !data.isEmpty else { return nil }
    guard let snapshot = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
    guard snapshot.version == currentVersion else { return nil }
    return snapshot
  }
}

/// Where the app publishes the snapshot the widget reads. A protocol so tests can capture
/// what was published without writing to the real shared container.
public protocol WidgetThemeStore: Sendable {
  func publish(_ snapshot: WidgetThemeSnapshot) async
}

#if DEBUG
/// A non-persistent `WidgetThemeStore` for previews and tests.
public actor InMemoryWidgetThemeStore: WidgetThemeStore {
  public private(set) var published: [WidgetThemeSnapshot] = []

  public init() {}

  public func publish(_ snapshot: WidgetThemeSnapshot) async { published.append(snapshot) }
}
#endif
