import DriverrCore
import Testing

@testable import DriverrTmux

private let backslash = "\u{5C}"

/// The fake is what the control's other tests stand on, so its two readings of a command line
/// are checked here against what was measured on tmux 3.7c.
@Suite("FakeTmuxHost")
struct FakeTmuxHostTests {
  @Test("an argument that is ; ends a command, as a shell-escaped semicolon does")
  func separator() {
    #expect(
      FakeTmuxHost.commands(in: ["send-keys", "a", ";", "send-keys", "Enter"])
        == [["send-keys", "a"], ["send-keys", "Enter"]])
  }

  @Test("an argument that ends in ; ends a command and keeps its text, which is the trap")
  func trailingSemicolon() {
    #expect(
      FakeTmuxHost.commands(in: ["send-keys", "-l", "foo;"]) == [["send-keys", "-l", "foo"]])
    #expect(
      FakeTmuxHost.commands(in: ["send-keys", "foo;", "Enter"])
        == [["send-keys", "foo"], ["Enter"]])
  }

  @Test("a backslash before the final ; makes it plain text")
  func escaped() {
    #expect(
      FakeTmuxHost.commands(in: ["send-keys", "-l", "foo" + backslash + ";"])
        == [["send-keys", "-l", "foo;"]])
    #expect(
      FakeTmuxHost.commands(in: ["x", backslash + ";"]) == [["x", ";"]])
    // The backslash before the escape is the text's own, and survives as one.
    #expect(
      FakeTmuxHost.commands(in: ["x", "a" + backslash + backslash + ";"])
        == [["x", "a" + backslash + ";"]])
  }

  @Test("a semicolon inside an argument means nothing")
  func inside() {
    #expect(FakeTmuxHost.commands(in: ["x", "a;b", "c"]) == [["x", "a;b", "c"]])
  }

  @Test("it answers tmux -V, and a host with no tmux says command not found")
  func version() async throws {
    let host = FakeTmuxHost(version: "tmux 3.4")
    #expect(try await host.runner("tmux -V").standardOutput == "tmux 3.4\n")

    let none = FakeTmuxHost(version: nil)
    let result = try await none.runner("tmux -V")
    #expect(result.exitStatus == 127)
    #expect(result.standardError.contains("command not found"))
  }

  @Test("&& stops at the first failure and ; goes on")
  func shellOperators() async throws {
    let host = FakeTmuxHost.seeded()
    let stopped = try await host.runner(
      "tmux send-keys -t '%99' Up && tmux send-keys -t '%1' Down")
    #expect(stopped.exitStatus == 1)
    #expect(await host.input["%1"] == nil)

    let went = try await host.runner("tmux send-keys -t '%99' Up; tmux send-keys -t '%1' Down")
    #expect(went.exitStatus == 0)
    #expect(await host.input["%1"] == [.key("Down")])
  }

  @Test("an unquoted $1 is not the pane it looks like, so the fake finds nothing")
  func unquotedID() async throws {
    // Quoting is the control's job. The fake reads `$1` literally, and a pane named `%1` bare is
    // still found, which is `%`'s harmlessness. The shell's `$1` is the one that matters, and
    // the real-shell test covers it.
    let host = FakeTmuxHost.seeded()
    let result = try await host.runner("tmux rename-session -t '$1' renamed")
    #expect(result.exitStatus == 0)
    #expect(await host.sessions[1].name == "renamed")
  }

  @Test("tmux's own words for what it does not know")
  func unknown() async throws {
    let host = FakeTmuxHost.seeded()
    let result = try await host.runner("tmux frobnicate")
    #expect(result.exitStatus == 1)
    #expect(result.standardError.contains("unknown command"))
    #expect(try await host.runner("nosuchtool x").exitStatus == 127)
  }

  @Test("a name in a format that tmux does not know is empty, as in tmux")
  func unknownVariable() async throws {
    let host = FakeTmuxHost.seeded()
    let result = try await host.runner("tmux list-panes -a -F '[#{pane_id}][#{nonsense}]'")
    #expect(result.standardOutput.hasPrefix("[%0][]\n[%1][]\n"))
  }
}
