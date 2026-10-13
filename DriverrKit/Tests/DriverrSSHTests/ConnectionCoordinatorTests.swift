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

private struct FixedValidator: HostKeyValidator {
  let decision: HostKeyDecision
  func validate(_ key: SSHHostKey, for host: DriverrCore.Host) async -> HostKeyDecision {
    decision
  }
}

/// Trusts after a person-length pause. First contact suspends the handshake while someone
/// compares a fingerprint, and the deadline must not count that time.
private struct SlowValidator: HostKeyValidator {
  let thinkingTime: Duration
  func validate(_ key: SSHHostKey, for host: DriverrCore.Host) async -> HostKeyDecision {
    try? await Task.sleep(for: thinkingTime)
    return .trust
  }
}

@Suite("ConnectionCoordinator")
struct ConnectionCoordinatorTests {
  /// Nothing in SSH ends a handshake to a host that accepts and goes quiet, such as a wrong
  /// port on a filtered host.
  @Test("a handshake that never finishes fails on the deadline rather than hanging")
  func handshakeDeadlineEndsAStalledConnect() async {
    let transport = FakeSSHTransport(handshakeStall: .seconds(30))
    let coordinator = ConnectionCoordinator(
      transport: transport,
      handshakeDeadline: .milliseconds(50)
    )

    try? await coordinator.connect(
      to: workbox,
      validator: FixedValidator(decision: .trust),
      credential: .password("hunter2")
    )

    guard case .failed(.connectionFailed(let host, _)) = await coordinator.phase else {
      Issue.record("Expected a failed phase, got \(await coordinator.phase)")
      return
    }
    #expect(host == "10.1.0.9")
  }

  /// `NIOSSHTransport.connect` waits on `EventLoopFuture.get()`, which ignores cancellation,
  /// and a task group awaits its children, so the timer's throw alone never lands.
  /// `hangsUntilDisconnected` models that, and only `disconnect()` settles it. Without
  /// `await transport.disconnect()` in `withHandshakeDeadline`, this test hangs rather than
  /// fails.
  @Test(
    "the deadline tears the transport down, so a handshake that ignores cancellation ends",
    .timeLimit(.minutes(1))
  )
  func handshakeDeadlineEndsAnUncancellableConnect() async {
    let transport = FakeSSHTransport(hangsUntilDisconnected: true)
    let coordinator = ConnectionCoordinator(
      transport: transport,
      handshakeDeadline: .milliseconds(50)
    )

    try? await coordinator.connect(
      to: workbox,
      validator: FixedValidator(decision: .trust),
      credential: .password("hunter2")
    )

    guard case .failed(.connectionFailed(let host, _)) = await coordinator.phase else {
      Issue.record("Expected a failed phase, got \(await coordinator.phase)")
      return
    }
    #expect(host == "10.1.0.9")
    // The handshake was reached and let go of, not raced past.
    #expect(await transport.connectionAttempts.count == 1)
  }

  /// The deadline is not wall clock: time spent asking is refunded, so a person taking four
  /// times the budget still connects.
  @Test("time spent reading a fingerprint does not count against the deadline")
  func handshakeDeadlineRefundsTimeSpentAsking() async throws {
    let coordinator = ConnectionCoordinator(
      transport: FakeSSHTransport(),
      handshakeDeadline: .milliseconds(50)
    )

    try await coordinator.connect(
      to: workbox,
      validator: SlowValidator(thinkingTime: .milliseconds(200)),
      credential: .password("hunter2")
    )

    #expect(await coordinator.phase == .connected)
  }

  @Test("a successful connection ends in the connected phase")
  func successReachesConnected() async throws {
    let transport = FakeSSHTransport()
    let coordinator = ConnectionCoordinator(transport: transport)

    try await coordinator.connect(
      to: workbox,
      validator: FixedValidator(decision: .trust),
      credential: .password("hunter2")
    )

    #expect(await coordinator.phase == .connected)
  }

  @Test("a declined host key fails with hostKeyRejected, not a generic failure")
  func declinedKeyPhase() async {
    let coordinator = ConnectionCoordinator(transport: FakeSSHTransport())

    try? await coordinator.connect(
      to: workbox,
      validator: FixedValidator(decision: .reject),
      credential: .password("hunter2")
    )

    #expect(await coordinator.phase == .failed(.hostKeyRejected(host: "10.1.0.9")))
  }

  @Test("a changed host key fails with hostKeyMismatch, distinct from a decline")
  func mismatchPhase() async {
    let coordinator = ConnectionCoordinator(transport: FakeSSHTransport())

    try? await coordinator.connect(
      to: workbox,
      validator: FixedValidator(decision: .mismatch),
      credential: .password("hunter2")
    )

    #expect(await coordinator.phase == .failed(.hostKeyMismatch(host: "10.1.0.9")))
  }

  @Test("a wrong credential fails with authenticationFailed, distinct from both key errors")
  func authFailurePhase() async {
    let transport = FakeSSHTransport(acceptsCredentials: false)
    let coordinator = ConnectionCoordinator(transport: transport)

    try? await coordinator.connect(
      to: workbox,
      validator: FixedValidator(decision: .trust),
      credential: .password("wrong")
    )

    #expect(await coordinator.phase == .failed(.authenticationFailed(host: "10.1.0.9")))
  }

  @Test("the three failure modes are three different errors, not one generic screen")
  func failureModesAreDistinct() async {
    // "Wrong password", "the host key changed" and "cannot reach it" must never collapse.
    func phase(
      _ decision: HostKeyDecision,
      accepts: Bool
    ) async -> ConnectionPhase {
      let coordinator = ConnectionCoordinator(
        transport: FakeSSHTransport(acceptsCredentials: accepts)
      )
      try? await coordinator.connect(
        to: workbox,
        validator: FixedValidator(decision: decision),
        credential: .password("x")
      )
      return await coordinator.phase
    }

    let rejected = await phase(.reject, accepts: true)
    let mismatched = await phase(.mismatch, accepts: true)
    let unauthorised = await phase(.trust, accepts: false)

    #expect(rejected != mismatched)
    #expect(mismatched != unauthorised)
    #expect(rejected != unauthorised)
  }

  @Test("running a command before connecting throws")
  func runBeforeConnectThrows() async {
    let coordinator = ConnectionCoordinator(transport: FakeSSHTransport())
    await #expect(throws: AppError.self) {
      _ = try await coordinator.run("echo hi")
    }
  }

  @Test("a command runs once connected")
  func runsCommand() async throws {
    let transport = FakeSSHTransport(responses: [
      "uname -s": CommandResult(standardOutput: "Linux\n", standardError: "", exitStatus: 0)
    ])
    let coordinator = ConnectionCoordinator(transport: transport)
    try await coordinator.connect(
      to: workbox,
      validator: FixedValidator(decision: .trust),
      credential: .password("hunter2")
    )

    let result = try await coordinator.run("uname -s")

    #expect(result.trimmedOutput == "Linux")
  }

  @Test("disconnecting returns to idle so the host can be connected again")
  func disconnectReturnsToIdle() async throws {
    let coordinator = ConnectionCoordinator(transport: FakeSSHTransport())
    try await coordinator.connect(
      to: workbox,
      validator: FixedValidator(decision: .trust),
      credential: .password("hunter2")
    )

    await coordinator.disconnect()

    #expect(await coordinator.phase == .idle)
  }
}

@Suite("Connect flow against a real server")
struct ConnectionCoordinatorIntegrationTests {
  /// Through the app's connect logic: real handshake, host key decision, authentication and
  /// command.
  @Test("connects to a real SSH server, authenticates, and runs a command")
  func endToEndAgainstRealServer() async throws {
    let server = try await EmbeddedSSHServer(username: "carson", password: "hunter2")
    defer { Task { await server.stop() } }
    let host = DriverrCore.Host(
      name: "embedded",
      hostname: "127.0.0.1",
      port: server.port,
      username: "carson"
    )

    let knownHosts = InMemoryKnownHostsStore()
    let coordinator = ConnectionCoordinator(transport: NIOSSHTransport())

    try await coordinator.connect(
      to: host,
      validator: TOFUHostKeyValidator(store: knownHosts, prompt: AcceptingPrompt()),
      credential: .password("hunter2")
    )
    #expect(await coordinator.phase == .connected)

    let result = try await coordinator.run("echo it-works")
    #expect(result.trimmedOutput == "it-works")
    #expect(result.succeeded)

    // TOFU stored the key, so a second connection is a silent match.
    #expect(await knownHosts.trustedKey(for: "127.0.0.1") != nil)
    await coordinator.disconnect()
  }

  @Test("a wrong password against a real server fails as authenticationFailed")
  func wrongPasswordAgainstRealServer() async throws {
    let server = try await EmbeddedSSHServer(username: "carson", password: "hunter2")
    defer { Task { await server.stop() } }
    let host = DriverrCore.Host(
      name: "embedded",
      hostname: "127.0.0.1",
      port: server.port,
      username: "carson"
    )
    let coordinator = ConnectionCoordinator(transport: NIOSSHTransport())

    try? await coordinator.connect(
      to: host,
      validator: TOFUHostKeyValidator(
        store: InMemoryKnownHostsStore(),
        prompt: AcceptingPrompt()
      ),
      credential: .password("wrong")
    )

    #expect(await coordinator.phase == .failed(.authenticationFailed(host: "127.0.0.1")))
  }

  @Test("an unreachable host fails as connectionFailed, not as an auth problem")
  func unreachableAgainstRealPort() async throws {
    let server = try await EmbeddedSSHServer(username: "carson", password: "hunter2")
    let deadPort = server.port
    await server.stop()

    let host = DriverrCore.Host(
      name: "dead",
      hostname: "127.0.0.1",
      port: deadPort,
      username: "carson"
    )
    let coordinator = ConnectionCoordinator(transport: NIOSSHTransport())

    try? await coordinator.connect(
      to: host,
      validator: TOFUHostKeyValidator(
        store: InMemoryKnownHostsStore(),
        prompt: AcceptingPrompt()
      ),
      credential: .password("hunter2")
    )

    guard case .failed(let error) = await coordinator.phase else {
      Issue.record("expected a failure phase")
      return
    }
    #expect(error == .connectionFailed(host: "127.0.0.1", reason: error.reasonText))
  }

  @Test("a PTY opens once connected, at the size it was asked for")
  func opensPTYWhenConnected() async throws {
    let transport = FakeSSHTransport()
    let coordinator = ConnectionCoordinator(transport: transport)
    try await coordinator.connect(
      to: workbox,
      validator: FixedValidator(decision: .trust),
      credential: .password("hunter2")
    )

    let channel = try await coordinator.openPTY(size: TerminalSize(columns: 100, rows: 30))
    try await channel.send(Data("echo hi\n".utf8))

    #expect(await transport.lastPTYSize == TerminalSize(columns: 100, rows: 30))
  }

  @Test("asking for a PTY before connecting fails rather than hanging")
  func ptyBeforeConnectingThrows() async {
    let coordinator = ConnectionCoordinator(transport: FakeSSHTransport())

    await #expect(throws: AppError.notConnected(host: "the host")) {
      _ = try await coordinator.openPTY(size: TerminalSize(columns: 80, rows: 24))
    }
  }
}

struct AcceptingPrompt: HostKeyPrompt {
  func askToTrust(_ key: SSHHostKey, for host: DriverrCore.Host) async -> Bool { true }
}

extension AppError {
  /// Lets a test assert the case without pinning the message's wording.
  var reasonText: String {
    if case .connectionFailed(_, let reason) = self { return reason }
    return ""
  }
}
