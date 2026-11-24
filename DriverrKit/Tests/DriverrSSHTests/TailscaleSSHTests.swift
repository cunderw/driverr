import Crypto
import DriverrCore
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Testing
@testable import DriverrSSH

/// Driverr against a server that authenticates like Tailscale SSH (#171). See
/// `TailscaleLikeSSHServer` for the measured behaviour it imitates.
@Suite("Tailscale SSH")
struct TailscaleSSHTests {
  /// What a check-mode banner says. The control plane writes the text, so only "it holds a
  /// URL" is a fact; the wording is not.
  static let checkBanner =
    "# Tailscale SSH requires an additional check.\n"
    + "# To authenticate, visit: https://login.tailscale.com/a/1a2b3c4d5e6f\n"

  fileprivate func withServer(
    _ policy: TailscaleLikeSSHServer.Policy,
    _ body: (TailscaleLikeSSHServer, DriverrCore.Host) async throws -> Void
  ) async throws {
    let server = try await TailscaleLikeSSHServer(policy: policy)
    let host = DriverrCore.Host(
      name: "tailnet",
      hostname: "127.0.0.1",
      port: server.port,
      username: "carson"
    )
    do {
      try await body(server, host)
    } catch {
      await server.stop()
      throw error
    }
    await server.stop()
  }

  // MARK: - Behaviour that holds today

  /// Tailscale's PasswordCallback ignores the value, so a host saved with a password already
  /// connects in accept mode. Pins "hosts with a password behave as before".
  @Test("a Tailscale server accepts any password")
  func anyPasswordIsAccepted() async throws {
    try await withServer(.accept) { server, host in
      let transport = NIOSSHTransport()
      try await transport.connect(to: host, hostKeyValidator: TrustingValidator())
      try await transport.authenticate(.password("not-the-users-password"))
      await transport.disconnect()
      #expect(server.offers.seen == ["password"])
    }
  }

  /// Tailscale's PublicKeyCallback ignores the key. Pins "hosts with a key behave as before".
  @Test("a Tailscale server accepts any key")
  func anyKeyIsAccepted() async throws {
    try await withServer(.accept) { server, host in
      let transport = NIOSSHTransport()
      try await transport.connect(to: host, hostKeyValidator: TrustingValidator())
      let key = Curve25519.Signing.PrivateKey()
      try await transport.authenticate(
        .privateKey(SSHPrivateKey(rawRepresentation: key.rawRepresentation))
      )
      await transport.disconnect()
      #expect(server.offers.seen == ["publickey"])
    }
  }

  /// Measures swift-nio-ssh 0.15.0, not Driverr: its client can offer "none" first, even
  /// though the server never advertises it, and it fires the check-mode banner as a
  /// `NIOUserAuthBannerEvent` on the parent pipeline while the request is held, before
  /// `UserAuthSuccessEvent`. Nothing in the library calls a delegate with the banner.
  @Test("swift-nio-ssh offers none and delivers the banner before the held success")
  func libraryOffersNoneAndSurfacesTheBanner() async throws {
    try await withServer(.check(banner: Self.checkBanner, hold: .milliseconds(300))) {
      server, host in
      let events = try await RawNoneClient.run(port: host.port, username: host.username)
      #expect(server.offers.seen == ["none"])
      #expect(events == ["banner: \(Self.checkBanner)", "success"])
    }
  }

  // MARK: - The regression

  /// Check mode holds the request while the user signs in on the web: up to 30 minutes.
  /// Driverr's handshake deadline (20 s) covers `authenticate`, so the connect fails while
  /// the user is still signing in, and the URL that told them to sign in is never shown.
  /// The hold here outlasts a shortened deadline the same way.
  ///
  /// After #171 a login banner must stop the deadline (or count as asking time, as the trust
  /// prompt does), and the connect must finish once the server accepts. A stalled server
  /// that sent no banner must still fail on the deadline
  /// (`ConnectionCoordinatorTests.handshakeDeadlineEndsAStalledConnect`).
  @Test("a check-mode hold that outlasts the handshake deadline still connects")
  func checkModeHoldOutlastsTheDeadline() async throws {
    try await withServer(.check(banner: Self.checkBanner, hold: .milliseconds(1500))) {
      server, host in
      let coordinator = ConnectionCoordinator(
        transport: NIOSSHTransport(),
        handshakeDeadline: .milliseconds(500)
      )
      try? await coordinator.connect(
        to: host,
        validator: TrustingValidator(),
        credential: .password("ignored-by-tailscale")
      )
      let phase = await coordinator.phase
      await coordinator.disconnect()
      #expect(
        phase == .connected,
        "the deadline ended the connect while Tailscale held it for a sign-in: \(phase)"
      )
    }
  }
}

extension TailscaleSSHTests {
  /// The guard on the fix above. Ordinary sshd hosts send pre-auth banners too (an /etc/issue
  /// notice), so a banner alone must not stop the deadline; only a sign-in URL may. Passes
  /// today and must still pass after #171.
  @Test("a held request after a banner with no URL still fails on the deadline")
  func bannerWithoutURLKeepsTheDeadline() async throws {
    let notice = "Authorized use only. Activity is logged.\n"
    try await withServer(.check(banner: notice, hold: .milliseconds(1500))) { _, host in
      let coordinator = ConnectionCoordinator(
        transport: NIOSSHTransport(),
        handshakeDeadline: .milliseconds(500)
      )
      try? await coordinator.connect(
        to: host,
        validator: TrustingValidator(),
        credential: .password("ignored-by-tailscale")
      )
      let phase = await coordinator.phase
      await coordinator.disconnect()
      guard case .failed(.connectionFailed) = phase else {
        Issue.record("a banner with no URL stopped the handshake deadline: \(phase)")
        return
      }
    }
  }
}

extension TailscaleSSHTests {
  /// A host saved with "Tailscale SSH (no password)" offers nothing but the username.
  @Test("none authentication connects to a Tailscale server and offers no credential")
  func noneAuthenticationConnects() async throws {
    try await withServer(.accept) { server, host in
      let transport = NIOSSHTransport()
      try await transport.connect(to: host, hostKeyValidator: TrustingValidator())
      try await transport.authenticate(.none)
      await transport.disconnect()
      #expect(server.offers.seen == ["none"])
    }
  }

  /// Check mode: the URL reaches the caller while the server still holds the request, and
  /// the connect finishes after the hold.
  @Test("the check banner's sign-in URL surfaces before the connect succeeds")
  func checkBannerURLSurfacesBeforeSuccess() async throws {
    try await withServer(.check(banner: Self.checkBanner, hold: .milliseconds(400))) {
      server, host in
      let log = EventLog()
      let coordinator = ConnectionCoordinator(transport: NIOSSHTransport())
      try await coordinator.connect(
        to: host,
        validator: TrustingValidator(),
        credential: .none,
        onSignIn: { url in log.record("signIn: \(url.absoluteString)") }
      )
      log.record("connected")
      let phase = await coordinator.phase
      await coordinator.disconnect()
      #expect(phase == .connected)
      #expect(server.offers.seen == ["none"])
      #expect(
        log.events == ["signIn: https://login.tailscale.com/a/1a2b3c4d5e6f", "connected"])
    }
  }

  /// A denial sends a banner and closes with no failure message. The banner is the only
  /// reason the user gets, so the failure carries it.
  @Test("a denial banner surfaces in the failure")
  func denialBannerSurfacesInTheFailure() async throws {
    let denial = "\nTailscale SSH: tailnet policy does not permit you to SSH to this node.\n"
    try await withServer(.deny(banner: denial)) { _, host in
      let log = EventLog()
      let coordinator = ConnectionCoordinator(transport: NIOSSHTransport())
      do {
        try await coordinator.connect(
          to: host,
          validator: TrustingValidator(),
          credential: .none,
          onSignIn: { url in log.record("signIn: \(url.absoluteString)") }
        )
        Issue.record("a denied connect succeeded")
      } catch let error as AppError {
        #expect(
          error
            == .authenticationRefused(
              host: "127.0.0.1",
              message: "Tailscale SSH: tailnet policy does not permit you to SSH to this node."))
      }
      let phase = await coordinator.phase
      await coordinator.disconnect()
      guard case .failed(.authenticationRefused) = phase else {
        Issue.record("expected the refusal in the phase: \(phase)")
        return
      }
      // A banner with no link offers nothing to open.
      #expect(log.events.isEmpty)
    }
  }
}

extension TailscaleSSHTests {
  /// An sshd's notice banner is not the reason a password was wrong, so a real
  /// SSH_MSG_USERAUTH_FAILURE keeps the ordinary refusal.
  @Test("a wrong password after a notice banner is an ordinary refusal")
  func wrongPasswordAfterANoticeBannerIsAnOrdinaryRefusal() async throws {
    try await withServer(.refuse(banner: "Authorized use only. Activity is logged.\n")) {
      _, host in
      let transport = NIOSSHTransport()
      try await transport.connect(to: host, hostKeyValidator: TrustingValidator())
      do {
        try await transport.authenticate(.password("wrong"))
        Issue.record("a refused password authenticated")
      } catch let error as AppError {
        #expect(error == .authenticationFailed(host: "127.0.0.1"))
      }
      await transport.disconnect()
    }
  }

  /// A close after only the check-mode banner is the sign-in ending. The URL is not a reason
  /// to quote.
  @Test("a close after only the sign-in banner does not quote the URL")
  func closeAfterTheSignInBannerDoesNotQuoteTheURL() async throws {
    try await withServer(.deny(banner: Self.checkBanner)) { _, host in
      let log = EventLog()
      let coordinator = ConnectionCoordinator(transport: NIOSSHTransport())
      do {
        try await coordinator.connect(
          to: host,
          validator: TrustingValidator(),
          credential: .none,
          onSignIn: { url in log.record("signIn: \(url.absoluteString)") }
        )
        Issue.record("a closed connect succeeded")
      } catch let error as AppError {
        #expect(
          error
            == .disconnected(reason: "127.0.0.1 closed the connection before the sign-in finished."))
      }
      await coordinator.disconnect()
      #expect(log.events == ["signIn: https://login.tailscale.com/a/1a2b3c4d5e6f"])
    }
  }

  /// A real tailscaled may end a denial with SSH_MSG_DISCONNECT or a dropped socket, not a
  /// plain close. A reset reaches the pipeline as an error before the close, and the banner
  /// is still the only reason the user gets.
  @Test(
    "a denial that ends in a disconnect or a reset still quotes the banner",
    .timeLimit(.minutes(1)),
    arguments: TailscaleLikeSSHServer.DenialEnding.allCases)
  func denialEndingInADisconnectOrResetQuotesTheBanner(
    ending: TailscaleLikeSSHServer.DenialEnding
  ) async throws {
    let denial = "\nTailscale SSH: tailnet policy does not permit you to SSH to this node.\n"
    try await withServer(.denyLater(banner: denial)) { server, host in
      let transport = NIOSSHTransport()
      try await transport.connect(to: host, hostKeyValidator: TrustingValidator())
      let banners = await transport.authenticationBanners
      async let outcome = Self.failure(of: transport)
      var received = banners.makeAsyncIterator()
      let banner = await received.next()
      #expect(banner == denial)
      try await server.endDenial(ending)
      let error = await outcome
      await transport.disconnect()
      #expect(
        error
          == .authenticationRefused(
            host: "127.0.0.1",
            message: "Tailscale SSH: tailnet policy does not permit you to SSH to this node."))
    }
  }

  /// Cancel during a held sign-in, as a scene's Cancel does (#175). `NIOSSHTransport` waits
  /// on futures that ignore cancellation, so cancelling the task alone ends nothing. The
  /// disconnect is what fails the held request, and the connect has to settle after it.
  @Test("cancelling a held sign-in settles the connect", .timeLimit(.minutes(1)))
  func cancellingAHeldSignInSettlesTheConnect() async throws {
    try await withServer(.checkUntilEnded(banner: Self.checkBanner)) { server, host in
      let coordinator = ConnectionCoordinator(transport: NIOSSHTransport())
      let (signIns, signedIn) = AsyncStream.makeStream(of: URL.self)
      let attempt = Task {
        try await coordinator.connect(
          to: host,
          validator: TrustingValidator(),
          credential: .none,
          onSignIn: { url in signedIn.yield(url) }
        )
      }
      // A signal, not a sleep: the server holds the request from here on.
      var received = signIns.makeAsyncIterator()
      let url = await received.next()
      #expect(url?.absoluteString == "https://login.tailscale.com/a/1a2b3c4d5e6f")

      attempt.cancel()
      await coordinator.disconnect()
      let outcome = await attempt.result
      let phase = await coordinator.phase
      await server.endCheck()

      guard case .failure = outcome else {
        Issue.record("a connect cancelled during its sign-in succeeded")
        return
      }
      #expect(phase == .idle, "the cancelled connect left the coordinator at \(phase)")
    }
  }

  /// The error `authenticate(.none)` fails with, or `nil` when it succeeds.
  private static func failure(of transport: NIOSSHTransport) async -> AppError? {
    do {
      try await transport.authenticate(.none)
      return nil
    } catch let error as AppError {
      return error
    } catch {
      return .channelFailed(reason: "not an AppError: \(error)")
    }
  }
}

/// Records events from the `@Sendable` sign-in callback, in order.
private final class EventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []

  func record(_ event: String) {
    lock.withLock { recorded.append(event) }
  }

  var events: [String] { lock.withLock { recorded } }
}

private struct TrustingValidator: HostKeyValidator {
  func validate(_ key: SSHHostKey, for host: DriverrCore.Host) async -> HostKeyDecision {
    .trust
  }
}

/// A bare swift-nio-ssh client that offers "none" and records the auth events it sees.
private enum RawNoneClient {
  static func run(port: Int, username: String) async throws -> [String] {
    let loop = MultiThreadedEventLoopGroup.singleton.next()
    let done = loop.makePromise(of: [String].self)
    let recorder = EventRecorder(done: done)
    let bootstrap = ClientBootstrap(group: loop).channelInitializer { channel in
      channel.eventLoop.makeCompletedFuture {
        try channel.pipeline.syncOperations.addHandlers([
          NIOSSHHandler(
            role: .client(
              SSHClientConfiguration(
                userAuthDelegate: NoneDelegate(username: username),
                serverAuthDelegate: AcceptAnyHostKey()
              )
            ),
            allocator: channel.allocator,
            inboundChildChannelInitializer: nil
          ),
          recorder,
        ])
      }
    }
    let channel = try await bootstrap.connect(host: "127.0.0.1", port: port).get()
    let timeout = loop.scheduleTask(in: .seconds(5)) {
      recorder.settle(.failure(AppError.channelFailed(reason: "no auth outcome within 5 s")))
    }
    defer { timeout.cancel() }
    do {
      let events = try await done.futureResult.get()
      try? await channel.close().get()
      return events
    } catch {
      try? await channel.close().get()
      throw error
    }
  }

  final class NoneDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let username: String
    var offered = false
    init(username: String) { self.username = username }

    func nextAuthenticationType(
      availableMethods: NIOSSHAvailableUserAuthenticationMethods,
      nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
      guard !offered else {
        nextChallengePromise.succeed(nil)
        return
      }
      offered = true
      nextChallengePromise.succeed(
        NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .none)
      )
    }
  }

  final class AcceptAnyHostKey: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    func validateHostKey(
      hostKey: NIOSSHPublicKey,
      validationCompletePromise: EventLoopPromise<Void>
    ) {
      validationCompletePromise.succeed(())
    }
  }

  final class EventRecorder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    private let done: EventLoopPromise<[String]>
    private var events: [String] = []
    private var settled = false

    init(done: EventLoopPromise<[String]>) { self.done = done }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
      if let banner = event as? NIOUserAuthBannerEvent {
        events.append("banner: \(banner.message)")
      } else if event is UserAuthSuccessEvent {
        events.append("success")
        settle(.success(events))
      }
      context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
      settle(.failure(AppError.channelFailed(reason: "closed before auth finished: \(events)")))
      context.fireChannelInactive()
    }

    /// On the loop only. The first outcome wins.
    func settle(_ result: Result<[String], any Error>) {
      guard !settled else { return }
      settled = true
      done.completeWith(result)
    }
  }
}
