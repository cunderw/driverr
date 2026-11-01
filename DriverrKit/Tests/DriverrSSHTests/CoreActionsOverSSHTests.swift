import DriverrCore
import DriverrHC
import DriverrHerdr
import Foundation
import Testing

@testable import DriverrSSH

/// Close and New terminal against two real scratch cores, one added to the other, over real SSH
/// exec channels.
///
/// What a fake cannot say: that `terminal.kill` answers inside a call's deadline for a program
/// that ignores it, that a bare `terminal.run` gives a shell, and that `on` reaches a machine.
///
/// Off unless `DRIVERR_LIVE_CORE=1`, like `CoreMachineIdentityTests`, and for the same reason:
/// this kills and starts terminals, so every `hc` here runs under `env -i` with `HC_SESSION`. Run
/// it by hand:
///
/// ```sh
/// DRIVERR_LIVE_CORE=1 swift test --package-path DriverrKit --filter CoreActionsOverSSH
/// ```
@Suite(
  "CoreActionsOverSSH",
  .enabled(
    if: ProcessInfo.processInfo.environment["DRIVERR_LIVE_CORE"] == "1"
      && CoreProbe.binary != nil
  ),
  .serialized,
  .timeLimit(.minutes(1))
)
struct CoreActionsOverSSHTests {
  private static let username = "carson"
  private static let password = UUID().uuidString
  private static let adding = "driverr-actions-a"
  private static let added = "driverr-actions-b"
  /// What ignores a hangup and a terminate, so only a kill ends it.
  private static let stubborn = "trap '' HUP TERM; while :; do sleep 1; done"

  private struct Stream: HerdrStream {
    let stream: any ExecStream
    var output: AsyncThrowingStream<Data, any Error> { stream.output }
    var end: ProcessEnd? { get async { nil } }
    func send(_ data: Data) async throws { try await stream.send(data) }
    func close() async { await stream.close() }
  }

  /// One terminal as `hc get` prints it, cut down to what these tests read.
  private struct Record: Decodable {
    let address: String
    let argv: [String]
    let cwd: String
    let keep: Bool
    let labels: [String: String]
    let state: String
    let reason: String?
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

  /// One `hc` command, without blocking a cooperative thread, and what it printed.
  @discardableResult
  private func hc(_ session: String, _ arguments: String...) async throws -> (Int32, Data) {
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("driverr-actions-\(UUID().uuidString).out")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: output) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: try #require(CoreProbe.binary))
    process.arguments = arguments
    process.environment = Self.environment(session: session)
    process.standardOutput = try FileHandle(forWritingTo: output)
    process.standardError = FileHandle.nullDevice
    let status = await withCheckedContinuation { continuation in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(returning: Int32(-1))
      }
    }
    return (status, (try? Data(contentsOf: output)) ?? Data())
  }

  private func record(_ session: String, _ terminal: String) async throws -> Record {
    let (status, output) = try await hc(session, "get", terminal, "--json")
    #expect(status == 0)
    return try JSONDecoder().decode(Record.self, from: output)
  }

  private func viaScript() throws -> URL {
    let script = FileManager.default.temporaryDirectory
      .appendingPathComponent("driverr-actions-\(UUID().uuidString).sh")
    try Data("#!/bin/sh\nexec sh -c \"$1\"\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  private func cleanUp() async throws {
    try await hc(Self.adding, "machine", "rm", "bee")
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

  /// Reads until a pane `wanted` accepts is there, and returns it.
  private func pane(
    in control: CoreControl,
    where wanted: (Pane) -> Bool
  ) async throws -> Pane {
    for _ in 0..<200 {
      if let pane = try await control.snapshot().allPanes.first(where: wanted) { return pane }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw AppError.herdrCommandFailed(reason: "no such pane arrived")
  }

  @Test("close ends what ignores it, inside a call's deadline; New terminal starts a shell")
  func actions() async throws {
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
      let control = try control(on: Self.adding, over: transport)
      try await close(on: control)
      try await startUnlabelled(on: control)
      try await startLabelled(on: control)
      try await startOnAMachine(via: via, on: control)
    } catch {
      failure = error
    }
    try await cleanUp()
    if let failure { throw failure }
  }

  private func close(on control: CoreControl) async throws {
    #expect(try await hc(Self.adding, "run", "--bg", "--name", "stubborn", Self.stubborn).0 == 0)
    let source = try await record(Self.adding, "stubborn")
    let pane = try await pane(in: control) { $0.terminalID == source.address }

    let clock = ContinuousClock()
    let started = clock.now
    try await control.perform(.close, on: pane.id)
    let took = clock.now - started
    #expect(took < CoreControl.defaultCallDeadline)
    print("close: a program that ignores HUP and TERM ended in \(took)")

    let closed = try await record(Self.adding, source.address)
    #expect(closed.state == "finished")
    #expect(closed.reason == "killed")
    while try await control.snapshot().pane(id: pane.id) != nil {
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  /// The one call that starts a terminal, and what it started.
  private func started(
    beside pane: Pane,
    on control: CoreControl,
    session: String,
    prefix: String = ""
  ) async throws -> Record {
    let before = Set(try await control.snapshot().allPanes.map(\.id))
    try await control.perform(.split(.right), on: pane.id)
    let new = try await self.pane(in: control) { !before.contains($0.id) }
    let address = try #require(new.terminalID)
    #expect(address.hasPrefix(prefix))
    return try await record(session, String(address.dropFirst(prefix.count)))
  }

  private func startUnlabelled(on control: CoreControl) async throws {
    let directory = FileManager.default.temporaryDirectory.path
    #expect(
      try await hc(
        Self.adding, "run", "--bg", "--name", "plain", "--cwd", directory, "sleep 60"
      ).0 == 0)
    let pane = try await pane(in: control) { $0.title == "plain" }

    let new = try await started(beside: pane, on: control, session: Self.adding)
    #expect(new.labels.isEmpty)
    #expect(!new.keep)
    #expect(new.argv.first?.hasSuffix("sh") == true, "the machine's shell: \(new.argv)")
    #expect(new.cwd.hasSuffix(URL(fileURLWithPath: directory).lastPathComponent))
    #expect(new.state == "live")
  }

  private func startLabelled(on control: CoreControl) async throws {
    #expect(
      try await hc(
        Self.adding, "run", "--bg", "--name", "desk", "--label", "herdr.space=s1",
        "--label", "herdr.tab=t1", "--label", "where=dev / 1", "sleep 60"
      ).0 == 0)
    let pane = try await pane(in: control) { $0.title == "desk" }

    let new = try await started(beside: pane, on: control, session: Self.adding)
    #expect(new.labels == ["herdr.space": "s1", "herdr.tab": "t1", "herdr.seen": "0"])
    #expect(new.keep)

    // In the source's group, which is how the app's own terminals land in a tab.
    let tree = try await control.snapshot()
    let space = try #require(tree.workspaces.first { $0.id == "core:s1" })
    #expect(space.tabs.first?.panes.count == 2)
  }

  private func startOnAMachine(via: URL, on control: CoreControl) async throws {
    #expect(
      try await hc(
        Self.adding, "machine", "add", "--via", via.path, "--name", "bee",
        "--session", Self.added
      ).0 == 0)
    #expect(try await hc(Self.added, "run", "--bg", "--name", "far", "sleep 60").0 == 0)
    let pane = try await pane(in: control) { $0.id.hasPrefix("core:bee/") }

    let new = try await started(
      beside: pane, on: control, session: Self.added, prefix: "bee/")
    #expect(new.state == "live")
    #expect(new.argv.first?.hasSuffix("sh") == true, "the machine's shell: \(new.argv)")
    #expect(new.labels.isEmpty)

    try await control.perform(.close, on: "core:bee/\(new.address)")
    #expect(try await record(Self.added, new.address).state == "finished")
  }
}
