@testable import DriverrTerm

/// Fakes `GCKeyboardDidConnect` and `GCKeyboardDidDisconnect` by holding
/// `HardwareKeyboardMonitor`'s two closures, so a test fires the events by hand.
@MainActor
final class FakeHardwareKeyboardSource {
  private(set) var onConnect: (@MainActor () -> Void)?
  private(set) var onDisconnect: (@MainActor () -> Void)?

  var subscribe: HardwareKeyboardMonitor.Subscription {
    { [weak self] onConnect, onDisconnect in
      self?.onConnect = onConnect
      self?.onDisconnect = onDisconnect
    }
  }

  func connect() { onConnect?() }
  func disconnect() { onDisconnect?() }
}
