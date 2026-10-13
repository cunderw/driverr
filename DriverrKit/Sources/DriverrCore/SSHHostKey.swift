import Foundation

/// A server's public host key, as the domain sees it.
///
/// A plain value, not a NIOSSH type, so the trust prompt and the known-hosts store can show
/// and persist a key without `DriverrSSH`. `CryptoKit` is a system framework, so this module
/// stays dependency-free.
public struct SSHHostKey: Hashable, Sendable, Codable {
  /// The SSH algorithm name, e.g. `ssh-ed25519`.
  public let algorithm: String
  /// The raw public key blob, exactly as it appears base64-encoded in `known_hosts`.
  public let blob: Data

  public init(algorithm: String, blob: Data) {
    self.algorithm = algorithm
    self.blob = blob
  }

  /// The key's fingerprint in OpenSSH's modern form, e.g.
  /// `SHA256:3ZVlu7DWz3ouUzrF93cx5zY5jkgAbT4R9WQqqZJePA8`.
  ///
  /// Byte-identical to `ssh-keygen -lf`, including the stripped base64 padding, so a user can
  /// compare it with a fingerprint read off the server.
  public var fingerprint: String { sshFingerprint(of: blob) }
}
