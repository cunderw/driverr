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

  /// What `agent get <pane>` answers: by default no agent, as for a shell, measured on #97.
  var agentGet = LaunchHost.refusal("agent_not_found", "agent target w2:p1 not found")

  /// `agent get`'s answer for a pane with this agent, trimmed from herdr 0.9.5's as recorded on
  /// #97.
  static func found(_ agent: String) -> CommandResult {
    CommandResult(
      standardOutput: #"{"id":"cli:agent:get","result":{"agent":{"agent":"\#(agent)","#
        + #""agent_status":"working","name":"my-app-w2-p1","pane_id":"w2:p1"}}}"#,
      standardError: "", exitStatus: 0)
  }

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
    if command.contains("agent get") { return agentGet }
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
        "herdr agent start my-app-w2-p1 --kind claude --pane 'w2:p1' --timeout 10000 -- -- 'fix the build'",
      ])
  }

  @Test("with no message nothing follows the pane, and Codex is its own kind")
  func noPrompt() async throws {
    let host = LaunchHost()
    _ = try await CLIControl(run: host.runner).startAgent(
      AgentLaunch(kind: .codex, directory: "/srv/my app"))
    #expect(host.commands.last == "herdr agent start my-app-w2-p1 --kind codex --pane 'w2:p1' --timeout 10000")
  }

  @Test("the message herdr types is the one tmux and a core type: one line, no tabs")
  func sameMessageEverywhere() async throws {
    let host = LaunchHost()
    _ = try await CLIControl(run: host.runner).startAgent(
      AgentLaunch(kind: .claude, directory: "/srv", prompt: "fix\tthe\nbuild"))
    #expect(host.commands.last?.hasSuffix(" -- -- 'fix the build'") == true)
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
      "agent_not_ready", "agent my-app-w2-p1 is blocked during startup and is not ready for prompts")
    #expect(try await CLIControl(run: host.runner).startAgent(launch) == "w2:p1")
  }

  /// Measured on #97 with a kind whose program is not installed: the shell says 127, and
  /// `agent start` waits out its timeout and answers this. That run used herdr's default
  /// 30 s; this command passes `--timeout 10000`.
  @Test("an agent that does not start leaves the pane open and names it")
  func halfFailure() async {
    let host = LaunchHost()
    host.agentStart = LaunchHost.refusal("timeout", "timed out waiting for agent startup")
    await #expect(
      throws: AppError.agentDidNotStart(
        paneID: "w2:p1", place: "my app", reason: "herdr said: timed out waiting for agent startup.")
    ) {
      try await CLIControl(run: host.runner).startAgent(launch)
    }
    #expect(host.commands.last == "herdr agent get 'w2:p1'", "the pane was asked first")
    #expect(!host.commands.contains { $0.contains("close") }, "the pane stays")
  }

  /// herdr keeps `agent start` waiting while the agent works, so a first message in a folder
  /// the agent trusts ends in `timeout` on a running agent (herdr's `src/cli/agent.rs`).
  @Test("a timeout with the agent detected in the pane is a start")
  func timeoutWithAgentIsStarted() async throws {
    let host = LaunchHost()
    host.agentStart = LaunchHost.refusal("timeout", "timed out waiting for agent startup")
    host.agentGet = LaunchHost.found("claude")
    #expect(try await CLIControl(run: host.runner).startAgent(launch) == "w2:p1")
    #expect(host.commands.last == "herdr agent get 'w2:p1'")
  }

  @Test("an agent of another kind in the pane is not this start")
  func otherAgentIsNotStarted() async {
    let host = LaunchHost()
    host.agentStart = LaunchHost.refusal("timeout", "timed out waiting for agent startup")
    host.agentGet = LaunchHost.found("codex")
    await #expect(throws: AppError.self) { try await CLIControl(run: host.runner).startAgent(launch) }
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
      ("my app", "w2:p1", AgentLaunch.Kind.claude, "my-app-w2-p1"),
      ("Driverr_Kit!", "w10:p3", .claude, "driverr_kit-w10-p3"),
      ("2026 notes", "w2:p1", .codex, "codex-2026-notes-w2-p1"),
      ("/", "w2:p1", .claude, "claude-w2-p1"),
      ("über", "wJ:pK", .claude, "ber-_4197029f"),
      (String(repeating: "a", count: 40), "w2:p1", .claude, String(repeating: "a", count: 26) + "-w2-p1"),
      ("app", String(repeating: "p", count: 40), .claude, "app-_037c0f65"),
    ])
  func agentName(folder: String, paneID: String, kind: AgentLaunch.Kind, expected: String) {
    let name = CLIControl.agentName(folder: folder, paneID: paneID, kind: kind)
    #expect(name == expected)
    #expect(name.count <= 32)
  }

  @Test("two pane ids that differ only in case and colon place give two names")
  func tagsDoNotCollide() {
    let first = CLIControl.agentName(folder: "app", paneID: "w2:p1P3", kind: .claude)
    let second = CLIControl.agentName(folder: "app", paneID: "w2P1:p3", kind: .claude)
    #expect(first == "app-_312398b4")
    #expect(second == "app-_9ee105ca")
    #expect(CLIControl.paneTag("w2:p13") != CLIControl.paneTag("w2p1:3"))
  }
}
