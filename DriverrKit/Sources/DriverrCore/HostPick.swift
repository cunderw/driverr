import Foundation

/// Whether the selected host was chosen by the user's own tap, rather than by a route.
///
/// The hook offer follows only a connect the user started. A row tap connects on the host
/// screen's appearance, but so does a restored last host, a Live Activity, a notification or
/// a URL. Only a row tap is recorded.
///
/// The app records a pick from the two setters SwiftUI calls on a tap (the sidebar's `List`
/// selection and the phone stack's path) and reports every selection change. A change to a
/// host the user did not pick clears it.
public struct HostPick: Hashable, Sendable {
  public private(set) var pickedByUser: UUID?

  public init() {}

  /// The user tapped this row. Record it before the selection itself changes.
  public mutating func userPicked(_ hostID: UUID?) {
    pickedByUser = hostID
  }

  /// The selection is now `hostID`, by whatever route.
  public mutating func selectionChanged(to hostID: UUID?) {
    if hostID != pickedByUser { pickedByUser = nil }
  }

  /// Whether this host's connect-on-appearance was the user's doing, and so may offer.
  public func offersHooksOnConnect(for hostID: UUID) -> Bool {
    pickedByUser == hostID
  }
}
