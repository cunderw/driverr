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
  /// Every sign-in a held transport is waiting on. See `endSignInHolds()`.
  private let signInHolds = SignInHolds()
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
  /// web, as Tailscale SSH's check mode does: the check banner, then a hold.
  ///
  /// The hold has no clock. Cancelling the connect ends it, and so does `endSignInHolds()`.
  /// Scoped to new transports, so a test can arm it before dropping the link and only the
  /// reconnect meets the sign-in.
  var holdsNewTransportsForSignIn: Bool {
    get { lock.withLock { holdingForSignIn } }
    set { lock.withLock { holdingForSignIn = newValue } }
  }

  /// Ends every sign-in a held transport is waiting on, or starts waiting on from now, the way
  /// a host closes the connection before the sign-in finishes.
  ///
  /// From now as well, because the URL shows before the hold has parked.
  func endSignInHolds() {
    signInHolds.endAll()
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
    let id = lock.withLock {
      issued += 1
      return issued
    }
    let transport = FakeSSHTransport(
      acceptsCredentials: accepting,
      authenticationBanner: holding ? Self.checkBanner : nil,
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
    guard holding else { return transport }
    return SignInHoldTransport(inner: transport, holds: signInHolds)
  }
}

/// A transport whose authentication waits on a sign-in after the check banner, until the
/// connect is cancelled or the test calls `TransportSupply.endSignInHolds()`.
///
/// A wrapper because `FakeSSHTransport`'s own hold is a clock, which previews, demo mode and
/// the UI suite share. The banner is the fake's: it goes out before this hold starts.
private final class SignInHoldTransport: SSHTransport {
  private let inner: FakeSSHTransport
  private let holds: SignInHolds

  init(inner: FakeSSHTransport, holds: SignInHolds) {
    self.inner = inner
    self.holds = holds
  }

  func connect(to host: DriverrCore.Host, hostKeyValidator: any HostKeyValidator) async throws {
    try await inner.connect(to: host, hostKeyValidator: hostKeyValidator)
  }

  /// The banner, then the hold. An ended hold is the host closing the connection, which is
  /// what `NIOSSHTransport` reports for a close after only the sign-in banner.
  func authenticate(_ method: SSHAuthMethod) async throws {
    try await inner.authenticate(method)
    try await holds.hold()
    throw AppError.disconnected(
      reason: "The host closed the connection before the sign-in finished.")
  }

  func ptyChannel(size: TerminalSize) async throws -> any PTYChannel {
    try await inner.ptyChannel(size: size)
  }

  func execChannel(command: String) async throws -> CommandResult {
    try await inner.execChannel(command: command)
  }

  func execStream(command: String) async throws -> any ExecStream {
    try await inner.execStream(command: command)
  }

  func disconnect() async {
    await inner.disconnect()
  }

  var disconnections: AsyncStream<AppError> {
    get async { await inner.disconnections }
  }

  var authenticationBanners: AsyncStream<String> {
    get async { await inner.authenticationBanners }
  }
}

/// The sign-ins held transports wait on. A lock rather than an actor, because
/// `endSignInHolds()` is called from synchronous test code.
private final class SignInHolds: @unchecked Sendable {
  private let lock = NSLock()
  private var waiting: [UUID: CheckedContinuation<Void, any Error>] = [:]
  /// Holds cancelled before they parked, so they do not park at all.
  private var cancelled: Set<UUID> = []
  /// Set by `endAll()`, after which a hold ends as soon as it starts.
  private var ended = false

  /// Returns when `endAll()` runs or has run, and throws `CancellationError` when the task is cancelled.
  func hold() async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let outcome: Result<Void, any Error>? = lock.withLock {
          if cancelled.remove(id) != nil { return .failure(CancellationError()) }
          if ended { return .success(()) }
          waiting[id] = continuation
          return nil
        }
        if let outcome { continuation.resume(with: outcome) }
      }
    } onCancel: {
      let parked = lock.withLock {
        if let continuation = waiting.removeValue(forKey: id) { return Optional(continuation) }
        cancelled.insert(id)
        return nil
      }
      parked?.resume(throwing: CancellationError())
    }
  }

  func endAll() {
    let all = lock.withLock {
      ended = true
      defer { waiting = [:] }
      return Array(waiting.values)
    }
    for continuation in all { continuation.resume() }
  }
}
