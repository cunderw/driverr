import DriverrCore
import Foundation
import Testing

@testable import DriverrTmux

@Suite("TmuxProcessTable")
struct TmuxProcessTableTests {
  // macOS `ps -A -o pid=,pgid=,tpgid=,tty=,comm=`: `comm` is a path, and a process with no
  // terminal prints `??`.
  private let macOS = """
        1     1    0 ??       /sbin/launchd
      556   556    0 ??       /usr/libexec/logd
    11660 11660 11660 ttys036  claude
    11700 11660 11660 ttys036  /opt/homebrew/bin/node
    11701 11660 11660 ttys036  /Applications/My Tool/mcp server
    12000 12000 12000 ttys040  -zsh
    """

  @Test("macOS rows read into pid, groups, terminal and command")
  func parsesMacOS() {
    let rows = TmuxProcessTable.parse(macOS)
    #expect(rows.count == 6)
    #expect(
      rows[0]
        == TmuxProcess(
          pid: 1, groupID: 1, foregroundGroupID: 0, tty: "??", command: "/sbin/launchd"))
    #expect(rows[2].command == "claude")
    #expect(rows[4].command == "/Applications/My Tool/mcp server", "a path with spaces stays whole")
  }

  @Test("Linux rows, whose terminal is pts/N, read the same way")
  func parsesLinux() {
    let linux = """
      1 1 -1 ? systemd
      800 800 800 pts/3 claude
      801 800 800 pts/3 node
      """
    let rows = TmuxProcessTable.parse(linux)
    #expect(rows.map(\.tty) == ["?", "pts/3", "pts/3"])
    #expect(TmuxProcessTable.candidates(forPaneTTY: "/dev/pts/3", in: rows) == [800, 801])
  }

  @Test("a line that is not a row is skipped")
  func malformed() {
    let output = "garbage\n\n1 2 3\nx y z tty cmd\n  42  42  42 ttys001 vim\n"
    #expect(TmuxProcessTable.parse(output).map(\.pid) == [42])
  }

  @Test("pane_tty loses /dev/ to match what ps prints")
  func ttyName() {
    #expect(TmuxProcessTable.ttyName(ofPaneTTY: "/dev/ttys036") == "ttys036")
    #expect(TmuxProcessTable.ttyName(ofPaneTTY: "/dev/pts/3") == "pts/3")
    #expect(TmuxProcessTable.ttyName(ofPaneTTY: "ttys036") == "ttys036")
  }

  @Test("the foreground group's leader comes first, then its members")
  func candidates() {
    let rows = TmuxProcessTable.parse(macOS)
    #expect(
      TmuxProcessTable.candidates(forPaneTTY: "/dev/ttys036", in: rows) == [11660, 11700, 11701])
    #expect(TmuxProcessTable.candidates(forPaneTTY: "/dev/ttys040", in: rows) == [12000])
  }

  @Test("a process outside the foreground group is not a candidate")
  func background() {
    let rows = TmuxProcessTable.parse(
      """
      100 100 200 ttys001 -zsh
      200 200 200 ttys001 claude
      300 300 200 ttys001 sleep
      """)
    // The shell (100) is a background group while claude (200) holds the terminal.
    #expect(TmuxProcessTable.candidates(forPaneTTY: "/dev/ttys001", in: rows) == [200])
  }

  @Test("a wrapper that leads the group is tried first, and the agent behind it still is")
  func wrapper() {
    let rows = TmuxProcessTable.parse(
      """
      500 500 500 ttys002 npx
      501 500 500 ttys002 node
      502 500 500 ttys002 claude
      """)
    #expect(TmuxProcessTable.candidates(forPaneTTY: "/dev/ttys002", in: rows) == [500, 501, 502])
  }

  @Test("a terminal with no foreground group, an unknown terminal and an empty name have none")
  func none() {
    let rows = TmuxProcessTable.parse("1 1 0 ?? launchd\n7 7 -1 ttys009 orphan\n")
    #expect(TmuxProcessTable.candidates(forPaneTTY: "/dev/ttys009", in: rows).isEmpty)
    #expect(TmuxProcessTable.candidates(forPaneTTY: "/dev/ttys404", in: rows).isEmpty)
    #expect(TmuxProcessTable.candidates(forPaneTTY: "", in: rows).isEmpty)
    #expect(TmuxProcessTable.candidates(forPaneTTY: "/dev/", in: rows).isEmpty)
  }

  @Test("a build with a huge process group is cut off")
  func limit() {
    let rows = (1...40).map {
      TmuxProcess(
        pid: 1000 + $0, groupID: 1001, foregroundGroupID: 1001, tty: "ttys5", command: "cc")
    }
    let found = TmuxProcessTable.candidates(forPaneTTY: "/dev/ttys5", in: rows)
    #expect(found.count == TmuxProcessTable.candidateLimit)
    #expect(found.first == 1001)
  }
}

@Suite("ClaudeRecordFiles")
struct ClaudeRecordFilesTests {
  @Test("the command prints a boundary and each pid's file from Claude Code's directory, under sh -c")
  func command() {
    let command = ClaudeRecordFiles.command(forPIDs: [11, 22])
    let first = #"printf '\n%s\n' '__DRIVERR_RECORD__ 11'; "#
      + #"cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/sessions/11.json 2>/dev/null; "#
    let second = #"printf '\n%s\n' '__DRIVERR_RECORD__ 22'; "#
      + #"cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/sessions/22.json 2>/dev/null"#
    // The login shell may be fish, which cannot read `${…:-…}`, so the script goes to `sh`.
    #expect(command == "sh -c " + HookInstallCommands.loginShellQuoted(first + second))
  }

  /// A real `/bin/sh`, so the `:-` default and the quoting are what a host's shell makes of
  /// them, not what the fake does. Scratch directories only: nothing reads the real `~/.claude`.
  @Test("a real shell reads CLAUDE_CONFIG_DIR's records, and ~/.claude's when it is unset")
  func realShell() async throws {
    let directory = try LocalShell.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let home = directory.appendingPathComponent("home")
    let config = directory.appendingPathComponent("config")
    for (root, id) in [(home.appendingPathComponent(".claude"), "from-home"), (config, "from-config")] {
      let sessions = root.appendingPathComponent("sessions")
      try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
      try FakeTmuxHost.claudeRecord(pid: 11, sessionID: id, status: "waiting")
        .write(to: sessions.appendingPathComponent("11.json"), atomically: true, encoding: .utf8)
    }
    let command = ClaudeRecordFiles.command(forPIDs: [11, 22])

    func sessionID(_ environment: String) async throws -> String? {
      let result = try await LocalShell.runner(environment + command)
      let records = ClaudeRecordFiles.contents(of: result.standardOutput, forPIDs: [11, 22])
      #expect(result.standardError.isEmpty, "\(result.standardError)")
      return ClaudeSessionRecord.parse(records[11] ?? Data())?.sessionID
    }
    let homeOnly = "HOME=\(shellQuoted(home.path)); export HOME; "
    #expect(try await sessionID(homeOnly) == "from-home")
    let both = homeOnly + "CLAUDE_CONFIG_DIR=\(shellQuoted(config.path)); export CLAUDE_CONFIG_DIR; "
    #expect(try await sessionID(both) == "from-config")
  }

  @Test("each pid's text comes back after its boundary, and a missing file is empty")
  func contents() {
    let output =
      "\n__DRIVERR_RECORD__ 11\n{\"sessionId\":\"a\"}\n"
      + "\n__DRIVERR_RECORD__ 22\n"
      + "\n__DRIVERR_RECORD__ 33\n{\"sessionId\":\n\"c\"}\n"
    let records = ClaudeRecordFiles.contents(of: output, forPIDs: [11, 22, 33])
    #expect(ClaudeSessionRecord.parse(records[11] ?? Data())?.sessionID == "a")
    let missing = String(decoding: records[22] ?? Data(), as: UTF8.self)
    #expect(missing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(ClaudeSessionRecord.parse(records[33] ?? Data())?.sessionID == "c", "a record may span lines")
  }

  @Test("a boundary for a pid nobody asked about is text, not a boundary")
  func unaskedBoundary() {
    let output = "\n__DRIVERR_RECORD__ 11\n{\"sessionId\":\"a\"}\n__DRIVERR_RECORD__ 999\n"
    let records = ClaudeRecordFiles.contents(of: output, forPIDs: [11])
    #expect(records.keys.sorted() == [11])
    // The unasked boundary stays inside 11's text, which then does not parse as a record.
    #expect(ClaudeSessionRecord.parse(records[11] ?? Data()) == nil)
  }

  @Test("text before the first boundary belongs to no pid")
  func preamble() {
    let output = "banner from a login profile\n\n__DRIVERR_RECORD__ 5\n{\"sessionId\":\"x\"}\n"
    let records = ClaudeRecordFiles.contents(of: output, forPIDs: [5])
    #expect(ClaudeSessionRecord.parse(records[5] ?? Data())?.sessionID == "x")
  }
}
