import DriverrCore
import DriverrSSH
import Foundation
import Testing

@testable import Driverr

/// What the host list reads off the registry, without a screen.
///
/// The words are `HostStatusTests`'. This needs a registry with connections in it: which host
/// counts as connected, which herdr answered, and how many panes are blocked on it.
@MainActor
@Suite("Host list status", .serialized)
struct HostListStatusTests {
  private let workbox = DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson")
  private let edge = DriverrCore.Host(name: "edge-01", hostname: "10.1.0.99", username: "root")

  /// `.ephemeral` with both hosts' keys already trusted, or TOFU raises a prompt nobody
  /// answers and the connect suspends rather than failing.
  private func environment() -> AppEnvironment {
    var environment = AppEnvironment.ephemeral
    environment.knownHostsStore = InMemoryKnownHostsStore(
      seeded: [
        workbox.hostname: FakeSSHTransport.defaultHostKey,
        edge.hostname: FakeSSHTransport.defaultHostKey,
      ]
    )
    return environment
  }

  /// A host nobody has opened must not acquire a connection just by being *listed*.
  ///
  /// The list asks about every saved host on every redraw. `model(for:environment:)` makes a
  /// model, so answering through it would fill the registry with connections nobody asked for.
  @Test("asking a cold host's status does not give it a connection")
  func statusDoesNotMakeAConnection() {
    let registry = ConnectionRegistry()

    let status = registry.status(for: workbox)

    #expect(status.isConnected == false)
    #expect(status.subtitle == "10.1.0.9")
    #expect(registry.existingModel(for: workbox.id) == nil, "the list made a connection")
  }

  @Test("a connected host reports the herdr that answered and what is waiting on it")
  func connectedHostReportsHerdrAndBlockedCount() async {
    let registry = ConnectionRegistry()
    let model = registry.model(for: workbox, environment: environment())
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    #expect(model.phase == .connected)
    await model.session?.refresh()

    let status = registry.status(for: workbox)

    #expect(status.isConnected)
    // Connected keeps the address rather than swapping it out. The version is `FakeControl`'s
    // default availability.
    #expect(status.subtitle == "10.1.0.9 · herdr 0.9.1")
    // `FakeControl.seededTree` blocks exactly one agent: `w1:p2`.
    #expect(status.blockedPaneCount == 1)
    #expect(status.badge == "1")
    #expect(status.badgeAccessibilityLabel == "1 pane needs you")
  }

  /// Disconnecting takes the session with it, so the count goes too, rather than a badge left
  /// by a connection that has ended.
  @Test("disconnecting takes the badge with it")
  func disconnectingClearsTheBadge() async {
    let registry = ConnectionRegistry()
    let model = registry.model(for: workbox, environment: environment())
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    await model.session?.refresh()
    #expect(registry.status(for: workbox).badge == "1")

    await model.disconnect()

    let status = registry.status(for: workbox)
    #expect(status.isConnected == false)
    #expect(status.badge == nil)
    #expect(status.subtitle == "10.1.0.9", "a host that is not connected names itself")
  }

  @Test("the footer counts the hosts the list is showing and how many are up")
  func summaryCountsWhatIsOnScreen() async {
    let registry = ConnectionRegistry()
    let connected = registry.model(for: workbox, environment: environment())
    await connected.connect(password: "hunter2", persistence: .promptEveryTime)
    #expect(connected.phase == .connected)

    let summary = registry.summary(of: [workbox, edge])

    #expect(summary.hostCount == 2)
    #expect(summary.connectedCount == 1)
    #expect(summary.text == "2 hosts · 1 connected")
  }
}
