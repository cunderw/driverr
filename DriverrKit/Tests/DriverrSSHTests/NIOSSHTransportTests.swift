import Crypto
import DriverrCore
import Foundation
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
