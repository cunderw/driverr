import DriverrCore
import DriverrSSH
import Foundation

/// The per-connection hooks a `TransportSupply` installs on every transport it hands out.
///
/// A protocol because the one conformer, `HerdrAttachTokens`, is private to
/// `TerminalSceneModelTests`. This lets the supply be shared without moving the token model out
/// of that suite.
protocol TransportConnectionHooks: Sendable {
  /// Answers streamed commands for one connection.
  func responder(connection: Int) -> @Sendable (String) -> Data?
  /// Told when a stream on one connection closes.
  func closeHook(connection: Int) -> @Sendable (String) -> Void
}

/// A supply of fake transports for one host, so a test can watch a **reconnect** rather
/// than a re-use.
///
/// `ConnectionModel.connect` asks `AppEnvironment.makeTransport` for a fresh transport on
/// every attempt, as the app does. `isAccepting` makes the host refuse, which is how a test
/// watches a backoff run to its end.
///
/// `@unchecked Sendable` with a lock because `makeTransport` is a `@Sendable` synchronous
/// closure, so there is no actor to hop to.
final class TransportSupply: @unchecked Sendable {
  private let lock = NSLock()
  private var accepting = true
  private var stalling = false
  private var holdingForSignIn = false
  private var hold = Duration.seconds(600)
  private var handed: [FakeSSHTransport] = []
  private var issued = 0
  private let responder: (@Sendable (String) -> Data?)?
  /// The host's attach tokens, when a test models them. Each connection gets its own view of
  /// the host, so the host can tell one link's controller from the next one's.
  private let tokens: (any TransportConnectionHooks)?

  init(
    responder: (@Sendable (String) -> Data?)? = nil,
    tokens: (any TransportConnectionHooks)? = nil
  ) {
    self.responder = responder
    self.tokens = tokens
  }

  /// Whether the next connection is allowed to authenticate.
  var isAccepting: Bool {
    get { lock.withLock { accepting } }
    set { lock.withLock { accepting = newValue } }
  }

  /// Whether every transport handed out from now on stops answering streamed commands.
  ///
  /// Models a host that reconnects and answers set-up but never answers the re-opened pane's
  /// stream. Scoped to new transports, so a test can arm it before dropping the link.
  var stallsNewTransports: Bool {
    get { lock.withLock { stalling } }
    set { lock.withLock { stalling = newValue } }
  }

  /// Whether every transport handed out from now on holds authentication for a sign-in on the
  /// web, as Tailscale SSH's check mode does: the check banner, then `signInHold`.
  ///
  /// Scoped to new transports, so a test can arm it before dropping the link and only the
  /// reconnect meets the sign-in. Cancelling the connect ends the hold early.
  var holdsNewTransportsForSignIn: Bool {
    get { lock.withLock { holdingForSignIn } }
    set { lock.withLock { holdingForSignIn = newValue } }
  }

  /// How long a held transport holds. A hold that ends while `isAccepting` is `false` ends
  /// in a close, as a host closes the connection before the sign-in finishes.
  var signInHold: Duration {
    get { lock.withLock { hold } }
    set { lock.withLock { hold = newValue } }
  }

  /// What a check-mode host sends before it holds the request.
  static let checkBanner =
    "# Tailscale SSH requires an additional check.\n"
    + "# To authenticate, visit: https://login.tailscale.com/a/1a2b3c4d5e6f\n"

  /// The transport the connection is on now — what a test drops, and what it reads a
  /// stream log off.
  var latest: FakeSSHTransport? { lock.withLock { handed.last } }

  /// Every transport handed out, oldest first, for a question about a link that was replaced.
  var handedOut: [FakeSSHTransport] { lock.withLock { handed } }

  /// How many connections have been attempted through this supply.
  var attempts: Int { lock.withLock { handed.count } }

  /// The id of the connection currently up — what `HerdrAttachTokens.loseConnection` takes.
  var latestConnection: Int { lock.withLock { issued } }

  func make() -> any SSHTransport {
    let accepting = isAccepting
    let holding = holdsNewTransportsForSignIn
    let hold = signInHold
    let id = lock.withLock {
      issued += 1
      return issued
    }
    let transport = FakeSSHTransport(
      acceptsCredentials: accepting,
      authenticationBanner: holding ? Self.checkBanner : nil,
      authenticationHold: holding ? hold : nil,
      refusalClosesTheConnection: holding,
      streamResponder: tokens?.responder(connection: id) ?? responder,
      onStreamClose: tokens?.closeHook(connection: id),
      // On every transport: a reconnect test waits on the new transport's log, so a hook on
      // the first alone would leave waits after the drop with nothing to wake them.
      onActivity: { Waker.signalShared() }
    )
    lock.withLock { handed.append(transport) }
    if stallsNewTransports {
      // A `Task` because `make()` is synchronous and `stopAnswering` is on an actor. It is
      // enqueued long before the first streamed command, which comes after connect, auth and
      // a session refresh. If it lost the race, the test would fail rather than pass wrongly.
      Task { await transport.stopAnswering() }
    }
    return transport
  }
}
