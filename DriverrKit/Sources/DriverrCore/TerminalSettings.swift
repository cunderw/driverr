import Foundation

/// The complete set of global settings: theme, font, font size, whether the captured screen
/// wraps, and whether Driverr draws Live Activities.
///
/// The list is closed. A new setting has to argue its case (see `CLAUDE.md`), and this type
/// has nowhere to put one without changing it on purpose.
///
/// The theme is stored by id, so a build that changes or drops a theme still decodes an old
/// blob. An unknown id resolves to the default.
public struct TerminalSettings: Hashable, Sendable, Codable {
  public var themeID: String
  public var fontID: String
  public var fontSize: Double
  /// Whether the captured screen wraps long lines rather than letting them run off the edge.
  /// See `screenLayout`.
  public var wrapsScreenLines: Bool
  /// Whether Driverr may draw a Live Activity at all. Off ends any card showing and requests
  /// none; the rule is the first one in `BlockedPaneActivityPlan.reconcile`.
  public var liveActivities: Bool

  /// Small enough to fit a wide terminal on a phone, large enough to read. Enforced here
  /// rather than left to a stepper.
  public static let fontSizeRange: ClosedRange<Double> = 8...24
  public static let defaultFontSize: Double = 13

  public init(
    themeID: String = Theme.default.id,
    fontID: String = TerminalFont.default.id,
    fontSize: Double = TerminalSettings.defaultFontSize,
    wrapsScreenLines: Bool = true,
    liveActivities: Bool = true
  ) {
    self.themeID = themeID
    self.fontID = fontID
    self.fontSize = Self.clamp(fontSize)
    self.wrapsScreenLines = wrapsScreenLines
    self.liveActivities = liveActivities
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Each field falls back on its own, so a missing or corrupt field costs only that
    // setting.
    let theme = try container.decodeIfPresent(String.self, forKey: .themeID)
    let font = try container.decodeIfPresent(String.self, forKey: .fontID)
    let size = try container.decodeIfPresent(Double.self, forKey: .fontSize)
    // `?? true`: blobs written before this key existed are drawing wrapped lines.
    let wraps = try container.decodeIfPresent(Bool.self, forKey: .wrapsScreenLines)
    // `?? true`: blobs written before this key existed draw Live Activities.
    let activities = try container.decodeIfPresent(Bool.self, forKey: .liveActivities)
    self.init(
      themeID: theme ?? Theme.default.id,
      // The resolved id, so an id this build no longer ships shows the face it draws as
      // selected.
      fontID: TerminalFont.bundled(id: font ?? TerminalFont.default.id).id,
      fontSize: size ?? Self.defaultFontSize,
      wrapsScreenLines: wraps ?? true,
      liveActivities: activities ?? true
    )
  }

  public static let `default` = TerminalSettings()

  /// The resolved theme, falling back on an id this build no longer ships.
  public var theme: Theme { Theme.bundled(id: themeID) }
  public var font: TerminalFont { TerminalFont.bundled(id: fontID) }

  /// How the captured screen lays out its lines. Here so `swift test` asserts the mapping.
  public var screenLayout: PaneScreenLayout { wrapsScreenLines ? .wrapped : .clipped }

  public mutating func setFontSize(_ size: Double) {
    fontSize = Self.clamp(size)
  }

  /// One step is one point, because terminal size is a whole number of columns.
  public mutating func growFont() { setFontSize(fontSize + 1) }
  public mutating func shrinkFont() { setFontSize(fontSize - 1) }

  public var canGrowFont: Bool { fontSize < Self.fontSizeRange.upperBound }
  public var canShrinkFont: Bool { fontSize > Self.fontSizeRange.lowerBound }

  private static func clamp(_ size: Double) -> Double {
    guard size.isFinite else { return defaultFontSize }
    return min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound)
  }
}

/// Where the global settings live. Async like `HostStore` even though `UserDefaults` is
/// synchronous, so a test store can replace it and a move to other persistence needs no
/// protocol change.
public protocol SettingsStore: Sendable {
  func settings() async -> TerminalSettings
  func save(_ settings: TerminalSettings) async
}

#if DEBUG
/// A non-persistent `SettingsStore` for previews, UI tests, and demo mode.
public actor InMemorySettingsStore: SettingsStore {
  private var current: TerminalSettings

  public init(_ initial: TerminalSettings = .default) {
    current = initial
  }

  public func settings() async -> TerminalSettings { current }
  public func save(_ settings: TerminalSettings) async { current = settings }
}
#endif
