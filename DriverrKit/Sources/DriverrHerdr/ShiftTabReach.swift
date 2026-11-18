import DriverrCore

/// The first herdr that keeps Shift on `pane send-keys … shift+tab`: 0.8.2, protocol 20.
/// herdr's changelog for 0.8.2 says so, and older herdr sends a plain Tab.
enum ShiftTabFloor {
  static let protocolVersion = 20
  static let version = [0, 8, 2]

  /// Whether `version` is 0.8.2 or newer. The leading digits of each dot-separated part are
  /// compared, so `0.9.5-dev` reads as 0.9.5. Anything with no number first is `false`.
  /// `TmuxID.prefix`, spelled here because this module cannot import DriverrTmux. tmux names
  /// the key `BTab` and writes `CSI Z`, whatever herdr runs beside it.
  static let tmuxPanePrefix = "tmux:"

  static func isReached(byVersion version: String) -> Bool {
    var parts: [Int] = []
    for part in version.split(separator: ".") {
      guard let number = Int(part.prefix(while: \.isNumber)) else { break }
      parts.append(number)
    }
    guard !parts.isEmpty else { return false }
    while parts.count < Self.version.count { parts.append(0) }
    return parts.lexicographicallyPrecedes(Self.version) == false
  }
}

extension HerdrAvailability {
  /// Whether Shift-Tab reaches pane `paneID` as Shift-Tab, not as a plain Tab.
  ///
  /// A core pane always gets it: a viewer writes `CSI Z` itself, whatever the TUI beside it.
  /// So does a tmux pane. A TUI pane needs protocol 20. `.combined` carries the TUI's version and no protocol
  /// number, so there the version decides.
  public func deliversShiftTab(toPane paneID: String) -> Bool {
    if CorePaneID.isCore(paneID) || paneID.hasPrefix(ShiftTabFloor.tmuxPanePrefix) {
      return true
    }
    switch self {
    case .ready(_, let protocolVersion), .readyWithCoreRefused(_, let protocolVersion, _, _, _):
      return protocolVersion >= ShiftTabFloor.protocolVersion
    case .combined(let herdrVersion, _):
      return ShiftTabFloor.isReached(byVersion: herdrVersion)
    case .coreReady, .serverNotRunning, .notInstalled, .tooOld, .statusUnreadable,
      .coreIncompatible:
      return false
    }
  }
}
