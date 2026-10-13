import Foundation

/// Private key material for SSH public-key authentication.
///
/// Raw material rather than an OpenSSH PEM string. swift-nio-ssh ships no OpenSSH private
/// key parser, so Driverr owns that format with key management (generation, import,
/// Keychain), and the transport only consumes material. `Codable` only for the single
/// Keychain item that holds it; never encode it anywhere else.
public struct SSHPrivateKey: Hashable, Sendable, Codable, CustomDebugStringConvertible,
  CustomStringConvertible
{
  public enum Algorithm: String, Hashable, Sendable, Codable {
    case ed25519
  }

  public let algorithm: Algorithm
  /// The raw scalar: 32 bytes for Ed25519.
  public let rawRepresentation: Data

  public init(algorithm: Algorithm = .ed25519, rawRepresentation: Data) {
    self.algorithm = algorithm
    self.rawRepresentation = rawRepresentation
  }

  /// Redacted, like `SSHAuthMethod`: the synthesised description would print every secret
  /// byte into any log.
  public var debugDescription: String { "SSHPrivateKey(\(algorithm.rawValue), <redacted>)" }
  public var description: String { debugDescription }
}
