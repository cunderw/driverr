import Crypto
import DriverrCore
import Foundation

/// Reads OpenSSH's `openssh-key-v1` private key files.
///
/// swift-nio-ssh has no private-key parser, and a pasted key is always this format.
///
/// Only unencrypted Ed25519 keys are supported, as `ssh-keygen -t ed25519` produces.
/// Anything else is refused with a message that says what to do.
public enum OpenSSHPrivateKey {
  /// An Ed25519 key pair recovered from a private key file.
  public struct Parsed: Sendable {
    /// The private scalar, ready for `SSHAuthMethod.privateKey`.
    public let privateKey: SSHPrivateKey
    /// The raw 32-byte public point.
    public let publicKeyRaw: Data
    /// The SSH wire-format public key blob, the base64 in an `authorized_keys` line.
    public let publicKeyBlob: Data
    public let comment: String

    public var publicKeyBase64: String { publicKeyBlob.base64EncodedString() }
  }

  private static let magic = "openssh-key-v1\0"
  private static let ed25519 = "ssh-ed25519"

  public static func parse(pem: String) throws -> Parsed {
    let body = try base64Body(of: pem)
    var reader = SSHWireReader(body)

    guard reader.readRawString(count: magic.utf8.count) == magic else {
      throw AppError.keyImportFailed(
        reason: "That does not look like an OpenSSH private key."
      )
    }

    let cipher = try reader.readString()
    let kdf = try reader.readString()
    _ = try reader.readData()  // kdf options

    guard cipher == "none", kdf == "none" else {
      throw AppError.keyImportFailed(
        reason: """
          That key is protected by a passphrase. Make a copy of the key, remove the \
          passphrase from the copy with `ssh-keygen -p -f <copy>`, import the copy, then \
          delete it.
          """
      )
    }

    guard try reader.readUInt32() == 1 else {
      throw AppError.keyImportFailed(reason: "That file contains more than one key.")
    }

    let publicKeyBlob = try reader.readData()
    let privateSection = try reader.readData()
    var privateReader = SSHWireReader(privateSection)

    // OpenSSH writes two equal check integers. They always match in an unencrypted key.
    let check1 = try privateReader.readUInt32()
    let check2 = try privateReader.readUInt32()
    guard check1 == check2 else {
      throw AppError.keyImportFailed(reason: "That key file appears to be damaged.")
    }

    let keyType = try privateReader.readString()
    guard keyType == ed25519 else {
      throw AppError.keyImportFailed(
        reason: "Driverr supports Ed25519 keys. That one is \(keyType)."
      )
    }

    let publicKeyRaw = try privateReader.readData()
    let privateBlob = try privateReader.readData()
    let comment = try privateReader.readString()

    // OpenSSH stores seed || public key in one 64-byte field; CryptoKit wants the seed.
    guard privateBlob.count == 64 else {
      throw AppError.keyImportFailed(reason: "That key file appears to be damaged.")
    }
    let seed = privateBlob.prefix(32)

    return Parsed(
      privateKey: SSHPrivateKey(algorithm: .ed25519, rawRepresentation: Data(seed)),
      publicKeyRaw: publicKeyRaw,
      publicKeyBlob: publicKeyBlob,
      comment: comment
    )
  }

  /// Strips the PEM armour and decodes the base64 between the markers.
  private static func base64Body(of pem: String) throws -> Data {
    let lines = pem.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard lines.contains(where: { $0.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY") }) else {
      // Name the supported format. Users often paste an RSA or PuTTY key.
      throw AppError.keyImportFailed(
        reason: """
          Driverr supports OpenSSH-format Ed25519 keys. Generate one with \
          `ssh-keygen -t ed25519`.
          """
      )
    }

    let base64 = lines.filter { !$0.hasPrefix("-----") }.joined()
    guard let data = Data(base64Encoded: base64), !data.isEmpty else {
      throw AppError.keyImportFailed(reason: "That key file could not be decoded.")
    }
    return data
  }
}

/// Reads SSH's wire encoding: big-endian `uint32` lengths followed by that many bytes.
private struct SSHWireReader {
  private let bytes: Data
  private var offset: Int

  init(_ bytes: Data) {
    self.bytes = bytes
    offset = bytes.startIndex
  }

  mutating func readUInt32() throws -> UInt32 {
    try require(4)
    defer { offset += 4 }
    return bytes[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  }

  mutating func readData() throws -> Data {
    let length = Int(try readUInt32())
    try require(length)
    defer { offset += length }
    return Data(bytes[offset..<offset + length])
  }

  mutating func readString() throws -> String {
    String(decoding: try readData(), as: UTF8.self)
  }

  mutating func readRawString(count: Int) -> String? {
    guard (try? require(count)) != nil else { return nil }
    defer { offset += count }
    return String(decoding: bytes[offset..<offset + count], as: UTF8.self)
  }

  private func require(_ count: Int) throws {
    guard count >= 0, offset + count <= bytes.endIndex else {
      throw AppError.keyImportFailed(reason: "That key file appears to be truncated.")
    }
  }
}
