#if DEBUG
import DriverrCore
import Foundation

/// An `SSHTransport` that never touches the network.
///
/// It ships in the module, not the test target, because stores, previews, demo mode and
/// the UI suite all need it. It runs the same state machine as `NIOSSHTransport`.
public actor FakeSSHTransport: SSHTransport {
  private enum State {
    case disconnected
    /// Key exchange finished; no credential accepted yet.
    case connected
    case authenticated
  }

  private var state: State = .disconnected
  private var responses: [String: CommandResult]
  private let acceptsCredentials: Bool
  /// When `false`, a private key is refused while a password is still accepted: a host
  /// where a key was installed and sshd does not read it.
  private let acceptsPrivateKeys: Bool
  /// Written to every PTY the moment it opens, if set. Off by default so the echo tests
  /// see their own bytes first.
  private let ptyGreeting: String?
  /// When set, a resized PTY writes its new dimensions back at the terminal. A real shell
  /// does not do this. It lets a UI test tell a view relayout from a channel resize.
  private let announcesResizes: Bool
  /// When set, echoed control bytes come back as caret notation (`0x03` as `^C`), as a
  /// canonical-mode tty does. Off by default so the echo tests see exactly what they sent.
  private let echoesControlAsCaret: Bool
  /// When cleared, the PTY swallows input instead of echoing it. The App Store tour
  /// clears it so the echo of `herdr agent attach` does not land after the transcript.
  private let echoesInput: Bool
  /// How long `connect` waits before it does anything. Models a host that accepts TCP
  /// and never finishes the handshake, which is what `ConnectionCoordinator`'s deadline
  /// is for.
  private let handshakeStall: Duration?
  /// When set, `connect` parks on a promise that cancellation cannot resume. Only
  /// `disconnect()` settles it.
  ///
  /// `NIOSSHTransport.connect` waits on futures that ignore cancellation and fail only
  /// when the channel closes. A `Task.sleep` stall cannot model that, so this one forces
  /// `ConnectionCoordinator`'s deadline to tear the transport down.
  private let hangsUntilDisconnected: Bool
  /// Handshakes parked on `hangsUntilDisconnected`. `disconnect()` always resumes them,
  /// because a dropped `CheckedContinuation` logs a runtime misuse warning.
  private var parkedHandshakes: [CheckedContinuation<Void, any Error>] = []
  private var openChannels: [FakePTYChannel] = []
  private var openStreams: [FakeExecStream] = []
  /// Remembered from `connect` so failures name the host that refused, as
  /// `NIOSSHTransport`'s do.
  private var connectedHost: DriverrCore.Host?
  /// The closure signal for the current connection. Every `connect` rebuilds it, so a
  /// loss cannot reach the next connection. See `SSHTransport.disconnections`.
  private var closureStream: AsyncStream<AppError>?
  private var closureSignal: AsyncStream<AppError>.Continuation?

  /// Every credential the fake was offered, so a store's auth flow can be asserted on.
  public private(set) var authenticationAttempts: [SSHAuthMethod] = []
  /// Every host this fake was asked to connect to, in order, recorded before the key is
  /// validated so refused attempts count too.
  ///
  /// It holds the whole `Host`, not the hostname, so a test can prove that an edited port
  /// reaches the connection.
  public private(set) var connectionAttempts: [DriverrCore.Host] = []
  /// How many times Driverr asked this transport to disconnect.
  ///
  /// A leaked link is otherwise invisible to a test. `drop()` and `signalLoss()` do not
  /// count, so a test can tell a lost link from one Driverr retired.
  public private(set) var disconnectCount = 0
  /// The most recent size a PTY was created at or resized to.
  public private(set) var lastPTYSize: TerminalSize?
  /// The host key the fake presents to the validator during `connect`.
  public let presentedHostKey: SSHHostKey

  /// Called whenever the fake records something a test may wait for.
  ///
  /// The recorded values are actor state, which `withObservationTracking` cannot see, so
  /// without this hook a test could only poll a wall clock. It is `nonisolated` so the
  /// fake's synchronous `@Sendable` closures can call it.
  private nonisolated let onActivity: (@Sendable () -> Void)?

  /// Notifies `onActivity`, if a test set one.
  private nonisolated func note() { onActivity?() }

  public init(
    responses: [String: CommandResult] = [:],
    acceptsCredentials: Bool = true,
    acceptsPrivateKeys: Bool = true,
    presentedHostKey: SSHHostKey = FakeSSHTransport.defaultHostKey,
    ptyGreeting: String? = nil,
    announcesResizes: Bool = false,
    echoesControlAsCaret: Bool = false,
    echoesInput: Bool = true,
    handshakeStall: Duration? = nil,
    hangsUntilDisconnected: Bool = false,
    streamResponder: (@Sendable (String) -> Data?)? = nil,
    onStreamClose: (@Sendable (String) -> Void)? = nil,
    onActivity: (@Sendable () -> Void)? = nil
  ) {
    self.responses = responses
    self.acceptsCredentials = acceptsCredentials
    self.acceptsPrivateKeys = acceptsPrivateKeys
    self.presentedHostKey = presentedHostKey
    self.ptyGreeting = ptyGreeting
    self.announcesResizes = announcesResizes
    self.echoesControlAsCaret = echoesControlAsCaret
    self.echoesInput = echoesInput
    self.handshakeStall = handshakeStall
    self.hangsUntilDisconnected = hangsUntilDisconnected
    self.streamResponder = streamResponder
    self.onStreamClose = onStreamClose
    self.onActivity = onActivity
  }

  /// A stable, obviously fake key so a snapshot of the TOFU prompt is deterministic.
  public static let defaultHostKey = SSHHostKey(
    algorithm: "ssh-ed25519",
    blob: Data("driverr-fake-host-key".utf8)
  )

  /// Seeds a command's result after construction, for tests that connect first.
  public func stub(command: String, result: CommandResult) {
    responses[command] = result
  }

  public func connect(to host: DriverrCore.Host, hostKeyValidator: any HostKeyValidator) async throws {
    connectionAttempts.append(host)
    if let handshakeStall { try await Task.sleep(for: handshakeStall) }
    if hangsUntilDisconnected {
      try await withCheckedThrowingContinuation { continuation in
        parkedHandshakes.append(continuation)
      }
    }
    switch await hostKeyValidator.validate(presentedHostKey, for: host) {
    case .reject:
      state = .disconnected
      throw AppError.hostKeyRejected(host: host.hostname)
    case .mismatch:
      state = .disconnected
      throw AppError.hostKeyMismatch(host: host.hostname)
    case .trust:
      connectedHost = host
      state = .connected
      armClosureSignal()
    }
  }

  public func authenticate(_ method: SSHAuthMethod) async throws {
    guard case .connected = state else {
      throw AppError.channelFailed(reason: "Not connected.")
    }
    authenticationAttempts.append(method)
    guard acceptsCredentials else {
      throw AppError.authenticationFailed(host: connectedHost?.hostname ?? "unknown host")
    }
    if case .privateKey = method, !acceptsPrivateKeys {
      throw AppError.authenticationFailed(host: connectedHost?.hostname ?? "unknown host")
    }
    state = .authenticated
  }

  public func ptyChannel(size: TerminalSize) async throws -> any PTYChannel {
    try requireAuthenticated()
    lastPTYSize = size
    let channel = FakePTYChannel(
      transport: self,
      announcesResizes: announcesResizes,
      echoesControlAsCaret: echoesControlAsCaret,
      echoesInput: echoesInput
    )
    openChannels.append(channel)
    if let ptyGreeting { channel.emit(ptyGreeting) }
    return channel
  }

  /// Every streamed command this fake was asked to start, in order.
  public private(set) var streamedCommands: [String] = []

  /// Every streamed-command event in one timeline: `open: <command>`, `input: <line>` for
  /// each stdin line, `close: <command>`, and `unanswered: …` for a stall.
  ///
  /// One list, because tests assert the order between kinds. For example, a pane switch
  /// must open the new observer before it releases the controller, and must send the
  /// scroll home before the release.
  public private(set) var streamLog: [String] = []

  /// Scripted answers for `execStream`, keyed by command. The bytes are emitted when the
  /// command starts, and the stream then stays open.
  private var streamResponses: [String: Data] = [:]

  /// Answers a streamed command with bytes computed from it.
  ///
  /// This lets the app supply herdr frames without `DriverrSSH` knowing herdr's protocol.
  /// A keyed entry cannot do it, because the bridge command carries the caller's
  /// `--cols`/`--rows`.
  public let streamResponder: (@Sendable (String) -> Data?)?

  /// Called when a streamed command's channel closes, with its command.
  ///
  /// herdr returns its attach token when the controlling client's socket closes. A test
  /// that models the token needs to hear the close as it happens. A link that is lost
  /// closes nothing, so this does not fire for it.
  public let onStreamClose: (@Sendable (String) -> Void)?

  /// Seeds the bytes a streamed command emits when it starts.
  public func setStreamResponse(_ data: Data, for command: String) {
    streamResponses[command] = data
  }

  /// A host that has stopped answering without closing the link.
  ///
  /// This differs from `drop()`, which tells Driverr something failed. Here nothing is
  /// ever said, so a caller with no deadline of its own waits forever.
  /// - Parameter duration: how long each command stalls. The default outlives any
  ///   deadline. A short one lets the command finish after the caller gave up, which is
  ///   how a test reaches the abandoned-step cases `TerminalSceneModel` guards against.
  public func stopAnswering(for duration: Duration = .seconds(3600)) {
    stall = duration
  }

  private var stall: Duration?

  /// Holds every write to a streamed command's stdin for `duration`, except a
  /// `terminal.release`, so a test can order the hand-back against slow input.
  public func delayInput(by duration: Duration) {
    inputDelay = duration
  }

  private var inputDelay: Duration?

  fileprivate func awaitInputDelayIfAny(for data: Data) async {
    guard let inputDelay,
      !String(decoding: data, as: UTF8.self).contains("terminal.release")
    else { return }
    try? await Task.sleep(for: inputDelay)
  }

  /// How many stalled commands have finished stalling.
  ///
  /// Monotonic on purpose. The state an abandoned step leaves behind can look the same as
  /// the state before it ran, so a poll can miss it. A rising count cannot be missed.
  public private(set) var releasedStalls = 0

  public func execStream(command: String) async throws -> any ExecStream {
    try requireAuthenticated()
    if let stall {
      streamLog.append("unanswered: \(command)")
      note()
      // A sleep, not a continuation nobody resumes: a leaked `CheckedContinuation` logs a
      // runtime misuse warning.
      try? await Task.sleep(for: stall)
      releasedStalls += 1
      note()
    }
    streamedCommands.append(command)
    streamLog.append("open: \(command)")
    note()
    let stream = FakeExecStream(transport: self, command: command)
    openStreams.append(stream)
    if let seeded = streamResponses[command] ?? streamResponder?(command) {
      stream.emit(seeded)
    }
    return stream
  }

  /// Emits bytes on every open stream, as if the far side had written them.
  public func emitOnStreams(_ data: Data) {
    for stream in openStreams { stream.emit(data) }
  }

  /// Emits bytes only on the open streams whose command `matches`.
  ///
  /// Use this when a pane holds two streams, such as an `observe` beside a `control`, and
  /// only one of them should receive the record.
  ///
  /// - Returns: how many open streams were written to. A closed stream is not counted,
  ///   because its continuation is finished and the write reaches nobody. Assert on the
  ///   count, or a predicate that matches nothing passes silently.
  @discardableResult
  public func emitOnStreams(_ data: Data, matching matches: @Sendable (String) -> Bool) -> Int {
    var written = 0
    for stream in openStreams where matches(stream.commandName) {
      guard stream.isOpen else { continue }
      stream.emit(data)
      written += 1
    }
    return written
  }

  /// Emits on stderr instead, so a test can prove diagnostics stay out of the payload.
  public func emitStandardErrorOnStreams(_ data: Data) {
    for stream in openStreams { stream.emitStandardError(data) }
  }

  /// Ends every open stream, as if the remote command had exited.
  public func finishStreams(exitStatus: Int = 0) {
    for stream in openStreams { stream.finish(exitStatus: exitStatus) }
    openStreams.removeAll()
  }

  /// Ends only the streams whose command `matches`, as a remote process that refuses
  /// ends one: a line on stderr, then a nonzero exit status, on a healthy link.
  ///
  /// stderr is written before the status, the order a real process produces them.
  /// `close()` is not called, so `onStreamClose` does not fire: the process exited on its
  /// own.
  ///
  /// - Returns: how many streams were ended. Assert on it, or a predicate that matches
  ///   nothing passes silently.
  @discardableResult
  public func failStreams(
    matching matches: @Sendable (String) -> Bool,
    exitStatus: Int = 1,
    standardError: String = ""
  ) -> Int {
    let failing = openStreams.filter { matches($0.commandName) }
    for stream in failing {
      if !standardError.isEmpty {
        stream.emitStandardError(Data(standardError.utf8))
      }
      stream.finish(exitStatus: exitStatus)
    }
    openStreams.removeAll { stream in failing.contains { $0 === stream } }
    return failing.count
  }

  /// Ends only the streams whose command `matches`, with no exit status and nothing
  /// written first.
  ///
  /// This models one bridge stream stopping on a healthy link without the host saying
  /// anything, for example a restarted herdr or a channel that died while the phone was
  /// suspended. `BridgeFramePump` reads it as `TerminalCloseReason.streamEnded`. `close()`
  /// is not called, so nothing is logged and `onStreamClose` does not fire.
  ///
  /// - Returns: how many streams were ended. Assert on it, or a predicate that matches
  ///   nothing passes silently.
  @discardableResult
  public func endStreams(matching matches: @Sendable (String) -> Bool) -> Int {
    let ending = openStreams.filter { matches($0.commandName) }
    for stream in ending { stream.endWithoutStatus() }
    openStreams.removeAll { stream in ending.contains { $0 === stream } }
    return ending.count
  }

  public func execChannel(command: String) async throws -> CommandResult {
    try requireAuthenticated()
    // Every `HerdrControl` command comes through here, so a silent host stalls it as well
    // as `execStream`.
    if let stall {
      streamLog.append("unanswered: \(command)")
      note()
      try? await Task.sleep(for: stall)
      releasedStalls += 1
      note()
    }
    if let seeded = responses[command] { return seeded }
    // Match a real shell's answer to an unknown command, so callers that branch on exit
    // status behave the same.
    return CommandResult(
      standardOutput: "",
      standardError: "\(command): command not found\n",
      exitStatus: 127
    )
  }

  public func disconnect() async {
    disconnectCount += 1
    note()
    // Finished, never yielded to: a closure Driverr asked for is not a loss.
    closureSignal?.finish()
    closureSignal = nil
    // Before the channels. A real transport gets this for free, because closing the NIO
    // channel fails every promise waiting on it.
    failParkedHandshakes()
    await tearDownChannels()
    state = .disconnected
  }

  /// Ends every handshake parked on `hangsUntilDisconnected`, as a closed channel ends
  /// the futures a real handshake waits on.
  private func failParkedHandshakes() {
    let parked = parkedHandshakes
    parkedHandshakes = []
    let hostname = connectionAttempts.last?.hostname ?? "the host"
    for continuation in parked {
      continuation.resume(
        throwing: AppError.connectionFailed(
          host: hostname,
          reason: "The connection was closed before the handshake finished."
        )
      )
    }
  }

  public var disconnections: AsyncStream<AppError> {
    // With nothing connected, return a finished stream so no caller waits forever.
    closureStream ?? AsyncStream { $0.finish() }
  }

  /// Drops the connection the way a network does, without warning.
  ///
  /// It calls `signalLoss()` and then `tearDownEveryChannel()`. A real transport does not
  /// order the two: `NIOSSHTransport` reports the loss from the parent channel's
  /// `closeFuture` and each stream's end from a child's `channelInactive`, and children
  /// often close first. Call the two halves directly to test the child-first order.
  public func drop() async {
    guard closureSignal != nil else { return }
    await signalLoss()
    await tearDownEveryChannel()
  }

  /// The half of a drop that tells every watcher the link is gone. It touches no channel.
  /// See `drop()`.
  public func signalLoss() async {
    guard let closureSignal else { return }
    closureSignal.yield(
      .disconnected(reason: "\(connectedHost?.hostname ?? "The host") is no longer reachable.")
    )
    closureSignal.finish()
    self.closureSignal = nil
  }

  /// The half of a drop that ends every channel and stream and tells nobody.
  ///
  /// Each stream ends with nothing written on it. That is how a caller tells a lost link
  /// from a session herdr ended, because herdr writes a `terminal.closed` record first.
  public func tearDownEveryChannel() async {
    await tearDownChannels()
    state = .disconnected
  }

  private func armClosureSignal() {
    closureSignal?.finish()
    let (stream, continuation) = AsyncStream<AppError>.makeStream(of: AppError.self)
    closureStream = stream
    closureSignal = continuation
  }

  private func tearDownChannels() async {
    for channel in openChannels { await channel.close() }
    openChannels.removeAll()
    for stream in openStreams { await stream.close() }
    openStreams.removeAll()
  }

  fileprivate func recordResize(_ size: TerminalSize) {
    lastPTYSize = size
  }

  /// Logs one `input:` entry per NDJSON line, so a test counts records, not writes.
  fileprivate func recordStreamInput(_ data: Data, from stream: FakeExecStream) {
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
      streamLog.append("input: \(line)")
      guard line.contains("terminal.release") else { continue }
      // herdr answers every release with this record on the same stream.
      stream.emit(Data("{\"type\":\"terminal.closed\",\"reason\":\"detached\"}\n".utf8))
    }
    // Once, after the loop, so a woken waiter sees every line of the write.
    note()
  }

  fileprivate func recordStreamClose(_ command: String) {
    streamLog.append("close: \(command)")
    note()
    onStreamClose?(command)
  }

  private func requireAuthenticated() throws {
    guard case .authenticated = state else {
      throw AppError.channelFailed(reason: "Not connected.")
    }
  }

  /// Stalls a close the same way `execStream` and `execChannel` stall an open.
  ///
  /// A hand-back's network step is the close. Without this stall no `close()` could hang,
  /// and a test could not reach the case `TerminalSceneModel.close()`'s per-entry bound
  /// exists for: one unanswered hand-back starving the entries behind it.
  fileprivate func awaitCloseStallIfAny(for command: String) async {
    guard let stall else { return }
    streamLog.append("unanswered: close \(command)")
    note()
    // A sleep, for the reason in `execStream`.
    try? await Task.sleep(for: stall)
    releasedStalls += 1
    note()
  }
}

/// A PTY that echoes whatever is written to it, which proves the byte path end to end.
final class FakePTYChannel: PTYChannel {
  let output: AsyncThrowingStream<Data, any Error>
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let transport: FakeSSHTransport
  private let announcesResizes: Bool
  /// See `FakeSSHTransport.echoesControlAsCaret`.
  private let echoesControlAsCaret: Bool
  /// See `FakeSSHTransport.echoesInput`.
  private let echoesInput: Bool

  init(
    transport: FakeSSHTransport,
    announcesResizes: Bool = false,
    echoesControlAsCaret: Bool = false,
    echoesInput: Bool = true
  ) {
    self.transport = transport
    self.announcesResizes = announcesResizes
    self.echoesControlAsCaret = echoesControlAsCaret
    self.echoesInput = echoesInput
    (output, continuation) = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self
    )
  }

  /// Writes bytes to the terminal side, as the remote shell would.
  func emit(_ text: String) {
    continuation.yield(Data(text.utf8))
  }

  func send(_ data: Data) async throws {
    guard echoesInput else { return }
    continuation.yield(echoesControlAsCaret ? Self.caretNotation(data) : data)
  }

  /// `0x03` becomes `^C`, as a tty echoes it. Tab, line feed and carriage return pass
  /// through, because the emulator lays the screen out with them.
  private static func caretNotation(_ data: Data) -> Data {
    var out = Data()
    for byte in data {
      switch byte {
      case 0x09, 0x0A, 0x0D:
        out.append(byte)
      case 0x00...0x1F:
        out.append(contentsOf: [UInt8(ascii: "^"), byte + 0x40])
      case 0x7F:
        out.append(contentsOf: Array("^?".utf8))
      default:
        out.append(byte)
      }
    }
    return out
  }

  func resize(to size: TerminalSize) async throws {
    await transport.recordResize(size)
    if announcesResizes {
      emit("\r\n[resized \(size.columns)x\(size.rows)]\r\n")
    }
  }

  func close() async {
    continuation.finish()
  }
}

/// A scripted `ExecStream`. It stays open after its seeded output, as a bridge process
/// does.
final class FakeExecStream: ExecStream, @unchecked Sendable {
  let output: AsyncThrowingStream<Data, any Error>
  let standardError: AsyncThrowingStream<Data, any Error>

  private let outputContinuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let errorContinuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let transport: FakeSSHTransport
  /// Logged on close. An observer's `release()` writes nothing, so the close is its only
  /// trace.
  private let command: String
  private let lock = NSLock()
  private var status: Int?
  private var closed = false

  /// The command this stream runs, so the transport can pick out one stream.
  var commandName: String { command }

  /// Everything written to the command's stdin, in order.
  private var written: [Data] = []

  init(transport: FakeSSHTransport, command: String = "") {
    self.transport = transport
    self.command = command
    (output, outputContinuation) = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self
    )
    (standardError, errorContinuation) = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self,
      bufferingPolicy: .bufferingNewest(32)
    )
  }

  var exitStatus: Int? {
    // `withLock`, because bare `lock()`/`unlock()` is unavailable from an async context
    // under strict concurrency.
    get async { lock.withLock { status } }
  }

  var sent: [Data] { lock.withLock { written } }

  /// Whether this stream can still deliver anything. A finished continuation drops every
  /// later `emit`.
  var isOpen: Bool { lock.withLock { !closed } }

  func send(_ data: Data) async throws {
    await transport.awaitInputDelayIfAny(for: data)
    let isClosed = lock.withLock {
      if !closed { written.append(data) }
      return closed
    }
    if isClosed {
      throw AppError.channelFailed(reason: "The command is no longer running.")
    }
    await transport.recordStreamInput(data, from: self)
  }

  func emit(_ data: Data) {
    outputContinuation.yield(data)
  }

  func emit(_ text: String) {
    emit(Data(text.utf8))
  }

  func emitStandardError(_ data: Data) {
    errorContinuation.yield(data)
  }

  func finish(exitStatus: Int) {
    lock.withLock {
      status = exitStatus
      closed = true
    }
    outputContinuation.finish()
    errorContinuation.finish()
  }

  /// Ends the stream as a torn-down channel does. See
  /// `FakeSSHTransport.endStreams(matching:)`.
  ///
  /// `exitStatus` stays `nil` on purpose. `HerdrStream.end` carries a status through, and
  /// `BridgeFramePump` would then read `.processFailed` instead of `.streamEnded`.
  func endWithoutStatus() {
    lock.withLock { closed = true }
    outputContinuation.finish()
    errorContinuation.finish()
  }

  func close() async {
    await transport.awaitCloseStallIfAny(for: command)
    let wasOpen = lock.withLock {
      let wasOpen = !closed
      closed = true
      return wasOpen
    }
    outputContinuation.finish()
    errorContinuation.finish()
    if wasOpen { await transport.recordStreamClose(command) }
  }
}
#endif
