import DriverrCore
import Foundation
import Testing

@testable import DriverrTmux

/// A single backslash, spelled so no source line needs two in a row.
private let backslash = "\u{5C}"

@Suite("TmuxArgument")
struct TmuxArgumentTests {
  @Test("only a trailing semicolon is escaped, because tmux reads only that one")
  func escaping() {
    #expect(TmuxArgument.escaped("plain") == "plain")
    #expect(TmuxArgument.escaped("a;b") == "a;b")
    #expect(TmuxArgument.escaped("a;") == "a" + backslash + ";")
    #expect(TmuxArgument.escaped(";") == backslash + ";")
    #expect(TmuxArgument.escaped("a;;") == "a;" + backslash + ";")
    #expect(TmuxArgument.escaped("") == "")
    // A backslash in front of the semicolon is kept, and tmux gives back one `;` and no more.
    #expect(TmuxArgument.escaped("a" + backslash + ";") == "a" + backslash + backslash + ";")
  }

  @Test("the shell word is the escaped value, quoted")
  func quoted() {
    #expect(TmuxArgument.quoted("hello") == "hello")
    #expect(TmuxArgument.quoted("two words") == "'two words'")
    #expect(TmuxArgument.quoted("it's") == "'it'" + backslash + "''s'")
    #expect(TmuxArgument.quoted("a;") == "'a" + backslash + ";'")
  }
}

@Suite("TmuxArgument.label")
struct TmuxLabelTests {
  @Test("every # is doubled, because tmux expands formats in names and titles")
  func hashes() {
    #expect(TmuxArgument.label("plain") == "plain")
    #expect(TmuxArgument.label("#S") == "'##S'")
    #expect(TmuxArgument.label("a#{pane_id}b") == "'a##{pane_id}b'")
    #expect(TmuxArgument.label("#(id)") == "'##(id)'")
    #expect(TmuxArgument.label("##") == "'####'")
    #expect(TmuxArgument.label("issue #3") == "'issue ##3'")
  }

  @Test("a newline is a space, whichever kind it is")
  func newlines() {
    #expect(TmuxArgument.label("a\nb") == "'a b'")
    #expect(TmuxArgument.label("a\r\nb") == "'a b'")
    #expect(TmuxArgument.label("a\rb") == "'a b'")
  }

  @Test("a tab and every other control character is a space")
  func controls() {
    #expect(TmuxArgument.label("a\tb") == "'a b'")
    #expect(TmuxArgument.label("a\u{1}b\u{1B}c\u{7F}d") == "'a b c d'")
    #expect(TmuxArgument.label("é✓ x") == "'é✓ x'", "printable text is untouched")
  }

  @Test("the semicolon rule still applies after the rest")
  func semicolon() {
    #expect(TmuxArgument.label("#;") == "'##" + backslash + ";'")
  }
}

@Suite("TmuxCommands")
struct TmuxCommandsTests {
  private let tmux = "tmux"
  private let pane = "'%3'"

  @Test("the listing is one list-panes -a with the format quoted")
  func listPanes() {
    let command = TmuxCommands.listPanes(binary: tmux)
    #expect(command.hasPrefix("tmux list-panes -a -F '#{pane_id}"))
    #expect(command.hasSuffix("#{pane_current_path}'"))
    #expect(command.contains(TmuxPaneFormat.delimiter))
  }

  @Test("typed text is literal, after --, and sends no Enter")
  func typed() {
    #expect(
      TmuxCommands.input(binary: tmux, pane: pane, text: "hello world", submit: false)
        == "tmux send-keys -t '%3' -l -- 'hello world'")
  }

  @Test("a submit is send-keys -l then send-keys Enter, in one invocation")
  func submitted() {
    #expect(
      TmuxCommands.input(binary: tmux, pane: pane, text: "yes", submit: true)
        == "tmux send-keys -t '%3' -l -- yes " + backslash + "; send-keys -t '%3' Enter")
  }

  @Test("an empty submit is only Enter, and empty text with no submit is nothing")
  func empty() {
    #expect(
      TmuxCommands.input(binary: tmux, pane: pane, text: "", submit: true)
        == "tmux send-keys -t '%3' Enter")
    #expect(TmuxCommands.input(binary: tmux, pane: pane, text: "", submit: false) == nil)
  }

  @Test("a reply's trailing newlines and spaces are trimmed, and its inside is left")
  func submittable() {
    #expect(TmuxCommands.submittable("yes\n\n") == "yes")
    #expect(TmuxCommands.submittable("a\nb \t\n") == "a\nb")
    #expect(TmuxCommands.submittable(" lead") == " lead")
    #expect(TmuxCommands.submittable("\n \n") == "")
  }

  @Test("each key is its own tmux call, chained so the first refusal stops the rest")
  func keys() {
    #expect(
      TmuxCommands.keys(binary: tmux, pane: pane, keys: [.up, .enter])
        == "tmux send-keys -t '%3' Up && tmux send-keys -t '%3' Enter")
    #expect(TmuxCommands.keys(binary: tmux, pane: pane, keys: []) == nil)
  }

  @Test("every key has a tmux name, and a character is typed, not named")
  func keyNames() {
    #expect(TmuxCommands.key(.enter) == (name: "Enter", isLiteral: false))
    #expect(TmuxCommands.key(.esc) == (name: "Escape", isLiteral: false))
    #expect(TmuxCommands.key(.interrupt) == (name: "C-c", isLiteral: false))
    #expect(TmuxCommands.key(.tab) == (name: "Tab", isLiteral: false))
    #expect(TmuxCommands.key(.yes) == (name: "y", isLiteral: true))
    #expect(TmuxCommands.key(.digit7) == (name: "7", isLiteral: true))
    for key in PaneKey.allCases {
      #expect(!TmuxCommands.key(key).name.isEmpty)
    }
    #expect(
      TmuxCommands.keys(binary: tmux, pane: pane, keys: [.yes])
        == "tmux send-keys -t '%3' -l -- y")
  }

  @Test("a batched read prints a boundary with the pane's id before each capture")
  func batchedRead() {
    #expect(
      TmuxCommands.readPanes(
        binary: tmux, panes: [(id: "tmux:%1", quoted: "'%1'"), (id: "tmux:%2", quoted: "'%2'")])
        == #"printf '\n%s\n' '__DRIVERR_PANE__ tmux:%1'; tmux capture-pane -p -t '%1'; "#
        + #"printf '\n%s\n' '__DRIVERR_PANE__ tmux:%2'; tmux capture-pane -p -t '%2'"#
    )
  }

  @Test("the single-pane read keeps the styling")
  func screenRead() {
    #expect(
      TmuxCommands.readScreen(binary: tmux, pane: pane) == "tmux capture-pane -p -e -t '%3'")
  }

  @Test("a batch splits back into rows by boundary, and every id gets an entry")
  func splitting() {
    let output = """

      __DRIVERR_PANE__ tmux:%1
      first
      second

      __DRIVERR_PANE__ tmux:%2

      __DRIVERR_PANE__ tmux:%3
      a
      b
      c

      """
    let panes = TmuxCommands.panes(from: output, ids: ["tmux:%1", "tmux:%2", "tmux:%3", "tmux:%4"], lines: 2)
    #expect(panes["tmux:%1"] == ["first", "second"])
    #expect(panes["tmux:%2"] == [])
    #expect(panes["tmux:%3"] == ["b", "c"], "the tail, not the head")
    #expect(panes["tmux:%4"] == [], "asked and got nothing differs from never asked")
  }

  @Test("pane text that looks like a boundary for another pane is not one")
  func spoofedBoundary() {
    let output = "\n__DRIVERR_PANE__ tmux:%1\n__DRIVERR_PANE__ tmux:%9\nx\n"
    let panes = TmuxCommands.panes(from: output, ids: ["tmux:%1"], lines: 5)
    #expect(panes["tmux:%1"] == ["__DRIVERR_PANE__ tmux:%9", "x"])
  }

  @Test("each action is one tmux command")
  func actions() {
    #expect(
      TmuxCommands.perform(binary: tmux, action: .split(.right), pane: pane)
        == "tmux split-window -d -h -t '%3' -c '#{pane_current_path}'")
    #expect(
      TmuxCommands.perform(binary: tmux, action: .split(.down), pane: pane)
        == "tmux split-window -d -v -t '%3' -c '#{pane_current_path}'")
    #expect(
      TmuxCommands.perform(binary: tmux, action: .close, pane: pane) == "tmux kill-pane -t '%3'")
    #expect(
      TmuxCommands.perform(binary: tmux, action: .rename("two words"), pane: pane)
        == "tmux select-pane -t '%3' -T 'two words'")
  }

  @Test("a session and a window rename through their own commands, with ids quoted")
  func renames() {
    #expect(
      TmuxCommands.rename(binary: tmux, target: .workspace(id: "tmux:$1"), id: "'$1'", label: "api")
        == "tmux rename-session -t '$1' -- api")
    #expect(
      TmuxCommands.rename(binary: tmux, target: .tab(id: "tmux:@2"), id: "'@2'", label: "a b")
        == "tmux rename-window -t '@2' -- 'a b'")
  }

  @Test("a label that starts with - goes after --, and an expanding one is escaped")
  func awkwardLabels() {
    #expect(
      TmuxCommands.rename(binary: tmux, target: .tab(id: "tmux:@2"), id: "'@2'", label: "-x")
        == "tmux rename-window -t '@2' -- -x")
    #expect(
      TmuxCommands.rename(binary: tmux, target: .workspace(id: "tmux:$1"), id: "'$1'", label: "#S")
        == "tmux rename-session -t '$1' -- '##S'")
    #expect(
      TmuxCommands.perform(binary: tmux, action: .rename("#{pane_id}"), pane: pane)
        == "tmux select-pane -t '%3' -T '##{pane_id}'")
    // The pane title takes its value as the flag's argument, so a leading `-` is safe there.
    #expect(
      TmuxCommands.perform(binary: tmux, action: .rename("-x"), pane: pane)
        == "tmux select-pane -t '%3' -T -x")
  }

  @Test("typed text is not format-escaped, because send-keys -l expands nothing")
  func typedHash() {
    #expect(
      TmuxCommands.input(binary: tmux, pane: pane, text: "#S ##", submit: false)
        == "tmux send-keys -t '%3' -l -- '#S ##'")
  }

  @Test("a new window and a new session print the id of the pane they make")
  func starts() {
    #expect(TmuxCommands.newWindow(binary: tmux) == "tmux new-window -d -P -F '#{pane_id}'")
    #expect(TmuxCommands.newSession(binary: tmux) == "tmux new-session -d -P -F '#{pane_id}'")
  }
}

#if os(macOS)
  /// What a real `/bin/sh` and tmux's own argument rule make of the commands this module
  /// sends, for text that is hostile to each.
  ///
  /// A stub in place of `tmux` prints the arguments the shell gave it. `FakeTmuxHost.commands(in:)`
  /// then reads them as tmux does, and the result must be the commands that were meant, with the
  /// typed text unchanged.
  @Suite("tmux commands through a real shell")
  struct TmuxCommandsShellTests {
    private static let hostile: [String] = [
      "plain", "two words", "it's", #"say "hi""#, "a;b", "ends with;", ";", ";;", "; kill-server",
      "$HOME $(id) `id`", "line one\nline two", "-x --flag -t %9", "back" + backslash + "slash",
      "a" + backslash + ";", backslash, "%s %d #{pane_id}", "héllo ✓", "tab\tseparated",
      "trailing space ", "  leading", "'", "''", "\"", "*", "~", "a && b", "a | b", "a > /tmp/x",
    ]

    /// The arguments the shell passed, and tmux's reading of them.
    private func read(_ command: String) async throws -> [[String]] {
      let result = try await LocalShell.runner(command)
      try #require(result.exitStatus == 0, "the shell refused: \(result.standardError)")
      let arguments = result.standardOutput.split(
        separator: "\0", omittingEmptySubsequences: false
      ).dropLast().map(String.init)
      return FakeTmuxHost.commands(in: arguments)
    }

    @Test("typed text reaches tmux as exactly the text typed, and a submit is two commands")
    func text() async throws {
      let directory = try LocalShell.temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let stub = try LocalShell.argumentPrinter(in: directory)

      for text in Self.hostile {
        for submit in [false, true] {
          let command = try #require(
            TmuxCommands.input(binary: shellQuoted(stub), pane: shellQuoted("%3"), text: text, submit: submit))
          let commands = try await read(command)
          var expected = [["send-keys", "-t", "%3", "-l", "--", text]]
          if submit { expected.append(["send-keys", "-t", "%3", "Enter"]) }
          #expect(commands == expected, "text: \(text.debugDescription), submit: \(submit)")
        }
      }
    }

    @Test("a label reaches tmux as the text tmux must be given to store it")
    func labels() async throws {
      let directory = try LocalShell.temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let stub = try LocalShell.argumentPrinter(in: directory)

      for label in Self.hostile + ["-x", "--flag", "#S", "a#{pane_id}b", "#(id)", "x\ny"] {
        // What tmux is given: control characters as spaces, and every # doubled so tmux's
        // format expansion gives the label back as it was.
        let given = String(
          label.map { ($0.isNewline || $0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }) ? " " : $0 })
          .replacingOccurrences(of: "#", with: "##")

        let rename = TmuxCommands.rename(
          binary: shellQuoted(stub), target: .tab(id: "tmux:@2"), id: shellQuoted("@2"), label: label)
        #expect(
          try await read(rename) == [["rename-window", "-t", "@2", "--", given]],
          "rename: \(label.debugDescription)")

        let pane = TmuxCommands.perform(
          binary: shellQuoted(stub), action: .rename(label), pane: shellQuoted("%3"))
        #expect(
          try await read(pane) == [["select-pane", "-t", "%3", "-T", given]],
          "pane title: \(label.debugDescription)")
      }
    }

    @Test("ids that look like shell syntax arrive as themselves")
    func ids() async throws {
      let directory = try LocalShell.temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let stub = try LocalShell.argumentPrinter(in: directory)

      // `$1` unquoted is the shell's first parameter, and would arrive as nothing.
      let rename = TmuxCommands.rename(
        binary: shellQuoted(stub), target: .workspace(id: "tmux:$1"), id: shellQuoted("$1"), label: "x")
      #expect(try await read(rename) == [["rename-session", "-t", "$1", "--", "x"]])

      let close = TmuxCommands.perform(binary: shellQuoted(stub), action: .close, pane: shellQuoted("%12"))
      #expect(try await read(close) == [["kill-pane", "-t", "%12"]])
    }

    @Test("a binary path with spaces and a quote still runs")
    func awkwardBinary() async throws {
      let parent = try LocalShell.temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: parent) }
      let directory = parent.appendingPathComponent("it's a dir")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let stub = try LocalShell.argumentPrinter(in: directory)

      let control = TmuxControl(binaryPath: stub, run: LocalShell.runner)
      try await control.perform(.close, on: "tmux:%3")
    }

    @Test("a chained key press is several shell commands, each reaching tmux in order")
    func keyChain() async throws {
      let directory = try LocalShell.temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let stub = try LocalShell.argumentPrinter(in: directory)

      let command = try #require(
        TmuxCommands.keys(binary: shellQuoted(stub), pane: shellQuoted("%3"), keys: [.down, .enter, .yes]))
      let result = try await LocalShell.runner(command)
      #expect(result.exitStatus == 0)
      let calls = result.standardOutput.split(separator: "\0").map(String.init)
      #expect(calls == ["send-keys", "-t", "%3", "Down", "send-keys", "-t", "%3", "Enter", "send-keys", "-t", "%3", "-l", "--", "y"])
    }
  }
#endif
