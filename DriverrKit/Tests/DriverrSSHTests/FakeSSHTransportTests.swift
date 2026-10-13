import DriverrCore
import Foundation
import Testing
@testable import DriverrSSH

private let testHost = DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", port: 22, username: "carson")

/// Accepts any key.
private struct AlwaysTrust: HostKeyValidator {
  func validate(_ key: SSHHostKey, for host: DriverrCore.Host) async -> HostKeyDecision { .trust }
}

private struct AlwaysReject: HostKeyValidator {
  func validate(_ key: SSHHostKey, for host: DriverrCore.Host) async -> HostKeyDecision { .reject }
}

@Suite("FakeSSHTransport")
struct FakeSSHTransportTests {
  @Test("running a command before connecting is a channel failure, not a crash")
  func execBeforeConnectThrows() async {
    let transport = FakeSSHTransport()
    await #expect(throws: AppError.self) {
      try await transport.execChannel(command: "uname -s")
    }
  }

  @Test("authenticating before connecting throws")
  func authenticateBeforeConnectThrows() async {
    let transport = FakeSSHTransport()
    await #expect(throws: AppError.self) {
      try await transport.authenticate(.password("x"))
    }
  }

  @Test("a rejected host key stops the connection with hostKeyRejected")
  func rejectedHostKeyStopsConnection() async {
    let transport = FakeSSHTransport()
    await #expect(throws: AppError.hostKeyRejected(host: "10.1.0.9")) {
      try await transport.connect(to: testHost, hostKeyValidator: AlwaysReject())
    }
  }

  @Test("a seeded command returns its seeded result")
  func seededCommandReturnsResult() async throws {
    let transport = FakeSSHTransport(responses: [
      "uname -s": CommandResult(standardOutput: "Linux\n", standardError: "", exitStatus: 0)
    ])
    try await transport.connect(to: testHost, hostKeyValidator: AlwaysTrust())
    try await transport.authenticate(.password("hunter2"))

    let result = try await transport.execChannel(command: "uname -s")
    #expect(result.trimmedOutput == "Linux")
    #expect(result.succeeded)
  }

  @Test("an unseeded command comes back like a shell that could not find it")
  func unseededCommandLooksLikeCommandNotFound() async throws {
    let transport = FakeSSHTransport()
    try await transport.connect(to: testHost, hostKeyValidator: AlwaysTrust())
    try await transport.authenticate(.password("hunter2"))

    let result = try await transport.execChannel(command: "definitely-not-a-command")
    #expect(!result.succeeded)
    #expect(result.exitStatus == 127)
  }

  @Test("the fake records which credential it was given, so stores can assert on it")
  func recordsAuthMethod() async throws {
    let transport = FakeSSHTransport()
    try await transport.connect(to: testHost, hostKeyValidator: AlwaysTrust())
    try await transport.authenticate(.password("hunter2"))
    let recorded = await transport.authenticationAttempts
    #expect(recorded.count == 1)
  }

  @Test("a PTY channel echoes what is written to it")
  func ptyEchoesInput() async throws {
    let transport = FakeSSHTransport()
    try await transport.connect(to: testHost, hostKeyValidator: AlwaysTrust())
    try await transport.authenticate(.password("hunter2"))

    let pty = try await transport.ptyChannel(size: TerminalSize(columns: 80, rows: 24))
    var iterator = pty.output.makeAsyncIterator()
    try await pty.send(Data("echo hi\n".utf8))

    let received = try await iterator.next()
    #expect(received == Data("echo hi\n".utf8))
    await pty.close()
  }

  @Test("resize announcements are off unless asked for, and say the new size when on")
  func announcedResizes() async throws {
    let transport = FakeSSHTransport(announcesResizes: true)
    try await transport.connect(to: testHost, hostKeyValidator: AlwaysTrust())
    try await transport.authenticate(.password("hunter2"))

    let pty = try await transport.ptyChannel(size: TerminalSize(columns: 80, rows: 24))
    var iterator = pty.output.makeAsyncIterator()
    try await pty.resize(to: TerminalSize(columns: 120, rows: 40))

    let announcement = try await iterator.next().map { String(decoding: $0, as: UTF8.self) }
    #expect(announcement?.contains("120x40") == true)
    await pty.close()
  }

  @Test("caret echo turns control bytes into what a tty shows, and leaves layout alone")
  func caretEcho() async throws {
    let transport = FakeSSHTransport(echoesControlAsCaret: true)
    try await transport.connect(to: testHost, hostKeyValidator: AlwaysTrust())
    try await transport.authenticate(.password("hunter2"))

    let pty = try await transport.ptyChannel(size: TerminalSize(columns: 80, rows: 24))
    var iterator = pty.output.makeAsyncIterator()
    // Ctrl-C and Escape, then a Return and a Tab that must survive as themselves.
    try await pty.send(Data([0x03, 0x1B, 0x0D, 0x09]))

    let echoed = try await iterator.next().map { String(decoding: $0, as: UTF8.self) }
    #expect(echoed == "^C^[\r\t")
    await pty.close()
  }

  @Test("a PTY channel remembers the last size it was resized to")
  func ptyRecordsResize() async throws {
    let transport = FakeSSHTransport()
    try await transport.connect(to: testHost, hostKeyValidator: AlwaysTrust())
    try await transport.authenticate(.password("hunter2"))

    let pty = try await transport.ptyChannel(size: TerminalSize(columns: 80, rows: 24))
    try await pty.resize(to: TerminalSize(columns: 120, rows: 40))

    let size = await transport.lastPTYSize
    #expect(size == TerminalSize(columns: 120, rows: 40))
    await pty.close()
  }

  @Test("after disconnecting, running a command throws again")
  func execAfterDisconnectThrows() async throws {
    let transport = FakeSSHTransport()
    try await transport.connect(to: testHost, hostKeyValidator: AlwaysTrust())
    try await transport.authenticate(.password("hunter2"))
    await transport.disconnect()

    await #expect(throws: AppError.self) {
      try await transport.execChannel(command: "uname -s")
    }
  }

  @Test("a fake seeded to refuse credentials throws authenticationFailed")
  func seededAuthFailure() async throws {
    let transport = FakeSSHTransport(acceptsCredentials: false)
    try await transport.connect(to: testHost, hostKeyValidator: AlwaysTrust())

    await #expect(throws: AppError.authenticationFailed(host: "10.1.0.9")) {
      try await transport.authenticate(.password("wrong"))
    }
  }

  @Test("a streamed command records what was started and stays open")
  func execStreamStaysOpen() async throws {
    // Unlike `execChannel`, the stream stays live after its seeded output, because a bridge
    // process does not exit.
    let transport = FakeSSHTransport()
    await transport.setStreamResponse(Data("{\"type\":\"terminal.frame\"}\n".utf8), for: "herdr terminal session control w1:p1")
    try await transport.connect(to: testHost, hostKeyValidator: AlwaysTrust())
    try await transport.authenticate(.password("hunter2"))

    let stream = try await transport.execStream(command: "herdr terminal session control w1:p1")
    #expect(await transport.streamedCommands == ["herdr terminal session control w1:p1"])

    var iterator = stream.output.makeAsyncIterator()
    let seeded = try await iterator.next()
    #expect(String(decoding: seeded ?? Data(), as: UTF8.self).contains("terminal.frame"))

    await transport.emitOnStreams(Data("{\"type\":\"terminal.closed\"}\n".utf8))
    let later = try await iterator.next()
    #expect(String(decoding: later ?? Data(), as: UTF8.self).contains("terminal.closed"))
  }

  @Test("what the caller sends is recorded, so a client's commands can be asserted")
  func execStreamRecordsInput() async throws {
    let transport = FakeSSHTransport()
    try await transport.connect(to: testHost, hostKeyValidator: AlwaysTrust())
    try await transport.authenticate(.password("hunter2"))

    let stream = try await transport.execStream(command: "bridge")
    try await stream.send(Data("{\"type\":\"terminal.scroll\",\"direction\":\"up\"}\n".utf8))

    let fake = try #require(stream as? FakeExecStream)
    let sent = fake.sent.map { String(decoding: $0, as: UTF8.self) }
    #expect(sent == ["{\"type\":\"terminal.scroll\",\"direction\":\"up\"}\n"])
  }

  @Test("stderr is delivered separately from the payload")
  func execStreamKeepsStandardErrorApart() async throws {
    let transport = FakeSSHTransport()
    try await transport.connect(to: testHost, hostKeyValidator: AlwaysTrust())
    try await transport.authenticate(.password("hunter2"))

    let stream = try await transport.execStream(command: "bridge")
    await transport.emitStandardErrorOnStreams(Data("warning: something\n".utf8))
    await transport.emitOnStreams(Data("{\"type\":\"terminal.frame\"}\n".utf8))

    var payload = stream.output.makeAsyncIterator()
    let first = try await payload.next()
    #expect(
      String(decoding: first ?? Data(), as: UTF8.self) == "{\"type\":\"terminal.frame\"}\n",
      "a diagnostic must never arrive inside the payload a client is parsing"
    )

    var errors = stream.standardError.makeAsyncIterator()
    let diagnostic = try await errors.next()
    #expect(String(decoding: diagnostic ?? Data(), as: UTF8.self).contains("warning"))
  }

  @Test("a finished stream reports how the command exited")
  func execStreamReportsExitStatus() async throws {
    // A finished stream alone cannot say whether the bridge closed cleanly or died.
    let transport = FakeSSHTransport()
    try await transport.connect(to: testHost, hostKeyValidator: AlwaysTrust())
    try await transport.authenticate(.password("hunter2"))

    let stream = try await transport.execStream(command: "bridge")
    #expect(await stream.exitStatus == nil, "still running")

    await transport.finishStreams(exitStatus: 2)

    var payload = stream.output.makeAsyncIterator()
    #expect(try await payload.next() == nil, "the stream ends when the command exits")
    #expect(await stream.exitStatus == 2)
  }

  @Test("a failing command's stderr and status both survive the end of its stream")
  func failStreamsCarriesBothHalves() async throws {
    // `finishStreams` and `endStreams` cannot model one bridge process answering with a reason
    // and a nonzero status on a healthy link.
    let transport = FakeSSHTransport()
    try await transport.connect(to: testHost, hostKeyValidator: AlwaysTrust())
    try await transport.authenticate(.password("hunter2"))

    let control = try await transport.execStream(command: "herdr terminal session control w1:p1")
    let observe = try await transport.execStream(command: "herdr terminal session observe w1:p2")

    let failed = await transport.failStreams(
      matching: { $0.contains("session control") },
      exitStatus: 1,
      standardError: "herdr: failed to request terminal attach: pane not found\n"
    )
    #expect(failed == 1, "a predicate that matched nothing would pass silently otherwise")

    var payload = control.output.makeAsyncIterator()
    #expect(try await payload.next() == nil, "the stream ends when the command exits")
    #expect(await control.exitStatus == 1)

    var errors = control.standardError.makeAsyncIterator()
    let diagnostic = try await errors.next()
    #expect(
      String(decoding: diagnostic ?? Data(), as: UTF8.self)
        == "herdr: failed to request terminal attach: pane not found\n",
      "herdr's own words, unparsed, and off the payload the client is decoding"
    )

    #expect(
      await observe.exitStatus == nil,
      "one bridge process failing is not the other one's news, nor the link's"
    )
  }

  @Test("a channel that vanished reports no exit status at all")
  func endStreamsReportsNoStatus() async throws {
    // `nil` is not zero. A channel torn down sends no `exit-status`, and a zero here would make
    // `BridgeFramePump` read a process that answered.
    let transport = FakeSSHTransport()
    try await transport.connect(to: testHost, hostKeyValidator: AlwaysTrust())
    try await transport.authenticate(.password("hunter2"))

    let stream = try await transport.execStream(command: "herdr terminal session control w1:p1")
    let ended = await transport.endStreams(matching: { $0.contains("session control") })
    #expect(ended == 1)

    var payload = stream.output.makeAsyncIterator()
    #expect(try await payload.next() == nil)
    #expect(await stream.exitStatus == nil, "nothing on the host knows this happened")
  }

  @Test("sending after the command exited fails rather than being swallowed")
  func execStreamRefusesSendAfterExit() async throws {
    let transport = FakeSSHTransport()
    try await transport.connect(to: testHost, hostKeyValidator: AlwaysTrust())
    try await transport.authenticate(.password("hunter2"))

    let stream = try await transport.execStream(command: "bridge")
    await transport.finishStreams(exitStatus: 0)

    await #expect(throws: (any Error).self) {
      try await stream.send(Data("late\n".utf8))
    }
  }
}
