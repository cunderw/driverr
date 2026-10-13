import DriverrCore
import Foundation

/// What Driverr decided to do about a host key it was shown.
public enum HostKeyDecision: Sendable, Hashable {
  case trust
  /// The user was asked and declined.
  case reject
  /// The host presented a different key than the one already trusted.
  ///
  /// Kept apart from `reject`, because a mismatch may be an interception. It maps to
  /// `AppError.hostKeyMismatch`, which is not retryable, so no UI can offer a way past it.
  case mismatch
}

/// Decides whether a server's presented host key is acceptable.
///
/// The known-hosts store plugs in here. The transport knows when a key must be judged and
/// nothing about trust policy. It is `async` because the answer may need the user.
public protocol HostKeyValidator: Sendable {
  func validate(_ key: SSHHostKey, for host: DriverrCore.Host) async -> HostKeyDecision
}

/// A live pseudo-terminal on a connected host: bytes in, bytes out, resizable.
///
/// A plain byte pipe, so `DriverrTerm` can render it without knowing the source.
public protocol PTYChannel: Sendable {
  /// Everything the remote side has written. Finishes when the channel closes; throws
  /// if it closed abnormally.
  var output: AsyncThrowingStream<Data, any Error> { get }
  func send(_ data: Data) async throws
  func resize(to size: TerminalSize) async throws
  func close() async
}

/// A remote command whose stdin and stdout both stay open for as long as it runs.
///
/// `execChannel` waits for the command to exit, so it cannot serve a long-lived process.
/// `ptyChannel` allocates a pty, which echoes input and may turn `\n` into `\r\n`, and
/// that breaks a line protocol. This is an exec channel with no pty and both directions
/// open, which herdr's terminal bridge needs.
public protocol ExecStream: Sendable {
  /// The command's stdout, as it arrives. Finishes when the command exits; throws if the
  /// channel failed rather than closed.
  var output: AsyncThrowingStream<Data, any Error> { get }
  /// The command's stderr, kept apart from `output` so a warning cannot corrupt a frame.
  /// The buffer is bounded, so a caller may ignore it.
  var standardError: AsyncThrowingStream<Data, any Error> { get }
  /// The exit status, once the command has exited. `nil` while it runs, and also when the
  /// channel went away without one, which is how a caller tells a lost channel from an
  /// exit.
  var exitStatus: Int? { get async }
  func send(_ data: Data) async throws
  func close() async
}

/// An SSH connection to one host.
///
/// The only abstraction over swift-nio-ssh. See the layering rule in `CLAUDE.md`.
///
/// `connect` and `authenticate` are separate, although SSH authenticates inside the
/// handshake, so the host-key prompt comes before the password prompt.
/// `NIOSSHTransport` suspends its auth delegate until `authenticate` supplies a
/// credential.
public protocol SSHTransport: Sendable {
  /// Opens the connection and completes key exchange, consulting `hostKeyValidator`
  /// with the key the server presented. Returns before user authentication.
  func connect(to host: DriverrCore.Host, hostKeyValidator: any HostKeyValidator) async throws
  /// Offers a credential. Must be called after `connect`.
  func authenticate(_ method: SSHAuthMethod) async throws
  func ptyChannel(size: TerminalSize) async throws -> any PTYChannel
  /// Runs one command to completion on its own channel and collects its output.
  func execChannel(command: String) async throws -> CommandResult
  /// Starts a command and keeps both directions open. See `ExecStream`.
  func execStream(command: String) async throws -> any ExecStream
  func disconnect() async
  /// Yields when the connection goes away without Driverr asking: the link dropped, the
  /// server went, the network changed. The error is always `disconnected` and names the
  /// host.
  ///
  /// The coordinator relies on two properties. The stream belongs to one connection, and
  /// the next `connect` gets a fresh one. `disconnect` finishes it before teardown, so a
  /// requested disconnect is never reported as a loss.
  var disconnections: AsyncStream<AppError> { get async }
}
