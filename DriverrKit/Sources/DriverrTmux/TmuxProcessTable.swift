import DriverrCore
import Foundation

/// One row of `ps`, as far as the pane-to-agent join needs it.
struct TmuxProcess: Equatable, Sendable {
  let pid: Int
  /// The process's own group.
  let groupID: Int
  /// The foreground group of the terminal this process is on. `0` or `-1` with no terminal.
  let foregroundGroupID: Int
  /// `ttys036` on macOS and `pts/3` on Linux, as `ps` prints it: no `/dev/`.
  let tty: String
  let command: String
}

/// Which process is in the foreground of a pane's terminal.
///
/// tmux gives each pane a `pane_tty`, `/dev/ttys036`, and `ps` prints the same terminal without
/// `/dev/`. Claude Code's own record is named by its pid, and `pane_current_command` is no help,
/// because it reads Claude's version string.
///
/// `ps`'s `stat` shows `S+` on Claude and on its MCP children alike, so it cannot pick one.
/// The terminal's foreground group can: Claude is its leader, so `pid == tpgid`. A wrapper that
/// leads the group (`npx`, `node`) is the case nobody has measured, so every member of the group
/// is a candidate, leader first.
enum TmuxProcessTable {
  /// Both macOS and Linux `ps` take these columns. The `=` drops the header.
  static let command = "ps -A -o pid=,pgid=,tpgid=,tty=,comm="

  /// The most processes tried for one pane. A pane with more than this in one group is a build
  /// or a pipeline, not an agent.
  static let candidateLimit = 12

  static func parse(_ output: String) -> [TmuxProcess] {
    output.split(separator: "\n").compactMap { line in
      // `comm` is last because a macOS path can hold spaces.
      let fields = line.split(
        maxSplits: 4, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" }
      )
      guard fields.count == 5,
        let pid = Int(fields[0]), let group = Int(fields[1]), let foreground = Int(fields[2])
      else { return nil }
      return TmuxProcess(
        pid: pid,
        groupID: group,
        foregroundGroupID: foreground,
        tty: String(fields[3]),
        // `ps` pads the column before `comm`, and the split leaves that padding on it.
        command: fields[4].trimmingCharacters(in: .whitespaces)
      )
    }
  }

  /// `ps`'s name for a `pane_tty`.
  static func ttyName(ofPaneTTY paneTTY: String) -> String {
    paneTTY.hasPrefix("/dev/") ? String(paneTTY.dropFirst("/dev/".count)) : paneTTY
  }

  /// The pids that may be this pane's agent, most likely first: the foreground group's leader,
  /// then its other members by pid.
  static func candidates(forPaneTTY paneTTY: String, in processes: [TmuxProcess]) -> [Int] {
    foregroundGroup(forPaneTTY: paneTTY, in: processes).map(\.pid)
  }

  /// The processes behind `candidates(forPaneTTY:in:)`, in the same order, with their commands.
  static func foregroundGroup(
    forPaneTTY paneTTY: String, in processes: [TmuxProcess]
  ) -> [TmuxProcess] {
    let tty = ttyName(ofPaneTTY: paneTTY)
    guard !tty.isEmpty else { return [] }
    let onTTY = processes.filter { $0.tty == tty && $0.foregroundGroupID > 0 }
    guard let foreground = onTTY.first?.foregroundGroupID else { return [] }
    let group = onTTY.filter { $0.groupID == foreground }.sorted { $0.pid < $1.pid }
    let ordered = group.filter { $0.pid == foreground } + group.filter { $0.pid != foreground }
    return Array(ordered.prefix(candidateLimit))
  }

  /// Whether a process is Codex, by its command's last path component.
  ///
  /// Codex keeps no record that names its process, so its name is the only signal. macOS `ps`
  /// prints `comm` as the path it was started by, which for a symlinked install is the link,
  /// such as `/home/dev/.local/bin/codex`, and `codex` when a shell found it on `PATH`. Linux
  /// prints the bare name, which is not measured. On codex 0.164.0 on macOS one launch led the
  /// foreground group and another was only a member of it, so every member is checked. A `node`
  /// wrapper from an npm install is not measured, and does not match.
  static func isCodex(_ process: TmuxProcess) -> Bool {
    name(of: process) == "codex"
  }

  /// Whether a pane's foreground group, from `foregroundGroup(forPaneTTY:in:)`, is Codex.
  ///
  /// **Not when Claude leads the group.** Claude can start `codex mcp-server` as an MCP child in
  /// its own group, and with Claude's record missing or unreadable that child would make a
  /// Claude pane a Codex one. Claude's `comm` is `claude`, or its version string, `2.1.325`.
  static func runsCodex(_ group: [TmuxProcess]) -> Bool {
    if let leader = group.first, leader.pid == leader.groupID, !isCodex(leader) {
      let leaderName = name(of: leader)
      if leaderName == "claude" || TmuxSnapshotMapper.looksLikeVersion(leaderName) { return false }
    }
    return group.contains(where: isCodex)
  }

  /// A command's last path component.
  private static func name(of process: TmuxProcess) -> String {
    process.command.split(separator: "/").last.map(String.init) ?? ""
  }
}

/// Claude Code's records for many pids, read in one command and split again.
enum ClaudeRecordFiles {
  /// What precedes each record in the combined output. The pid follows it, because the
  /// file's own text is arbitrary and a bare marker in it would shift every later record.
  static let marker = "__DRIVERR_RECORD__"

  /// One command that prints each pid's record after a boundary line. A missing file prints
  /// nothing and no error.
  ///
  /// The records are in Claude Code's configuration directory,
  /// `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`, as `AgentIntegration.claudeCode` resolves it. That
  /// expression is POSIX and the exec channel hands the command to the login shell, which may
  /// be fish, so the script runs under `sh -c`, quoted as `HookInstallCommands` quotes its own.
  /// The variable only counts if it reaches a non-interactive SSH shell.
  ///
  /// Plain sequenced commands, which `FakeTmuxHost` reads. The pids are integers Driverr
  /// parsed, so nothing reaches the shell as syntax.
  static func command(forPIDs pids: [Int]) -> String {
    let directory = AgentIntegration.claudeCode.configDirectory
    let script = pids.map { pid in
      "printf '\\n%s\\n' '\(marker) \(pid)'; "
        + "cat \(directory)/sessions/\(pid).json 2>/dev/null"
    }
    .joined(separator: "; ")
    return "sh -c " + HookInstallCommands.loginShellQuoted(script)
  }

  /// The text after each boundary, by pid. A pid the command did not ask for is dropped.
  static func contents(of output: String, forPIDs pids: [Int]) -> [Int: Data] {
    let asked = Set(pids)
    var records: [Int: [Substring]] = [:]
    var current: Int?
    for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("\(marker) "), let pid = Int(line.dropFirst(marker.count + 1)),
        asked.contains(pid)
      {
        current = pid
        records[pid] = []
      } else if let current {
        records[current, default: []].append(line)
      }
    }
    return records.mapValues { Data($0.joined(separator: "\n").utf8) }
  }
}
