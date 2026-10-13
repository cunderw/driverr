import CryptoKit
import Foundation

/// OpenSSH's modern fingerprint for an SSH public key blob, e.g.
/// `SHA256:3ZVlu7DWz3ouUzrF93cx5zY5jkgAbT4R9WQqqZJePA8`.
///
/// Shared by host keys and identities, both of which a user may compare against
/// `ssh-keygen -lf`, so there is one copy of the format, stripped padding included.
func sshFingerprint(of blob: Data) -> String {
  let digest = SHA256.hash(data: blob)
  let base64 = Data(digest).base64EncodedString()
  return "SHA256:" + base64.replacingOccurrences(of: "=", with: "")
}

/// Encodes a value as an SSH wire "string": a big-endian `uint32` length, then bytes.
public func sshWireString(_ bytes: Data) -> Data {
  var out = Data()
  let length = UInt32(bytes.count)
  out.append(contentsOf: [
    UInt8((length >> 24) & 0xFF),
    UInt8((length >> 16) & 0xFF),
    UInt8((length >> 8) & 0xFF),
    UInt8(length & 0xFF),
  ])
  out.append(bytes)
  return out
}
