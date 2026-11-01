import DriverrCore
import DriverrHC
import DriverrHerdr
import Foundation
import Testing

@testable import DriverrSSH

/// Two scratch cores, one added to the other, read over real SSH exec channels.
///
/// What a filter on `machine.list` stands on: a machine's id there is that core's own
/// `hello.core.id`, and a rename changes the name and not the id. The schema says so, and no
/// fake can.
///
/// Off unless `DRIVERR_LIVE_CORE=1`, like `CoreOverSSHTests`, and for a stronger reason: this
/// one adds a machine. So every `hc` here runs under `env -i` with `HC_SESSION`, because an
/// agent's `HC_TERMINAL_SOCKET` would otherwise reach the default core. Run it by hand:
///
/// ```sh
/// DRIVERR_LIVE_CORE=1 swift test --package-path DriverrKit --filter CoreMachineIdentity
/// ```
@Suite(
  "CoreMachineIdentity",
  .enabled(
    if: ProcessInfo.processInfo.environment["DRIVERR_LIVE_CORE"] == "1"
      && CoreProbe.binary != nil
  ),
  .serialized,
  .timeLimit(.minutes(1))
)
struct CoreMachineIdentityTests {
  private static let username = "carson"
  private static let password = UUID().uuidString
  private static let adding = "driverr-identity-a"
  private static let added = "driverr-identity-b"

  private struct Stream: HerdrStream {
    let stream: any ExecStream
    var output: AsyncThrowingStream<Data, any Error> { stream.output }
    var end: ProcessEnd? { get async { nil } }
    func send(_ data: Data) async throws { try await stream.send(data) }
    func close() async { await stream.close() }
  }

  /// The environment `hc` gets, which is this and nothing else.
  private static func environment(session: String) -> [String: String] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return [
      "HOME": home,
      "USER": NSUserName(),
      "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
      "HC_SESSION": session,
    ]
  }

  /// One `hc` command, without blocking a cooperative thread. Fails on anything but exit 0.
  @discardableResult
  private func hc(_ session: String, _ arguments: String...) async throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: try #require(CoreProbe.binary))
    process.arguments = arguments
    process.environment = Self.environment(session: session)
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    return await withCheckedContinuation { continuation in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(returning: -1)
      }
    }
  }

  /// A machine's `--via` command: runs the line it is given, as `ssh` would.
  private func viaScript() throws -> URL {
    let script = FileManager.default.temporaryDirectory
      .appendingPathComponent("driverr-identity-\(UUID().uuidString).sh")
    try Data("#!/bin/sh\nexec sh -c \"$1\"\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  private func cleanUp() async throws {
    for name in ["bee", "cee"] { try await hc(Self.adding, "machine", "rm", name) }
    try await hc(Self.added, "server", "stop")
    try await hc(Self.adding, "server", "stop")
  }

  private func control(
    on session: String,
    over transport: NIOSSHTransport
  ) throws -> CoreControl {
    let binary = try #require(CoreProbe.binary)
    let environment = Self.environment(session: session)
      .map { "\($0.key)=\(shellQuoted($0.value))" }
      .sorted()
      .joined(separator: " ")
    return CoreControl(binaryPath: binary) { command in
      Stream(stream: try await transport.execStream(command: "env -i \(environment) \(command)"))
    }
  }

  @Test("a machine's id is its core's own, through a rename, and a filter on it finds the group")
  func machineIdentity() async throws {
    let server = try await EmbeddedSSHServer(
      username: Self.username,
      password: Self.password,
      executesRealCommands: true,
      streamsStandardOutput: true
    )
    defer { Task { await server.stop() } }
    let transport = NIOSSHTransport()
    defer { Task { await transport.disconnect() } }
    try await transport.connect(
      to: DriverrCore.Host(
        name: "localhost", hostname: "127.0.0.1", port: server.port, username: Self.username),
      hostKeyValidator: AlwaysTrustValidator())
    try await transport.authenticate(.password(Self.password))

    try await cleanUp()
    let via = try viaScript()
    defer { try? FileManager.default.removeItem(at: via) }

    var failure: (any Error)?
    do {
      try await check(via: via, over: transport)
    } catch {
      failure = error
    }
    try await cleanUp()
    if let failure { throw failure }
  }

  private func check(via: URL, over transport: NIOSSHTransport) async throws {
    #expect(
      try await hc(
        Self.adding, "machine", "add", "--via", via.path, "--name", "bee",
        "--session", Self.added) == 0)
    #expect(try await hc(Self.added, "run", "--bg", "--name", "marker", "sleep 60") == 0)

    let own = try await control(on: Self.added, over: transport).snapshot()
    let ownID = try #require(own.coreID)
    #expect(own.workspaces.allSatisfy { $0.machineCoreID == nil })

    let adder = try control(on: Self.adding, over: transport)
    let seen = try await adder.snapshot()
    #expect(seen.coreID != ownID)
    let machine = try #require(seen.workspaces.first { $0.id.hasPrefix("core:bee/") })
    #expect(machine.machineCoreID == ownID)
    #expect(seen.hidingMachines(coveredBy: [ownID]).pane(id: "core:bee/t1") == nil)

    // The name is this core's and the id is the other's, so only one of them moves.
    #expect(try await hc(Self.adding, "machine", "rename", "bee", "cee") == 0)
    var renamed = seen
    while !renamed.workspaces.contains(where: { $0.id.hasPrefix("core:cee/") }) {
      try await Task.sleep(for: .milliseconds(50))
      renamed = try await adder.snapshot()
    }
    while renamed.workspaces.first(where: { $0.id.hasPrefix("core:cee/") })?.machineCoreID == nil {
      try await Task.sleep(for: .milliseconds(50))
      renamed = try await adder.snapshot()
    }
    #expect(
      renamed.workspaces.first { $0.id.hasPrefix("core:cee/") }?.machineCoreID == ownID)
    #expect(!renamed.workspaces.contains { $0.id.hasPrefix("core:bee/") })
    print("identity: \(machine.tabs.flatMap(\.panes).count) terminals, one id through a rename")
  }
}
