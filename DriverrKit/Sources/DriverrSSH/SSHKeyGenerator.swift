import Crypto
import DriverrCore
import Foundation

/// Creates Ed25519 identities on device.
///
/// Ed25519 only: `ssh-keygen` recommends it, its keys fit on a phone screen, and one
/// algorithm leaves the user no choice to make.
public enum SSHKeyGenerator {
  public struct Generated: Sendable {
    /// Goes straight to the Keychain and nowhere else.
    public let privateKey: SSHPrivateKey
    /// Safe to persist, display, and export.
    public let identity: SSHIdentity
  }

  public static func generateEd25519(name: String) -> Generated {
    let key = Curve25519.Signing.PrivateKey()
    return Generated(
      privateKey: SSHPrivateKey(algorithm: .ed25519, rawRepresentation: key.rawRepresentation),
      identity: SSHIdentity(
        name: name,
        publicKeyBlob: OpenSSHPublicKey.blob(forEd25519: key.publicKey.rawRepresentation)
      )
    )
  }
}

/// Builds SSH's wire encoding of a public key.
public enum OpenSSHPublicKey {
  /// `string "ssh-ed25519" || string <32-byte point>`. Its base64 is what
  /// `authorized_keys` holds and what `ssh-keygen -lf` fingerprints.
  public static func blob(forEd25519 rawPoint: Data) -> Data {
    sshWireString(Data("ssh-ed25519".utf8)) + sshWireString(rawPoint)
  }
}
