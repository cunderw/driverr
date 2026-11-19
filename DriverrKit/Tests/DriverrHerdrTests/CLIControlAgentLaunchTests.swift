import DriverrCore
import Foundation
import Testing

@testable import DriverrHerdr

/// A host that answers the folder check, `workspace create` and `agent start`, and records
/// every command it was given.
private final class LaunchHost: @unchecked Sendable {
  private let lock = NSLock()
  private var _commands: [String] = []
  var commands: [String] { lock.withLock { _commands } }

  /// What the folder check prints, or `nil` for a folder that is not there.
  var folder: String? = "/srv/my app"
  var paneID = "w2:p1"
  var agentStart = CommandResult(
    standardOutput: #"{"id":"cli:agent:start","result":{"type":"agent_started"}}"#,
    standardError: "", exitStatus: 0)

  var runner: CommandRunner {
    { [self] command in
      lock.withLock { _commands.append(command) }
      return answer(command)
    }
  }

  private func answer(_ command: String) -> CommandResult {
    if command.contains("driverr-agent-folder") {
      guard let folder else {
        return CommandResult(
          standardOutput: "", standardError: "cd: no such file or directory\n", exitStatus: 1)
      }
      return CommandResult(
        standardOutput: "\ndriverr-agent-folder\n\(folder)\n", standardError: "", exitStatus: 0)
    }
    if command.contains("workspace create") {
      // As herdr 0.9.5 answered, trimmed to the fields that matter.
      let json = """
        {"id":"cli:workspace:create","result":{"root_pane":{"pane_id":"\(paneID)",\
        "tab_id":"w2:t1","terminal_id":"term_1","workspace_id":"w2"},\
        "type":"workspace_created","workspace":{"label":"my app","workspace_id":"w2"}}}
        """
      return CommandResult(standardOutput: json, standardError: "", exitStatus: 0)
    }
    if command.contains("agent start") { return agentStart }
    return CommandResult(standardOutput: "", standardError: "unexpected\n", exitStatus: 2)
  }

  static func refusal(_ code: String, _ message: String) -> CommandResult {
    CommandResult(
      standardOutput: "",
      standardError: #"{"error":{"code":"\#(code)","message":"\#(message)"},"id":"cli:agent:start"}"#
        + "\n",
      exitStatus: 1)
  }
}

@Suite("CLIControl agent launch")
struct CLIControlAgentLaunchTests {
  private let launch = AgentLaunch(kind: .claude, directory: "~/my app", prompt: "fix the build")

  @Test("a TUI can start an agent")
  func canStart() {
    #expect(CLIControl(run: LaunchHost().runner).canStartAgent)
  }

  @Test("the folder is resolved, a workspace named after it opens, and the agent starts in its pane")
  func commandsSent() async throws {
    let host = LaunchHost()
    let control = CLIControl(run: host.runner)

    let paneID = try await control.startAgent(launch)

    #expect(paneID == "w2:p1")
    #expect(
      host.commands == [
        AgentLaunch.resolveCommand(for: "~/my app"),
        "herdr workspace create --cwd '/srv/my app' --label 'my app' --no-focus",
        "herdr agent start my-app-w2p1 --kind claude --pane 'w2:p1' -- -- 'fix the build'",
      ])
  }

  @Test("with no message nothing follows the pane, and Codex is its own kind")
  func noPrompt() async throws {
    let host = LaunchHost()
    _ = try await CLIControl(run: host.runner).startAgent(
      AgentLaunch(kind: .codex, directory: "/srv/my app"))
    #expect(host.commands.last == "herdr agent start my-app-w2p1 --kind codex --pane 'w2:p1'")
  }

  /// A herdr call without the socket path reaches the default session, silently.
  @Test("every herdr call carries the host's socket path, and the folder check does not need it")
  func socketPath() async throws {
    let host = LaunchHost()
    let control = CLIControl(run: host.runner).bound(toSocketPath: "/tmp/h.sock")

    _ = try await control.startAgent(launch)

    let commands = host.commands
    #expect(commands.count == 3)
    #expect(commands[0] == AgentLaunch.resolveCommand(for: "~/my app"))
    #expect(commands.dropFirst().allSatisfy { $0.hasPrefix("export HERDR_SOCKET_PATH=/tmp/h.sock; herdr ") })
  }

  /// Measured on #97: `workspace create --cwd /missing` exits 0 with a workspace in `$HOME`.
  @Test("a folder that is not there opens nothing")
  func badFolder() async {
    let host = LaunchHost()
    host.folder = nil
    await #expect(throws: AppError.directoryUnavailable(path: "~/my app")) {
      try await CLIControl(run: host.runner).startAgent(launch)
    }
    #expect(host.commands.count == 1)
  }

  /// Measured on #97: at Claude Code's trust check `agent start` exits 1 with this, after about
  /// 3.4 s, and the agent is running.
  @Test("an agent stopped at a startup question has started")
  func notReadyIsStarted() async throws {
    let host = LaunchHost()
    host.agentStart = LaunchHost.refusal(
      "agent_not_ready", "agent my-app-w2p1 is blocked during startup and is not ready for prompts")
    #expect(try await CLIControl(run: host.runner).startAgent(launch) == "w2:p1")
  }

  @Test("an agent that does not start leaves the pane open and names it")
  func halfFailure() async {
    let host = LaunchHost()
    host.agentStart = LaunchHost.refusal("agent_start_timeout", "claude did not become ready")
    await #expect(
      throws: AppError.agentDidNotStart(
        paneID: "w2:p1", place: "my app", reason: "claude did not become ready")
    ) {
      try await CLIControl(run: host.runner).startAgent(launch)
    }
    #expect(!host.commands.contains { $0.contains("close") }, "the pane stays")
  }

  @Test("a link that drops at the agent start still names the open pane")
  func linkDropsAtTheStart() async {
    let host = LaunchHost()
    let control = CLIControl(run: { command in
      if command.contains("agent start") { throw AppError.channelFailed(reason: "gone") }
      return try await host.runner(command)
    })
    await #expect(
      throws: AppError.agentDidNotStart(
        paneID: "w2:p1", place: "my app",
        reason: AppError.channelFailed(reason: "gone").localizedDescription)
    ) {
      try await control.startAgent(launch)
    }
  }

  @Test("a message too long to type is refused before anything runs")
  func tooLong() async {
    let host = LaunchHost()
    let long = AgentLaunch(kind: .claude, directory: "/srv", prompt: String(repeating: "x", count: 2000))
    await #expect(throws: AppError.agentPromptTooLong) {
      try await CLIControl(run: host.runner).startAgent(long)
    }
    #expect(host.commands.isEmpty)
  }

  /// herdr refuses `invalid_agent_name` outside `[a-z][a-z0-9_-]{0,31}` and `agent_name_taken`
  /// for a live agent's name. A pane id is unique among live panes, so it makes the name unique.
  @Test(
    "an agent's name is the folder as herdr allows it, then the pane",
    arguments: [
      ("my app", "w2:p1", AgentLaunch.Kind.claude, "my-app-w2p1"),
      ("Driverr_Kit!", "w10:p3", .claude, "driverr_kit-w10p3"),
      ("2026 notes", "w2:p1", .codex, "codex-2026-notes-w2p1"),
      ("/", "w2:p1", .claude, "claude-w2p1"),
      ("über", "wJ:pK", .claude, "ber-wjpk"),
      (String(repeating: "a", count: 40), "w2:p1", .claude, String(repeating: "a", count: 27) + "-w2p1"),
    ])
  func agentName(folder: String, paneID: String, kind: AgentLaunch.Kind, expected: String) {
    let name = CLIControl.agentName(folder: folder, paneID: paneID, kind: kind)
    #expect(name == expected)
    #expect(name.count <= 32)
  }
}
