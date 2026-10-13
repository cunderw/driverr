import Foundation

/// A key pair the user owns, as everything outside the Keychain sees it.
///
/// Only the public half. Identities are listed, shown and persisted as ordinary values,
/// while the private key stays in the Keychain and is fetched only to authenticate, so no
/// screen, store, log or backup can leak it.
public struct SSHIdentity: Identifiable, Hashable, Sendable, Codable {
  public let id: UUID
  /// User-facing label, also used as the key's comment in exported form.
  public var name: String
  /// SSH algorithm name, e.g. `ssh-ed25519`.
  public let algorithm: String
  /// The SSH wire-format public key blob: the base64 part of an `authorized_keys` line.
  public let publicKeyBlob: Data
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    algorithm: String = "ssh-ed25519",
    publicKeyBlob: Data,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.algorithm = algorithm
    self.publicKeyBlob = publicKeyBlob
    self.createdAt = createdAt
  }

  public var fingerprint: String { sshFingerprint(of: publicKeyBlob) }

  /// The line to paste into a remote host's `~/.ssh/authorized_keys`.
  ///
  /// Shaped like an `ssh-keygen` `.pub` file, so it pastes into a server unedited.
  public var authorizedKeysLine: String {
    let comment = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = "\(algorithm) \(publicKeyBlob.base64EncodedString())"
    return comment.isEmpty ? base : "\(base) \(comment)"
  }
}
