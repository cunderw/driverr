import Foundation
import GameController
import Observation

/// Whether a hardware keyboard is attached, from GameController's `GCKeyboard`.
///
/// The one reader of `GCKeyboard.coalesced`, so call sites cannot disagree.
///
/// `subscribe` is a seam, so a Kit test fires connect and disconnect by hand. In a UI-test
/// launch `GCKeyboard.coalesced` is nil, so a UI test cannot drive either change.
@MainActor
@Observable
public final class HardwareKeyboardMonitor {
  /// Wires the two ends up. Production uses the `GCKeyboardDidConnect` and
  /// `GCKeyboardDidDisconnect` notifications, and a test banks the two closures.
  public typealias Subscription = @MainActor (
    _ onConnect: @escaping @MainActor () -> Void,
    _ onDisconnect: @escaping @MainActor () -> Void
  ) -> Void

  public private(set) var isConnected: Bool

  /// Called after `isConnected` changes. A `var`, because `KeyboardNoticeModel` must
  /// exist before it can capture `self`.
  public var onChange: @MainActor () -> Void = {}

  public init(
    isConnected: Bool = HardwareKeyboardMonitor.isCurrentlyConnected,
    subscribe: Subscription = HardwareKeyboardMonitor.liveSubscription
  ) {
    self.isConnected = isConnected
    subscribe(
      { [weak self] in self?.set(true) },
      { [weak self] in self?.set(false) }
    )
  }

  private func set(_ connected: Bool) {
    guard connected != isConnected else { return }
    isConnected = connected
    onChange()
  }

  nonisolated public static var isCurrentlyConnected: Bool { GCKeyboard.coalesced != nil }

  nonisolated public static let liveSubscription: Subscription = { onConnect, onDisconnect in
    NotificationCenter.default.addObserver(
      forName: .GCKeyboardDidConnect, object: nil, queue: .main
    ) { _ in MainActor.assumeIsolated(onConnect) }
    NotificationCenter.default.addObserver(
      forName: .GCKeyboardDidDisconnect, object: nil, queue: .main
    ) { _ in MainActor.assumeIsolated(onDisconnect) }
  }
}
