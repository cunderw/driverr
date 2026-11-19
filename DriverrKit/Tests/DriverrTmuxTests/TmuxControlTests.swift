import DriverrCore
import DriverrHerdr
import Foundation
import Testing

@testable import DriverrTmux

private let backslash = "\u{5C}"

@Suite("TmuxControl snapshot")
struct TmuxControlSnapshotTests {
  @Test("the seeded host maps to sessions, windows and panes, with the Claude waiting")
  func seeded() async throws {
    let host = FakeTmuxHost.seeded()
    let tree = try await TmuxControl(run: host.runner).snapshot()

    #expect(tree.workspaces.map(\.label) == ["work", "scratch"])
    #expect(tree.workspaces[0].tabs.map(\.label) == ["editor", "logs"])
    #expect(tree.allPanes.map(\.id) == ["tmux:%0", "tmux:%1", "tmux:%2", "tmux:%3"])
    #expect(tree.allPanes.map(\.title) == ["zsh", "Claude Code", "tail", "zsh"])
    #expect(tree.focusedPaneID == "tmux:%0")

    let claude = try #require(tree.pane(id: "tmux:%1"))
    #expect(claude.agent?.name == "Claude")
    #expect(claude.agent?.status == .blocked)
    #expect(claude.agent?.session?.identifier == "11111111-2222-3333-4444-555555555555")
    #expect(tree.blockedPanes.map(\.id) == ["tmux:%1"])
    #expect(tree.loneBlockedPane?.id == "tmux:%1")
    #expect(tree.workspaces[0].status == .blocked)
    #expect(tree.workspaces[1].status == nil)
    #expect(tree.pane(id: "tmux:%0")?.agent == nil)
  }

  @Test("every tmux call carries -u, because an exec channel has no locale and tmux prints _ for non-ASCII")
  func utf8Flag() async throws {
    let host = FakeTmuxHost.seeded()
    let control = TmuxControl(run: host.runner)
    _ = try await control.snapshot()
    try await control.sendText(paneID: "tmux:%1", text: "x")
    try await control.sendKeys(paneID: "tmux:%1", keys: [.up])
    _ = try await control.readPanes(ids: ["tmux:%1"], lines: 3)
    try await control.perform(.split(.down), on: "tmux:%1")
    _ = await control.tmuxAvailability()
    for command in await host.commands where command.hasPrefix("tmux") {
      #expect(command.hasPrefix("tmux -u "), "\(command)")
    }
  }

  @Test("a title with non-ASCII characters survives, which it did not before -u")
  func unicodeTitles() async throws {
    let host = FakeTmuxHost.seeded()
    let tree = try await TmuxControl(run: host.runner).snapshot()
    #expect(tree.pane(id: "tmux:%1")?.title == "Claude Code")
    // Without -u the fake answers as tmux did under no locale: the separator is `_`.
    let bare = try await host.runner(TmuxCommands.listPanes(binary: "tmux"))
    #expect(TmuxPaneFormat.rows(from: bare.standardOutput).isEmpty)
    let withFlag = try await host.runner(TmuxCommands.listPanes(binary: "tmux -u"))
    #expect(TmuxPaneFormat.rows(from: withFlag.standardOutput).count == 4)
  }

  @Test("a snapshot is the listing, the process table and one batched read of records")
  func commands() async throws {
    let host = FakeTmuxHost.seeded()
    _ = try await TmuxControl(run: host.runner).snapshot()
    let commands = await host.commands
    #expect(commands.count == 3)
    #expect(commands.contains { $0.hasPrefix("tmux -u list-panes -a -F ") })
    #expect(commands.contains("ps -A -o pid=,pgid=,tpgid=,tty=,comm="))
    let reads = commands.filter { $0.contains(ClaudeRecordFiles.marker) }
    try #require(reads.count == 1)
    // Every foreground pid is tried: 5001 5002 5003 5004 5005, and the zsh shells too.
    for pid in [5001, 5002, 5003, 5004, 5005] {
      #expect(reads[0].contains("/sessions/\(pid).json"))
    }
  }

  @Test("a host with tmux and no server has an empty tree, not an error")
  func noServer() async throws {
    let host = FakeTmuxHost(sessions: [])
    #expect(try await TmuxControl(run: host.runner).snapshot() == .empty)
    // Nothing to join, so not even the process table is asked.
    #expect(await host.commands.count == 1)
    #expect(await !host.commands.contains { $0.contains(".claude/sessions/") })
  }

  @Test(
    "the other ways tmux says no server is running read the same",
    arguments: [
      "no server running on /tmp/tmux-1000/default",
      "error connecting to /tmp/tmux-1000/default (No such file or directory)",
      "error connecting to /tmp/tmux-1000/default (Connection refused)",
    ])
  func noServerWords(message: String) async throws {
    let control = TmuxControl(run: { command in
      command.contains("list-panes")
        ? CommandResult(standardOutput: "", standardError: message + "\n", exitStatus: 1)
        : CommandResult(standardOutput: "", standardError: "", exitStatus: 0)
    })
    #expect(try await control.snapshot() == .empty)
  }

  @Test(
    "a socket that cannot be reached is not an empty server",
    arguments: [
      "error connecting to /tmp/tmux-1000/default (Permission denied)",
      "error connecting to /tmp/tmux-1000/default (Operation not permitted)",
      "error connecting to /tmp/tmux-1000/default (Not a directory)",
    ])
  func unreachableSocket(message: String) async {
    let control = TmuxControl(run: { _ in
      CommandResult(standardOutput: "", standardError: message + "\n", exitStatus: 1)
    })
    await #expect(throws: AppError.herdrCommandFailed(reason: message)) {
      try await control.snapshot()
    }
    // A new terminal must not start a second server beside one the user cannot reach.
    await #expect(throws: AppError.herdrCommandFailed(reason: message)) {
      try await control.startTerminal()
    }
    await #expect(throws: AppError.herdrCommandFailed(reason: message)) {
      try await control.readPanes(ids: ["tmux:%1"], lines: 3)
    }
  }

  @Test("the words that do mean no server, and the ones that do not")
  func noServerWords() {
    for yes in [
      "no server running on /tmp/x", "no sessions",
      "error connecting to /tmp/x (No such file or directory)",
      "error connecting to /tmp/x (Connection refused)",
    ] { #expect(TmuxControl.isNoServer(yes), "\(yes)") }
    for no in [
      "error connecting to /tmp/x (Permission denied)", "can't find pane: %1", "unknown flag -x",
      "",
    ] { #expect(!TmuxControl.isNoServer(no), "\(no)") }
  }

  @Test("a real failure is not an empty tree")
  func failure() async {
    let control = TmuxControl(run: { _ in
      CommandResult(standardOutput: "", standardError: "protocol version mismatch", exitStatus: 1)
    })
    await #expect(throws: AppError.herdrCommandFailed(reason: "protocol version mismatch")) {
      try await control.snapshot()
    }
  }

  @Test("tmux missing is the shell's 127, and says so")
  func missing() async {
    let control = TmuxControl(run: { _ in
      CommandResult(standardOutput: "", standardError: "sh: tmux: command not found", exitStatus: 127)
    })
    await #expect(throws: AppError.tmuxNotInstalled) { try await control.snapshot() }
  }

  @Test("a transport that fails is a channel failure")
  func channel() async {
    let control = TmuxControl(run: { _ in throw CancellationError() })
    await #expect(throws: AppError.channelFailed(reason: "Could not run tmux on this host.")) {
      try await control.snapshot()
    }
  }

  @Test("a line tmux printed that cannot be read costs that pane and no other")
  func malformedLine() async throws {
    let good = FakeTmuxHost.seeded()
    let listing = try await good.runner(TmuxCommands.listPanes(binary: "tmux -u")).standardOutput
    let broken = "garbage line\n" + listing + "%99\u{1F}@99\n"
    let control = TmuxControl(run: { command in
      command.contains("list-panes")
        ? CommandResult(standardOutput: broken, standardError: "", exitStatus: 0)
        : try await good.runner(command)
    })
    #expect(try await control.snapshot().allPanes.count == 4)
  }

  @Test("a host whose ps fails still lists its panes, as shells")
  func psFails() async throws {
    let host = FakeTmuxHost.seeded()
    let control = TmuxControl(run: { command in
      command.hasPrefix("ps ")
        ? CommandResult(standardOutput: "", standardError: "ps: boom", exitStatus: 1)
        : try await host.runner(command)
    })
    let tree = try await control.snapshot()
    #expect(tree.allPanes.count == 4)
    #expect(tree.allPanes.allSatisfy { $0.agent == nil })
  }

  @Test("a ps that throws, or garbage ps output, also leaves shells")
  func psUnusable() async throws {
    let host = FakeTmuxHost.seeded()
    let throwing = TmuxControl(run: { command in
      if command.hasPrefix("ps ") { throw CancellationError() }
      return try await host.runner(command)
    })
    #expect(try await throwing.snapshot().blockedPanes.isEmpty)

    let garbage = TmuxControl(run: { command in
      command.hasPrefix("ps ")
        ? CommandResult(standardOutput: "what\nis this\n", standardError: "", exitStatus: 0)
        : try await host.runner(command)
    })
    #expect(try await garbage.snapshot().blockedPanes.isEmpty)
  }

  @Test("a failed read of the records leaves shells")
  func recordsFail() async throws {
    let host = FakeTmuxHost.seeded()
    let control = TmuxControl(run: { command in
      command.contains(ClaudeRecordFiles.marker)
        ? CommandResult(standardOutput: "", standardError: "denied", exitStatus: 1)
        : try await host.runner(command)
    })
    #expect(try await control.snapshot().blockedPanes.isEmpty)
  }

  @Test("each state a record reports reaches the pane")
  func states() async throws {
    for (word, expected) in [
      ("idle", AgentStatus.idle), ("busy", .working), ("waiting", .blocked),
    ] {
      let host = FakeTmuxHost.seeded()
      await host.setRecord(
        pid: 5002,
        FakeTmuxHost.claudeRecord(pid: 5002, sessionID: "s-1", status: word))
      let tree = try await TmuxControl(run: host.runner).snapshot()
      #expect(tree.pane(id: "tmux:%1")?.agent?.status == expected, "\(word)")
    }
  }

  @Test("a missing record for the last pid does not hide the records before it")
  func lastRecordMissing() async throws {
    // The shell reports the last command's status, and `cat` of a missing file exits 1.
    let host = FakeTmuxHost.seeded()
    let files = try await host.runner(ClaudeRecordFiles.command(forPIDs: [5002, 5005]))
    #expect(files.exitStatus == 1)
    #expect(try await TmuxControl(run: host.runner).snapshot().blockedPanes.count == 1)
  }

  @Test("a pane with no record has no agent, even if claude runs in it")
  func missingRecord() async throws {
    let host = FakeTmuxHost.seeded()
    await host.setRecord(pid: 5002, nil)
    let tree = try await TmuxControl(run: host.runner).snapshot()
    #expect(tree.pane(id: "tmux:%1")?.agent == nil)
  }

  @Test("a record that names another pid is another process's, and is not taken")
  func wrongPID() async throws {
    let host = FakeTmuxHost.seeded()
    await host.setRecord(
      pid: 5002, FakeTmuxHost.claudeRecord(pid: 7777, sessionID: "s-1", status: "busy"))
    #expect(try await TmuxControl(run: host.runner).snapshot().pane(id: "tmux:%1")?.agent == nil)
  }

  @Test("a malformed record is no agent and no failure")
  func malformedRecord() async throws {
    let host = FakeTmuxHost.seeded()
    await host.setRecord(pid: 5002, "{not json")
    let tree = try await TmuxControl(run: host.runner).snapshot()
    #expect(tree.pane(id: "tmux:%1")?.agent == nil)
    #expect(tree.allPanes.count == 4)
  }

  @Test("an agent behind a wrapper that leads the process group is found by its own pid")
  func wrapper() async throws {
    let host = FakeTmuxHost.seeded()
    await host.setProcesses([
      .init(pid: 6000, groupID: 6000, foregroundGroupID: 6000, tty: "ttys101", command: "npx"),
      .init(pid: 6001, groupID: 6000, foregroundGroupID: 6000, tty: "ttys101", command: "node"),
      .init(pid: 6002, groupID: 6000, foregroundGroupID: 6000, tty: "ttys101", command: "claude"),
    ])
    await host.setRecord(pid: 5002, nil)
    await host.setRecord(
      pid: 6002, FakeTmuxHost.claudeRecord(pid: 6002, sessionID: "s-2", status: "waiting"))
    let agent = try await TmuxControl(run: host.runner).snapshot().pane(id: "tmux:%1")?.agent
    #expect(agent?.status == .blocked)
    #expect(agent?.session?.identifier == "s-2")
  }

  @Test("two panes with a Claude each get their own session")
  func twoAgents() async throws {
    let host = FakeTmuxHost.seeded()
    await host.setProcesses([
      .init(pid: 5001, tty: "ttys100", command: "claude"),
      .init(pid: 5002, tty: "ttys101", command: "claude"),
    ])
    await host.setRecord(
      pid: 5001, FakeTmuxHost.claudeRecord(pid: 5001, sessionID: "first", status: "idle"))
    let tree = try await TmuxControl(run: host.runner).snapshot()
    #expect(tree.pane(id: "tmux:%0")?.agent?.session?.identifier == "first")
    #expect(tree.pane(id: "tmux:%1")?.agent?.status == .blocked)
  }

  @Test("polling is the only way to know, and nothing subscribes")
  func polling() {
    let control = TmuxControl(run: FakeTmuxHost().runner)
    #expect(control.needsPolling)
    #expect(control.changes == nil)
    #expect(control.paneAttacher(for: "tmux:%1") == nil)
    #expect(control.commandRunner(forPane: "tmux:%1") == nil)
    #expect(control.canPerform(.close, on: "tmux:%1"))
    #expect(control.canRename(.tab(id: "tmux:@1")))
  }
}

@Suite("TmuxControl Codex")
struct TmuxControlCodexTests {
  /// One session: `%0` a shell, and `%1` with Codex in its foreground group behind a leader that
  /// is not Codex, as measured on macOS. No Claude record anywhere.
  private func host(
    title: String, codex: String = "/home/dev/.local/bin/codex"
  ) -> FakeTmuxHost {
    FakeTmuxHost(
      sessions: [
        .init(
          id: 0, name: "work", attached: 1,
          windows: [
            .init(
              id: 0, index: 0, name: "codex", isActive: true,
              panes: [
                .init(id: 0, isActive: true),
                .init(id: 1, title: title, command: "codex", path: "/home/dev/app"),
              ])
          ])
      ],
      processes: [
        .init(pid: 5001, tty: "ttys100", command: "zsh"),
        .init(pid: 6000, groupID: 6000, foregroundGroupID: 6000, tty: "ttys101", command: "sh"),
        .init(pid: 6001, groupID: 6000, foregroundGroupID: 6000, tty: "ttys101", command: codex),
      ]
    )
  }

  @Test(
    "a Codex in the pane's foreground group is Codex, with its state from the title",
    arguments: [
      ("[ ! ] Action Required | app", AgentStatus.blocked),
      ("[ . ] Action Required | app", .blocked),
      ("⠋ app", .working),
      ("app", .idle),
    ])
  func codex(title: String, status: AgentStatus) async throws {
    let tree = try await TmuxControl(run: host(title: title).runner).snapshot()
    let pane = try #require(tree.pane(id: "tmux:%1"))
    let agent = try #require(pane.agent)
    #expect(agent.name == "Codex")
    #expect(agent.kind == TranscriptAgent.codex.rawValue)
    #expect(agent.status == status)
    #expect(agent.session == nil, "the reader matches Codex's rollout by directory")
    #expect(agent.blockedKind == nil, "Codex's title does not say what it waits for")
    #expect(pane.directory == "/home/dev/app")
    #expect(pane.title == "app", "the label does not change with the state")
    #expect(tree.pane(id: "tmux:%0")?.agent == nil)
  }

  @Test("a Codex title with nothing after the marker names the pane Codex")
  func bareTitle() async throws {
    let tree = try await TmuxControl(run: host(title: "[ ! ] Action Required").runner).snapshot()
    #expect(tree.pane(id: "tmux:%1")?.title == "Codex")
  }

  @Test("Linux's bare name is Codex too")
  func linux() async throws {
    let tree = try await TmuxControl(run: host(title: "⠋ app", codex: "codex").runner).snapshot()
    #expect(tree.pane(id: "tmux:%1")?.agent?.kind == TranscriptAgent.codex.rawValue)
  }

  @Test("a Claude record in the same group wins over Codex")
  func claudeWins() async throws {
    let host = host(title: "[ ! ] Action Required | app")
    await host.setRecord(
      pid: 6000, FakeTmuxHost.claudeRecord(pid: 6000, sessionID: "s-1", status: "busy"))
    let agent = try await TmuxControl(run: host.runner).snapshot().pane(id: "tmux:%1")?.agent
    #expect(agent?.kind == TranscriptAgent.claude.rawValue)
    #expect(agent?.status == .working)
  }

  @Test("Codex is still found when the read of Claude's records throws")
  func recordsFail() async throws {
    let host = host(title: "[ ! ] Action Required | app")
    let control = TmuxControl(run: { command in
      if command.contains(ClaudeRecordFiles.marker) {
        throw AppError.channelFailed(reason: "dropped")
      }
      return try await host.runner(command)
    })
    #expect(try await control.snapshot().blockedPanes.map(\.id) == ["tmux:%1"])
  }
}

@Suite("TmuxControl input")
struct TmuxControlInputTests {
  @Test("typed text arrives as typed, whatever it holds")
  func sendText() async throws {
    let host = FakeTmuxHost.seeded()
    let control = TmuxControl(run: host.runner)
    let texts = [
      "plain", #"it's "quoted""#, "$HOME $(id)", "line one\nline two", "ends;", ";", "a;b",
      "-x --flag", "a" + backslash + ";", "; kill-server",
    ]
    for text in texts { try await control.sendText(paneID: "tmux:%1", text: text) }
    #expect(await host.input["%1"] == texts.map { .text($0) })
    #expect(await host.input["%0"] == nil, "no other pane was typed into")
  }

  @Test("a trailing newline stays literal and does not submit")
  func newline() async throws {
    let host = FakeTmuxHost.seeded()
    try await TmuxControl(run: host.runner).sendText(paneID: "tmux:%1", text: "yes\n")
    #expect(await host.input["%1"] == [.text("yes\n")])
  }

  @Test("a submit types the text and presses Enter, in one command")
  func submit() async throws {
    let host = FakeTmuxHost.seeded()
    let control = TmuxControl(run: host.runner)
    let before = await host.commands.count

    try await control.submitText(paneID: "tmux:%1", text: "yes; please\n\n")

    #expect(await host.input["%1"] == [.text("yes; please"), .key("Enter")])
    #expect(await host.commands.count == before + 1, "one exec, so a failure cannot half-type")
  }

  @Test("a submit whose text ends in a semicolon keeps it")
  func submitSemicolon() async throws {
    let host = FakeTmuxHost.seeded()
    try await TmuxControl(run: host.runner).submitText(paneID: "tmux:%1", text: "run it;")
    #expect(await host.input["%1"] == [.text("run it;"), .key("Enter")])
  }

  @Test("a submit of nothing is only Enter")
  func submitNothing() async throws {
    let host = FakeTmuxHost.seeded()
    try await TmuxControl(run: host.runner).submitText(paneID: "tmux:%1", text: " \n")
    #expect(await host.input["%1"] == [.key("Enter")])
  }

  @Test("empty text sends nothing at all")
  func emptyText() async throws {
    let host = FakeTmuxHost.seeded()
    try await TmuxControl(run: host.runner).sendText(paneID: "tmux:%1", text: "")
    #expect(await host.commands.isEmpty)
  }

  @Test("keys are pressed in order, characters typed and names pressed")
  func keys() async throws {
    let host = FakeTmuxHost.seeded()
    try await TmuxControl(run: host.runner).sendKeys(
      paneID: "tmux:%1", keys: [.down, .down, .enter, .yes, .digit2, .esc, .interrupt])
    #expect(
      await host.input["%1"] == [
        .key("Down"), .key("Down"), .key("Enter"), .text("y"), .text("2"), .key("Escape"),
        .key("C-c"),
      ])
  }

  @Test("no keys is no command")
  func noKeys() async throws {
    let host = FakeTmuxHost.seeded()
    try await TmuxControl(run: host.runner).sendKeys(paneID: "tmux:%1", keys: [])
    #expect(await host.commands.isEmpty)
  }

  @Test("a pane that is gone is a refusal, not silence")
  func gone() async {
    let host = FakeTmuxHost.seeded()
    let control = TmuxControl(run: host.runner)
    await #expect(throws: AppError.herdrCommandFailed(reason: "can't find pane: %99")) {
      try await control.sendText(paneID: "tmux:%99", text: "hi")
    }
    await #expect(throws: AppError.herdrCommandFailed(reason: "can't find pane: %99")) {
      try await control.sendKeys(paneID: "tmux:%99", keys: [.enter])
    }
  }

  @Test(
    "an id that is not a tmux pane never reaches the shell",
    arguments: ["", "w1:p2", "core:t1", "tmux:%1;rm", "tmux:@2", "tmux:$1", "%1", "tmux:%1 -x"])
  func foreignIDs(id: String) async {
    let host = FakeTmuxHost.seeded()
    let control = TmuxControl(run: host.runner)
    await #expect(throws: AppError.self) { try await control.sendText(paneID: id, text: "x") }
    await #expect(throws: AppError.self) { try await control.submitText(paneID: id, text: "x") }
    await #expect(throws: AppError.self) { try await control.sendKeys(paneID: id, keys: [.up]) }
    await #expect(throws: AppError.self) { try await control.perform(.close, on: id) }
    #expect(await host.commands.isEmpty)
  }
}

@Suite("TmuxControl reads")
struct TmuxControlReadTests {
  @Test("a batched read gives each pane its rows, trimmed to the tail")
  func readPanes() async throws {
    let host = FakeTmuxHost.seeded()
    let rows = try await TmuxControl(run: host.runner).readPanes(
      ids: ["tmux:%1", "tmux:%0"], lines: 2)
    #expect(rows["tmux:%1"] == ["❯ 1. Yes", "  2. No"])
    #expect(rows["tmux:%0"] == [], "a blank pane is an empty array")
    #expect(await host.commands.count == 1, "one exec for the whole batch")
  }

  @Test("a closed pane is empty and the rest are still read")
  func closedPane() async throws {
    let host = FakeTmuxHost.seeded()
    let rows = try await TmuxControl(run: host.runner).readPanes(
      ids: ["tmux:%99", "tmux:%1"], lines: 5)
    #expect(rows["tmux:%99"] == [])
    #expect(rows["tmux:%1"]?.count == 3)
  }

  @Test("an id that is not a tmux pane is answered empty and never asked")
  func foreign() async throws {
    let host = FakeTmuxHost.seeded()
    let rows = try await TmuxControl(run: host.runner).readPanes(
      ids: ["core:t1", "tmux:%1;x", "tmux:%1"], lines: 5)
    #expect(rows["core:t1"] == [])
    #expect(rows["tmux:%1;x"] == [])
    #expect(rows["tmux:%1"]?.count == 3)
    #expect(await !host.commands[0].contains(";x"))

    let none = try await TmuxControl(run: host.runner).readPanes(ids: ["w1:p1"], lines: 5)
    #expect(none == ["w1:p1": []])
    #expect(try await TmuxControl(run: host.runner).readPanes(ids: [], lines: 5).isEmpty)
    #expect(await host.commands.count == 1, "nothing to ask means nothing is asked")
  }

  @Test("a refusal of the whole batch is an error, and one closed pane is not")
  func refusal() async {
    let refusing = TmuxControl(run: { _ in
      CommandResult(standardOutput: "", standardError: "unknown option -- p", exitStatus: 1)
    })
    await #expect(throws: AppError.herdrCommandFailed(reason: "unknown option -- p")) {
      try await refusing.readPanes(ids: ["tmux:%1"], lines: 5)
    }
  }

  @Test("a single closed pane is an empty answer, not a refusal")
  func soleClosedPane() async throws {
    let host = FakeTmuxHost.seeded()
    let rows = try await TmuxControl(run: host.runner).readPanes(ids: ["tmux:%99"], lines: 5)
    #expect(rows == ["tmux:%99": []])
  }

  @Test("a server that went away reads as empty panes")
  func serverGone() async throws {
    let control = TmuxControl(run: { _ in
      CommandResult(standardOutput: "", standardError: "no server running on /tmp/x\n", exitStatus: 1)
    })
    #expect(try await control.readPanes(ids: ["tmux:%1"], lines: 5) == ["tmux:%1": []])
  }

  @Test("the reply surface reads one pane's screen")
  func readScreen() async throws {
    let host = FakeTmuxHost.seeded()
    let control = TmuxControl(run: host.runner)
    let pane = try #require(try await control.snapshot().pane(id: "tmux:%1"))
    let screen = try await control.readScreen(of: pane, lines: 10)
    #expect(screen.text == "Do you want to proceed?\n❯ 1. Yes\n  2. No")
    #expect(await host.commands.last == "tmux -u capture-pane -p -e -t '%1'")
  }

  @Test("a styled screen keeps its colour")
  func styledScreen() async throws {
    let host = FakeTmuxHost.seeded()
    await host.setScreen(of: 1, ["\u{1B}[1;31mError\u{1B}[0m: plain"])
    let control = TmuxControl(run: host.runner)
    let pane = try #require(try await control.snapshot().pane(id: "tmux:%1"))
    let screen = try await control.readScreen(of: pane, lines: 5)
    #expect(screen.text == "Error: plain")
    #expect(screen.lines.first?.spans.first?.style.isBold == true)
  }

  @Test("a blank screen is blank and a closed pane throws")
  func blankAndClosed() async throws {
    let host = FakeTmuxHost.seeded()
    let control = TmuxControl(run: host.runner)
    let shell = try #require(try await control.snapshot().pane(id: "tmux:%0"))
    #expect(try await control.readScreen(of: shell, lines: 5).isEmpty)

    let gone = Pane(id: "tmux:%99", tabID: "tmux:@0", workspaceID: "tmux:$0", title: "gone")
    await #expect(throws: AppError.herdrCommandFailed(reason: "can't find pane: %99")) {
      try await control.readScreen(of: gone, lines: 5)
    }
  }
}

@Suite("TmuxControl actions")
struct TmuxControlActionTests {
  @Test("a split adds a pane that starts where the first one is")
  func split() async throws {
    let host = FakeTmuxHost.seeded()
    let control = TmuxControl(run: host.runner)
    try await control.perform(.split(.right), on: "tmux:%1")
    let tree = try await control.snapshot()
    #expect(tree.workspaces[0].tabs[0].panes.map(\.id) == ["tmux:%0", "tmux:%1", "tmux:%4"])
    #expect(tree.pane(id: "tmux:%4")?.directory == "/home/dev/driverr")
  }

  @Test("a close removes the pane, and its window when it was the last")
  func close() async throws {
    let host = FakeTmuxHost.seeded()
    let control = TmuxControl(run: host.runner)
    try await control.perform(.close, on: "tmux:%1")
    #expect(try await control.snapshot().allPanes.map(\.id) == ["tmux:%0", "tmux:%2", "tmux:%3"])
    try await control.perform(.close, on: "tmux:%2")
    #expect(try await control.snapshot().workspaces[0].tabs.map(\.label) == ["editor"])
  }

  @Test("closing a pane that is gone says so")
  func closeGone() async {
    let control = TmuxControl(run: FakeTmuxHost.seeded().runner)
    await #expect(throws: AppError.herdrCommandFailed(reason: "can't find pane: %42")) {
      try await control.perform(.close, on: "tmux:%42")
    }
  }

  @Test("a pane rename sets its title, which then shows as the pane's name")
  func renamePane() async throws {
    let host = FakeTmuxHost.seeded()
    let control = TmuxControl(run: host.runner)
    try await control.perform(.rename("build; watch"), on: "tmux:%0")
    #expect(try await control.snapshot().pane(id: "tmux:%0")?.title == "build; watch")
  }

  @Test(
    "a name tmux would expand or refuse as a flag is stored as typed",
    arguments: ["#S", "-x", "--flag", "a#{pane_id}b", "#(id)", "##", "issue #3", "x;", "-"])
  func awkwardLabels(label: String) async throws {
    let host = FakeTmuxHost.seeded()
    let control = TmuxControl(run: host.runner)

    try await control.rename(.workspace(id: "tmux:$1"), to: label)
    try await control.rename(.tab(id: "tmux:@2"), to: label)
    try await control.perform(.rename(label), on: "tmux:%3")

    let tree = try await control.snapshot()
    #expect(tree.workspaces[1].label == label)
    #expect(tree.workspaces[1].tabs[0].label == label)
    // A title of only symbols is trimmed to nothing for display, as any title is, and the pane
    // then takes its command's name.
    if label.contains(where: { $0.isLetter || $0.isNumber }) {
      #expect(tree.pane(id: "tmux:%3")?.title == label)
    }
    #expect(await host.sessions[1].windows[0].panes[0].title == label)
  }

  @Test("a newline in a name or a title is a space, and the rename still lands")
  func newlineLabels() async throws {
    let host = FakeTmuxHost.seeded()
    let control = TmuxControl(run: host.runner)
    try await control.rename(.workspace(id: "tmux:$1"), to: "two\nlines")
    try await control.rename(.tab(id: "tmux:@2"), to: "two\r\nlines")
    try await control.perform(.rename("two\nlines"), on: "tmux:%3")
    let tree = try await control.snapshot()
    #expect(tree.workspaces[1].label == "two lines")
    #expect(tree.workspaces[1].tabs[0].label == "two lines")
    #expect(tree.pane(id: "tmux:%3")?.title == "two lines")
  }

  @Test("a tab or another control character in a name or a title is a space, and the rename lands")
  func controlLabels() async throws {
    let host = FakeTmuxHost.seeded()
    let control = TmuxControl(run: host.runner)
    try await control.rename(.workspace(id: "tmux:$1"), to: "a\tb")
    try await control.rename(.tab(id: "tmux:@2"), to: "c\u{1B}d")
    try await control.perform(.rename("e\u{7F}f\tg"), on: "tmux:%3")
    let tree = try await control.snapshot()
    #expect(tree.workspaces[1].label == "a b")
    #expect(tree.workspaces[1].tabs[0].label == "c d")
    #expect(tree.pane(id: "tmux:%3")?.title == "e f g")
  }

  @Test("a session and a window rename; the window then stops being auto-named")
  func renameContainers() async throws {
    let host = FakeTmuxHost.seeded()
    let control = TmuxControl(run: host.runner)
    try await control.rename(.workspace(id: "tmux:$1"), to: "notes;")
    try await control.rename(.tab(id: "tmux:@2"), to: "todo")
    let tree = try await control.snapshot()
    #expect(tree.workspaces[1].label == "notes;")
    #expect(tree.workspaces[1].tabs[0].label == "todo")
    #expect(tree.workspaces[1].tabs[0].isAutoNamed == false)
  }

  @Test("a rename aimed at the wrong kind of id never reaches the shell")
  func renameWrongKind() async {
    let host = FakeTmuxHost.seeded()
    let control = TmuxControl(run: host.runner)
    await #expect(throws: AppError.self) {
      try await control.rename(.workspace(id: "tmux:@2"), to: "x")
    }
    await #expect(throws: AppError.self) {
      try await control.rename(.tab(id: "tmux:$1"), to: "x")
    }
    await #expect(throws: AppError.self) {
      try await control.rename(.tab(id: "w1:t2"), to: "x")
    }
    #expect(await host.commands.isEmpty)
  }

  @Test("a new terminal is a window in the busiest session, and its pane id comes back")
  func startTerminal() async throws {
    let host = FakeTmuxHost.seeded()
    let control = TmuxControl(run: host.runner)
    let id = try await control.startTerminal()
    #expect(id == "tmux:%4")
    let tree = try await control.snapshot()
    #expect(tree.workspaces[0].tabs.count == 3, "work was the most recently active")
    #expect(tree.pane(id: id) != nil)
  }

  @Test("with no server a new terminal starts a session")
  func startTerminalNoServer() async throws {
    let host = FakeTmuxHost(sessions: [])
    let control = TmuxControl(run: host.runner)
    let id = try await control.startTerminal()
    #expect(id == "tmux:%0")
    #expect(try await control.snapshot().workspaces.count == 1)
    #expect(await host.commands.count == 4, "new-window refused, new-session, then the snapshot's two")
  }

  @Test("an answer that is not a pane id is unreadable, not trusted")
  func startTerminalGarbage() async {
    let control = TmuxControl(run: { _ in
      CommandResult(standardOutput: "created\n", standardError: "", exitStatus: 0)
    })
    await #expect(throws: AppError.herdrResponseUnreadable) { try await control.startTerminal() }
  }

}

@Suite("TmuxControl discovery")
struct TmuxControlDiscoveryTests {
  @Test("an absolute path ending in tmux is the answer, and banners are not")
  func path() {
    #expect(TmuxControl.discoveredPath(in: "/opt/homebrew/bin/tmux\n") == "/opt/homebrew/bin/tmux")
    #expect(
      TmuxControl.discoveredPath(in: "Welcome back\nalias tmux=foo\n  /usr/local/bin/tmux  \n")
        == "/usr/local/bin/tmux")
    #expect(TmuxControl.discoveredPath(in: "tmux\n") == nil)
    #expect(TmuxControl.discoveredPath(in: "/usr/bin/tmuxinator\n") == nil)
    #expect(TmuxControl.discoveredPath(in: "") == nil)
  }

  @Test("the probe tries the path, the login shell, then Homebrew and the user's bin")
  func command() {
    let command = TmuxControl.discoveryCommand
    #expect(command.contains("command -v tmux"))
    #expect(command.contains("-lc 'command -v tmux'"))
    #expect(command.contains("\"/opt/homebrew/bin/tmux\""))
    #expect(command.contains("\"/usr/local/bin/tmux\""))
    #expect(command.contains("\"$HOME/.local/bin/tmux\""))
  }

  @Test("discovery binds the control to the path it found")
  func discovering() async {
    let found = await TmuxControl.discovering(run: { _ in
      CommandResult(standardOutput: "/opt/homebrew/bin/tmux\n", standardError: "", exitStatus: 0)
    })
    #expect(found?.binaryPath == "/opt/homebrew/bin/tmux")

    let none = await TmuxControl.discovering(run: { _ in
      CommandResult(standardOutput: "", standardError: "", exitStatus: 0)
    })
    #expect(none == nil)

    let throwing = await TmuxControl.discovering(run: { _ in throw CancellationError() })
    #expect(throwing == nil)
  }

  @Test("a binary path with a space is quoted into every command")
  func quotedBinary() async throws {
    let host = FakeTmuxHost.seeded()
    let control = TmuxControl(binaryPath: "/Users/a b/bin/tmux", run: host.runner)
    _ = try await control.snapshot()
    #expect(await host.commands.contains { $0.hasPrefix("'/Users/a b/bin/tmux' -u list-panes") })
  }
}
