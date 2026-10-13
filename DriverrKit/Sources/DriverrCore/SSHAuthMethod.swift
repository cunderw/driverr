/// A credential offered to a server during SSH user authentication.
///
/// Carries secrets, so it overrides its debug description. The synthesised one prints
/// associated values, which would put a password or key into a log or crash report.
public enum SSHAuthMethod: Sendable, CustomDebugStringConvertible, CustomStringConvertible {
  case password(String)
  case privateKey(SSHPrivateKey)

  public var debugDescription: String {
    switch self {
    case .password: "SSHAuthMethod.password(<redacted>)"
    case .privateKey: "SSHAuthMethod.privateKey(<redacted>)"
    }
  }

  /// Mirrors `debugDescription`, so `String(describing:)` and interpolation are redacted too.
  public var description: String { debugDescription }
}
