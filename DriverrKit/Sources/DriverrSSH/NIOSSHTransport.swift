import Crypto
import DriverrCore
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// The real `SSHTransport`, on swift-nio-ssh.
///
/// **This is the only production file that may import `NIOSSH`.** Every type crossing
/// the public boundary is a `DriverrCore` type, and every upstream error maps to
/// `AppError` here.
///
/// SSH authenticates inside the handshake, but the UI validates the host key first and
/// asks for a credential after. `HandshakeCoordinator` bridges the two: the auth
/// delegate parks on a promise that `authenticate` fulfils later, so `connect` returns
/// when key exchange is done.
public actor NIOSSHTransport: SSHTransport {
  private var channel: Channel?
  private var coordinator: HandshakeCoordinator?
  private var host: DriverrCore.Host?
  private var isAuthenticated = false
  /// The closure signal for the current connection. Every `connect` rebuilds it, so a
  /// loss cannot reach the next connection. See `SSHTransport.disconnections`.
  private var closureStream: AsyncStream<AppError>?
  private var closureSignal: AsyncStream<AppError>.Continuation?

  public init() {}

  public var disconnections: AsyncStream<AppError> {
    // With nothing connected, return a finished stream so no caller waits forever.
    closureStream ?? AsyncStream { $0.finish() }
  }

  public var authenticationBanners: AsyncStream<String> {
    // With nothing connected, a finished stream, as `disconnections` does.
    coordinator?.banners ?? AsyncStream { $0.finish() }
  }

  public func connect(
    to host: DriverrCore.Host,
    hostKeyValidator: any HostKeyValidator
  ) async throws {
    // One loop of NIO's shared group, never shut down (#151). A per-connection group that
    // teardown shut down dropped any write a concurrent send had already started, and its
    // promise never settled. On a live loop a write to a closed channel fails instead.
    // The coordinator is confined to the channel's loop, so both take this one loop.
    let loop = MultiThreadedEventLoopGroup.singleton.next()
    let coordinator = HandshakeCoordinator(
      eventLoop: loop,
      host: host,
      validator: hostKeyValidator
    )
    self.coordinator = coordinator
    self.host = host

    let bootstrap = ClientBootstrap(group: loop)
      .channelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandlers([
            NIOSSHHandler(
              role: .client(
                SSHClientConfiguration(
                  userAuthDelegate: coordinator,
                  serverAuthDelegate: coordinator
                )
              ),
              allocator: channel.allocator,
              inboundChildChannelInitializer: nil
            ),
            AuthenticationOutcomeHandler(coordinator: coordinator),
          ])
        }
      }

    // A disconnect during the TCP connect does not end it; NIO's connect timeout does
    // (10 s). A socket that connects after the disconnect is closed by the `catch` below,
    // because the disconnect has already failed the host-key decision.
    let connected: Channel
    do {
      connected = try await bootstrap.connect(host: host.hostname, port: host.port).get()
      channel = connected
      // A server that closes during the handshake sends no failure message, and the close
      // does not reach `AuthenticationOutcomeHandler`. Tailscale SSH denies a user this
      // way, after a banner. Without this the attempt waits for the handshake deadline.
      // On the channel's loop, where the coordinator is confined. A no-op once settled.
      connected.closeFuture.whenComplete { _ in coordinator.connectionClosed() }
    } catch {
      await teardown()
      throw AppError.connectionFailed(
        host: host.hostname,
        reason: Self.readableReason(for: error, whileConnecting: true)
      )
    }

    do {
      // Key exchange, and with it the trust prompt, finishes after the TCP connect.
      try await coordinator.waitForHostKeyDecision()
    } catch {
      await teardown()
      throw error
    }

    armClosureSignal(for: host, on: connected)
  }

  /// Surfaces the NIO channel's close future as the transport's closure signal.
  ///
  /// Armed only after key exchange. A failure before that is an attempt, reported by
  /// `connect` throwing, and must not also arrive as a loss.
  private func armClosureSignal(for host: DriverrCore.Host, on channel: Channel) {
    closureSignal?.finish()
    let (stream, continuation) = AsyncStream<AppError>.makeStream(of: AppError.self)
    closureStream = stream
    closureSignal = continuation
    let loss = AppError.disconnected(reason: "\(host.hostname) is no longer reachable.")
    // `whenComplete`, because a channel that closed on an error is still closed.
    channel.closeFuture.whenComplete { _ in
      continuation.yield(loss)
      continuation.finish()
    }
  }

  public func authenticate(_ method: SSHAuthMethod) async throws {
    guard let coordinator, let host else {
      throw AppError.notConnected(host: host?.hostname ?? "the host")
    }
    do {
      try await coordinator.supplyCredential(method)
      isAuthenticated = true
    } catch let error as AppError {
      throw error
    } catch {
      throw AppError.authenticationFailed(host: host.hostname)
    }
  }

  public func execChannel(command: String) async throws -> CommandResult {
    let channel = try requireAuthenticatedChannel()
    let eventLoop = channel.eventLoop
    let resultPromise = eventLoop.makePromise(of: CommandResult.self)
    let childPromise = eventLoop.makePromise(of: Channel.self)

    channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
      switch result {
      case .success(let sshHandler):
        sshHandler.createChannel(childPromise, channelType: .session) { child, _ in
          child.eventLoop.makeCompletedFuture {
            try child.pipeline.syncOperations.addHandler(
              ExecHandler(command: command, resultPromise: resultPromise)
            )
          }
        }
      case .failure(let error):
        childPromise.fail(error)
        resultPromise.fail(error)
      }
    }

    do {
      _ = try await childPromise.futureResult.get()
      return try await resultPromise.futureResult.get()
    } catch {
      throw AppError.channelFailed(reason: Self.readableReason(for: error))
    }
  }

  public func execStream(command: String) async throws -> any ExecStream {
    let channel = try requireAuthenticatedChannel()
    let eventLoop = channel.eventLoop
    let childPromise = eventLoop.makePromise(of: Channel.self)
    let readyPromise = eventLoop.makePromise(of: Void.self)
    let (output, outputContinuation) = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self
    )
    // Bounded and newest-wins, because most callers never drain stderr.
    let (errors, errorContinuation) = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self,
      bufferingPolicy: .bufferingNewest(32)
    )
    let status = ExitStatusBox()

    channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
      switch result {
      case .success(let sshHandler):
        sshHandler.createChannel(childPromise, channelType: .session) { child, _ in
          child.eventLoop.makeCompletedFuture {
            try child.pipeline.syncOperations.addHandler(
              ExecStreamHandler(
                command: command,
                readyPromise: readyPromise,
                output: outputContinuation,
                standardError: errorContinuation,
                status: status
              )
            )
          }
        }
      case .failure(let error):
        childPromise.fail(error)
        readyPromise.fail(error)
      }
    }

    do {
      let child = try await childPromise.futureResult.get()
      // The server discards bytes written before it handles the exec request, so wait,
      // as `ptyChannel` does.
      try await readyPromise.futureResult.get()
      return NIOExecStream(
        channel: child,
        output: output,
        standardError: errors,
        outputContinuation: outputContinuation,
        errorContinuation: errorContinuation,
        status: status
      )
    } catch {
      outputContinuation.finish(throwing: error)
      errorContinuation.finish(throwing: error)
      throw AppError.channelFailed(reason: Self.readableReason(for: error))
    }
  }

  public func ptyChannel(size: TerminalSize) async throws -> any PTYChannel {
    let channel = try requireAuthenticatedChannel()
    let eventLoop = channel.eventLoop
    let childPromise = eventLoop.makePromise(of: Channel.self)
    let readyPromise = eventLoop.makePromise(of: Void.self)
    let (stream, continuation) = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self
    )

    channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
      switch result {
      case .success(let sshHandler):
        sshHandler.createChannel(childPromise, channelType: .session) { child, _ in
          child.eventLoop.makeCompletedFuture {
            try child.pipeline.syncOperations.addHandler(
              PTYHandler(size: size, readyPromise: readyPromise, continuation: continuation)
            )
          }
        }
      case .failure(let error):
        childPromise.fail(error)
        readyPromise.fail(error)
      }
    }

    do {
      let child = try await childPromise.futureResult.get()
      // Wait until the shell runs. The server discards bytes written before it handles
      // the shell request, which would drop the user's first keystrokes.
      try await readyPromise.futureResult.get()
      return NIOPTYChannel(channel: child, output: stream, continuation: continuation)
    } catch {
      continuation.finish(throwing: error)
      throw AppError.channelFailed(reason: Self.readableReason(for: error))
    }
  }

  public func disconnect() async {
    await teardown()
  }

  private func requireAuthenticatedChannel() throws -> Channel {
    guard let channel, channel.isActive, isAuthenticated else {
      throw AppError.notConnected(host: host?.hostname ?? "the host")
    }
    return channel
  }

  private func teardown() async {
    // Finish before the channel closes. The close future's later `yield` is then dropped,
    // so Driverr's own disconnect is not reported as a loss.
    closureSignal?.finish()
    closureSignal = nil
    closureStream = nil
    // The loop is NIO's shared one and stays up, so these promises always settle.
    if let coordinator { await coordinator.cancelPendingWork() }
    if let channel { try? await channel.close().get() }
    channel = nil
    coordinator = nil
    isAuthenticated = false
  }

  /// Turns an upstream error into text for a person. NIO's own descriptions are type
  /// dumps.
  ///
  /// A closed channel reads "The connection closed." for a send or a channel open that a
  /// disconnect overtook (#151). A connect keeps the generic reason, because
  /// `connectionFailed` already says "Could not reach <host>".
  static func readableReason(for error: any Error, whileConnecting: Bool = false) -> String {
    if !whileConnecting, let channelError = error as? ChannelError,
      case .ioOnClosedChannel = channelError
    {
      return "The connection closed."
    }
    if let channelError = error as? NIOConnectionError {
      _ = channelError
      return "The host refused the connection or is unreachable."
    }
    if error is NIOSSHError {
      return "The SSH handshake failed."
    }
    if let ioError = error as? IOError {
      return String(cString: strerror(ioError.errnoCode))
    }
    return "The connection could not be established."
  }
}

/// Bridges NIOSSH's synchronous, event-loop-bound delegates to Driverr's async API.
///
/// Confined to `eventLoop`: mutable fields are touched only from NIOSSH callbacks on that
/// loop or from `execute` hops. That makes `@unchecked Sendable` sound.
final class HandshakeCoordinator: NIOSSHClientServerAuthenticationDelegate,
  NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable
{
  private let eventLoop: EventLoop
  private let host: DriverrCore.Host
  private let validator: any HostKeyValidator

  private let hostKeyDecided: EventLoopPromise<Void>
  private let credentialAvailable: EventLoopPromise<SSHAuthMethod>
  private let authenticationFinished: EventLoopPromise<Void>
  /// The server's auth banners. Read from any thread; written only on the loop.
  let banners: AsyncStream<String>
  private let bannerSignal: AsyncStream<String>.Continuation
  /// The newest banner, so a refusal after it can say what the server said. A Tailscale SSH
  /// host that denies a user sends the reason as a banner and then closes the connection.
  private var lastBanner: String?

  /// Driverr offers one credential per `authenticate` call. A refusal then surfaces at
  /// once, instead of the delegate parking on a second credential nobody supplies.
  private var hasOfferedCredential = false
  private var authenticationSettled = false
  private var hostKeySettled = false
  private var credentialSettled = false
  /// Set by `cancelPendingWork`. Not `hostKeySettled`, which is also true after a trusted
  /// first key exchange, when a re-key asks again.
  private var isCancelled = false

  init(eventLoop: EventLoop, host: DriverrCore.Host, validator: any HostKeyValidator) {
    self.eventLoop = eventLoop
    self.host = host
    self.validator = validator
    hostKeyDecided = eventLoop.makePromise(of: Void.self)
    credentialAvailable = eventLoop.makePromise(of: SSHAuthMethod.self)
    authenticationFinished = eventLoop.makePromise(of: Void.self)
    (banners, bannerSignal) = AsyncStream.makeStream(of: String.self)
  }

  func waitForHostKeyDecision() async throws {
    try await hostKeyDecided.futureResult.get()
  }

  func supplyCredential(_ method: SSHAuthMethod) async throws {
    eventLoop.execute { [self] in
      guard !credentialSettled else { return }
      credentialSettled = true
      credentialAvailable.succeed(method)
    }
    try await authenticationFinished.futureResult.get()
  }

  /// Settles every promise still outstanding.
  ///
  /// NIO traps on a promise deallocated unfulfilled, and a connect followed by a
  /// disconnect without authentication leaves the credential promise open.
  func cancelPendingWork() async {
    try? await eventLoop.submit { [self] in
      isCancelled = true
      if !credentialSettled {
        credentialSettled = true
        credentialAvailable.fail(AppError.cancelled)
      }
      if !hostKeySettled {
        hostKeySettled = true
        hostKeyDecided.fail(AppError.cancelled)
      }
      if !authenticationSettled {
        authenticationSettled = true
        authenticationFinished.fail(AppError.cancelled)
      }
      bannerSignal.finish()
    }.get()
  }

  // MARK: - Host key

  func validateHostKey(
    hostKey: NIOSSHPublicKey,
    validationCompletePromise: EventLoopPromise<Void>
  ) {
    // Do not ask the person about a connection that a disconnect has cancelled. The loop
    // stays up now (#151), so a socket that connects after a teardown can still reach key
    // exchange before its close lands.
    guard !isCancelled else {
      validationCompletePromise.fail(AppError.cancelled)
      return
    }
    let domainKey = SSHHostKey(niosshPublicKey: hostKey)
    let host = host
    let validator = validator

    Task { [self] in
      let decision = await validator.validate(domainKey, for: host)
      eventLoop.execute { [self] in
        // NIOSSH's promise is settled on every path. An unsettled one stalls its key
        // exchange, and NIO traps on a promise released unfulfilled.
        //
        // A disconnect while the prompt was up cancelled the handshake.
        guard !isCancelled else {
          validationCompletePromise.fail(AppError.cancelled)
          return
        }
        // A re-key asks again after the first exchange settled `hostKeyDecided`. Answer
        // NIOSSH, and leave the settled promises alone.
        let isFirstDecision = !hostKeySettled
        hostKeySettled = true
        switch decision {
        case .trust:
          validationCompletePromise.succeed(())
          if isFirstDecision { hostKeyDecided.succeed(()) }
        case .reject, .mismatch:
          // A mismatch keeps its own error: the UI must never offer a way past it.
          let error =
            decision == .mismatch
            ? AppError.hostKeyMismatch(host: host.hostname)
            : AppError.hostKeyRejected(host: host.hostname)
          validationCompletePromise.fail(error)
          if isFirstDecision { hostKeyDecided.fail(error) }
          // Nothing will supply a credential now; unblock any waiter. A no-op once
          // authentication has settled.
          settleAuthentication(with: error)
        }
      }
    }
  }

  // MARK: - User authentication

  func nextAuthenticationType(
    availableMethods: NIOSSHAvailableUserAuthenticationMethods,
    nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
  ) {
    guard !hasOfferedCredential else {
      // The one credential was refused. Settle the failure here, because swift-nio-ssh
      // (checked on 0.15.0) sends no signal when authentication is exhausted: returning
      // nil throws, closes and fires nothing. A wait for a pipeline failure would wait
      // forever.
      nextChallengePromise.succeed(nil)
      settleAuthentication(with: authenticationFailure)
      return
    }
    hasOfferedCredential = true

    credentialAvailable.futureResult.whenComplete { [self] result in
      switch result {
      case .success(let method):
        nextChallengePromise.succeed(offer(for: method, availableMethods: availableMethods))
      case .failure(let error):
        nextChallengePromise.fail(error)
      }
    }
  }

  private func offer(
    for method: SSHAuthMethod,
    availableMethods: NIOSSHAvailableUserAuthenticationMethods
  ) -> NIOSSHUserAuthenticationOffer? {
    switch method {
    case .password(let password):
      guard availableMethods.contains(.password) else { return nil }
      return NIOSSHUserAuthenticationOffer(
        username: host.username,
        serviceName: "",
        offer: .password(.init(password: password))
      )
    case .none:
      // Not checked against `availableMethods`: no server lists "none" there (RFC 4252,
      // section 5.2), and Tailscale SSH accepts it anyway.
      return NIOSSHUserAuthenticationOffer(username: host.username, serviceName: "", offer: .none)
    case .privateKey(let key):
      guard availableMethods.contains(.publicKey),
        let signingKey = try? Curve25519.Signing.PrivateKey(
          rawRepresentation: key.rawRepresentation
        )
      else { return nil }
      return NIOSSHUserAuthenticationOffer(
        username: host.username,
        serviceName: "",
        offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(ed25519Key: signingKey)))
      )
    }
  }

  /// Called by the pipeline when authentication succeeds, or when the connection goes
  /// away without it having succeeded.
  func settleAuthentication(with error: (any Error)?) {
    guard !authenticationSettled else { return }
    authenticationSettled = true
    bannerSignal.finish()
    if let error {
      authenticationFinished.fail(error)
      // A connection that dies during key exchange never reaches the host-key decision.
      if !hostKeySettled {
        hostKeySettled = true
        hostKeyDecided.fail(error)
      }
    } else {
      authenticationFinished.succeed(())
    }
  }

  /// A refusal, with the server's last banner when it sent one.
  var authenticationFailure: AppError {
    guard let message = lastBanner.flatMap(AuthBanner.displayText) else {
      return AppError.authenticationFailed(host: host.hostname)
    }
    return AppError.authenticationRefused(host: host.hostname, message: message)
  }

  /// Called when the connection closes. Settles whatever is still waiting: a close during
  /// key exchange reads as an unreachable host, and a close after it as a refusal.
  func connectionClosed() {
    guard hostKeySettled else {
      settleAuthentication(
        with: AppError.connectionFailed(
          host: host.hostname,
          reason: "It closed the connection during the handshake."
        )
      )
      return
    }
    settleAuthentication(with: authenticationFailure)
  }

  /// Called by the pipeline for each SSH_MSG_USERAUTH_BANNER. Ignored once authentication
  /// has settled.
  func receivedBanner(_ text: String) {
    guard !authenticationSettled else { return }
    lastBanner = text
    bannerSignal.yield(text)
  }
}

/// Watches the parent channel for the end of user authentication.
///
/// It never sees `channelInactive`: `NIOSSHHandler` (checked on 0.15.0) does not pass it on.
/// `connect` watches the channel's `closeFuture` for a server that closes instead.
private final class AuthenticationOutcomeHandler: ChannelInboundHandler {
  typealias InboundIn = Any

  private let coordinator: HandshakeCoordinator

  init(coordinator: HandshakeCoordinator) {
    self.coordinator = coordinator
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if event is UserAuthSuccessEvent {
      coordinator.settleAuthentication(with: nil)
    } else if let banner = event as? NIOUserAuthBannerEvent {
      coordinator.receivedBanner(banner.message)
    }
    context.fireUserInboundEventTriggered(event)
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    coordinator.settleAuthentication(with: coordinator.authenticationFailure)
    context.fireErrorCaught(error)
  }
}

/// Runs one command and collects everything it produced.
private final class ExecHandler: ChannelDuplexHandler {
  typealias InboundIn = SSHChannelData
  typealias InboundOut = SSHChannelData
  typealias OutboundIn = SSHChannelData
  typealias OutboundOut = SSHChannelData

  private let command: String
  private let resultPromise: EventLoopPromise<CommandResult>
  private var standardOutput = ByteBuffer()
  private var standardError = ByteBuffer()
  private var exitStatus = 0
  private var completed = false

  init(command: String, resultPromise: EventLoopPromise<CommandResult>) {
    self.command = command
    self.resultPromise = resultPromise
  }

  func channelActive(context: ChannelHandlerContext) {
    context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenComplete {
      _ in
    }
    context.triggerUserOutboundEvent(
      SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true),
      promise: nil
    )
    context.fireChannelActive()
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let channelData = unwrapInboundIn(data)
    guard case .byteBuffer(var buffer) = channelData.data else { return }
    if channelData.type == .stdErr {
      standardError.writeBuffer(&buffer)
    } else {
      standardOutput.writeBuffer(&buffer)
    }
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if let status = event as? SSHChannelRequestEvent.ExitStatus {
      exitStatus = status.exitStatus
    }
    context.fireUserInboundEventTriggered(event)
  }

  func channelInactive(context: ChannelHandlerContext) {
    complete()
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    guard !completed else { return }
    completed = true
    resultPromise.fail(error)
    context.close(promise: nil)
  }

  private func complete() {
    guard !completed else { return }
    completed = true
    resultPromise.succeed(
      CommandResult(
        standardOutput: standardOutput.getString(at: 0, length: standardOutput.readableBytes) ?? "",
        standardError: standardError.getString(at: 0, length: standardError.readableBytes) ?? "",
        exitStatus: exitStatus
      )
    )
  }
}

/// Requests a PTY and a shell, then pumps bytes into an `AsyncThrowingStream`.
private final class PTYHandler: ChannelDuplexHandler {
  typealias InboundIn = SSHChannelData
  typealias InboundOut = SSHChannelData
  typealias OutboundIn = ByteBuffer
  typealias OutboundOut = SSHChannelData

  private let size: TerminalSize
  private let readyPromise: EventLoopPromise<Void>
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  /// A box, so the completion closure can settle the promise without capturing the
  /// non-`Sendable` handler. Touched only on the channel's event loop.
  private let ready = OnceFlag()

  init(
    size: TerminalSize,
    readyPromise: EventLoopPromise<Void>,
    continuation: AsyncThrowingStream<Data, any Error>.Continuation
  ) {
    self.size = size
    self.readyPromise = readyPromise
    self.continuation = continuation
  }

  func channelActive(context: ChannelHandlerContext) {
    let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
      wantReply: true,
      term: "xterm-256color",
      terminalCharacterWidth: size.columns,
      terminalRowHeight: size.rows,
      terminalPixelWidth: size.pixelWidth,
      terminalPixelHeight: size.pixelHeight,
      terminalModes: SSHTerminalModes([:])
    )
    let shell = SSHChannelRequestEvent.ShellRequest(wantReply: true)
    let channel = context.channel
    let readyPromise = readyPromise
    let ready = ready

    channel.triggerUserOutboundEvent(pty)
      .flatMap { channel.triggerUserOutboundEvent(shell) }
      .whenComplete { result in
        guard ready.fire() else { return }
        switch result {
        case .success: readyPromise.succeed(())
        case .failure(let error): readyPromise.fail(error)
        }
      }
    context.fireChannelActive()
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let channelData = unwrapInboundIn(data)
    guard case .byteBuffer(let buffer) = channelData.data else { return }
    continuation.yield(Data(buffer.readableBytesView))
  }

  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    let buffer = unwrapOutboundIn(data)
    context.write(
      wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
      promise: promise
    )
  }

  func channelInactive(context: ChannelHandlerContext) {
    if ready.fire() {
      readyPromise.fail(AppError.channelFailed(reason: "The shell closed before it started."))
    }
    continuation.finish()
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    if ready.fire() {
      readyPromise.fail(error)
    }
    continuation.finish(throwing: error)
    context.close(promise: nil)
  }
}

/// Requests an exec, not a pty, and pumps stdout and stderr into separate streams.
///
/// Without a pty nothing echoes and no line endings are rewritten. `channelData.type` is
/// honoured, so stderr never lands in the stdout stream.
private final class ExecStreamHandler: ChannelDuplexHandler {
  typealias InboundIn = SSHChannelData
  typealias InboundOut = SSHChannelData
  typealias OutboundIn = ByteBuffer
  typealias OutboundOut = SSHChannelData

  private let command: String
  private let readyPromise: EventLoopPromise<Void>
  private let output: AsyncThrowingStream<Data, any Error>.Continuation
  private let standardError: AsyncThrowingStream<Data, any Error>.Continuation
  private let status: ExitStatusBox
  private let ready = OnceFlag()

  init(
    command: String,
    readyPromise: EventLoopPromise<Void>,
    output: AsyncThrowingStream<Data, any Error>.Continuation,
    standardError: AsyncThrowingStream<Data, any Error>.Continuation,
    status: ExitStatusBox
  ) {
    self.command = command
    self.readyPromise = readyPromise
    self.output = output
    self.standardError = standardError
    self.status = status
  }

  func channelActive(context: ChannelHandlerContext) {
    // The remote may close its output while input is still to send. Without half-closure
    // that reads as the whole channel closing.
    context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenComplete {
      _ in
    }
    let exec = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
    let ready = ready
    let readyPromise = readyPromise
    context.triggerUserOutboundEvent(exec).whenComplete { result in
      guard ready.fire() else { return }
      switch result {
      case .success: readyPromise.succeed(())
      case .failure(let error): readyPromise.fail(error)
      }
    }
    context.fireChannelActive()
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let channelData = unwrapInboundIn(data)
    guard case .byteBuffer(let buffer) = channelData.data else { return }
    let bytes = Data(buffer.readableBytesView)
    if channelData.type == .stdErr {
      standardError.yield(bytes)
    } else {
      output.yield(bytes)
    }
  }

  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    let buffer = unwrapOutboundIn(data)
    context.write(
      wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
      promise: promise
    )
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if let exit = event as? SSHChannelRequestEvent.ExitStatus {
      status.set(exit.exitStatus)
    }
    context.fireUserInboundEventTriggered(event)
  }

  func channelInactive(context: ChannelHandlerContext) {
    if ready.fire() {
      readyPromise.fail(AppError.channelFailed(reason: "The command closed before it started."))
    }
    output.finish()
    standardError.finish()
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    if ready.fire() {
      readyPromise.fail(error)
    }
    output.finish(throwing: error)
    standardError.finish(throwing: error)
    context.close(promise: nil)
  }
}

/// The exit status, written on the event loop and read from anywhere.
///
/// Kept outside the handler, because callers read it after the stream finishes, when the
/// channel and its handler are gone.
final class ExitStatusBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Int?

  func set(_ status: Int) {
    lock.lock()
    defer { lock.unlock() }
    value = status
  }

  var current: Int? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

#if DEBUG
  /// A test seam. It runs in a channel's `send`, after the `isActive` guard and before the
  /// write, which is the window a concurrent disconnect can land in (#151). Nil outside
  /// tests, and absent from a Release build.
  enum ChannelWriteHook {
    @TaskLocal static var afterGuard: (@Sendable () async -> Void)?
  }
#endif

/// The `ExecStream` handed to callers; owns the NIO child channel.
private final class NIOExecStream: ExecStream, @unchecked Sendable {
  let output: AsyncThrowingStream<Data, any Error>
  let standardError: AsyncThrowingStream<Data, any Error>

  private let channel: Channel
  private let outputContinuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let errorContinuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let status: ExitStatusBox

  init(
    channel: Channel,
    output: AsyncThrowingStream<Data, any Error>,
    standardError: AsyncThrowingStream<Data, any Error>,
    outputContinuation: AsyncThrowingStream<Data, any Error>.Continuation,
    errorContinuation: AsyncThrowingStream<Data, any Error>.Continuation,
    status: ExitStatusBox
  ) {
    self.channel = channel
    self.output = output
    self.standardError = standardError
    self.outputContinuation = outputContinuation
    self.errorContinuation = errorContinuation
    self.status = status
  }

  var exitStatus: Int? {
    get async { status.current }
  }

  func send(_ data: Data) async throws {
    guard channel.isActive else {
      throw AppError.channelFailed(reason: "The command is no longer running.")
    }
    #if DEBUG
      if let hook = ChannelWriteHook.afterGuard { await hook() }
    #endif
    var buffer = channel.allocator.buffer(capacity: data.count)
    buffer.writeBytes(data)
    do {
      try await channel.writeAndFlush(buffer)
    } catch {
      throw AppError.channelFailed(reason: NIOSSHTransport.readableReason(for: error))
    }
  }

  /// Not awaited, and guarded on `isActive`. No caller needs the close to complete; the
  /// streams finish synchronously above.
  ///
  /// Both were the fix while `NIOSSHTransport.teardown()` shut the channel's event loop
  /// down, and an await on that loop never returned. The loop is now NIO's shared one and
  /// stays up (#151), so they are belt-and-braces.
  func close() async {
    outputContinuation.finish()
    errorContinuation.finish()
    guard channel.isActive else { return }
    channel.close(promise: nil)
  }
}

/// One-shot latch, so a promise is settled exactly once from several call sites.
///
/// `EventLoopPromise` traps on a second completion, and a channel can finish twice: the
/// request fails, then the channel goes inactive. Confined to one event loop, which makes
/// the unchecked conformance sound.
private final class OnceFlag: @unchecked Sendable {
  private var hasFired = false

  /// Returns `true` exactly once, to the first caller.
  func fire() -> Bool {
    if hasFired { return false }
    hasFired = true
    return true
  }
}

/// The `PTYChannel` handed to callers; owns the NIO child channel.
private final class NIOPTYChannel: PTYChannel, @unchecked Sendable {
  let output: AsyncThrowingStream<Data, any Error>
  private let channel: Channel
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

  init(
    channel: Channel,
    output: AsyncThrowingStream<Data, any Error>,
    continuation: AsyncThrowingStream<Data, any Error>.Continuation
  ) {
    self.channel = channel
    self.output = output
    self.continuation = continuation
  }

  /// Guarded on `isActive`, which is belt-and-braces now. A write that a disconnect
  /// overtakes fails as a closed channel, because the event loop stays up (#151). See
  /// `NIOExecStream.close()`.
  func send(_ data: Data) async throws {
    guard channel.isActive else {
      throw AppError.channelFailed(reason: "The terminal is no longer open.")
    }
    #if DEBUG
      if let hook = ChannelWriteHook.afterGuard { await hook() }
    #endif
    var buffer = channel.allocator.buffer(capacity: data.count)
    buffer.writeBytes(data)
    do {
      try await channel.writeAndFlush(buffer).get()
    } catch {
      throw AppError.channelFailed(reason: "Could not write to the terminal.")
    }
  }

  func resize(to size: TerminalSize) async throws {
    // Same guard as `send`. A rotation just after a drop is common.
    guard channel.isActive else {
      throw AppError.channelFailed(reason: "The terminal is no longer open.")
    }
    let request = SSHChannelRequestEvent.WindowChangeRequest(
      terminalCharacterWidth: size.columns,
      terminalRowHeight: size.rows,
      terminalPixelWidth: size.pixelWidth,
      terminalPixelHeight: size.pixelHeight
    )
    do {
      try await channel.triggerUserOutboundEvent(request).get()
    } catch {
      throw AppError.channelFailed(reason: "Could not resize the terminal.")
    }
  }

  /// Not awaited. See `NIOExecStream.close()`.
  func close() async {
    continuation.finish()
    guard channel.isActive else { return }
    channel.close(promise: nil)
  }
}

extension SSHHostKey {
  /// Maps NIOSSH's key type into the domain at the module boundary.
  ///
  /// Goes through OpenSSH's text form, whose bytes match `known_hosts`, so the
  /// fingerprint matches `ssh-keygen -lf`.
  init(niosshPublicKey key: NIOSSHPublicKey) {
    let openSSH = String(openSSHPublicKey: key)
    let parts = openSSH.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    let algorithm = parts.first.map(String.init) ?? "unknown"
    let blob = parts.count > 1 ? Data(base64Encoded: String(parts[1])) ?? Data() : Data()
    self.init(algorithm: algorithm, blob: blob)
  }
}
