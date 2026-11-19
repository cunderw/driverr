import DriverrCore
import Foundation
import Testing

@testable import DriverrTmux

/// A `list-panes` line, built from the format's own field names, so reordering the format
/// cannot make a fixture wrong without the test saying so.
private func line(_ overrides: [String: String] = [:]) -> String {
  let defaults: [String: String] = [
    "pane_id": "%0", "window_id": "@0", "session_id": "$0", "session_name": "work",
    "session_attached": "0", "session_activity": "100", "window_index": "0",
    "window_name": "zsh", "automatic-rename": "1", "window_active": "1", "pane_active": "1",
    "pane_tty": "/dev/ttys036", "pane_width": "80", "pane_height": "24",
    "pane_title": "box.local", "host": "box.local", "host_short": "box",
    "pane_current_command": "zsh", "pane_current_path": "/home/dev",
  ]
  return TmuxPaneFormat.fields
    .map { overrides[$0] ?? defaults[$0] ?? "" }
    .joined(separator: TmuxPaneFormat.delimiter)
}

private func tree(_ lines: [String], agents: [String: Agent] = [:]) -> SessionTree {
  TmuxSnapshotMapper.tree(
    from: TmuxPaneFormat.rows(from: lines.joined(separator: "\n")), agents: agents)
}

@Suite("tmux list-panes format")
struct TmuxPaneFormatTests {
  @Test("the format asks for every field, in order, joined by the separator")
  func format() {
    let format = TmuxPaneFormat.format
    #expect(format.hasPrefix("#{pane_id}\u{1F}#{window_id}\u{1F}#{session_id}"))
    #expect(format.hasSuffix("#{pane_current_path}"))
    #expect(format.components(separatedBy: "\u{1F}").count == TmuxPaneFormat.fields.count)
  }

  @Test("a line reads into its fields")
  func parses() throws {
    let rows = TmuxPaneFormat.rows(
      from: line([
        "pane_id": "%7", "window_id": "@3", "session_id": "$2", "session_name": "api",
        "window_index": "4", "window_name": "tests", "automatic-rename": "0",
        "pane_width": "120", "pane_height": "33", "pane_current_path": "/srv/a b",
      ]))
    let row = try #require(rows.first)
    #expect(rows.count == 1)
    #expect(row.paneID == "%7")
    #expect(row.windowID == "@3")
    #expect(row.sessionID == "$2")
    #expect(row.sessionName == "api")
    #expect(row.windowIndex == 4)
    #expect(row.windowName == "tests")
    #expect(!row.windowAutoNamed)
    #expect(row.width == 120)
    #expect(row.height == 33)
    #expect(row.path == "/srv/a b")
  }

  @Test("a path that holds the separator is still one field, because the path is last")
  func separatorInPath() throws {
    let row = try #require(
      TmuxPaneFormat.rows(from: line(["pane_current_path": "/a\u{1F}b"])).first)
    #expect(row.path == "/a\u{1F}b")
  }

  @Test("a malformed line is skipped and the lines around it are kept")
  func malformed() {
    let output = [
      line(["pane_id": "%1"]),
      "",
      "no separators at all",
      "%2\u{1F}@2\u{1F}$2",
      line(["pane_id": "2"]),
      line(["window_id": "w1"]),
      line(["session_id": ""]),
      line(["pane_id": "%x"]),
      line(["pane_id": "%3"]) + "\u{1F}",
      line(["pane_id": "%4"]),
    ].joined(separator: "\n")
    // `%3`'s extra separator lands in the path, which is last, so that line is kept.
    #expect(TmuxPaneFormat.rows(from: output).map(\.paneID) == ["%1", "%3", "%4"])
  }

  @Test("numbers that do not parse fall back and never fail the line")
  func lenientNumbers() throws {
    let row = try #require(
      TmuxPaneFormat.rows(
        from: line([
          "session_attached": "x", "session_activity": "", "window_index": "?", "pane_width": "",
        ])
      ).first)
    #expect(row.sessionAttached == 0)
    #expect(row.sessionActivity == 0)
    #expect(row.windowIndex == 0)
    #expect(row.width == nil)
  }

  @Test("tmux's own error text is not a row")
  func errorText() {
    #expect(TmuxPaneFormat.rows(from: "no server running on /tmp/tmux-1000/default\n").isEmpty)
    #expect(TmuxPaneFormat.rows(from: "").isEmpty)
  }
}

@Suite("TmuxSnapshotMapper")
struct TmuxSnapshotMapperTests {
  @Test("sessions, windows and panes become workspaces, tabs and panes, in tmux's order")
  func shape() throws {
    let result = tree([
      line(["pane_id": "%0", "window_id": "@0", "session_id": "$0", "session_name": "work"]),
      line(["pane_id": "%1", "window_id": "@0", "session_id": "$0", "session_name": "work"]),
      line([
        "pane_id": "%2", "window_id": "@1", "session_id": "$0", "session_name": "work",
        "window_index": "1", "window_name": "logs",
      ]),
      line(["pane_id": "%3", "window_id": "@2", "session_id": "$1", "session_name": "scratch"]),
    ])

    #expect(result.workspaces.map(\.id) == ["tmux:$0", "tmux:$1"])
    #expect(result.workspaces.map(\.label) == ["work", "scratch"])
    #expect(result.workspaces.map(\.number) == [1, 2])
    #expect(result.workspaces[0].tabs.map(\.id) == ["tmux:@0", "tmux:@1"])
    #expect(result.workspaces[0].tabs.map(\.label) == ["zsh", "logs"])
    #expect(result.workspaces[0].tabs.map(\.number) == [0, 1])
    #expect(result.workspaces[0].tabs[0].panes.map(\.id) == ["tmux:%0", "tmux:%1"])
    #expect(result.allPanes.map(\.id) == ["tmux:%0", "tmux:%1", "tmux:%2", "tmux:%3"])

    let pane = try #require(result.pane(id: "tmux:%2"))
    #expect(pane.tabID == "tmux:@1")
    #expect(pane.workspaceID == "tmux:$0")
    #expect(result.workspaces.allSatisfy { $0.machineCoreID == nil })
    #expect(result.coreID == nil)
  }

  @Test("an empty list is an empty tree")
  func empty() {
    #expect(tree([]) == .empty)
  }

  @Test("directory, height and agent-free shells come across")
  func paneFields() throws {
    let result = tree([line(["pane_current_path": "/home/dev/app", "pane_height": "40"])])
    let pane = try #require(result.allPanes.first)
    #expect(pane.directory == "/home/dev/app")
    #expect(pane.viewportRows == 40)
    #expect(pane.agent == nil)
    // The pane's own id, which the live terminal opens. It is reused after a restart, so the
    // directory stays the witness.
    #expect(pane.terminalID == pane.id)
    #expect(pane.sessionWitness == "/home/dev/app")
    #expect(result.agentStatusCounts.shells == 1)
  }

  @Test("an empty path is no directory")
  func emptyPath() throws {
    let pane = try #require(tree([line(["pane_current_path": ""])]).allPanes.first)
    #expect(pane.directory == nil)
  }

  @Test("only the attached session with the latest activity has focus")
  func focus() {
    let result = tree([
      line([
        "pane_id": "%0", "session_id": "$0", "window_id": "@0", "session_attached": "1",
        "session_activity": "50",
      ]),
      line([
        "pane_id": "%1", "session_id": "$1", "window_id": "@1", "session_attached": "1",
        "session_activity": "90",
      ]),
      line([
        "pane_id": "%2", "session_id": "$1", "window_id": "@1", "session_attached": "1",
        "session_activity": "90", "pane_active": "0",
      ]),
      line([
        "pane_id": "%3", "session_id": "$2", "window_id": "@2", "session_attached": "0",
        "session_activity": "999",
      ]),
    ])
    #expect(result.focusedPaneID == "tmux:%1")
    #expect(result.workspaces.map(\.isFocused) == [false, true, false])
    #expect(result.allPanes.filter(\.isFocused).map(\.id) == ["tmux:%1"])
    #expect(result.defaultExpandedWorkspaceIDs == ["tmux:$1"])
  }

  @Test("a host nobody is attached to has no focus, and still opens its first session")
  func nobodyAttached() {
    let result = tree([line(["session_attached": "0"])])
    #expect(result.focusedPaneID == nil)
    #expect(result.workspaces.allSatisfy { !$0.isFocused })
    #expect(result.defaultExpandedWorkspaceIDs == ["tmux:$0"])
  }

  @Test("the active pane of an inactive window is not focused")
  func inactiveWindow() {
    let result = tree([
      line([
        "pane_id": "%0", "window_id": "@0", "session_attached": "1", "window_active": "0",
        "pane_active": "1",
      ]),
      line([
        "pane_id": "%1", "window_id": "@1", "session_attached": "1", "window_active": "1",
        "pane_active": "1",
      ]),
    ])
    #expect(result.focusedPaneID == "tmux:%1")
    #expect(result.pane(id: "tmux:%0")?.isFocused == false)
  }

  @Test("a window tmux names is auto-named, so a lone one earns no header")
  func autoNamed() {
    let lone = tree([line(["automatic-rename": "1"])])
    #expect(lone.workspaces[0].tabs[0].isAutoNamed)
    #expect(lone.workspaces[0].showsTabHeaders == false)

    let named = tree([line(["automatic-rename": "0", "window_name": "build"])])
    #expect(!named.workspaces[0].tabs[0].isAutoNamed)
    #expect(named.workspaces[0].showsTabHeaders)
    #expect(named.workspaces[0].tabHeaderStyle == .inline)
  }

  @Test("a window with no name is called Tab and its index")
  func unnamedWindow() {
    let result = tree([line(["window_name": "", "window_index": "3"])])
    #expect(result.workspaces[0].tabs[0].label == "Tab 3")
  }

  @Test("an agent is attached to its pane, and the roll-up takes the most urgent")
  func agents() {
    let blocked = Agent(name: "Claude", kind: "claude", status: .blocked)
    let working = Agent(name: "Claude", kind: "claude", status: .working)
    let result = tree(
      [
        line(["pane_id": "%0", "window_id": "@0"]),
        line(["pane_id": "%1", "window_id": "@0"]),
        line(["pane_id": "%2", "window_id": "@1"]),
        line(["pane_id": "%3", "window_id": "@2", "session_id": "$1"]),
      ],
      agents: ["%1": working, "%2": blocked]
    )
    #expect(result.pane(id: "tmux:%1")?.agent == working)
    #expect(result.workspaces[0].tabs[0].status == .working)
    #expect(result.workspaces[0].tabs[1].status == .blocked)
    #expect(result.workspaces[0].status == .blocked)
    #expect(result.workspaces[1].status == nil, "a session of shells wears no badge")
    #expect(result.blockedPanes.map(\.id) == ["tmux:%2"])
  }

  @Test("the title is the program's, then the agent's name, then the command, then a number")
  func titles() throws {
    func title(_ overrides: [String: String], agent: Agent? = nil) throws -> String {
      let result = tree([line(overrides)], agents: agent.map { ["%0": $0] } ?? [:])
      return try #require(result.allPanes.first).title
    }
    let claude = Agent(name: "Claude", kind: "claude", status: .idle)
    let version = ["pane_title": "box.local", "pane_current_command": "2.1.325"]

    #expect(try title(["pane_title": "✳ Claude Code"]) == "Claude Code")
    #expect(try title(["pane_title": "~/driverr"]) == "~/driverr")
    #expect(try title(["pane_title": "#3 build"]) == "#3 build")
    // tmux's default title is the host's name, which says nothing.
    #expect(try title(["pane_title": "box.local", "pane_current_command": "vim"]) == "vim")
    #expect(try title(["pane_title": "box", "pane_current_command": "vim"]) == "vim")
    #expect(try title(["pane_title": "", "pane_current_command": "tail"]) == "tail")
    // Claude Code's process is named by its version.
    #expect(try title(version, agent: claude) == "Claude")
    #expect(try title(version) == "Pane 1")
    // A title that is only a spinner strips to nothing and passes to the next candidate.
    #expect(try title(["pane_title": "✳", "pane_current_command": "node"]) == "node")
    #expect(try title(["pane_title": "", "pane_current_command": ""]) == "Pane 1")
  }

  @Test("the last resort counts panes within a window, from one")
  func paneNumbers() {
    let result = tree([
      line(["pane_id": "%0", "pane_title": "", "pane_current_command": "2.1.1"]),
      line(["pane_id": "%1", "pane_title": "", "pane_current_command": "3.7c"]),
    ])
    #expect(result.allPanes.map(\.title) == ["Pane 1", "Pane 2"])
  }

  @Test("symbol stripping leaves paths and numbered titles alone")
  func stripping() {
    #expect(TmuxSnapshotMapper.strippingLeadingSymbolRun("✳ Claude Code") == "Claude Code")
    #expect(TmuxSnapshotMapper.strippingLeadingSymbolRun("◐ driverr") == "driverr")
    #expect(TmuxSnapshotMapper.strippingLeadingSymbolRun("~/driverr") == "~/driverr")
    #expect(TmuxSnapshotMapper.strippingLeadingSymbolRun("plain") == "plain")
    #expect(TmuxSnapshotMapper.strippingLeadingSymbolRun("✳") == "")
  }
}
