import DriverrCore
import DriverrHC
import DriverrHerdr
import Foundation
import Testing

@testable import DriverrSSH

/// Whether this machine can run the suite. Apart from it, because a suite's own attribute
/// cannot read one of its members.
enum CoreProbe {
  /// The places `CoreControl.discoveryCommand` falls back to, named directly so the suite does
  /// not depend on the `PATH` whoever launched `swift test` exported.
  static let binary: String? = {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin"]
      .flatMap { [$0 + "/herdr-core", $0 + "/hc"] }
      .first { FileManager.default.isExecutableFile(atPath: $0) }
  }()
}

/// A real core over a real SSH exec channel, so the frames have crossed a transport no fake
/// shares a line of code with.
///
/// Off unless `DRIVERR_LIVE_CORE=1` and a core is installed here. It sends only `hello`,
/// `terminal.list`, `doc.get` and `file.read` of a Claude terminal's own record, which change
/// nothing, but `hc connect` starts a core when none is running, which is why a default run
/// leaves it out. Run it by hand:
///
/// ```sh
/// DRIVERR_LIVE_CORE=1 swift test --package-path DriverrKit --filter CoreOverSSH
/// ```
@Suite(
  "herdr-core over SSH",
  .enabled(
    if: ProcessInfo.processInfo.environment["DRIVERR_LIVE_CORE"] == "1"
      && CoreProbe.binary != nil
  ),
  .serialized,
  .timeLimit(.minutes(1))
)
struct CoreOverSSHTests {
  private static let username = "carson"
  private static let password = UUID().uuidString

  /// `ExecStreamBridge`, which is in the app target, cut down to what these tests read.
  private struct Stream: HerdrStream {
    let stream: any ExecStream
    var output: AsyncThrowingStream<Data, any Error> { stream.output }
    var end: ProcessEnd? { get async { nil } }
    func send(_ data: Data) async throws { try await stream.send(data) }
    func close() async { await stream.close() }
  }

  private func connectedTransport(_ server: EmbeddedSSHServer) async throws -> NIOSSHTransport {
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

  private func server() async throws -> EmbeddedSSHServer {
    try await EmbeddedSSHServer(
      username: Self.username,
      password: Self.password,
      executesRealCommands: true,
      streamsStandardOutput: true
    )
  }

  @Test("hello and terminal.list cross the exec channel behind a login banner")
  func throughABanner() async throws {
    let server = try await server()
    defer { Task { await server.stop() } }
    let transport = try await connectedTransport(server)
    defer { Task { await transport.disconnect() } }

    let binary = try #require(CoreProbe.binary)
    // What a chatty `.zshenv` does: bytes on stdout, ahead of the program, with no framing.
    let control = CoreControl(binaryPath: binary) { command in
      let chatty = "sh -c 'echo \"Welcome {to} this host\"; exec \(command)'"
      return Stream(stream: try await transport.execStream(command: chatty))
    }

    let availability = await control.availability()
    guard case .coreReady(let version) = availability else {
      Issue.record("expected a ready core, got \(availability)")
      return
    }
    #expect(!version.isEmpty)

    let tree = try await control.snapshot()
    #expect(tree.allPanes.allSatisfy { CorePaneID.isCore($0.id) && $0.terminalID != nil })
    print("core \(version) listed \(tree.allPanes.count) terminals over SSH")
  }

  /// Only what holds on any machine, because the terminals are whoever ran this. The print is
  /// the part to read: the groups in the order the desktop app shows them.
  @Test("a real core's snapshot comes back in groups")
  func snapshot() async throws {
    let server = try await server()
    defer { Task { await server.stop() } }
    let transport = try await connectedTransport(server)
    defer { Task { await transport.disconnect() } }

    let binary = try #require(CoreProbe.binary)
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let control = CoreControl(binaryPath: binary, home: home) { command in
      Stream(stream: try await transport.execStream(command: command))
    }

    let tree = try await control.snapshot()
    for workspace in tree.workspaces {
      #expect(CorePaneID.isCore(workspace.id) && !workspace.label.isEmpty)
      #expect(workspace.tabs.allSatisfy { !$0.panes.isEmpty && !$0.label.isEmpty })
      print("group \(workspace.label): \(workspace.tabs.map(\.label)) \(workspace.status as Any)")
    }
    let agents = tree.allPanes.filter { $0.agent != nil }
    let sessions = agents.compactMap(\.agent?.session)
    #expect(sessions.allSatisfy { $0.source == "claude:sessions" && $0.identifier != nil })
    print(
      "snapshot: \(tree.allPanes.count) terminals, \(agents.count) agents, "
        + "\(sessions.count) sessions from Claude's records")
  }

  @Test("discovery finds it over the same channels the app uses")
  func discovery() async throws {
    let server = try await server()
    defer { Task { await server.stop() } }
    let transport = try await connectedTransport(server)
    defer { Task { await transport.disconnect() } }

    let control = await CoreControl.discovering(
      run: { try await transport.execChannel(command: $0) },
      open: { Stream(stream: try await transport.execStream(command: $0)) }
    )

    let found = try #require(control)
    #expect(found.binaryPath.hasPrefix("/"))
    #expect(found.home?.hasPrefix("/") == true)
    #expect(await found.availability() != .notInstalled)
  }

  @Test("a program that is not a core ends the stream and reads as not installed")
  func notACore() async throws {
    let server = try await server()
    defer { Task { await server.stop() } }
    let transport = try await connectedTransport(server)
    defer { Task { await transport.disconnect() } }

    // `/bin/echo connect` prints a word and exits, as a stranger called `hc` might.
    let control = CoreControl(binaryPath: "/bin/echo") { command in
      Stream(stream: try await transport.execStream(command: command))
    }
    #expect(await control.availability() == .notInstalled)
  }
}
