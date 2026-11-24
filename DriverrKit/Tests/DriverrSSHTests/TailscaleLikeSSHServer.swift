import Foundation
import NIOCore
import NIOPosix
// `@testable` for one thing only: `NIOSSHHandler.writeFromChildChannel`, the sole way to send
// SSH_MSG_USERAUTH_BANNER while a request is held. The public API sends a banner only bundled
// with the success (`SSHServerConfiguration.banner`), and Tailscale's check mode sends it first.
@testable import NIOSSH

/// An in-process SSH server that authenticates the way tailscaled does (#171).
///
/// Measured from tailscale/tailscale at 940e4c2, `ssh/tailssh/tailssh.go`, on
/// golang.org/x/crypto v0.59.0 `ssh/server.go`:
/// - It accepts "none", any password and any public key, and ignores the credential's value.
///   Each runs the same tailnet policy check (`ServerConfig`, the NoClientAuthCallback,
///   PasswordCallback and PublicKeyCallback).
/// - It advertises `password,publickey` and never "none" or keyboard-interactive, because x/crypto
///   lists only the callbacks that are set.
/// - Check mode sends the login message as SSH_MSG_USERAUTH_BANNER
///   (`ServerPreAuthConn.SendAuthBanner`), then holds the request while it waits for the
///   sign-in. The real hold is up to 30 minutes (`delegateFetchTimeout`), then it accepts.
/// - A denial sends a banner and then closes with no failure message.
final class TailscaleLikeSSHServer: @unchecked Sendable {
  enum Policy: Sendable {
    /// The tailnet policy allows the user.
    case accept
    /// Check mode: the banner, then a hold, then success.
    case check(banner: String, hold: TimeAmount)
    /// Check mode with a hold the test ends: the banner, then a hold until `endCheck()` or
    /// `stop()`. A long `.check` hold leaves its promise unfulfilled at `stop()`, and NIO
    /// traps on that.
    case checkUntilEnded(banner: String)
    /// The tailnet policy denies the user: the banner, then the connection closes.
    case deny(banner: String)
    /// A denial whose end the test picks: the banner, then a hold until `endDenial(_:)`.
    case denyLater(banner: String)
    /// Not Tailscale: an ordinary sshd that sends a notice banner and then refuses the
    /// credential with SSH_MSG_USERAUTH_FAILURE.
    case refuse(banner: String)
  }

  private let group: MultiThreadedEventLoopGroup
  private let channel: Channel
  let port: Int
  let hostPublicKey: NIOSSHPublicKey
  /// The auth methods clients offered, in order.
  let offers: OfferLog
  private let heldDenial = HeldDenial()
  private let heldCheck = HeldCheck()

  /// How a held denial ends. A real tailscaled may end one with SSH_MSG_DISCONNECT or a
  /// dropped socket instead of a plain close.
  enum DenialEnding: Sendable, CaseIterable {
    case disconnect
    case reset
  }

  init(policy: Policy) async throws {
    group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let offers = OfferLog()
    self.offers = offers
    let heldDenial = heldDenial
    let heldCheck = heldCheck
    let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
    hostPublicKey = hostKey.publicKey

    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          let delegate = TailscaleAuthDelegate(
            policy: policy, offers: offers, heldDenial: heldDenial, heldCheck: heldCheck)
          let handler = NIOSSHHandler(
            role: .server(SSHServerConfiguration(hostKeys: [hostKey], userAuthDelegate: delegate)),
            allocator: channel.allocator,
            inboundChildChannelInitializer: { child, _ in
              child.eventLoop.makeFailedFuture(EmbeddedServerError.unsupportedChannelType)
            }
          )
          delegate.handler = handler
          delegate.channel = channel
          try channel.pipeline.syncOperations.addHandler(handler)
        }
      }

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

  /// Ends the request a `.denyLater` policy holds. Call it after the client has the banner.
  func endDenial(_ ending: DenialEnding) async throws {
    guard let held = heldDenial.take() else { throw NoHeldDenial() }
    try await held.channel.eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
      switch ending {
      case .disconnect:
        do {
          try held.handler._disconnect()
        } catch {
          return held.channel.eventLoop.makeFailedFuture(error)
        }
        return held.channel.close()
      case .reset:
        // SO_LINGER 0 makes the close a TCP reset, so the client's read fails.
        guard let socket = held.channel as? SocketOptionProvider else {
          return held.channel.eventLoop.makeFailedFuture(NoHeldDenial())
        }
        return socket.setSoLinger(linger(l_onoff: 1, l_linger: 0)).flatMap {
          held.channel.close()
        }
      }
    }.always { _ in held.promise.fail(Denied()) }.get()
  }

  /// Ends the request a `.checkUntilEnded` policy holds, with no success. Call it after the
  /// client has gone. Does nothing when no request is held.
  func endCheck() async {
    guard let promise = heldCheck.take() else { return }
    // On the promise's loop, which `stop()` has not shut down yet.
    try? await promise.futureResult.eventLoop.submit { promise.fail(Denied()) }.get()
  }

  /// Awaited, never blocking. See `EmbeddedSSHServer.stop()`.
  ///
  /// Ends a check still held first, so a test that fails before its own `endCheck()` does
  /// not trap the whole process on an unfulfilled promise.
  func stop() async {
    await endCheck()
    try? await channel.close().get()
    try? await group.shutdownGracefully()
  }
}

/// The request a `.denyLater` policy holds, until the test ends it.
private final class HeldDenial: @unchecked Sendable {
  /// Unchecked for `NIOSSHHandler`, which `endDenial(_:)` touches only on the channel's loop.
  struct Held: @unchecked Sendable {
    let channel: Channel
    let handler: NIOSSHHandler
    let promise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
  }

  private let lock = NSLock()
  private var held: Held?

  func hold(_ value: Held) {
    lock.withLock { held = value }
  }

  func take() -> Held? {
    lock.withLock {
      defer { held = nil }
      return held
    }
  }
}

/// The request a `.checkUntilEnded` policy holds, until the test ends it.
private final class HeldCheck: @unchecked Sendable {
  private let lock = NSLock()
  private var held: EventLoopPromise<NIOSSHUserAuthenticationOutcome>?

  func hold(_ promise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
    lock.withLock { held = promise }
  }

  func take() -> EventLoopPromise<NIOSSHUserAuthenticationOutcome>? {
    lock.withLock {
      defer { held = nil }
      return held
    }
  }
}

final class OfferLog: @unchecked Sendable {
  private let lock = NSLock()
  private var methods: [String] = []

  func record(_ method: String) {
    lock.withLock { methods.append(method) }
  }

  var seen: [String] { lock.withLock { methods } }
}

/// Confined to the child channel's event loop, where NIOSSH calls it.
private final class TailscaleAuthDelegate: NIOSSHServerUserAuthenticationDelegate,
  @unchecked Sendable
{
  private let policy: TailscaleLikeSSHServer.Policy
  private let offers: OfferLog
  private let heldDenial: HeldDenial
  private let heldCheck: HeldCheck
  weak var handler: NIOSSHHandler?
  weak var channel: Channel?

  init(
    policy: TailscaleLikeSSHServer.Policy,
    offers: OfferLog,
    heldDenial: HeldDenial,
    heldCheck: HeldCheck
  ) {
    self.policy = policy
    self.offers = offers
    self.heldDenial = heldDenial
    self.heldCheck = heldCheck
  }

  var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods {
    [.password, .publicKey]
  }

  func requestReceived(
    request: NIOSSHUserAuthenticationRequest,
    responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
  ) {
    switch request.request {
    case .none:
      offers.record("none")
    case .password:
      offers.record("password")
    case .publicKey:
      offers.record("publickey")
    case .hostBased:
      offers.record("hostbased")
      responsePromise.succeed(.failure)
      return
    }

    switch policy {
    case .accept:
      responsePromise.succeed(.success)
    case .check(let banner, let hold):
      let loop = responsePromise.futureResult.eventLoop
      // Not inline: NIOSSH calls this delegate from inside its state machine's mutation, and
      // a write from here is an exclusivity violation (measured: signal 6). The next loop
      // turn is still before the success, which is what check mode does.
      loop.execute { [self] in sendBanner(banner) }
      loop.scheduleTask(in: hold) {
        responsePromise.succeed(.success)
      }
    case .checkUntilEnded(let banner):
      // Held before the banner goes out, so a client that has the banner can end the hold.
      heldCheck.hold(responsePromise)
      let loop = responsePromise.futureResult.eventLoop
      // Not inline, for the reason above.
      loop.execute { [self] in sendBanner(banner) }
    case .refuse(let banner):
      let loop = responsePromise.futureResult.eventLoop
      // Not inline, for the reason above.
      loop.execute { [self] in
        sendBanner(banner)
        responsePromise.succeed(.failure)
      }
    case .deny(let banner):
      let loop = responsePromise.futureResult.eventLoop
      // Not inline, for the reason above. No failure message: the connection just closes.
      loop.execute { [self] in
        sendBanner(banner)
        channel?.close(promise: nil)
        responsePromise.fail(Denied())
      }
    case .denyLater(let banner):
      let loop = responsePromise.futureResult.eventLoop
      // Not inline, for the reason above. Held before the banner goes out, so a client that
      // has the banner can end the denial.
      loop.execute { [self] in
        if let channel, let handler {
          heldDenial.hold(.init(channel: channel, handler: handler, promise: responsePromise))
        }
        sendBanner(banner)
      }
    }
  }

  private func sendBanner(_ text: String) {
    handler?.writeFromChildChannel(.userAuthBanner(.init(message: text, languageTag: "")), nil)
    handler?.flushFromChildChannel()
  }
}

/// Settles a denied request's promise once the connection is closed. NIO traps on a promise
/// released unfulfilled, and a `.failure` outcome would send the failure message that
/// Tailscale does not send.
private struct Denied: Error {}

/// `endDenial(_:)` found no held request, or no socket to reset.
private struct NoHeldDenial: Error {}
