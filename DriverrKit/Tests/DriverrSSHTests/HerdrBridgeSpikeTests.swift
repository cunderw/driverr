import DriverrCore
import Foundation
import NIOSSH
import Testing

@testable import DriverrSSH

/// Whether this machine can run the spike: a `herdr` binary and a running server.
enum HerdrProbe {
  /// The same three places `CLIControl.fallbackPaths` probes, named directly so the suite
  /// does not depend on the `PATH` whoever launched `swift test` exported. Kept in step by
  /// hand, because `DriverrSSHTests` does not depend on `DriverrHerdr`.
  static let binary: String? = {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for path in [
      "/opt/homebrew/bin/herdr",
      "/usr/local/bin/herdr",
      home + "/.local/bin/herdr",
    ]
    where FileManager.default.isExecutableFile(atPath: path) {
      return path
    }
    return which("herdr")
  }()

  /// A server must be running for `session.snapshot` to say anything.
  static var serverIsRunning: Bool {
    guard let output = run("status", "server") else { return false }
    return output.contains("status: running")
  }

  static var isAvailable: Bool { binary != nil && serverIsRunning }

  static func run(_ arguments: String...) -> String? {
    guard let binary else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }

  private static func which(_ tool: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["which", tool]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
  }
}

/// The herdr bridge spike, kept as a test. Driverr cannot reach a remote herdr's socket API
/// over SSH without a remote prerequisite. What works, over a real SSH exec channel, is
/// herdr's CLI, which speaks the same newline-delimited JSON envelope.
///
/// Off unless `DRIVERR_LIVE_HERDR=1` and a herdr server is running on this machine. The
/// variable is tested first, so a default run starts no `herdr` process. Run it by hand, so
/// the spike's evidence stays re-checkable:
///
/// ```sh
/// DRIVERR_LIVE_HERDR=1 swift test --package-path DriverrKit --filter HerdrBridgeSpike
/// ```
///
/// It runs `herdr` commands against the session on this machine through a loopback SSH
/// server, which is why a default run leaves it out.
@Suite(
  "herdr transport over SSH",
  .enabled(
    if: ProcessInfo.processInfo.environment["DRIVERR_LIVE_HERDR"] == "1" && HerdrProbe.isAvailable
  ),
  .serialized
)
struct HerdrBridgeSpikeTests {
  private static let username = "carson"
  private static let password = UUID().uuidString

  private func connectedTransport(
    _ server: EmbeddedSSHServer
  ) async throws -> NIOSSHTransport {
    let transport = NIOSSHTransport()
    let host = DriverrCore.Host(
      name: "localhost",
      hostname: "127.0.0.1",
      port: server.port,
      username: Self.username
    )
    try await transport.connect(to: host, hostKeyValidator: AlwaysTrustValidator())
    try await transport.authenticate(.password(Self.password))
    return transport
  }

  @Test("session.snapshot comes back over an SSH exec channel")
  func snapshotOverSSH() async throws {
    let server = try await EmbeddedSSHServer(
      username: Self.username,
      password: Self.password,
      executesRealCommands: true
    )
    defer { Task { await server.stop() } }
    let transport = try await connectedTransport(server)
    defer { Task { await transport.disconnect() } }

    let binary = try #require(HerdrProbe.binary)
    let result = try await transport.execChannel(command: "\(binary) api snapshot")

    #expect(result.exitStatus == 0, "stderr was: \(result.standardError)")

    // The socket API's envelope: `{"id": …, "result": …}`.
    let json = try #require(
      try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as? [String: Any],
      "not JSON: \(String(result.standardOutput.prefix(200)))"
    )
    #expect(json["id"] != nil)
    let payload = try #require(json["result"] as? [String: Any])
    let snapshot = try #require(payload["snapshot"] as? [String: Any])
    #expect(snapshot["workspaces"] != nil || snapshot["agents"] != nil)
  }

  /// `herdr remote-client-bridge` proxies stdio to the client socket, which speaks the TUI's
  /// protocol, not the JSON API. If a future herdr answers here, this fails and the transport
  /// choice can be revisited.
  @Test("the remote-client-bridge does not answer API requests")
  func bridgeIsNotAnAPIBridge() async throws {
    let server = try await EmbeddedSSHServer(
      username: Self.username,
      password: Self.password,
      executesRealCommands: true
    )
    defer { Task { await server.stop() } }
    let transport = try await connectedTransport(server)
    defer { Task { await transport.disconnect() } }

    let binary = try #require(HerdrProbe.binary)
    let request = #"{"id":"spike","method":"session.snapshot","params":{}}"#
    let result = try await transport.execChannel(
      command: "printf '%s\\n' '\(request)' | \(binary) remote-client-bridge"
    )

    #expect(
      !result.standardOutput.contains("\"result\""),
      """
      remote-client-bridge answered an API request, so it no longer speaks only the TUI's \
      protocol and Driverr could use it instead of the CLI: \
      \(String(result.standardOutput.prefix(200)))
      """
    )
  }

  /// A non-interactive SSH login shell's `PATH` need not include Homebrew, so the binary must
  /// be discovered. herdr's own remote attach probes the same way.
  @Test("an absolute path works where a bare name may not")
  func absolutePathIsRequired() async throws {
    let server = try await EmbeddedSSHServer(
      username: Self.username,
      password: Self.password,
      executesRealCommands: true
    )
    defer { Task { await server.stop() } }
    let transport = try await connectedTransport(server)
    defer { Task { await transport.disconnect() } }

    let discovery = try await transport.execChannel(command: "command -v herdr || true")
    let binary = try #require(HerdrProbe.binary)
    let absolute = try await transport.execChannel(command: "\(binary) --version")

    #expect(absolute.exitStatus == 0)
    #expect(absolute.standardOutput.contains("herdr"))
    // A record of what discovery returned, not an assertion about this machine's PATH.
    #expect(
      discovery.exitStatus == 0,
      "discovery itself must not fail: \(discovery.standardError)"
    )
  }
}
