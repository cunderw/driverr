import Foundation
import Testing

@testable import DriverrCore

@Suite("AgentLaunch")
struct AgentLaunchTests {
  @Test("with no message the line is the program alone")
  func noPrompt() {
    #expect(AgentLaunch(kind: .claude, directory: "~/app").typedLine == "claude")
    #expect(AgentLaunch(kind: .codex, directory: "~/app").typedLine == "codex")
  }

  @Test("a blank message is no message")
  func blankPrompt() {
    #expect(AgentLaunch(kind: .claude, directory: "/srv", prompt: " \n\t ").prompt == nil)
    #expect(AgentLaunch(kind: .claude, directory: "/srv", prompt: "  hi\n").prompt == "hi")
  }

  @Test("the message is one argument after --, so one that starts with - stays a message")
  func promptAfterDashes() {
    let launch = AgentLaunch(kind: .codex, directory: "/srv", prompt: "-p fix it")
    #expect(launch.typedLine == "codex -- '-p fix it'")
  }

  /// fish reads `\'` and `\\` inside single quotes as escapes, so both go outside the quotes.
  @Test("quotes and backslashes in the message are typed so that every shell reads them back")
  func promptQuoting() {
    let launch = AgentLaunch(kind: .claude, directory: "/srv", prompt: #"it's a "probe" \ test"#)
    #expect(launch.typedLine == #"claude -- 'it'\''s a "probe" '\\' test'"#)
  }

  @Test("a tab or a line break in the message is a space, so the line stays one line")
  func controlCharacters() {
    let launch = AgentLaunch(kind: .claude, directory: "/srv", prompt: "a\tb\r\nc\nd")
    #expect(launch.typedPrompt == "a b c d")
    #expect(launch.typedLine == "claude -- 'a b c d'")
  }

  /// herdr refuses any argument with a `char::is_control` character, C1 included, with
  /// `invalid_agent_argument`, after the workspace exists.
  @Test("a C1 control character or DEL in the message is a space too")
  func c1Control() {
    let launch = AgentLaunch(kind: .claude, directory: "/srv", prompt: "a\u{9B}b\u{7F}c\u{85}d")
    #expect(launch.typedPrompt == "a b c d")
  }

  @Test("a line over 1023 bytes is too long, and the check says so")
  func lengthCap() throws {
    let fixed = "claude -- ''".utf8.count
    let fits = AgentLaunch(
      kind: .claude, directory: "/srv",
      prompt: String(repeating: "x", count: AgentLaunch.typedLineLimit - fixed))
    #expect(fits.typedLine.utf8.count == 1023)
    #expect(!fits.isTooLong)
    try fits.checkLength()

    let over = AgentLaunch(
      kind: .claude, directory: "/srv",
      prompt: String(repeating: "x", count: AgentLaunch.typedLineLimit - fixed + 1))
    #expect(over.isTooLong)
    #expect(throws: AppError.agentPromptTooLong) { try over.checkLength() }
  }

  @Test("the cap counts bytes, not characters")
  func lengthCapInBytes() {
    let launch = AgentLaunch(kind: .claude, directory: "/srv", prompt: String(repeating: "é", count: 600))
    #expect(launch.isTooLong)
  }

  @Test("the folder is resolved with a leading ~ as $HOME, and the joins add the sh -c")
  func resolveCommand() {
    #expect(
      AgentLaunch.resolveCommand(for: "~/my app")
        == #"cd -- "$HOME"/'my app' >/dev/null && printf '\n%s\n' driverr-agent-folder && pwd -P"#
    )
    #expect(AgentLaunch.resolveCommand(for: "/srv").hasPrefix("cd -- /srv >/dev/null"))
  }

  @Test("the path is what follows the marker, whatever an rc file printed first")
  func resolvedPath() throws {
    let result = CommandResult(
      standardOutput: "Welcome!\n\ndriverr-agent-folder\n/srv/my app\n", standardError: "",
      exitStatus: 0)
    #expect(try AgentLaunch.resolvedDirectory(from: result, requested: "~/x") == "/srv/my app")
  }

  @Test("no marker is a folder that could not be opened, named as it was asked for")
  func unresolved() {
    let result = CommandResult(
      standardOutput: "", standardError: "sh: cd: /nope: No such file or directory\n",
      exitStatus: 2)
    #expect(throws: AppError.directoryUnavailable(path: "~/nope")) {
      try AgentLaunch.resolvedDirectory(from: result, requested: "~/nope")
    }
  }

  @Test("the folder's name is its last component, and the root is /")
  func folderName() {
    #expect(AgentLaunch.folderName(of: "/srv/my app") == "my app")
    #expect(AgentLaunch.folderName(of: "/") == "/")
  }

  @Test("the two new errors read as a person needs them, and neither offers a retry")
  func errors() {
    let didNotStart = AppError.agentDidNotStart(paneID: "w2:p1", place: "app", reason: "No claude.")
    #expect(didNotStart.errorDescription == "Opened app, but the agent did not start there. No claude.")
    #expect(!didNotStart.isRetryable)
    #expect(!AppError.agentPromptTooLong.isRetryable)
  }
}
