import DriverrCore
import Foundation
import Testing

@testable import DriverrTranscript

/// The one line that tells two sessions apart to a person. The picker keys on it because
/// uuids and close timestamps do not. It uses the chat parse's typed fields with one
/// difference, recorded on `TranscriptParser.brief(from:)`: a session opened with a slash
/// command was briefed by that command.
struct TranscriptBriefTests {
  private func brief(_ lines: [String]) -> String? {
    TranscriptParser.brief(from: lines.joined(separator: "\n"))
  }

  @Test("the first thing a person typed is the brief")
  func prose() {
    #expect(
      brief([
        Fixture.bookkeeping(),
        Fixture.humanWithOrigin("review the diff on the focus branch"),
        Fixture.assistant("on it"),
        Fixture.humanWithOrigin("and the tests", uuid: "h2"),
      ]) == "review the diff on the focus branch")
  }

  @Test("only the first line of a long opening message")
  func firstLineOnly() {
    #expect(
      brief([Fixture.humanWithOrigin("start on the pane-focus bug\n\nit only happens on iPad")])
        == "start on the pane-focus bug")
  }

  /// A session opened with `/doc-check` can reach the person's next prose hundreds of KB
  /// later, and the command is the better brief anyway.
  @Test("a session opened with a slash command is briefed by that command")
  func slashCommand() {
    #expect(
      brief([
        Fixture.clientEnvelope(
          "<command-message>doc-check</command-message>\n<command-name>/doc-check</command-name>")
      ]) == "/doc-check")
  }

  @Test("a slash command's arguments are part of the brief")
  func slashCommandArguments() {
    #expect(
      brief([
        Fixture.clientEnvelope(
          "<command-name>/code-review</command-name><command-args>high --fix</command-args>")
      ]) == "/code-review high --fix")
  }

  /// Claude Code writes `/clear` at the head of the new file when the previous conversation
  /// was cleared, so it was never typed here, and many files open with it.
  @Test("a file that opens with /clear is briefed by what came after it")
  func clearIsNotABrief() {
    #expect(
      brief([
        Fixture.clientEnvelope("<command-name>/clear</command-name><command-args></command-args>"),
        Fixture.bookkeeping(),
        Fixture.humanWithOrigin("let's pick up the next milestone"),
      ]) == "let's pick up the next milestone")
  }

  @Test("a person's bash-mode line is a brief, and keeps its bang")
  func bashInput() {
    #expect(
      brief([Fixture.clientEnvelope("<bash-input>git rm -r docs/old</bash-input>")])
        == "!git rm -r docs/old")
  }

  @Test("the client's own machinery in a user record is never a brief")
  func machineText() {
    #expect(brief([Fixture.taskNotification()]) == nil)
    #expect(brief([Fixture.clientEnvelope("<local-command-stdout>ok</local-command-stdout>")]) == nil)
    #expect(brief([Fixture.injected("<system-reminder>a reminder</system-reminder>")]) == nil)
    #expect(brief([Fixture.compactSummary("the conversation so far")]) == nil)
    #expect(brief([Fixture.toolResult(id: "toolu_1")]) == nil)
    #expect(brief([Fixture.subagent("a subagent said this")]) == nil)
    #expect(brief([Fixture.assistant("the agent spoke first")]) == nil)
  }

  /// A `<teammate-message>` record opens with a preface sentence, not `<`, so it escaped the
  /// machine-text check and showed the preface line as the brief.
  @Test("a relayed teammate message is not a brief, preface and all")
  func teammateMessageIsNotABrief() {
    let relayed = "Relayed from another session:\n"
      + "<teammate-message teammate_id=\"verifier-9\">\n"
      + "{\"type\":\"idle_notification\"}\n"
      + "</teammate-message>\n\n"
      + "Fixture text after the closing tag."
    #expect(brief([Fixture.clientEnvelope(relayed)]) == nil)
    // The bare form is caught by the `<` check; kept so a refactor cannot reopen the gap.
    #expect(
      brief([
        Fixture.clientEnvelope(
          "<teammate-message teammate_id=\"verifier-9\">hi</teammate-message>")
      ]) == nil)
  }

  /// The list errs toward dropping, as `isClientEnvelope` does, because showing a wrapper as
  /// what somebody typed invents a speaker.
  @Test("a tag this build does not know is not a brief")
  func unknownEnvelope() {
    #expect(brief([Fixture.clientEnvelope("<something-new>hello</something-new>")]) == nil)
  }

  @Test("a session with nothing a person typed has no brief, and that is an answer")
  func noBrief() {
    #expect(brief([Fixture.bookkeeping(), Fixture.assistant("working")]) == nil)
    #expect(brief([]) == nil)
  }

  @Test("a record that is not JSON at all is skipped rather than fatal")
  func unreadableRecord() {
    #expect(brief(["{\"type\":", Fixture.humanWithOrigin("still here")]) == "still here")
  }

  /// One line in a row, and pasted terminal output runs through the chat's scanner.
  @Test("a brief is bounded")
  func bounded() throws {
    let opening = try #require(brief([Fixture.humanWithOrigin(String(repeating: "x", count: 400))]))
    #expect(opening.count == TranscriptParser.briefLimit)
    #expect(opening.hasSuffix("…"))
  }

  @Test("a pasted escape sequence is stripped out of a brief")
  func sanitised() throws {
    #expect(brief([Fixture.humanWithOrigin("\u{1B}[1mbold\u{1B}[0m plan")]) == "bold plan")
  }

  /// A pasted first message starts with `<` and is not a command.
  @Test("a session opened with a paste is briefed by the pasted text")
  func pasted() {
    #expect(
      brief([
        Fixture.humanWithOrigin(
          "\n\n<pasted_content id=\"6e67\">\nfix the pane strip\nit clips\n</pasted_content id=\"6e67\">\n")
      ]) == "fix the pane strip")
  }

  /// The pasted body is not an envelope, so it is not read as a command.
  @Test("a pasted bash-input is briefed as the text that was pasted")
  func pastedBashInput() {
    #expect(
      brief([
        Fixture.humanWithOrigin(
          "\n\n<pasted_content id=\"b\">\n<bash-input>ls</bash-input>\n</pasted_content id=\"b\">\n")
      ]) == "<bash-input>ls</bash-input>")
  }

  @Test("a paste that starts with a tag is still a brief")
  func pastedMarkup() {
    #expect(
      brief([
        Fixture.humanWithOrigin(
          "<pasted_content id=\"h\">\n<div class=\"row\">hello</div>\n</pasted_content id=\"h\">")
      ]) == "<div class=\"row\">hello</div>")
  }
}
