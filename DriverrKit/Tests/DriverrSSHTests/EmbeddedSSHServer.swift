import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// A real SSH server, in-process, on an ephemeral loopback port. It exercises
/// `NIOSSHTransport`'s handshake, auth and channels with no reachable machine, no
/// credentials on disk and no change to the developer's `sshd`.
final class EmbeddedSSHServer: @unchecked Sendable {
  private let group: MultiThreadedEventLoopGroup
  private let channel: Channel

  let port: Int
  /// Whether this server was asked for a pseudo-terminal. Per server, so parallel tests
  /// cannot see each other's answer.
  let ptyRequests: PseudoTerminalRequestLog
  /// The key this server presents.
  let hostPublicKey: NIOSSHPublicKey
  /// Real commands started and not yet finished reporting. See `stop()`.
  private let runningCommands = RunningCommandLog()

  /// - Parameter executesRealCommands: run exec requests as real processes instead of the
  ///   canned `echo`/`fail` set. Off by default, because such a server can do anything.
  /// - Parameter truncatesStandardInputAfter: deliver only this many bytes of stdin to the
  ///   real command, then close it. A client cannot make a transfer arrive short, because
  ///   `ExecStream.close()` closes the whole channel and takes the exit status with it.
  /// - Parameter environment: the whole environment of every real command, in place of the
  ///   test process's own. For a command that writes under `$HOME`, so it writes under a
  ///   scratch directory. `nil` inherits.
  init(
    username: String,
    password: String,
    authorizedKey: NIOSSHPublicKey? = nil,
    executesRealCommands: Bool = false,
    truncatesStandardInputAfter: Int? = nil,
    environment: [String: String]? = nil
  ) async throws {
    // A write to the stdin of a command that has exited raises SIGPIPE, which kills the test
    // process. `head -c N` exits as soon as it has N bytes, so this happens in every upload
    // test. With SIGPIPE ignored the write fails with EPIPE, which `StandardInputPipe`
    // discards.
    //
    // `signal` is process-global, deliberately: nothing gives EPIPE instead of a signal for a
    // `Process` pipe. It is set once from a `static let`, so parallel suites cannot race it.
    Self.ignoreBrokenPipesOnce()
    group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    // A local, because the child initializer runs inside `init` and cannot capture `self`
    // until every member is set.
    let ptyRequests = PseudoTerminalRequestLog()
    self.ptyRequests = ptyRequests
    let runningCommands = self.runningCommands
    let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
    hostPublicKey = hostKey.publicKey

    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            NIOSSHHandler(
              role: .server(
                SSHServerConfiguration(
                  hostKeys: [hostKey],
                  userAuthDelegate: TestServerAuthDelegate(
                    username: username,
                    password: password,
                    authorizedKey: authorizedKey
                  )
                )
              ),
              allocator: channel.allocator,
              inboundChildChannelInitializer: { childChannel, channelType in
                guard channelType == .session else {
                  return childChannel.eventLoop.makeFailedFuture(
                    EmbeddedServerError.unsupportedChannelType
                  )
                }
                return childChannel.eventLoop.makeCompletedFuture {
                  try childChannel.pipeline.syncOperations.addHandler(
                    TestSessionHandler(
                      executesRealCommands: executesRealCommands,
                      ptyRequests: ptyRequests,
                      runningCommands: runningCommands,
                      truncatesStandardInputAfter: truncatesStandardInputAfter,
                      environment: environment
                    )
                  )
                }
              }
            )
          )
        }
      }

    // `.get()`, never `.wait()`; see `stop()`.
    do {
      channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
    } catch {
      try? await group.shutdownGracefully()
      throw error
    }
    guard let boundPort = channel.localAddress?.port else {
      try? await channel.close().get()
      try? await group.shutdownGracefully()
      throw EmbeddedServerError.noPort
    }
    port = boundPort
  }

  /// Tears the server down, and awaits it rather than blocking.
  ///
  /// Never `channel.close().wait()` or `group.syncShutdownGracefully()`. Swift Testing runs on
  /// the cooperative pool, `activeProcessorCount` threads that never grow, and many tests
  /// start a server. Once enough blocked in shutdown, every other test waited forever and the
  /// run parked at 0 % CPU (CLAUDE.md, "Never block a cooperative thread in a Kit test").
  ///
  /// It also waits for real commands still reporting. A command hands its output back with
  /// `loop.execute`, and shutting the group down first makes NIO log `Cannot schedule tasks on
  /// an EventLoop that has already shut down`. The wait is bounded so a wedged command fails
  /// its own test, and `Task.sleep` suspends rather than blocking a cooperative thread.
  func stop() async {
    for _ in 0..<500 where !runningCommands.isIdle {
      try? await Task.sleep(for: .milliseconds(10))
    }
    try? await channel.close().get()
    try? await group.shutdownGracefully()
  }

  private static let brokenPipeGuard: Void = {
    signal(SIGPIPE, SIG_IGN)
  }()

  private static func ignoreBrokenPipesOnce() { _ = brokenPipeGuard }
}

enum EmbeddedServerError: Error {
  case unsupportedChannelType
  case noPort
}

/// Accepts one username/password pair, and optionally one authorized public key.
private final class TestServerAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
  private let username: String
  private let password: String
  private let authorizedKey: NIOSSHPublicKey?

  init(username: String, password: String, authorizedKey: NIOSSHPublicKey?) {
    self.username = username
    self.password = password
    self.authorizedKey = authorizedKey
  }

  var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods {
    authorizedKey == nil ? [.password] : [.password, .publicKey]
  }

  func requestReceived(
    request: NIOSSHUserAuthenticationRequest,
    responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
  ) {
    guard request.username == username else {
      responsePromise.succeed(.failure)
      return
    }

    switch request.request {
    case .password(let passwordRequest):
      responsePromise.succeed(passwordRequest.password == password ? .success : .failure)
    case .publicKey(let keyRequest):
      responsePromise.succeed(keyRequest.publicKey == authorizedKey ? .success : .failure)
    case .hostBased, .none:
      responsePromise.succeed(.failure)
    }
  }
}

/// A minimal shell. `echo` covers stdout and exit 0, `fail` covers stderr and a non-zero
/// exit, and anything else answers 127, the three outcomes `CommandResult` distinguishes.
final class TestSessionHandler: ChannelDuplexHandler {
  typealias InboundIn = SSHChannelData
  typealias InboundOut = SSHChannelData
  typealias OutboundIn = SSHChannelData
  typealias OutboundOut = SSHChannelData

  /// Set once a shell starts, which makes the channel an echo server.
  private var echoing = false
  /// Set when a `PseudoTerminalRequest` arrives. `execStream` exists because a pty echoes and
  /// rewrites line endings, so "no pty was requested" is checked at the far end.
  private(set) var sawPseudoTerminalRequest = false
  private let executesRealCommands: Bool
  /// The running command's stdin, or `nil`. Assigned only on the event loop; writes happen
  /// off it.
  private var standardInput: StandardInputPipe?
  /// Shared with the server, so `stop()` can wait for this channel's command.
  private let runningCommands: RunningCommandLog
  /// See `EmbeddedSSHServer.init(truncatesStandardInputAfter:)`.
  private let truncatesStandardInputAfter: Int?
  /// See `EmbeddedSSHServer.init(environment:)`.
  private let environment: [String: String]?
  /// Shared with the server that created this handler, not static: suites run in parallel,
  /// and a static flag let one test's pty request fail another's assertion.
  private let ptyRequests: PseudoTerminalRequestLog

  init(
    executesRealCommands: Bool = false,
    ptyRequests: PseudoTerminalRequestLog,
    runningCommands: RunningCommandLog = RunningCommandLog(),
    truncatesStandardInputAfter: Int? = nil,
    environment: [String: String]? = nil
  ) {
    self.executesRealCommands = executesRealCommands
    self.ptyRequests = ptyRequests
    self.runningCommands = runningCommands
    self.truncatesStandardInputAfter = truncatesStandardInputAfter
    self.environment = environment
  }

  func handlerAdded(context: ChannelHandlerContext) {
    // `ChannelHandlerContext` is not `Sendable` and must not escape into the closure.
    let channel = context.channel
    channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in
      channel.close(promise: nil)
    }
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    switch event {
    case let exec as SSHChannelRequestEvent.ExecRequest:
      if exec.wantReply {
        context.channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
      }
      run(exec.command, context: context)

    case let pty as SSHChannelRequestEvent.PseudoTerminalRequest:
      sawPseudoTerminalRequest = true
      ptyRequests.record()
      if pty.wantReply {
        context.channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
      }

    case let shell as SSHChannelRequestEvent.ShellRequest:
      echoing = true
      if shell.wantReply {
        context.channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
      }

    // With `allowRemoteHalfClosure` on, a client closing its output arrives here rather than
    // as `channelInactive`, and a command reading to EOF needs it.
    case let channelEvent as ChannelEvent:
      if channelEvent == .inputClosed { closeStandardInput() }
      context.fireUserInboundEventTriggered(event)

    default:
      context.fireUserInboundEventTriggered(event)
    }
  }

  /// Runs the command as `sshd` would: through the login shell, with separate stdout and
  /// stderr and the exit status carried back. The wait happens off the event loop, because
  /// a single-threaded server blocked on `waitUntilExit` cannot service its own channel.
  private func runRealCommand(_ command: String, context: ChannelHandlerContext) {
    let channel = context.channel
    let loop = channel.eventLoop

    // Created before dispatching, because inbound data can arrive before the block runs, and
    // dropping that first chunk reads as a size mismatch.
    let pipe = Pipe()
    let input = StandardInputPipe(
      pipe.fileHandleForWriting,
      byteBudget: truncatesStandardInputAfter
    )
    standardInput = input
    // Registered on the loop before dispatch, so `stop()` never sees idle for a command about
    // to report.
    let commands = runningCommands
    commands.begin()
    let environment = environment

    DispatchQueue.global().async {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      // A login shell decides whether `herdr` is on `PATH`.
      process.arguments = ["-lc", command]
      if let environment { process.environment = environment }
      let out = Pipe()
      let err = Pipe()
      process.standardInput = pipe
      process.standardOutput = out
      process.standardError = err

      var stdout = Data()
      var stderr = Data()
      var status = 126
      do {
        try process.run()
        stdout = out.fileHandleForReading.readDataToEndOfFile()
        stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        status = Int(process.terminationStatus)
      } catch {
        stderr = Data("failed to launch: \(error)\n".utf8)
      }

      let finished = stdout
      let failed = stderr
      let exitStatus = status
      // Closed through the box, because the handler is not `Sendable` and this is not the event
      // loop. Later writes become no-ops.
      input.close()
      loop.execute {
        Self.write(finished, as: .channel, to: channel)
        Self.write(failed, as: .stdErr, to: channel)
        channel.triggerUserOutboundEvent(
          SSHChannelRequestEvent.ExitStatus(exitStatus: exitStatus)
        )
        // Only now is the command done with the loop. The event fails at once if the client has
        // gone, so this also runs on a dropped connection.
        .whenComplete { _ in
          channel.close(promise: nil)
          commands.finish()
        }
      }
    }
  }

  private static func write(_ data: Data, as type: SSHChannelData.DataType, to channel: Channel) {
    guard !data.isEmpty else { return }
    var buffer = channel.allocator.buffer(capacity: data.count)
    buffer.writeBytes(data)
    channel.writeAndFlush(SSHChannelData(type: type, data: .byteBuffer(buffer)), promise: nil)
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let channelData = unwrapInboundIn(data)
    // A command is running or a shell is echoing, never both.
    if let standardInput, case .byteBuffer(let buffer) = channelData.data {
      standardInput.write(Data(buffer.readableBytesView))
      return
    }
    guard echoing else { return }
    guard case .byteBuffer = channelData.data else { return }
    context.writeAndFlush(wrapOutboundOut(channelData), promise: nil)
  }

  /// The client closed its side, so the command's stdin gets EOF. A command reading to EOF
  /// would otherwise hang.
  func channelInactive(context: ChannelHandlerContext) {
    closeStandardInput()
    context.fireChannelInactive()
  }

  private func closeStandardInput() {
    standardInput?.close()
    standardInput = nil
  }

  private func run(_ command: String, context: ChannelHandlerContext) {
    // Stays open and echoes stdin, so a streaming exec channel can be tested round trip.
    if command == "stream-echo" {
      echoing = true
      return
    }
    if executesRealCommands {
      runRealCommand(command, context: context)
      return
    }
    let (text, stream, status): (String, SSHChannelData.DataType, Int)
    if command.hasPrefix("echo ") {
      (text, stream, status) = (String(command.dropFirst(5)) + "\n", .channel, 0)
    } else if command == "fail" {
      (text, stream, status) = ("something broke\n", .stdErr, 3)
    } else {
      (text, stream, status) = ("\(command): command not found\n", .stdErr, 127)
    }

    var buffer = context.channel.allocator.buffer(capacity: text.utf8.count)
    buffer.writeString(text)
    context.writeAndFlush(
      wrapOutboundOut(SSHChannelData(type: stream, data: .byteBuffer(buffer))),
      promise: nil
    )

    let channel = context.channel
    channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: status))
      .whenComplete { _ in channel.close(promise: nil) }
  }
}


/// Records whether the server was asked for a pseudo-terminal. A class, because strict
/// concurrency refuses a shared `static var`.
final class PseudoTerminalRequestLog: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func record() { lock.withLock { value = true } }
  func reset() { lock.withLock { value = false } }
  var seen: Bool { lock.withLock { value } }
}

/// The write end of a running command's stdin, shared between the event loop and the
/// thread waiting on the process. `TestSessionHandler` is not `Sendable`, so it cannot be
/// captured there.
///
/// Writes go to a serial queue, because a `write(2)` into a full pipe would block the
/// single-threaded loop that must read more of the channel. A failed write is not fatal:
/// once `head -c N` exits, a client with a packet in flight gets EPIPE as the ordinary end
/// of an upload.
final class StandardInputPipe: @unchecked Sendable {
  private let queue = DispatchQueue(label: "EmbeddedSSHServer.stdin")
  private let lock = NSLock()
  private var handle: FileHandle?
  /// Bytes that may still reach the command, or `nil` for no limit. See
  /// `EmbeddedSSHServer.init(truncatesStandardInputAfter:)`.
  private var remaining: Int?

  init(_ handle: FileHandle, byteBudget: Int? = nil) {
    self.handle = handle
    self.remaining = byteBudget
  }

  func write(_ data: Data) {
    queue.async { [self] in
      lock.lock()
      let open = handle
      let budget = remaining
      var chunk = data
      var exhausted = false
      if let budget {
        let allowed = min(budget, data.count)
        chunk = data.prefix(allowed)
        remaining = budget - allowed
        exhausted = budget - allowed == 0
      }
      lock.unlock()
      if !chunk.isEmpty { try? open?.write(contentsOf: chunk) }
      if exhausted { close() }
    }
  }

  /// Closes the write end, the command's EOF. Idempotent, because channel inactivity and
  /// process exit both call it, in either order.
  func close() {
    lock.lock()
    let open = handle
    handle = nil
    lock.unlock()
    guard let open else { return }
    queue.async { try? open.close() }
  }
}

/// Real commands started and not yet finished reporting. `Sendable` for the same reason as
/// `StandardInputPipe`. `EmbeddedSSHServer.stop()` waits on `isIdle` before shutting the
/// group down.
final class RunningCommandLog: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func begin() { lock.withLock { count += 1 } }
  func finish() { lock.withLock { count = max(0, count - 1) } }
  var isIdle: Bool { lock.withLock { count == 0 } }
}
