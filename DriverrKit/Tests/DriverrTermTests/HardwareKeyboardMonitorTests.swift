import Testing

@testable import DriverrTerm

@MainActor
@Suite("HardwareKeyboardMonitor")
struct HardwareKeyboardMonitorTests {
  @Test("starts at whatever isConnected was constructed with")
  func startsAtConstructedValue() {
    let source = FakeHardwareKeyboardSource()
    let connected = HardwareKeyboardMonitor(isConnected: true, subscribe: source.subscribe)
    let disconnected = HardwareKeyboardMonitor(isConnected: false, subscribe: source.subscribe)

    #expect(connected.isConnected)
    #expect(!disconnected.isConnected)
  }

  @Test("an injected connect event flips isConnected and fires onChange")
  func injectedConnectFlipsState() {
    let source = FakeHardwareKeyboardSource()
    let monitor = HardwareKeyboardMonitor(isConnected: false, subscribe: source.subscribe)
    var changes = 0
    monitor.onChange = { changes += 1 }

    source.connect()

    #expect(monitor.isConnected)
    #expect(changes == 1)
  }

  @Test("an injected disconnect event flips isConnected and fires onChange")
  func injectedDisconnectFlipsState() {
    let source = FakeHardwareKeyboardSource()
    let monitor = HardwareKeyboardMonitor(isConnected: true, subscribe: source.subscribe)
    var changes = 0
    monitor.onChange = { changes += 1 }

    source.disconnect()

    #expect(!monitor.isConnected)
    #expect(changes == 1)
  }

  @Test("a connect event that changes nothing does not fire onChange again")
  func noOpConnectDoesNotFireOnChange() {
    let source = FakeHardwareKeyboardSource()
    let monitor = HardwareKeyboardMonitor(isConnected: true, subscribe: source.subscribe)
    var changes = 0
    monitor.onChange = { changes += 1 }

    source.connect()

    #expect(monitor.isConnected)
    #expect(changes == 0, "isConnected was already true; nothing changed")
  }
}
