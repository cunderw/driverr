import Foundation
import Testing

@testable import DriverrTranscript

/// `TranscriptParser.codexPage(from:)` against `CodexFixture`.
struct CodexParserTests {
  @Test("a UserMessage item becomes a human turn")
  func userMessageBecomesHuman() {
    let page = TranscriptParser.codexPage(from: CodexFixture.userMessage("do the thing", id: "u1"))
    #expect(page.turns.map(\.id) == ["u1"])
    #expect(page.turns.first?.speech == .human("do the thing"))
    #expect(page.records == 1)
    #expect(page.unreadableRecords == 0)
  }

  @Test("an AgentMessage item becomes an assistant turn")
  func agentMessageBecomesAssistant() {
    let page = TranscriptParser.codexPage(from: CodexFixture.agentMessage("done", id: "a1"))
    #expect(page.turns.map(\.id) == ["a1"])
    #expect(page.turns.first?.speech == .assistant("done"))
  }

  @Test("a skill block beside a UserMessage's text contributes nothing of its own")
  func skillBlockIsNotItsOwnTurn() {
    let page = TranscriptParser.codexPage(
      from: CodexFixture.userMessageWithSkill("$example", skill: "example", id: "us1"))
    #expect(page.turns.map(\.speech) == [.human("$example")])
  }

  @Test("a custom_tool_call becomes a tool call with an unknown outcome and a shell-line target")
  func customToolCallBecomesToolCall() {
    let page = TranscriptParser.codexPage(
      from: CodexFixture.customToolCall(input: "echo hello\nmore lines", callID: "call_1"))
    let calls = page.turns.compactMap(\.toolRun).flatMap(\.calls)
    #expect(calls.map(\.name) == ["exec"])
    #expect(calls.first?.target == "echo hello")
    #expect(calls.first?.outcome == .unknown)
  }

  @Test("a function_call becomes a tool call named for the tool, targeted off its arguments")
  func functionCallBecomesToolCall() {
    let page = TranscriptParser.codexPage(
      from: CodexFixture.functionCall(
        name: "spawn_agent", arguments: ["task_name": "task_group_1", "agent_type": "worker"]))
    let calls = page.turns.compactMap(\.toolRun).flatMap(\.calls)
    #expect(calls.map(\.name) == ["spawn_agent"])
    #expect(calls.first?.target == "task_group_1")
    #expect(calls.first?.outcome == .unknown)
  }

  /// `send_message`'s `message` is ciphertext on real calls, so `target` must win.
  @Test("send_message's target wins over its encrypted message field")
  func sendMessageTargetWinsOverCiphertext() {
    let page = TranscriptParser.codexPage(
      from: CodexFixture.functionCall(
        name: "send_message",
        arguments: ["target": "teammate", "message": "gAAAAABq-ciphertext-not-shown"]))
    let calls = page.turns.compactMap(\.toolRun).flatMap(\.calls)
    #expect(calls.map(\.name) == ["send_message"])
    #expect(calls.first?.target == "teammate")
  }

  /// `spawn_agent` has no `target`, so it keeps its `task_name` target.
  @Test("spawn_agent is unaffected by target's new priority")
  func spawnAgentStillTargetsTaskName() {
    let page = TranscriptParser.codexPage(
      from: CodexFixture.functionCall(
        name: "spawn_agent", arguments: ["task_name": "task_group_1", "agent_type": "worker"]))
    #expect(page.turns.compactMap(\.toolRun).flatMap(\.calls).first?.target == "task_group_1")
  }

  @Test("consecutive tool calls collapse into one run, closed by the next thing said")
  func consecutiveCallsCollapseIntoOneRun() {
    let page = TranscriptParser.codexPage(
      from: [
        CodexFixture.customToolCall(input: "one", callID: "call_1"),
        CodexFixture.functionCall(name: "spawn_agent", arguments: ["task_name": "t"]),
        CodexFixture.agentMessage("done"),
      ].joined(separator: "\n")
    )
    #expect(page.turns.count == 2)
    #expect(page.turns.first?.toolRun?.calls.map(\.name) == ["exec", "spawn_agent"])
    #expect(page.turns.last?.speech == .assistant("done"))
  }

  @Test("a call_id never resolves against a CommandExecution item's id — outcomes stay unknown")
  func callIDNeverJoinsCommandExecutionID() {
    // `call_…` and `exec-…` never match (see `CodexRecord`), and the real selector drops
    // `commandExecution` items before the parser sees them.
    let page = TranscriptParser.codexPage(
      from: [
        CodexFixture.customToolCall(input: "echo hi", callID: "call_1"),
        CodexFixture.commandExecution(["echo", "hi"], id: "exec-1"),
      ].joined(separator: "\n")
    )
    let calls = page.turns.compactMap(\.toolRun).flatMap(\.calls)
    #expect(calls.count == 1, "the CommandExecution item is not a kind the selector keeps")
    #expect(calls.first?.outcome == .unknown)
  }

  @Test("record kinds the selector drops are simply not turns, and each still counts as a record")
  func droppedKindsAreNotTurns() {
    for line in [
      CodexFixture.reasoning(), CodexFixture.commandExecution(["ls"]),
      CodexFixture.fileChange(path: "a.swift"), CodexFixture.mcpToolCall(tool: "search"),
      CodexFixture.subAgentActivity("spawned"), CodexFixture.hookPrompt(),
      CodexFixture.bookkeeping("token_usage_record"), CodexFixture.bookkeeping("turn_context"),
      CodexFixture.sessionMeta(),
    ] {
      let page = TranscriptParser.codexPage(from: line)
      #expect(page.turns.isEmpty, "\(line) produced a turn")
      #expect(page.records == 1)
    }
  }

  @Test("the whole fixture session parses to the turns and calls it was built with")
  func wholeSessionParses() {
    let page = TranscriptParser.codexPage(from: CodexFixture.session())
    #expect(page.unreadableRecords == 0)
    // 2 human, 2 assistant, 2 tool-call rows; see `CodexFixture.session()`.
    let humanCount = page.turns.filter(\.isHuman).count
    let assistantCount = page.turns.filter(\.isAssistant).count
    let toolRunCount = page.turns.compactMap(\.toolRun).count
    #expect(humanCount == 2)
    #expect(assistantCount == 2)
    #expect(toolRunCount == 1, "the custom_tool_call and function_call are adjacent and collapse into one run")
    #expect(page.turns.compactMap(\.toolRun).flatMap(\.calls).map(\.name) == ["exec", "spawn_agent"])
  }

  @Test("a line that is not JSON at all is counted unreadable rather than dropped silently")
  func unreadableLineIsCounted() {
    let page = TranscriptParser.codexPage(from: "not json\n" + CodexFixture.userMessage("hi"))
    #expect(page.unreadableRecords == 1)
    #expect(page.records == 1)
    #expect(page.turns.count == 1)
  }

  /// A positional id churns whenever the byte bound moves the run to another index. The
  /// opening call's item id is stable, shown by parsing the run alone and behind an extra
  /// turn.
  @Test("a tool run's id is the opening call's own item id, not its position in the page")
  func toolRunIDIsTheOpeningCallsItemIDNotItsPosition() {
    let alone = TranscriptParser.codexPage(
      from: CodexFixture.customToolCall(input: "echo hi", callID: "call_1", id: "ctc-fixed"))
    let behindOtherContent = TranscriptParser.codexPage(
      from: [
        CodexFixture.userMessage("earlier", id: "u0"),
        CodexFixture.customToolCall(input: "echo hi", callID: "call_1", id: "ctc-fixed"),
      ].joined(separator: "\n")
    )
    #expect(alone.turns.map(\.id) == ["ctc-fixed"])
    #expect(behindOtherContent.turns.map(\.id) == ["u0", "ctc-fixed"])
  }

  @Test("a function_call run also takes its id from the opening call's own item id")
  func functionCallRunIDIsTheOpeningCallsItemID() {
    let page = TranscriptParser.codexPage(
      from: CodexFixture.functionCall(
        name: "spawn_agent", arguments: ["task_name": "task_group_1"], id: "fc-fixed"))
    #expect(page.turns.map(\.id) == ["fc-fixed"])
  }

  // MARK: - Outcomes

  /// The joinable case; `customToolCallBecomesToolCall` pins the unjoinable one as `.unknown`.
  @Test("an exec_command call joined to a completed CommandExecution succeeds")
  func execCommandJoinsToACompletedOutcome() {
    let page = TranscriptParser.codexPage(
      from: [
        CodexFixture.execCommandToolCall(command: "git status", callID: "call_1"),
        CodexFixture.execOutcomesScanned,
        CodexFixture.execOutcomeLine(command: "git status", status: "completed"),
      ].joined(separator: "\n")
    )
    let calls = page.turns.compactMap(\.toolRun).flatMap(\.calls)
    #expect(calls.map(\.name) == ["exec"])
    #expect(calls.first?.outcome == .succeeded)
  }

  @Test("an exec_command call joined to a failed CommandExecution fails")
  func execCommandJoinsToAFailedOutcome() {
    let page = TranscriptParser.codexPage(
      from: [
        CodexFixture.execCommandToolCall(command: "false", callID: "call_1"),
        CodexFixture.execOutcomesScanned,
        CodexFixture.execOutcomeLine(command: "false", status: "failed", exitCode: "1"),
      ].joined(separator: "\n")
    )
    let calls = page.turns.compactMap(\.toolRun).flatMap(\.calls)
    #expect(calls.first?.outcome == .failed)
  }

  /// The quoted-key spelling, `tools.exec_command({"cmd":"…"})`, is as common as the bare one,
  /// and a join built for one silently misses the other. Uses `execCommandToolCallQuoted`.
  @Test("an exec_command call written with a quoted cmd key still joins")
  func execCommandQuotedKeyStillJoins() {
    let page = TranscriptParser.codexPage(
      from: [
        CodexFixture.execCommandToolCallQuoted(command: "git status", callID: "call_1"),
        CodexFixture.execOutcomesScanned,
        CodexFixture.execOutcomeLine(command: "git status", status: "completed"),
      ].joined(separator: "\n")
    )
    #expect(page.turns.compactMap(\.toolRun).flatMap(\.calls).first?.outcome == .succeeded)
  }

  /// The pending check must not depend on spelling.
  @Test("a trailing quoted-key exec_command call with no completion is pending")
  func trailingQuotedKeyExecCommandIsPending() {
    let page = TranscriptParser.codexPage(
      from: [
        CodexFixture.execCommandToolCallQuoted(command: "sleep 30", callID: "call_1"),
        CodexFixture.execOutcomesScanned,
      ].joined(separator: "\n")
    )
    #expect(page.turns.compactMap(\.toolRun).flatMap(\.calls).first?.outcome == .pending)
  }

  /// Returning at the first failed sub-call would leave later completions in `CodexOutcomes`'
  /// FIFO queue, for a later call with the same command to steal. Here the first batch's
  /// middle sub-call fails, and the second call's `git status` must not take one of its
  /// completions.
  @Test("a failed middle sub-call still consumes every sub-call, leaving none for a later call")
  func failedMiddleSubCallStillConsumesEverySubCall() {
    let page = TranscriptParser.codexPage(
      from: [
        CodexFixture.execCommandToolCallBatch(
          commands: ["git status", "false", "git status"], callID: "call_1", id: "ctc1"
        ),
        CodexFixture.execCommandToolCall(command: "git status", callID: "call_2", id: "ctc2"),
        CodexFixture.execOutcomesScanned,
        CodexFixture.execOutcomeLine(command: "git status", status: "completed", id: "exec-1"),
        CodexFixture.execOutcomeLine(command: "false", status: "failed", exitCode: "1", id: "exec-2"),
        CodexFixture.execOutcomeLine(command: "git status", status: "completed", id: "exec-3"),
        CodexFixture.execOutcomeLine(command: "git status", status: "failed", exitCode: "1", id: "exec-4"),
      ].joined(separator: "\n")
    )
    let calls = page.turns.compactMap(\.toolRun).flatMap(\.calls)
    #expect(calls.count == 2)
    // The batch consumed exec-1 to exec-3 and reports failed, worst case wins.
    #expect(calls[0].outcome == .failed)
    // The second call claims exec-4, issued after it, not a leftover from the first batch.
    #expect(calls[1].outcome == .failed)
  }

  /// Many real commands embed a quote, which is why the extractor is a scanner rather than a
  /// `[^"]*` capture. Round-trips the escaping end to end.
  @Test("a command containing an embedded quote still joins")
  func commandWithEmbeddedQuoteStillJoins() {
    let command = #"python3 -c "print(1)""#
    let page = TranscriptParser.codexPage(
      from: [
        CodexFixture.execCommandToolCall(command: command, callID: "call_1"),
        CodexFixture.execOutcomesScanned,
        CodexFixture.execOutcomeLine(command: command, status: "completed"),
      ].joined(separator: "\n")
    )
    #expect(page.turns.compactMap(\.toolRun).flatMap(\.calls).first?.outcome == .succeeded)
  }

  /// Worst case wins: a batch with one failed command failed.
  @Test("a Promise.all batch with one failed sub-command reports the call as failed")
  func batchWithOneFailureReportsFailed() {
    let page = TranscriptParser.codexPage(
      from: [
        CodexFixture.execCommandToolCallBatch(commands: ["echo one", "false"], callID: "call_1"),
        CodexFixture.execOutcomesScanned,
        CodexFixture.execOutcomeLine(command: "echo one", status: "completed", id: "exec-1"),
        CodexFixture.execOutcomeLine(command: "false", status: "failed", exitCode: "1", id: "exec-2"),
      ].joined(separator: "\n")
    )
    #expect(page.turns.compactMap(\.toolRun).flatMap(\.calls).first?.outcome == .failed)
  }

  /// Identical commands, ordinary for `git status`, join in issue order.
  @Test("two calls with the identical command join in the order they were issued")
  func identicalCommandsJoinInOrder() {
    let page = TranscriptParser.codexPage(
      from: [
        CodexFixture.execCommandToolCall(command: "git status", callID: "call_1", id: "ctc1"),
        CodexFixture.agentMessage("first done", id: "a1"),
        CodexFixture.execCommandToolCall(command: "git status", callID: "call_2", id: "ctc2"),
        CodexFixture.execOutcomesScanned,
        CodexFixture.execOutcomeLine(command: "git status", status: "completed", id: "exec-1"),
        CodexFixture.execOutcomeLine(command: "git status", status: "failed", exitCode: "1", id: "exec-2"),
      ].joined(separator: "\n")
    )
    let calls = page.turns.compactMap(\.toolRun).flatMap(\.calls)
    #expect(calls.count == 2)
    #expect(calls[0].outcome == .succeeded)
    #expect(calls[1].outcome == .failed)
  }

  /// Only an `exec_command`-shaped last call can be `.pending`; a bare-shell call never
  /// produces a `CommandExecution`. See `ToolCall.Outcome.pending`.
  @Test("a trailing exec_command call with no completion in the page is pending")
  func trailingExecCommandWithNoCompletionIsPending() {
    let page = TranscriptParser.codexPage(
      from: [
        CodexFixture.execCommandToolCall(command: "sleep 30", callID: "call_1"),
        CodexFixture.execOutcomesScanned,
      ].joined(separator: "\n")
    )
    #expect(page.turns.compactMap(\.toolRun).flatMap(\.calls).first?.outcome == .pending)
  }

  @Test("a trailing bare-shell call never turns pending, whatever the page scanned")
  func trailingBareShellCallStaysUnknownNeverPending() {
    let page = TranscriptParser.codexPage(
      from: [
        CodexFixture.customToolCall(input: "*** Begin Patch\n*** Update File: a.md\n", callID: "call_1"),
        CodexFixture.execOutcomesScanned,
      ].joined(separator: "\n")
    )
    #expect(page.turns.compactMap(\.toolRun).flatMap(\.calls).first?.outcome == .unknown)
  }

  @Test("a trailing exec_command call is not pending when nothing scanned outcomes at all")
  func trailingExecCommandStaysUnknownWhenNothingScanned() {
    let page = TranscriptParser.codexPage(
      from: CodexFixture.execCommandToolCall(command: "sleep 30", callID: "call_1")
    )
    #expect(page.turns.compactMap(\.toolRun).flatMap(\.calls).first?.outcome == .unknown)
  }

  /// Not the run's last call, so unknown rather than pending.
  @Test("an unanswered exec_command call ahead of another stays unknown, not pending")
  func unansweredExecCommandAheadOfAnotherStaysUnknown() {
    let page = TranscriptParser.codexPage(
      from: [
        CodexFixture.execCommandToolCallBatch(commands: ["long running"], callID: "call_1", id: "ctc1"),
        CodexFixture.execCommandToolCall(command: "git status", callID: "call_2", id: "ctc2"),
        CodexFixture.execOutcomesScanned,
        CodexFixture.execOutcomeLine(command: "git status", status: "completed"),
      ].joined(separator: "\n")
    )
    let calls = page.turns.compactMap(\.toolRun).flatMap(\.calls)
    #expect(calls.count == 2)
    #expect(calls[0].outcome == .unknown)
    #expect(calls[1].outcome == .succeeded)
  }

  /// The same exception `results(in:)` makes for Claude.
  @Test("outcome lines are not counted as records")
  func outcomeLinesAreNotCountedAsRecords() {
    let page = TranscriptParser.codexPage(
      from: [
        CodexFixture.execCommandToolCall(command: "git status", callID: "call_1"),
        CodexFixture.execOutcomesScanned,
        CodexFixture.execOutcomeLine(command: "git status", status: "completed"),
      ].joined(separator: "\n")
    )
    #expect(page.records == 1)
    #expect(page.unreadableRecords == 0)
  }

  /// The terminal groups a chat by the record's `timestamp`; see `CodexRecord.timestamp`.
  @Test("every kind of turn carries the record's own timestamp")
  func turnsCarryTheRecordsTimestamp() throws {
    let expected = try #require(TranscriptParser.timestamp(CodexFixture.timestamp))
    let human = TranscriptParser.codexPage(from: CodexFixture.userMessage("hi"))
    let assistant = TranscriptParser.codexPage(from: CodexFixture.agentMessage("hi"))
    let tools = TranscriptParser.codexPage(
      from: CodexFixture.customToolCall(input: "echo hi", callID: "call_1"))
    #expect(human.turns.first?.at == expected)
    #expect(assistant.turns.first?.at == expected)
    #expect(tools.turns.first?.at == expected)
  }
}
