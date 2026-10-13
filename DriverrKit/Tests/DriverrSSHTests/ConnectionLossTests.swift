import DriverrCore
import Foundation
import Testing
@testable import DriverrSSH

private let workbox = DriverrCore.Host(
  name: "workbox",
  hostname: "10.1.0.9",
  port: 22,
  username: "carson"
)

private struct Trusting: HostKeyValidator {
  func validate(_ key: SSHHostKey, for host: DriverrCore.Host) async -> HostKeyDecision { .trust }
}

extension AppError {
  /// Asserts the case without pinning the message's wording.
  var isDisconnected: Bool {
    if case .disconnected = self { return true }
    return false
  }
}

/// Lets queued events arrive, for tests asserting a phase change does not happen.
/// Everything is in-process, so yields suffice; a sleep would be slower and no stricter.
private func settle() async {
  for _ in 0..<20 { await Task.yield() }
}

/// Connects through a fake, so these tests are about the phase machine, not a network.
private func connectedCoordinator(
  _ transport: FakeSSHTransport
) async throws -> ConnectionCoordinator {
  let coordinator = ConnectionCoordinator(transport: transport)
  try await coordinator.connect(
    to: workbox,
    validator: Trusting(),
    credential: .password("hunter2")
  )
  return coordinator
}

@Suite("Connection loss")
struct ConnectionLossTests {
  @Test("a dropped link moves a connected coordinator to lost")
  func dropReachesLost() async throws {
    let transport = FakeSSHTransport()
    let coordinator = try await connectedCoordinator(transport)

    await transport.drop()
    await coordinator.waitForClosureHandling()

    let phase = await coordinator.phase
    guard case .lost(let error) = phase else {
      Issue.record("expected .lost, got \(phase)")
      return
    }
    #expect(error.isDisconnected)
    // A message with no host is the generic screen this enum exists to avoid.
    #expect(error.errorDescription?.contains("10.1.0.9") == true)
  }

  @Test("lost and failed are different phases even for the same error")
  func lostIsDistinctFromFailed() {
    let error = AppError.disconnected(reason: "10.1.0.9 is no longer reachable.")
    #expect(ConnectionPhase.lost(error) != ConnectionPhase.failed(error))
  }

  @Test("a connect attempt that fails is failed, never lost")
  func failedAttemptIsNeverLost() async {
    let coordinator = ConnectionCoordinator(
      transport: FakeSSHTransport(acceptsCredentials: false)
    )

    try? await coordinator.connect(
      to: workbox,
      validator: Trusting(),
      credential: .password("wrong")
    )

    let phase = await coordinator.phase
    #expect(phase == .failed(.authenticationFailed(host: "10.1.0.9")))
    if case .lost = phase {
      Issue.record("a connect attempt that never connected must not report a loss")
    }
  }

  @Test("dropping a transport that never connected leaves the coordinator idle")
  func dropBeforeConnectingStaysIdle() async {
    let transport = FakeSSHTransport()
    let coordinator = ConnectionCoordinator(transport: transport)

    await transport.drop()
    await coordinator.waitForClosureHandling()

    #expect(await coordinator.phase == .idle)
  }

  @Test("disconnecting on purpose ends at idle, not lost")
  func deliberateDisconnectIsNotLost() async throws {
    let transport = FakeSSHTransport()
    let coordinator = try await connectedCoordinator(transport)

    await coordinator.disconnect()
    await settle()

    #expect(await coordinator.phase == .idle)
  }

  @Test("a coordinator that lost its link can connect again")
  func reconnectAfterLoss() async throws {
    let transport = FakeSSHTransport()
    let coordinator = try await connectedCoordinator(transport)
    await transport.drop()
    await coordinator.waitForClosureHandling()

    try await coordinator.connect(
      to: workbox,
      validator: Trusting(),
      credential: .password("hunter2")
    )

    // A closure signal shared across connections would hand this watcher the old loss.
    #expect(await coordinator.phase == .connected)
    await settle()
    #expect(await coordinator.phase == .connected)
  }
}

@Suite("FakeSSHTransport.drop")
struct FakeSSHTransportDropTests {
  @Test("drop reports the loss on the transport's own signal")
  func dropReportsOnTheSignal() async throws {
    let transport = FakeSSHTransport()
    try await transport.connect(to: workbox, hostKeyValidator: Trusting())
    try await transport.authenticate(.password("hunter2"))
    var disconnections = await transport.disconnections.makeAsyncIterator()

    await transport.drop()

    let reported = await disconnections.next()
    #expect(reported?.isDisconnected == true)
  }

  @Test("a dropped transport refuses further work, the way a real one would")
  func dropLeavesTheTransportUnusable() async throws {
    let transport = FakeSSHTransport()
    try await transport.connect(to: workbox, hostKeyValidator: Trusting())
    try await transport.authenticate(.password("hunter2"))

    await transport.drop()

    await #expect(throws: AppError.self) {
      _ = try await transport.execChannel(command: "echo hi")
    }
  }

  @Test("a dropped transport ends the channels it had open")
  func dropEndsOpenChannels() async throws {
    let transport = FakeSSHTransport()
    try await transport.connect(to: workbox, hostKeyValidator: Trusting())
    try await transport.authenticate(.password("hunter2"))
    let channel = try await transport.ptyChannel(size: TerminalSize(columns: 80, rows: 24))

    await transport.drop()

    // A real drop takes every channel with it, so the reader sees end-of-stream, not a hang.
    for try await _ in channel.output {}
  }
}

@Suite("Connection loss against a real server")
struct ConnectionLossIntegrationTests {
  /// A fake cannot prove the real transport notices; the server is torn down under a live
  /// connection.
  @Test("a server that goes away moves the coordinator to lost", .timeLimit(.minutes(1)))
  func realServerLossReachesLost() async throws {
    let server = try await EmbeddedSSHServer(username: "carson", password: "hunter2")
    let host = DriverrCore.Host(
      name: "embedded",
      hostname: "127.0.0.1",
      port: server.port,
      username: "carson"
    )
    let coordinator = ConnectionCoordinator(transport: NIOSSHTransport())
    try await coordinator.connect(
      to: host,
      validator: TOFUHostKeyValidator(
        store: InMemoryKnownHostsStore(),
        prompt: AcceptingPrompt()
      ),
      credential: .password("hunter2")
    )
    #expect(await coordinator.phase == .connected)

    await server.stop()

    await coordinator.waitForClosureHandling()
    let phase = await coordinator.phase
    guard case .lost(let error) = phase else {
      Issue.record("expected .lost, got \(phase)")
      return
    }
    #expect(error.isDisconnected)
    #expect(error.errorDescription?.contains("127.0.0.1") == true)
  }

  @Test("disconnecting a real connection on purpose is not reported as a loss")
  func realDisconnectIsNotLost() async throws {
    let server = try await EmbeddedSSHServer(username: "carson", password: "hunter2")
    defer { Task { await server.stop() } }
    let host = DriverrCore.Host(
      name: "embedded",
      hostname: "127.0.0.1",
      port: server.port,
      username: "carson"
    )
    let coordinator = ConnectionCoordinator(transport: NIOSSHTransport())
    try await coordinator.connect(
      to: host,
      validator: TOFUHostKeyValidator(
        store: InMemoryKnownHostsStore(),
        prompt: AcceptingPrompt()
      ),
      credential: .password("hunter2")
    )

    await coordinator.disconnect()
    await settle()

    #expect(await coordinator.phase == .idle)
  }
}

/// `ConnectionModel` reads the phase once, at the end of a connect, so later losses need
/// `losses` to reach anyone. A link that died while the phone was suspended may never
/// announce itself, so `probe` asks.
@Suite("Connection loss, as the app has to see it")
struct ConnectionLossSignalTests {
  @Test("a lost connection is announced on the coordinator's own signal")
  func lossIsAnnounced() async throws {
    let transport = FakeSSHTransport()
    let coordinator = try await connectedCoordinator(transport)
    var losses = await coordinator.losses.makeAsyncIterator()

    await transport.drop()

    let reported = await losses.next()
    #expect(reported?.isDisconnected == true)
  }

  @Test("a disconnect Driverr asked for is not announced as a loss")
  func deliberateDisconnectIsNotAnnounced() async throws {
    let transport = FakeSSHTransport()
    let coordinator = try await connectedCoordinator(transport)
    var losses = await coordinator.losses.makeAsyncIterator()

    await coordinator.disconnect()

    // Finished rather than yielded, as `SSHTransport.disconnections` does, so Disconnect does
    // not start a reconnect.
    #expect(await losses.next() == nil)
  }

  @Test("a reconnect gets its own signal, not the previous connection's")
  func lossesBelongToOneConnection() async throws {
    let transport = FakeSSHTransport()
    let coordinator = try await connectedCoordinator(transport)
    await transport.drop()
    await coordinator.waitForClosureHandling()

    try await coordinator.connect(
      to: workbox,
      validator: Trusting(),
      credential: .password("hunter2")
    )
    var losses = await coordinator.losses.makeAsyncIterator()
    await transport.drop()

    // Taken after the reconnect: a shared signal would hand this stream the previous death.
    #expect(await losses.next()?.isDisconnected == true)
    #expect(await losses.next() == nil)
  }

  @Test("probing a live connection leaves it connected")
  func probeOnALiveConnection() async throws {
    let transport = FakeSSHTransport()
    let coordinator = try await connectedCoordinator(transport)

    #expect(await coordinator.probe() == .connected)
  }

  @Test("probing a link that went away without saying so reports it lost")
  func probeFindsASilentDeath() async throws {
    let transport = FakeSSHTransport()
    let coordinator = try await connectedCoordinator(transport)

    // Torn down with nothing on the closure signal, as when the phone was suspended.
    await transport.disconnect()

    let phase = await coordinator.probe()
    guard case .lost(let error) = phase else {
      Issue.record("expected .lost, got \(phase)")
      return
    }
    #expect(error.isDisconnected)
    #expect(error.errorDescription?.contains("10.1.0.9") == true)
  }

  @Test("probing a connection that was never up changes nothing")
  func probeOnAnIdleCoordinator() async {
    let coordinator = ConnectionCoordinator(transport: FakeSSHTransport())

    #expect(await coordinator.probe() == .idle)
  }
}
