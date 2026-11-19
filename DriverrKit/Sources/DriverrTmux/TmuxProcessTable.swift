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
    let tty = ttyName(ofPaneTTY: paneTTY)
    guard !tty.isEmpty else { return [] }
    let onTTY = processes.filter { $0.tty == tty && $0.foregroundGroupID > 0 }
    guard let foreground = onTTY.first?.foregroundGroupID else { return [] }
    let group = onTTY.filter { $0.groupID == foreground }.map(\.pid).sorted()
    let ordered = group.filter { $0 == foreground } + group.filter { $0 != foreground }
    return Array(ordered.prefix(candidateLimit))
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
