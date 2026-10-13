import DriverrCore
import Foundation
import Testing

@testable import DriverrSSH

/// `ConnectionCoordinator.run(_:standardInput:)` over a scripted stream, where each ending
/// can be chosen. On a real channel the order of a send and the command's exit is a race.
@Suite("A command with standard input, over a scripted stream")
struct StandardInputExchangeTests {
  /// Not text, so a byte that is not UTF-8 shows a channel that is not binary clean.
  private func payload(_ count: Int) -> Data {
    var bytes = Data(capacity: count)
    for index in 0..<count { bytes.append(UInt8((index * 31 + 7) % 256)) }
    return bytes
  }

  @Test("the input is sent whole and in order, in chunks of the channel's packet size")
  func sendsTheInputInChunks() async throws {
    let input = payload(ImageUploader.chunkSize * 2 + 4_464)
    let stream = ScriptedStream(output: ["done\n"], standardError: "a warning\n", status: 0)

    let result = try await ConnectionCoordinator.exchange(input, over: stream)

    #expect(result == CommandResult(standardOutput: "done\n", standardError: "a warning\n", exitStatus: 0))
    #expect(stream.received.map(\.count) == [ImageUploader.chunkSize, ImageUploader.chunkSize, 4_464])
    #expect(stream.received.reduce(Data(), +) == input)
  }

  /// The hook write exits 75, 77 or 78 before it reads anything. The channel closes, the
  /// send fails, and the status is still the answer.
  @Test("a command that exits before it reads its input returns its status, and sending stops")
  func aRefusalBeforeTheReadIsNotAFailure() async throws {
    let stream = ScriptedStream(standardError: "refused\n", status: 75, acceptedSends: 0)

    let result = try await ConnectionCoordinator.exchange(payload(ImageUploader.chunkSize * 3), over: stream)

    #expect(result == CommandResult(standardOutput: "", standardError: "refused\n", exitStatus: 75))
    #expect(stream.received.isEmpty)
    #expect(stream.sendAttempts == 1, "a failed send was followed by another")
  }

  @Test("a send that fails part way stops the sending and returns the command's status")
  func aSendThatFailsPartWay() async throws {
    let stream = ScriptedStream(status: 74, acceptedSends: 1)

    let result = try await ConnectionCoordinator.exchange(payload(ImageUploader.chunkSize * 3), over: stream)

    #expect(result.exitStatus == 74)
    #expect(stream.received.count == 1)
    #expect(stream.sendAttempts == 2)
  }

  @Test("a channel that ends without an exit status is a failure, whether or not the send worked", arguments: [0, Int.max])
  func noStatusIsAChannelFailure(acceptedSends: Int) async {
    let stream = ScriptedStream(status: nil, acceptedSends: acceptedSends)
    await #expect(throws: AppError.channelFailed(reason: "The command ended without an exit status.")) {
      _ = try await ConnectionCoordinator.exchange(payload(64), over: stream)
    }
  }

  @Test("an output stream that failed still gives the status when one arrived")
  func aFailedOutputStream() async throws {
    let failure = AppError.channelFailed(reason: "The connection was reset.")
    let withStatus = ScriptedStream(output: ["partial"], outputFailure: failure, status: 1)
    let result = try await ConnectionCoordinator.exchange(payload(64), over: withStatus)
    #expect(result.exitStatus == 1)
    #expect(result.standardOutput == "partial")

    let without = ScriptedStream(outputFailure: failure, status: nil)
    await #expect(throws: AppError.channelFailed(reason: "The command ended without an exit status.")) {
      _ = try await ConnectionCoordinator.exchange(payload(64), over: without)
    }
  }

  @Test("no input sends nothing and still returns the result")
  func emptyInput() async throws {
    let stream = ScriptedStream(output: ["ok\n"], status: 0)
    let result = try await ConnectionCoordinator.exchange(Data(), over: stream)
    #expect(result.standardOutput == "ok\n")
    #expect(stream.sendAttempts == 0)
  }

  @Test("before connecting it throws not connected, as the other channels do")
  func notConnected() async {
    let coordinator = ConnectionCoordinator(transport: FakeSSHTransport())
    await #expect(throws: AppError.notConnected(host: "the host")) {
      _ = try await coordinator.run("head -c 1", standardInput: Data([0]))
    }
  }
}

/// A host that stops answering part way through a command with standard input. Nothing in
/// SSH ends such a command, so `withIdleDeadline` does.
///
/// No test here sleeps. Each one waits on the call it is testing, which the deadline ends,
/// or on a signal from its fake, and the suite's time limit turns a deadline that never
/// fires into a failure.
@Suite("A command with standard input, on a host that stops answering", .timeLimit(.minutes(1)))
struct StandardInputDeadlineTests {
  private let stalled = AppError.channelFailed(reason: "The host stopped answering before the command finished.")

  /// The start-up files of the host's shell took some of the input, so `head -c` waits for
  /// bytes that are not coming and prints nothing.
  @Test("a command that never finishes its output ends on the deadline, and the stream is closed")
  func outputThatNeverEnds() async {
    let stream = ScriptedStream(status: nil, endsOutput: false)

    await #expect(throws: stalled) {
      _ = try await ConnectionCoordinator.exchange(Data([1, 2, 3]), over: stream, idleDeadline: .milliseconds(50))
    }

    #expect(stream.received == [Data([1, 2, 3])])
    #expect(stream.closeCount == 1)
  }

  /// The case a task group cannot end: the group would wait for the send, and the close
  /// does not free it.
  @Test("a send the host never takes ends on the deadline, though the close does not free the send")
  func aSendThatParks() async {
    let stream = ScriptedStream(status: nil, parksSendsAfter: 1)
    defer { stream.release() }

    await #expect(throws: stalled) {
      _ = try await ConnectionCoordinator.exchange(
        Data(count: ImageUploader.chunkSize * 2), over: stream, idleDeadline: .milliseconds(50))
    }

    #expect(stream.received.count == 1)
    #expect(stream.closeCount == 1)
    #expect(stream.parkedSends == 1, "the abandoned send was freed, so this is not the dead-link case")
  }

  /// The deadline counts idle time. Thirty sends 30 ms apart take longer than the 600 ms
  /// deadline, and each gap is a twentieth of it, so a loaded machine does not fail this.
  @Test("bytes that keep moving hold the deadline off for longer than the deadline itself")
  func spacedSendsResetTheTimer() async throws {
    let deadline = Duration.milliseconds(600)
    let stream = ScriptedStream(output: ["done\n"], status: 0, sendDelay: .milliseconds(30))
    let started = ContinuousClock.now

    let result = try await ConnectionCoordinator.exchange(
      Data(count: ImageUploader.chunkSize * 30), over: stream, idleDeadline: deadline)

    #expect(result == CommandResult(standardOutput: "done\n", standardError: "", exitStatus: 0))
    #expect(stream.received.count == 30)
    #expect(ContinuousClock.now - started > deadline, "the exchange was too short to outlast the deadline")
    #expect(stream.closeCount == 0, "the deadline closed a stream that was still moving")
  }

  /// The deadline is far away, so only the cancellation can end the call.
  @Test("a cancelled caller gets CancellationError and a closed stream, without waiting for the deadline")
  func aCancelledCaller() async {
    let stream = ScriptedStream(status: nil, parksSendsAfter: 0)
    defer { stream.release() }
    let call = Task {
      try await ConnectionCoordinator.exchange(Data([1, 2, 3]), over: stream, idleDeadline: .seconds(3600))
    }
    // Cancels once the send is parked; a sleep here would race it.
    for await _ in stream.parked { break }
    call.cancel()

    await #expect(throws: CancellationError.self) { _ = try await call.value }
    #expect(stream.closeCount == 1)
  }

  @Test("a caller cancelled before the call sends nothing")
  func cancelledBeforeTheCall() async {
    let stream = ScriptedStream(output: ["done\n"], status: 0)
    let call = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await ConnectionCoordinator.exchange(Data([1, 2, 3]), over: stream, idleDeadline: .seconds(3600))
    }

    await #expect(throws: CancellationError.self) { _ = try await call.value }
    #expect(stream.sendAttempts == 0)
  }

  /// `FakeSSHTransport`'s stream stays open after its output, as a command still waiting
  /// for input does.
  @Test("run(_:standardInput:) uses the deadline the coordinator was made with, and closes the stream")
  func theCoordinatorsOwnDeadline() async throws {
    let transport = FakeSSHTransport()
    let coordinator = ConnectionCoordinator(transport: transport, inputIdleDeadline: .milliseconds(50))
    try await coordinator.connect(
      to: DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson"),
      validator: TOFUHostKeyValidator(store: InMemoryKnownHostsStore(), prompt: AcceptingPrompt()),
      credential: .password("hunter2")
    )

    await #expect(throws: stalled) {
      _ = try await coordinator.run("head -c 4", standardInput: Data("abc".utf8))
    }

    let log = await transport.streamLog
    #expect(log == ["open: head -c 4", "input: abc", "close: head -c 4"])
  }

  /// A fake transport that is connected, and the commands whose streams it has closed.
  private func silentHost(
    inputIdleDeadline: Duration,
    onActivity: (@Sendable () -> Void)? = nil
  ) async throws -> (FakeSSHTransport, ConnectionCoordinator, AsyncStream<String>) {
    let (closes, closed) = AsyncStream.makeStream(of: String.self)
    let transport = FakeSSHTransport(onStreamClose: { closed.yield($0) }, onActivity: onActivity)
    let coordinator = ConnectionCoordinator(transport: transport, inputIdleDeadline: inputIdleDeadline)
    try await coordinator.connect(
      to: DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson"),
      validator: TOFUHostKeyValidator(store: InMemoryKnownHostsStore(), prompt: AcceptingPrompt()),
      credential: .password("hunter2")
    )
    return (transport, coordinator, closes)
  }

  /// The link died before the command was sent, so the channel never opens. The open is
  /// under the deadline too. A channel that opens after the caller has gone must be closed,
  /// or it stays open on the host with a command waiting for input.
  @Test("a channel that never opens ends on the deadline, and one that opens late is closed with nothing sent")
  func anOpenThatStalls() async throws {
    let (transport, coordinator, closes) = try await silentHost(inputIdleDeadline: .milliseconds(50))
    // Forty times the deadline, so a loaded machine does not open the channel first.
    await transport.stopAnswering(for: .seconds(2))

    await #expect(throws: stalled) {
      _ = try await coordinator.run("head -c 4", standardInput: Data("abc".utf8))
    }

    for await _ in closes { break }
    // The fake stalls a close as it stalls an open, and logs both.
    let log = await transport.streamLog
    #expect(
      log == [
        "unanswered: head -c 4", "open: head -c 4", "unanswered: close head -c 4", "close: head -c 4",
      ])
  }

  /// The deadline is far away, so only the cancellation can end the call. An open does not
  /// check cancellation itself.
  @Test("a caller cancelled while the channel opens gets CancellationError, and the late channel is closed")
  func cancelledWhileOpening() async throws {
    let (activity, signal) = AsyncStream.makeStream(of: Void.self)
    let (transport, coordinator, closes) = try await silentHost(
      inputIdleDeadline: .seconds(3600), onActivity: { signal.yield() })
    await transport.stopAnswering()
    let call = Task { try await coordinator.run("head -c 4", standardInput: Data("abc".utf8)) }
    // Cancels once the fake has logged the open it will not answer; a sleep would race it.
    for await _ in activity {
      if await transport.streamLog == ["unanswered: head -c 4"] { break }
    }
    call.cancel()

    await #expect(throws: CancellationError.self) { _ = try await call.value }
    for await _ in closes { break }
    let log = await transport.streamLog
    #expect(
      log == [
        "unanswered: head -c 4", "open: head -c 4", "unanswered: close head -c 4", "close: head -c 4",
      ])
  }
}

/// The deadline over a real SSH handshake, exec channel and `/bin/sh`, for what happens on
/// the host after Driverr stops waiting.
///
/// **Every command here runs with `HOME` set to a scratch directory**, through
/// `EmbeddedSSHServer.init(environment:)`. That is what allows the real hook write, which
/// `StandardInputCommandTests` must never send. The hook test also asks the server's own
/// shell where the write would go, and stops unless the answer is under the scratch home.
@Suite("A stalled command against a real server", .timeLimit(.minutes(1)))
struct StalledCommandTests {
  private let stalled = AppError.channelFailed(reason: "The host stopped answering before the command finished.")

  /// A server whose commands see a scratch `HOME` and no `CLAUDE_CONFIG_DIR`, and the
  /// connections made to it.
  private final class ScratchHost: @unchecked Sendable {
    let home: URL
    private let server: EmbeddedSSHServer
    private let password: String
    private let lock = NSLock()
    private var coordinators: [ConnectionCoordinator] = []
    private var stopped = false

    init() async throws {
      home = FileManager.default.temporaryDirectory
        .appendingPathComponent("driverr-stalled-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      var environment = ProcessInfo.processInfo.environment
      environment["HOME"] = home.path
      environment["CLAUDE_CONFIG_DIR"] = nil
      password = UUID().uuidString
      server = try await EmbeddedSSHServer(
        username: "carson",
        password: password,
        executesRealCommands: true,
        environment: environment
      )
    }

    /// A new connection to the server. The deadline is per connection, so a test can stall
    /// one command in milliseconds and still run its set-up under the default.
    func connect(
      inputIdleDeadline: Duration = ConnectionCoordinator.defaultInputIdleDeadline
    ) async throws -> ConnectionCoordinator {
      let coordinator = ConnectionCoordinator(
        transport: NIOSSHTransport(), inputIdleDeadline: inputIdleDeadline)
      lock.withLock { coordinators.append(coordinator) }
      try await coordinator.connect(
        to: DriverrCore.Host(name: "embedded", hostname: "127.0.0.1", port: server.port, username: "carson"),
        validator: TOFUHostKeyValidator(store: InMemoryKnownHostsStore(), prompt: AcceptingPrompt()),
        credential: .password(password)
      )
      return coordinator
    }

    /// Disconnects and stops the server, **and waits for both**. `EmbeddedSSHServer.stop()`
    /// waits for commands still running, so after this the host's files are as the command
    /// left them. Safe to call twice.
    func stop() async {
      let open: [ConnectionCoordinator]? = lock.withLock {
        guard !stopped else { return nil }
        stopped = true
        return coordinators
      }
      guard let open else { return }
      for coordinator in open { await coordinator.disconnect() }
      await server.stop()
    }

    func remove() { try? FileManager.default.removeItem(at: home) }

    /// What the server's own shell makes of each shell word, one line each.
    ///
    /// **Call it before sending a command that writes under `$HOME`**, and stop unless the
    /// answers are under `home`. That is what keeps such a command off the real home
    /// directory if the environment did not reach the shell.
    func resolve(_ words: [String], over coordinator: ConnectionCoordinator) async throws -> [String] {
      let probe = try await coordinator.run(
        "printf '%s\\n' " + words.joined(separator: " "), standardInput: Data())
      // The last lines, because a login shell may print from its start-up files first.
      return probe.standardOutput.split(separator: "\n").suffix(words.count).map(String.init)
    }
  }

  /// Every teardown runs whether the body passes or throws, and is awaited, so nothing of
  /// one test is still running when the next starts.
  private func withScratchHost(_ body: (ScratchHost) async throws -> Void) async throws {
    let host = try await ScratchHost()
    let outcome: Result<Void, any Error>
    do {
      try await body(host)
      outcome = .success(())
    } catch {
      outcome = .failure(error)
    }
    await host.stop()
    host.remove()
    try outcome.get()
  }

  /// With no input, `run(_:standardInput:)` is a plain command under the deadline. The hook
  /// install's read goes this way.
  @Test("with no input the command's output and status come back as usual")
  func noInput() async throws {
    try await withScratchHost { host in
      let coordinator = try await host.connect()
      let result = try await coordinator.run("echo read; exit 4", standardInput: Data())
      #expect(result.standardOutput.split(separator: "\n").last == "read")
      #expect(result.exitStatus == 4)
    }
  }

  /// `cat` reads to an end of input the open channel never brings.
  @Test("a command that never exits ends on the deadline, and the connection still runs the next one")
  func aCommandThatNeverExits() async throws {
    try await withScratchHost { host in
      let coordinator = try await host.connect(inputIdleDeadline: .milliseconds(200))
      await #expect(throws: stalled) {
        _ = try await coordinator.run("cat > /dev/null", standardInput: Data())
      }
      // The stall closed one channel, not the connection.
      #expect(await coordinator.phase == .connected)
      let next = try await coordinator.openStream(command: "exit 3")
      for try await _ in next.output {}
      #expect(await next.exitStatus == 3)
      await next.close()
    }
  }

  /// The real hook write, one byte short of what its `head -c` waits for, as when a start-up
  /// file of the host's shell took a byte.
  ///
  /// When Driverr gives up it closes the channel, `head` sees the end of its input, and the
  /// write's own checksum refuses the short copy and removes it. The write makes its backup
  /// just before it reads its input, so the backup shows the command got that far.
  @Test("a hook write that stalls leaves settings.json as it was, and no part file")
  func aStalledHookWriteLeavesTheSettingsFile() async throws {
    try await withScratchHost { host in
      let claude = AgentIntegration.claudeCode
      let directory = host.home.appendingPathComponent(".claude", isDirectory: true)
      let settings = directory.appendingPathComponent("settings.json")
      let original = "{}\n"
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(original.utf8).write(to: settings)

      // **Before the write is sent.** The server's own shell says what `$HOME` is and where
      // the write's `d=` points. Anything but the scratch home stops the test here, so the
      // write cannot reach a real `~/.claude`.
      let patient = try await host.connect()
      try #require(
        try await host.resolve(["\"$HOME\"", claude.configDirectory], over: patient)
          == [host.home.path, directory.path],
        "the server's shell does not resolve the settings directory under the scratch home")

      let plan = try #require(
        try HookInstallCommands.plan(
          for: claude, read: .present(text: original, checksum: POSIXChecksum(of: original.utf8))))
      let short = Data(plan.settingsText.utf8).dropLast()

      let hurried = try await host.connect(inputIdleDeadline: .milliseconds(200))
      await #expect(throws: stalled) {
        _ = try await hurried.run(plan.command, standardInput: short)
      }

      await host.stop()
      #expect(try String(contentsOf: settings, encoding: .utf8) == original)
      #expect(!FileManager.default.fileExists(atPath: settings.path + ".driverr-part"))
      #expect(
        try String(contentsOfFile: settings.path + ".driverr-backup", encoding: .utf8) == original,
        "the write ended before it reached its read of standard input")
    }
  }

  /// The key install runs through `run(_:standardInput:)` with no input, for the deadline.
  /// The channel has no half-close, so the command's standard input stays open and never
  /// ends. The command must finish without reading it.
  @Test("the key install command finishes with its standard input left open and empty")
  func theKeyInstallReadsNoInput() async throws {
    try await withScratchHost { host in
      let coordinator = try await host.connect()
      // **Before the install is sent.** It appends to `$HOME/.ssh/authorized_keys`.
      try #require(
        try await host.resolve(["\"$HOME\""], over: coordinator) == [host.home.path],
        "the server's shell does not have the scratch home")
      let identity = SSHIdentity(name: "Driverr key", publicKeyBlob: Data((0..<51).map { UInt8($0) }))

      let result = try await coordinator.run(
        AuthorizedKeyInstallCommands.install(identity), standardInput: Data())

      #expect(result.exitStatus == 0)
      #expect(result.standardOutput.split(separator: "\n").last == "installed")
      let keys = host.home.appendingPathComponent(".ssh/authorized_keys")
      #expect(
        try String(contentsOf: keys, encoding: .utf8)
          == AuthorizedKeyInstallCommands.authorizedKeysLine(for: identity) + "\n")
    }
  }

  /// The real upload command, told to expect one byte more than is sent. The `.part` stays
  /// for the next sweep, as after any short upload, and the rename never runs.
  @Test("an upload that stalls fails as stalled, and no file appears in the inbox")
  func aStalledUploadLeavesNoFile() async throws {
    try await withScratchHost { host in
      let inbox = host.home.appendingPathComponent("inbox", isDirectory: true)
      let bytes = Data(repeating: 0x5A, count: 4096)
      let uploader = ImageUploader(
        coordinator: try await host.connect(),
        bytes: bytes,
        command: InboxUploadCommand.forUpload(
          fileName: "stalled.png", byteCount: bytes.count + 1, inboxDirectory: shellQuoted(inbox.path)),
        idleDeadline: .milliseconds(200)
      )

      await #expect(throws: ImageUploadFailure.stalled) { try await uploader.upload() }

      await host.stop()
      #expect(!FileManager.default.fileExists(atPath: inbox.appendingPathComponent("stalled.png").path))
    }
  }
}

/// The same call over a real SSH handshake and exec channel, with a real `/bin/sh`.
///
/// **Every command here writes only under a scratch directory.** `EmbeddedSSHServer` runs
/// `/bin/sh -lc` with the test process's `HOME`. Never send it `HookInstallCommands`' write:
/// it would edit the developer's own `~/.claude/settings.json`. `StalledCommandTests` sends
/// that write, to a server whose `HOME` is a scratch directory.
@Suite("A command with standard input against a real server")
struct StandardInputCommandTests {
  private func withConnection(
    _ body: (ConnectionCoordinator, URL) async throws -> Void
  ) async throws {
    let password = UUID().uuidString
    let server = try await EmbeddedSSHServer(
      username: "carson",
      password: password,
      executesRealCommands: true
    )
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("driverr-stdin-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let host = DriverrCore.Host(
      name: "embedded",
      hostname: "127.0.0.1",
      port: server.port,
      username: "carson"
    )
    let coordinator = ConnectionCoordinator(transport: NIOSSHTransport())
    // Every teardown in a `defer`, the client's too, or a throwing body leaks the transport's
    // event loop group.
    defer {
      Task {
        await coordinator.disconnect()
        await server.stop()
      }
      try? FileManager.default.removeItem(at: scratch)
    }

    try await coordinator.connect(
      to: host,
      validator: TOFUHostKeyValidator(
        store: InMemoryKnownHostsStore(),
        prompt: AcceptingPrompt()
      ),
      credential: .password(password)
    )

    try await body(coordinator, scratch)
  }

  /// The largest file a hook install writes, and bytes that are not text.
  private func payload(_ count: Int = 96 * 1024) -> Data {
    var bytes = Data(capacity: count)
    for index in 0..<count { bytes.append(UInt8((index * 31 + 7) % 256)) }
    return bytes
  }

  private func lastLine(of text: String) -> String? {
    text.split(separator: "\n").last.map(String.init)
  }

  /// The command is what `HookInstallCommands`' write does with its input, and nothing else
  /// of it: `head -c` into a file, then `cksum` of the file.
  @Test("the input lands byte for byte, and the output, stderr and status come back")
  func theInputReachesTheCommand() async throws {
    try await withConnection { coordinator, scratch in
      let bytes = payload()
      let landed = scratch.appendingPathComponent("landed")
      let script = [
        "p=\(shellQuoted(landed.path))",
        "head -c \(bytes.count) > \"$p\" || exit 1",
        "cksum < \"$p\"",
        "echo checked >&2",
        "exit 3",
      ].joined(separator: "\n")

      let result = try await coordinator.run("sh -c \(shellQuoted(script))", standardInput: bytes)

      #expect(try Data(contentsOf: landed) == bytes)
      // The last line of each stream, because the server's login shell may print from its
      // own start-up files first. What the command printed is still compared exactly.
      #expect(lastLine(of: result.standardOutput) == POSIXChecksum(of: bytes).text)
      #expect(lastLine(of: result.standardError) == "checked")
      #expect(result.exitStatus == 3)
    }
  }

  /// The command exits while the input is still being sent. Whether a send fails is a
  /// race, so only the result is asserted; `StandardInputExchangeTests` pins the path.
  @Test("a command that exits without reading its input returns its status instead of hanging")
  func aCommandThatNeverReads() async throws {
    try await withConnection { coordinator, _ in
      let result = try await coordinator.run(
        "echo unread; echo refused >&2; exit 75", standardInput: payload())
      #expect(result.exitStatus == 75)
      #expect(lastLine(of: result.standardOutput) == "unread")
      #expect(lastLine(of: result.standardError) == "refused")
    }
  }

  @Test("a second command runs on the same connection after one that never read")
  func theConnectionSurvivesARefusal() async throws {
    try await withConnection { coordinator, scratch in
      _ = try await coordinator.run("exit 77", standardInput: payload())
      let landed = scratch.appendingPathComponent("second")
      let bytes = payload(1_000)
      let result = try await coordinator.run(
        "head -c \(bytes.count) > \(shellQuoted(landed.path))", standardInput: bytes)
      #expect(result.exitStatus == 0)
      #expect(try Data(contentsOf: landed) == bytes)
    }
  }
}

/// An `ExecStream` whose output, stderr and status are fixed when it is made, and whose
/// `send` starts failing after a set number of calls, as a closed channel's does.
///
/// It can also stall, as a host that stopped answering does. `endsOutput: false` leaves both
/// output streams open until `close()`. `parksSendsAfter` makes every later `send` wait until
/// `release()`: **`close()` does not free a parked send**, because a write on a dead link
/// fails only when the peer answers the close.
private final class ScriptedStream: ExecStream, @unchecked Sendable {
  let output: AsyncThrowingStream<Data, any Error>
  let standardError: AsyncThrowingStream<Data, any Error>
  /// Yields each time a `send` parks, so a test can wait for one without a sleep.
  let parked: AsyncStream<Void>

  private let status: Int?
  private let acceptedSends: Int
  private let parksSendsAfter: Int
  private let sendDelay: Duration
  private let outputContinuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let errorContinuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let parkedSignal: AsyncStream<Void>.Continuation
  private let lock = NSLock()
  private var accepted: [Data] = []
  private var attempts = 0
  private var closes = 0
  private var waiting: [CheckedContinuation<Void, Never>] = []
  private var released = false

  init(
    output: [String] = [],
    outputFailure: (any Error)? = nil,
    standardError: String = "",
    status: Int?,
    acceptedSends: Int = .max,
    endsOutput: Bool = true,
    parksSendsAfter: Int = .max,
    sendDelay: Duration = .zero
  ) {
    self.status = status
    self.acceptedSends = acceptedSends
    self.parksSendsAfter = parksSendsAfter
    self.sendDelay = sendDelay
    let (out, outContinuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
    for chunk in output { outContinuation.yield(Data(chunk.utf8)) }
    self.output = out
    outputContinuation = outContinuation
    let (err, errContinuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
    if !standardError.isEmpty { errContinuation.yield(Data(standardError.utf8)) }
    self.standardError = err
    errorContinuation = errContinuation
    (parked, parkedSignal) = AsyncStream.makeStream(of: Void.self)
    if endsOutput {
      outContinuation.finish(throwing: outputFailure)
      errContinuation.finish()
    }
  }

  var exitStatus: Int? {
    get async { status }
  }

  var received: [Data] { lock.withLock { accepted } }
  var sendAttempts: Int { lock.withLock { attempts } }
  var closeCount: Int { lock.withLock { closes } }
  /// Sends waiting for `release()`.
  var parkedSends: Int { lock.withLock { waiting.count } }

  func send(_ data: Data) async throws {
    let parks = lock.withLock {
      attempts += 1
      return attempts > parksSendsAfter
    }
    if parks {
      await withCheckedContinuation { continuation in
        let isReleased = lock.withLock {
          if !released { waiting.append(continuation) }
          return released
        }
        if isReleased { continuation.resume() } else { parkedSignal.yield() }
      }
      throw AppError.channelFailed(reason: "The command is no longer running.")
    }
    if sendDelay > .zero { try? await Task.sleep(for: sendDelay) }
    let isAccepted = lock.withLock {
      guard accepted.count < acceptedSends else { return false }
      // A copy, so the chunk is compared as its own `Data` and not as a slice.
      accepted.append(Data(data))
      return true
    }
    if !isAccepted { throw AppError.channelFailed(reason: "The command is no longer running.") }
  }

  /// Finishes the output streams, as the real channel's close does, and leaves a parked send
  /// parked.
  func close() async {
    lock.withLock { closes += 1 }
    outputContinuation.finish()
    errorContinuation.finish()
  }

  /// Fails every parked send, as the peer's answer to a close does. A test calls it before
  /// it ends, because a continuation that is never resumed is reported as a leak.
  func release() {
    let freed = lock.withLock {
      released = true
      defer { waiting = [] }
      return waiting
    }
    for continuation in freed { continuation.resume() }
    parkedSignal.finish()
  }
}
