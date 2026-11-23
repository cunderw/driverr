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
/// - A denial (not imitated here) sends a banner and then closes with no failure message.
final class TailscaleLikeSSHServer: @unchecked Sendable {
  enum Policy: Sendable {
    /// The tailnet policy allows the user.
    case accept
    /// Check mode: the banner, then a hold, then success.
    case check(banner: String, hold: TimeAmount)
  }

  private let group: MultiThreadedEventLoopGroup
  private let channel: Channel
  let port: Int
  let hostPublicKey: NIOSSHPublicKey
  /// The auth methods clients offered, in order.
  let offers: OfferLog

  init(policy: Policy) async throws {
    group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let offers = OfferLog()
    self.offers = offers
    let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
    hostPublicKey = hostKey.publicKey

    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          let delegate = TailscaleAuthDelegate(policy: policy, offers: offers)
          let handler = NIOSSHHandler(
            role: .server(SSHServerConfiguration(hostKeys: [hostKey], userAuthDelegate: delegate)),
            allocator: channel.allocator,
            inboundChildChannelInitializer: { child, _ in
              child.eventLoop.makeFailedFuture(EmbeddedServerError.unsupportedChannelType)
            }
          )
          delegate.handler = handler
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

  /// Awaited, never blocking. See `EmbeddedSSHServer.stop()`.
  func stop() async {
    try? await channel.close().get()
    try? await group.shutdownGracefully()
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
  weak var handler: NIOSSHHandler?

  init(policy: TailscaleLikeSSHServer.Policy, offers: OfferLog) {
    self.policy = policy
    self.offers = offers
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
    }
  }

  private func sendBanner(_ text: String) {
    handler?.writeFromChildChannel(.userAuthBanner(.init(message: text, languageTag: "")), nil)
    handler?.flushFromChildChannel()
  }
}
