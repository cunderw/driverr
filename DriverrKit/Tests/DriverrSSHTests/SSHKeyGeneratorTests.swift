import Crypto
import DriverrCore
import Foundation
import NIOSSH
import Testing
@testable import DriverrSSH

@Suite("SSHKeyGenerator", .enabled(if: SSHKeygen.isAvailable))
struct SSHKeyGeneratorTests {
  /// Succeeds only if the line is a well-formed `authorized_keys` entry.
  private func fingerprintViaSSHKeygen(_ line: String) throws -> String? {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("driverr-pub-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = directory.appendingPathComponent("id.pub")
    try line.write(to: path, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    process.arguments = ["-l", "-f", path.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }

    // "256 SHA256:… comment (ED25519)"
    return String(decoding: output, as: UTF8.self)
      .split(separator: " ")
      .first(where: { $0.hasPrefix("SHA256:") })
      .map(String.init)
  }

  @Test("a generated key produces an authorized_keys line ssh-keygen accepts")
  func generatedLineIsValid() throws {
    let generated = SSHKeyGenerator.generateEd25519(name: "driverr-test")
    let line = generated.identity.authorizedKeysLine

    #expect(line.hasPrefix("ssh-ed25519 "))
    #expect(try fingerprintViaSSHKeygen(line) != nil, "ssh-keygen rejected the line")
  }

  @Test("our fingerprint matches the one ssh-keygen computes for the same key")
  func fingerprintMatchesSSHKeygen() throws {
    let generated = SSHKeyGenerator.generateEd25519(name: "driverr-test")
    let theirs = try fingerprintViaSSHKeygen(generated.identity.authorizedKeysLine)
    #expect(theirs == generated.identity.fingerprint)
  }

  @Test("each generated key is distinct")
  func keysAreDistinct() {
    let first = SSHKeyGenerator.generateEd25519(name: "a")
    let second = SSHKeyGenerator.generateEd25519(name: "b")
    #expect(first.privateKey != second.privateKey)
    #expect(first.identity.publicKeyBlob != second.identity.publicKeyBlob)
  }

  @Test("a generated key can actually authenticate to a server that trusts it")
  func generatedKeyAuthenticates() async throws {
    let generated = SSHKeyGenerator.generateEd25519(name: "driverr-test")
    let signingKey = try Curve25519.Signing.PrivateKey(
      rawRepresentation: generated.privateKey.rawRepresentation
    )
    let server = try await EmbeddedSSHServer(
      username: "carson",
      password: "unused",
      authorizedKey: NIOSSHPrivateKey(ed25519Key: signingKey).publicKey
    )
    defer { Task { await server.stop() } }

    let host = DriverrCore.Host(
      name: "embedded",
      hostname: "127.0.0.1",
      port: server.port,
      username: "carson"
    )
    let transport = NIOSSHTransport()
    try await transport.connect(to: host, hostKeyValidator: AlwaysTrustValidator())
    try await transport.authenticate(.privateKey(generated.privateKey))

    let result = try await transport.execChannel(command: "echo generated")
    #expect(result.trimmedOutput == "generated")
    await transport.disconnect()
  }
}

struct AlwaysTrustValidator: HostKeyValidator {
  func validate(_ key: SSHHostKey, for host: DriverrCore.Host) async -> HostKeyDecision { .trust }
}
