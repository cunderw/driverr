import Crypto
import DriverrCore
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Testing
@testable import DriverrSSH

/// Records the key it was shown, so a test can prove the client saw the real host key.
private final class RecordingValidator: HostKeyValidator, @unchecked Sendable {
  private let decision: HostKeyDecision
  private(set) var seenKey: SSHHostKey?

  init(decision: HostKeyDecision = .trust) {
    self.decision = decision
  }

  func validate(_ key: SSHHostKey, for host: DriverrCore.Host) async -> HostKeyDecision {
    seenKey = key
    return decision
  }
}

@Suite("NIOSSHTransport")
struct NIOSSHTransportTests {
  /// Starts a server and tears it down whether the test passed or threw.
  private func withServer(
    username: String = "carson",
    password: String = "hunter2",
    _ body: (EmbeddedSSHServer, DriverrCore.Host) async throws -> Void
  ) async throws {
    let server = try await EmbeddedSSHServer(username: username, password: password)
    defer { Task { await server.stop() } }
    let host = DriverrCore.Host(
      name: "embedded",
      hostname: "127.0.0.1",
      port: server.port,
      username: username
    )
    try await body(server, host)
  }

  /// Reads until `count` chunks arrive or the deadline passes. A single read races the
  /// network, and the bound makes a broken stream fail rather than hang.
  private func collect(
    _ stream: AsyncThrowingStream<Data, any Error>,
    count: Int,
    timeout: Duration = .seconds(5)
  ) async throws -> [Data] {
    try await withThrowingTaskGroup(of: [Data].self) { group in
      group.addTask {
        var chunks: [Data] = []
        for try await chunk in stream {
          chunks.append(chunk)
          if chunks.count >= count { break }
        }
        return chunks
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw AppError.channelFailed(reason: "timed out waiting for \(count) chunk(s)")
      }
      let first = try await group.next()!
      group.cancelAll()
      return first
    }
  }

  @Test("a streamed command keeps both directions open on a real server")
  func execStreamRoundTripsAgainstRealServer() async throws {
    // A fake cannot show bytes round-tripping through a real SSH channel.
    try await withServer { _, host in
      let transport = NIOSSHTransport()
      try await transport.connect(to: host, hostKeyValidator: RecordingValidator())
      try await transport.authenticate(.password("hunter2"))
      defer { Task { await transport.disconnect() } }

      let stream = try await transport.execStream(command: "stream-echo")
      try await stream.send(Data("{\"type\":\"terminal.scroll\"}\n".utf8))

      let chunks = try await collect(stream.output, count: 1)
      let text = String(decoding: chunks.joined(), as: UTF8.self)
      #expect(text.contains("terminal.scroll"))
      await stream.close()
    }
  }

  @Test("a streamed command asks for no pseudo-terminal")
  func execStreamAllocatesNoPTY() async throws {
    // A pty echoes input and rewrites line endings, which corrupts a line protocol, so the far
    // end checks that none was requested.
    try await withServer { server, host in
      let transport = NIOSSHTransport()
      try await transport.connect(to: host, hostKeyValidator: RecordingValidator())
      try await transport.authenticate(.password("hunter2"))
      defer { Task { await transport.disconnect() } }

      let stream = try await transport.execStream(command: "stream-echo")
      try await stream.send(Data("ping\n".utf8))
      _ = try await collect(stream.output, count: 1)

      #expect(
        server.ptyRequests.seen == false,
        "execStream must not allocate a pty; a pty would echo commands back and rewrite line endings"
      )
      await stream.close()
    }
  }

  @Test("stderr stays out of the payload stream, and the exit status survives")
  func execStreamSeparatesStandardError() async throws {
    // `fail` writes to stderr and exits 3. Merged into `output`, it would be parsed as frames.
    try await withServer { _, host in
      let transport = NIOSSHTransport()
      try await transport.connect(to: host, hostKeyValidator: RecordingValidator())
      try await transport.authenticate(.password("hunter2"))
      defer { Task { await transport.disconnect() } }

      let stream = try await transport.execStream(command: "fail")
      let errors = try await collect(stream.standardError, count: 1)
      #expect(String(decoding: errors.joined(), as: UTF8.self).contains("something broke"))

      var payload = Data()
      for try await chunk in stream.output { payload.append(chunk) }
      #expect(!String(decoding: payload, as: UTF8.self).contains("something broke"))

      #expect(await stream.exitStatus == 3, "a command that exited must say how")
    }
  }

  @Test("runs a command on a real SSH server and returns its output")
  func execAgainstRealServer() async throws {
    try await withServer { _, host in
      let transport = NIOSSHTransport()
      try await transport.connect(to: host, hostKeyValidator: RecordingValidator())
      try await transport.authenticate(.password("hunter2"))

      let result = try await transport.execChannel(command: "echo hello")
      #expect(result.trimmedOutput == "hello")
      #expect(result.succeeded)
      await transport.disconnect()
    }
  }

  @Test("a failing command reports its exit status and stderr separately")
  func execReportsFailure() async throws {
    try await withServer { _, host in
      let transport = NIOSSHTransport()
      try await transport.connect(to: host, hostKeyValidator: RecordingValidator())
      try await transport.authenticate(.password("hunter2"))

      let result = try await transport.execChannel(command: "fail")
      #expect(!result.succeeded)
      #expect(result.exitStatus == 3)
      #expect(result.standardError.contains("something broke"))
      #expect(result.standardOutput.isEmpty)
      await transport.disconnect()
    }
  }

  @Test("the validator is shown the server's actual host key")
  func validatorSeesRealHostKey() async throws {
    try await withServer { server, host in
      let validator = RecordingValidator()
      let transport = NIOSSHTransport()
      try await transport.connect(to: host, hostKeyValidator: validator)

      // Derived independently.
      let openSSH = String(openSSHPublicKey: server.hostPublicKey)
      let parts = openSSH.split(separator: " ")
      let expected = SSHHostKey(
        algorithm: String(parts[0]),
        blob: Data(base64Encoded: String(parts[1]))!
      )

      #expect(validator.seenKey == expected)
      #expect(validator.seenKey?.algorithm == "ssh-ed25519")
      await transport.disconnect()
    }
  }

  @Test("rejecting the host key stops the connection with hostKeyRejected")
  func rejectedHostKeyFailsConnect() async throws {
    try await withServer { _, host in
      let transport = NIOSSHTransport()
      await #expect(throws: AppError.hostKeyRejected(host: "127.0.0.1")) {
        try await transport.connect(
          to: host,
          hostKeyValidator: RecordingValidator(decision: .reject)
        )
      }
    }
  }

  @Test("a wrong password fails authentication rather than hanging")
  func wrongPasswordFailsAuthentication() async throws {
    try await withServer { _, host in
      let transport = NIOSSHTransport()
      try await transport.connect(to: host, hostKeyValidator: RecordingValidator())

      await #expect(throws: AppError.authenticationFailed(host: "127.0.0.1")) {
        try await transport.authenticate(.password("wrong-password"))
      }
    }
  }

  @Test("a PTY channel carries bytes to the remote shell and back")
  func ptyRoundTripsBytes() async throws {
    try await withServer { _, host in
      let transport = NIOSSHTransport()
      try await transport.connect(to: host, hostKeyValidator: RecordingValidator())
      try await transport.authenticate(.password("hunter2"))

      let pty = try await transport.ptyChannel(size: TerminalSize(columns: 80, rows: 24))
      var iterator = pty.output.makeAsyncIterator()
      try await pty.send(Data("hello pty\n".utf8))

      let received = try await iterator.next()
      #expect(received == Data("hello pty\n".utf8))

      // Resizing must not tear the PTY down.
      try await pty.resize(to: TerminalSize(columns: 120, rows: 40))
      await pty.close()
      await transport.disconnect()
    }
  }

  @Test("authenticates with an Ed25519 private key, not just a password")
  func publicKeyAuthentication() async throws {
    let signingKey = Curve25519.Signing.PrivateKey()
    let server = try await EmbeddedSSHServer(
      username: "carson",
      password: "hunter2",
      authorizedKey: NIOSSHPrivateKey(ed25519Key: signingKey).publicKey
    )
    defer { Task { await server.stop() } }

    let host = DriverrCore.Host(
      name: "embedded",
      hostname: "127.0.0.1",
      port: server.port,
      username: "carson"
    )
    let transport = NIOSSHTransport()
    try await transport.connect(to: host, hostKeyValidator: RecordingValidator())
    try await transport.authenticate(
      .privateKey(SSHPrivateKey(rawRepresentation: signingKey.rawRepresentation))
    )

    let result = try await transport.execChannel(command: "echo keyed")
    #expect(result.trimmedOutput == "keyed")
    await transport.disconnect()
  }

  @Test("an unauthorized private key is refused rather than accepted")
  func unauthorizedKeyIsRefused() async throws {
    let authorized = Curve25519.Signing.PrivateKey()
    let attacker = Curve25519.Signing.PrivateKey()
    let server = try await EmbeddedSSHServer(
      username: "carson",
      password: "hunter2",
      authorizedKey: NIOSSHPrivateKey(ed25519Key: authorized).publicKey
    )
    defer { Task { await server.stop() } }

    let host = DriverrCore.Host(
      name: "embedded",
      hostname: "127.0.0.1",
      port: server.port,
      username: "carson"
    )
    let transport = NIOSSHTransport()
    try await transport.connect(to: host, hostKeyValidator: RecordingValidator())

    await #expect(throws: AppError.authenticationFailed(host: "127.0.0.1")) {
      try await transport.authenticate(
        .privateKey(SSHPrivateKey(rawRepresentation: attacker.rawRepresentation))
      )
    }
  }

  @Test("connecting to a port with nothing on it fails as connectionFailed")
  func unreachablePortFailsToConnect() async throws {
    // Bind and release a port to get one that is almost certainly closed.
    let server = try await EmbeddedSSHServer(username: "carson", password: "hunter2")
    let deadPort = server.port
    await server.stop()

    let host = DriverrCore.Host(
      name: "dead",
      hostname: "127.0.0.1",
      port: deadPort,
      username: "carson"
    )
    let transport = NIOSSHTransport()
    await #expect(throws: AppError.self) {
      try await transport.connect(to: host, hostKeyValidator: RecordingValidator())
    }
  }

  /// A send or channel open that a disconnect overtakes fails on a closed channel (#151).
  /// The reason says the connection closed, not that it could not be made.
  @Test("a closed channel reads as a closed connection")
  func aClosedChannelReadsAsAClosedConnection() {
    #expect(
      NIOSSHTransport.readableReason(for: ChannelError.ioOnClosedChannel)
        == "The connection closed."
    )
  }

  /// A connect that fails reads "Could not reach <host>.", and "The connection closed."
  /// after it would say the host was reached. The connect keeps the generic reason.
  @Test("a connect that fails on a closed channel keeps the generic reason")
  func aConnectOnAClosedChannelKeepsTheGenericReason() {
    #expect(
      NIOSSHTransport.readableReason(for: ChannelError.ioOnClosedChannel, whileConnecting: true)
        == "The connection could not be established."
    )
  }

  @Test("running a command before authenticating throws instead of hanging")
  func execBeforeAuthenticateThrows() async throws {
    try await withServer { _, host in
      let transport = NIOSSHTransport()
      try await transport.connect(to: host, hostKeyValidator: RecordingValidator())

      await #expect(throws: AppError.self) {
        try await transport.execChannel(command: "echo hello")
      }
      await transport.disconnect()
    }
  }
}

/// Holds its decision until the test releases it, like a trust prompt left on screen.
private final class ParkedValidator: HostKeyValidator, Sendable {
  private let reachedStream: AsyncStream<Void>
  private let reachedSignal: AsyncStream<Void>.Continuation
  private let releaseStream: AsyncStream<Void>
  private let releaseSignal: AsyncStream<Void>.Continuation

  init() {
    (reachedStream, reachedSignal) = AsyncStream.makeStream(of: Void.self)
    (releaseStream, releaseSignal) = AsyncStream.makeStream(of: Void.self)
  }

  func validate(_ key: SSHHostKey, for host: DriverrCore.Host) async -> HostKeyDecision {
    reachedSignal.yield()
    for await _ in releaseStream { break }
    return .trust
  }

  func waitUntilAsked() async { for await _ in reachedStream { break } }
  func release() { releaseSignal.yield() }
}

/// What a promise settled with, recorded from its event loop.
private final class SettledBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Result<Void, any Error>?

  func record(_ result: Result<Void, any Error>) { lock.withLock { stored = result } }
  var result: Result<Void, any Error>? { lock.withLock { stored } }
}

/// NIOSSH hands `validateHostKey` a promise and waits on it. These cases drive the delegate
/// directly, so a promise left unsettled is an assertion rather than a stalled handshake.
@Suite("HandshakeCoordinator host-key promise")
struct HandshakeCoordinatorHostKeyTests {
  private let loop = MultiThreadedEventLoopGroup.singleton.next()
  private let host = DriverrCore.Host(
    name: "embedded",
    hostname: "127.0.0.1",
    port: 22,
    username: "carson"
  )
  private let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey

  /// Calls the delegate on its loop, as NIOSSH does, and returns NIOSSH's promise.
  private func validate(with coordinator: HandshakeCoordinator) async throws
    -> EventLoopPromise<Void>
  {
    let hostKey = hostKey
    let loop = loop
    return try await loop.submit {
      let promise = loop.makePromise(of: Void.self)
      coordinator.validateHostKey(hostKey: hostKey, validationCompletePromise: promise)
      return promise
    }.get()
  }

  /// How the promise settled, or nil if it had not within the budget.
  private func settled(
    _ promise: EventLoopPromise<Void>,
    within budget: Duration = .seconds(2)
  ) async throws -> Result<Void, any Error>? {
    let box = SettledBox()
    promise.futureResult.whenComplete { box.record($0) }
    let deadline = ContinuousClock.now + budget
    while box.result == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    return box.result
  }

  /// Settles whatever is still open, so a red run fails on its assertion rather than on
  /// NIO's trap for a promise released unfulfilled.
  private func finish(_ coordinator: HandshakeCoordinator, _ promises: EventLoopPromise<Void>...)
    async throws
  {
    try await loop.submit {
      for promise in promises { promise.fail(AppError.cancelled) }
    }.get()
    await coordinator.cancelPendingWork()
  }

  private func failedAsCancelled(_ result: Result<Void, any Error>?) -> Bool {
    guard case .failure(let error) = result else { return false }
    return error as? AppError == .cancelled
  }

  @Test("a trust answer that arrives after a disconnect fails NIOSSH's promise as cancelled")
  func aLateAnswerAfterADisconnectSettlesThePromise() async throws {
    let validator = ParkedValidator()
    let coordinator = HandshakeCoordinator(eventLoop: loop, host: host, validator: validator)
    let promise = try await validate(with: coordinator)
    await validator.waitUntilAsked()
    await coordinator.cancelPendingWork()
    validator.release()

    let result = try await settled(promise)
    #expect(result != nil, "the late answer left NIOSSH's promise unsettled")
    #expect(failedAsCancelled(result), "expected cancelled, got \(String(describing: result))")
    try await finish(coordinator, promise)
  }

  /// A re-key runs key exchange again on a live connection, and NIOSSH asks again.
  @Test("a second host-key check after a trusted first one succeeds")
  func aSecondCheckAfterATrustedFirstOneSucceeds() async throws {
    let coordinator = HandshakeCoordinator(
      eventLoop: loop,
      host: host,
      validator: RecordingValidator(decision: .trust)
    )
    let first = try await validate(with: coordinator)
    let firstResult = try await settled(first)
    try await coordinator.waitForHostKeyDecision()
    let second = try await validate(with: coordinator)
    let secondResult = try await settled(second)

    #expect(firstResult.map { (try? $0.get()) != nil } == true)
    #expect(secondResult != nil, "the second check left NIOSSH's promise unsettled")
    #expect(secondResult.map { (try? $0.get()) != nil } == true, "the second check failed")
    try await finish(coordinator, first, second)
  }

  @Test("a host-key check after a disconnect fails at once and asks nobody")
  func aCheckAfterADisconnectAsksNobody() async throws {
    let validator = RecordingValidator(decision: .trust)
    let coordinator = HandshakeCoordinator(eventLoop: loop, host: host, validator: validator)
    await coordinator.cancelPendingWork()
    let promise = try await validate(with: coordinator)

    let result = try await settled(promise)
    #expect(result != nil, "the check left NIOSSH's promise unsettled")
    #expect(failedAsCancelled(result), "expected cancelled, got \(String(describing: result))")
    #expect(validator.seenKey == nil, "the validator was asked about a cancelled connection")
    try await finish(coordinator, promise)
  }
}
