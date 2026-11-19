import DriverrCore
import DriverrHerdr
import Foundation
import Testing

@testable import DriverrTmux

/// tmux starts an agent as a new window in the folder, and types the agent's command into its
/// shell. Measured on #97 against tmux 3.7c: `new-window -c /missing` exits 0 with the window
/// in `$HOME`, and `-c` expands formats, so `c#Sx` lands in `$HOME` and `c##Sx` in `c#Sx`.
@Suite("TmuxControl agent launch")
struct TmuxAgentLaunchTests {
  private let launch = AgentLaunch(kind: .claude, directory: "~/my app", prompt: "fix it")

  /// The fake host, with the folder check answered in front of it: the fake's small shell has
  /// no `cd`.
  private final class Host: @unchecked Sendable {
    let tmux: FakeTmuxHost
    let folder: String?
    let refuseTyping: Bool
    private let lock = NSLock()
    private var _checks: [String] = []
    var checks: [String] { lock.withLock { _checks } }

    init(_ tmux: FakeTmuxHost, folder: String? = "/srv/my app", refuseTyping: Bool = false) {
      self.tmux = tmux
      self.folder = folder
      self.refuseTyping = refuseTyping
    }

    var runner: CommandRunner {
      { [self] command in
        if command.contains("driverr-agent-folder") {
          lock.withLock { _checks.append(command) }
          guard let folder else {
            return CommandResult(standardOutput: "", standardError: "cd: nope\n", exitStatus: 2)
          }
          return CommandResult(
            standardOutput: "\ndriverr-agent-folder\n\(folder)\n", standardError: "", exitStatus: 0)
        }
        if refuseTyping, command.contains("send-keys") {
          return CommandResult(standardOutput: "", standardError: "can't find pane: %4\n", exitStatus: 1)
        }
        return try await tmux.runner(command)
      }
    }
  }

  /// Not tied to a terminal, as `canStartTerminal` is: an agent's chat reads its transcript.
  @Test("tmux can start an agent")
  func canStart() {
    #expect(TmuxControl(run: FakeTmuxHost.seeded().runner).canStartAgent)
  }

  @Test("the folder is resolved, a window named after it opens there, and the agent is typed and submitted")
  func commandsSent() async throws {
    let host = Host(FakeTmuxHost.seeded())
    let control = TmuxControl(run: host.runner)

    let id = try await control.startAgent(launch)

    #expect(id == "tmux:%4")
    #expect(host.checks == [AgentLaunch.resolveCommand(for: "~/my app")])
    let commands = await host.tmux.commands
    #expect(
      commands.prefix(2) == [
        "tmux -u new-window -d -P -F '#{pane_id}' -n 'my app' -c '/srv/my app'",
        "tmux -u copy-mode -q -t '%4'",
      ])
    #expect(commands[2].contains("send-keys -t '%4' -l"), "the mode is left before the typing")
    #expect(await host.tmux.input["%4"] == [.text("claude -- 'fix it'"), .key("Enter")])

    let tree = try await control.snapshot()
    let pane = try #require(tree.pane(id: id))
    #expect(pane.directory == "/srv/my app")
    #expect(tree.workspaces[0].tabs.last?.label == "my app")
  }

  @Test("with no server the window is a new session's")
  func noServer() async throws {
    let host = Host(FakeTmuxHost(sessions: []))
    let id = try await TmuxControl(run: host.runner).startAgent(
      AgentLaunch(kind: .codex, directory: "/srv/my app"))
    #expect(id == "tmux:%0")
    let commands = await host.tmux.commands
    #expect(commands.count == 4, "new-window refused, new-session, leaving a mode, then the typing")
    #expect(commands[2] == "tmux -u copy-mode -q -t '%0'")
    #expect(commands[1] == "tmux -u new-session -d -P -F '#{pane_id}' -n 'my app' -c '/srv/my app'")
    #expect(await host.tmux.input["%0"] == [.text("codex"), .key("Enter")])
  }

  @Test("a # in the folder is doubled, so tmux opens that folder and not a format's")
  func hashInFolder() async throws {
    let host = Host(FakeTmuxHost.seeded(), folder: "/srv/c#Sx")
    let control = TmuxControl(run: host.runner)
    let id = try await control.startAgent(launch)
    #expect(await host.tmux.commands.first?.hasSuffix("-n 'c##Sx' -c '/srv/c##Sx'") == true)
    #expect(try await control.snapshot().pane(id: id)?.directory == "/srv/c#Sx")
  }

  @Test("a folder that is not there opens nothing")
  func badFolder() async {
    let host = Host(FakeTmuxHost.seeded(), folder: nil)
    await #expect(throws: AppError.directoryUnavailable(path: "~/my app")) {
      try await TmuxControl(run: host.runner).startAgent(launch)
    }
    #expect(await host.tmux.commands.isEmpty)
  }

  @Test("a window that opened and could not be typed into stays open, and is named")
  func halfFailure() async {
    let host = Host(FakeTmuxHost.seeded(), refuseTyping: true)
    let control = TmuxControl(run: host.runner)
    await #expect(
      throws: AppError.agentDidNotStart(
        paneID: "tmux:%4", place: "my app", reason: "can't find pane: %4")
    ) {
      try await control.startAgent(launch)
    }
    #expect(await !host.tmux.commands.contains { $0.contains("kill-pane") }, "the window stays")
  }

  @Test("a message too long to type is refused before anything runs")
  func tooLong() async {
    let host = Host(FakeTmuxHost.seeded())
    let long = AgentLaunch(kind: .claude, directory: "/srv", prompt: String(repeating: "x", count: 2000))
    await #expect(throws: AppError.agentPromptTooLong) {
      try await TmuxControl(run: host.runner).startAgent(long)
    }
    #expect(host.checks.isEmpty)
    #expect(await host.tmux.commands.isEmpty)
  }
}
