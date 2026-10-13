import Foundation

/// Whether Driverr may draw its Live Activity, globally and per host.
///
/// Held together because the reconciler needs both. The global answer is a
/// `TerminalSettings` field. The per-host answer is a remembered Start/Stop from the pane menu
/// and host screen, not a setting, and not on the Settings screen.
public struct LiveActivityPreferences: Codable, Hashable, Sendable {
  /// The global toggle, mirrored from `TerminalSettings.liveActivities`. Never persisted
  /// here, so there is no second copy to disagree with the switch.
  public var isEnabled: Bool

  /// The hosts the reader has started or stopped, keyed by `hostID.uuidString`.
  ///
  /// A `String` key, because synthesised `Codable` writes a dictionary with any other key
  /// type as an array of alternating keys and values, which is unreadable in `defaults read`.
  public var hostOverrides: [String: Bool]

  public init(isEnabled: Bool = true, hostOverrides: [String: Bool] = [:]) {
    self.isEnabled = isEnabled
    self.hostOverrides = hostOverrides
  }

  /// Whether this host may appear on the card. The global setting is the default for an
  /// untouched host. A host explicitly stopped stays stopped until started, even across the
  /// global switch going off and on: Stop is about one machine, the switch about the feature.
  public func isOn(for hostID: UUID) -> Bool {
    isEnabled && (hostOverrides[hostID.uuidString] ?? true)
  }

  /// Whether this host's own Start/Stop reads as started, ignoring the global switch. The
  /// buttons title themselves from this, and are hidden while the switch is off.
  public func isStarted(for hostID: UUID) -> Bool {
    hostOverrides[hostID.uuidString] ?? true
  }

  public mutating func set(_ on: Bool, for hostID: UUID) {
    hostOverrides[hostID.uuidString] = on
  }

  /// Drops a deleted host's entry, so the map cannot outlive the hosts it is about.
  public mutating func forget(_ hostID: UUID) {
    hostOverrides.removeValue(forKey: hostID.uuidString)
  }
}

/// Where the per-host overrides are kept. A separate blob from `SettingsStore`'s, so an
/// unreadable one costs Start/Stop decisions and not the theme.
public protocol LiveActivityPreferenceStore: Sendable {
  func hostOverrides() async -> [String: Bool]
  func save(_ hostOverrides: [String: Bool]) async
}

#if DEBUG
/// A non-persistent store for previews and UI runs, so one UI test's Stop cannot reach the
/// next launch.
public actor InMemoryLiveActivityPreferenceStore: LiveActivityPreferenceStore {
  private var current: [String: Bool]

  public init(_ initial: [String: Bool] = [:]) { current = initial }

  public func hostOverrides() async -> [String: Bool] { current }
  public func save(_ hostOverrides: [String: Bool]) async { current = hostOverrides }
}
#endif
