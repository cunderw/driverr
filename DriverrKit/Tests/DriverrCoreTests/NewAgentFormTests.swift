import Testing

@testable import DriverrCore

@Suite("NewAgentForm")
struct NewAgentFormTests {
  @Test("no folder, or a folder of only white space, starts nothing")
  func noFolder() {
    #expect(NewAgentForm().launch == nil)
    #expect(!NewAgentForm().canStart)
    let blank = NewAgentForm(directory: "  \n")
    #expect(blank.launch == nil)
    #expect(!blank.canStart)
  }

  @Test("a folder is trimmed, and the launch carries the agent and the message")
  func launch() {
    let form = NewAgentForm(kind: .codex, directory: "  ~/dev/app \n", prompt: "fix the build")
    #expect(form.trimmedDirectory == "~/dev/app")
    #expect(form.launch == AgentLaunch(kind: .codex, directory: "~/dev/app", prompt: "fix the build"))
    #expect(form.canStart)
  }

  @Test("an empty message is no message")
  func emptyPrompt() {
    #expect(NewAgentForm(directory: "/srv", prompt: " ").launch?.prompt == nil)
  }

  /// The limit is on the typed line, which holds the agent's name and the quoted message.
  @Test("a message too long to type is flagged with or without a folder, and blocks Start")
  func tooLong() {
    let limit = AgentLaunch.typedLineLimit
    // `claude -- '…'` is 12 bytes around the message.
    let fits = String(repeating: "a", count: limit - 12)
    let over = fits + "a"
    #expect(AgentLaunch(kind: .claude, directory: "/", prompt: fits).typedLine.utf8.count == limit)

    #expect(!NewAgentForm(directory: "/srv", prompt: fits).isPromptTooLong)
    #expect(NewAgentForm(directory: "/srv", prompt: fits).canStart)
    #expect(NewAgentForm(prompt: over).isPromptTooLong)
    #expect(NewAgentForm(directory: "/srv", prompt: over).isPromptTooLong)
    #expect(!NewAgentForm(directory: "/srv", prompt: over).canStart)
  }

  @Test("the agent's name counts: a message that fits Codex can be too long for Claude Code")
  func kindCounts() {
    // `codex` is one byte shorter than `claude`.
    let message = String(repeating: "a", count: AgentLaunch.typedLineLimit - 11)
    #expect(!NewAgentForm(kind: .codex, directory: "/srv", prompt: message).isPromptTooLong)
    #expect(NewAgentForm(kind: .claude, directory: "/srv", prompt: message).isPromptTooLong)
  }

  @Test("quoting counts: each single quote costs four bytes on the line")
  func quotingCounts() {
    let quotes = String(repeating: "'", count: (AgentLaunch.typedLineLimit - 12) / 4 + 1)
    #expect(NewAgentForm(directory: "/srv", prompt: quotes).isPromptTooLong)
  }
}
