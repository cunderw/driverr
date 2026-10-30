import DriverrCore
import DriverrHerdr
import DriverrSSH
import Foundation
import Testing

@testable import Driverr

/// `Host.herdrSocketPath` reaching the `CLIControl` a connection runs commands on.
/// `AppEnvironment.makeHerdrControl` gets only the transport, not the `Host`, so this proves
/// `ConnectionModel.connect()` passes the path on. `CLIControlTests` cannot reach this layer.
@MainActor
@Suite("ConnectionModel wires the herdr socket path")
struct ConnectionHerdrSocketPathTests {
  private var environment: AppEnvironment {
    var environment = AppEnvironment.ephemeral
    environment.knownHostsStore = InMemoryKnownHostsStore(
      seeded: ["10.1.0.9": FakeSSHTransport.defaultHostKey]
    )
    environment.makeTransport = { FakeSSHTransport() }
    // A real `CLIControl` over a fake command runner, because `FakeControl` has no socket path.
    environment.makeHerdrControl = { _ in
      CLIControl(run: { _ in CommandResult(standardOutput: "", standardError: "", exitStatus: 0) })
    }
    return environment
  }

  @Test("a host with a socket path connects to a CLIControl carrying it")
  func socketPathReachesTheControl() async throws {
    let host = DriverrCore.Host(
      name: "workbox",
      hostname: "10.1.0.9",
      username: "carson",
      herdrSocketPath: "/run/herdr.sock"
    )
    let model = ConnectionModel(host: host, environment: environment)

    await model.connect(password: "hunter2", persistence: .promptEveryTime)

    #expect(model.phase == .connected)
    let control = try #require(model.herdr as? CLIControl)
    #expect(control.herdrSocketPath == "/run/herdr.sock")
  }

  @Test("a host with both publishes one control, with the socket path on its TUI side")
  func combinedControlTakesTheSocketPath() async throws {
    var environment = environment
    environment.makeHerdrControl = { _ in
      CombinedControl(
        tui: CLIControl(
          run: { _ in CommandResult(standardOutput: "", standardError: "", exitStatus: 0) }
        ),
        core: FakeControl(tree: .empty, availability: .coreReady(version: "0.1.14"))
      )
    }
    let host = DriverrCore.Host(
      name: "workbox",
      hostname: "10.1.0.9",
      username: "carson",
      herdrSocketPath: "/run/herdr.sock"
    )
    let model = ConnectionModel(host: host, environment: environment)

    await model.connect(password: "hunter2", persistence: .promptEveryTime)

    #expect(model.phase == .connected)
    let control = try #require(model.herdr as? CombinedControl)
    let pane = DriverrCore.Pane(
      id: "w1:p1", tabID: "t", workspaceID: "w", title: "x", terminalID: "term")
    #expect(
      control.attachCommand(for: pane).hasPrefix("export HERDR_SOCKET_PATH=/run/herdr.sock;"))
    #expect(model.herdrAvailability == .coreReady(version: "0.1.14"))
    #expect(model.herdrVersion == "core 0.1.14")
  }

  @Test("a host with no socket path connects to a CLIControl carrying none")
  func noSocketPathLeavesItNil() async throws {
    let host = DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson")
    let model = ConnectionModel(host: host, environment: environment)

    await model.connect(password: "hunter2", persistence: .promptEveryTime)

    #expect(model.phase == .connected)
    let control = try #require(model.herdr as? CLIControl)
    #expect(control.herdrSocketPath == nil)
  }

  /// The bridge streams go to the host's socket too, not only the `CLIControl` commands.
  /// `herdr terminal session observe` and `control` pick their server from
  /// `HERDR_SOCKET_PATH` exactly as the API commands do (measured against herdr 0.9.1).
  /// Without it they reach the host's default herdr, which does not know the terminal id
  /// the tree came from and answers `terminal.closed` with "terminal target … not found".
  /// That decodes to `.other`, and the scene draws "This pane was closed." over a live pane.
  @Test("a host with a socket path opens its pane streams on that socket")
  func socketPathReachesThePaneStreams() async throws {
    let transport = FakeSSHTransport()
    var environment = self.environment
    environment.makeTransport = { transport }
    let host = DriverrCore.Host(
      name: "workbox",
      hostname: "10.1.0.9",
      username: "carson",
      herdrSocketPath: "/run/herdr.sock"
    )
    let model = ConnectionModel(host: host, environment: environment)
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    #expect(model.phase == .connected)

    let size = TerminalSize(columns: 80, rows: 24)
    _ = await model.observePane(terminalID: "term_1", size: size)
    _ = await model.openPaneBridge(terminalID: "term_1", size: size)

    let streamed = await transport.streamedCommands
    let observe = try #require(streamed.first { $0.contains("terminal session observe") })
    let control = try #require(streamed.first { $0.contains("terminal session control") })
    #expect(observe.hasPrefix("export HERDR_SOCKET_PATH=/run/herdr.sock; "))
    #expect(control.hasPrefix("export HERDR_SOCKET_PATH=/run/herdr.sock; "))
  }
}
