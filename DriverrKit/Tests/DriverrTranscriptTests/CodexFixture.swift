import Foundation

@testable import DriverrTranscript

/// Codex CLI rollout records, hand-built line by line. No real rollout is committed, for
/// `Fixture.swift`'s reason; every uuid, path and string is synthesised. `LiveTranscriptProbeTests`,
/// opt-in, checks the shape against this machine's own corpus.
enum CodexFixture {
  static func line(_ fields: [String: String]) -> String {
    "{" + fields.map { "\"\($0.key)\":\($0.value)" }.sorted().joined(separator: ",") + "}"
  }

  static func quoted(_ value: String) -> String {
    var out = ""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\\": out += "\\\\"
      case "\"": out += "\\\""
      case "\n": out += "\\n"
      default: out.unicodeScalars.append(scalar)
      }
    }
    return "\"\(out)\""
  }

  static let timestamp = "2026-09-11T16:43:31.997Z"

  // MARK: - Line 1

  /// A rollout's line 1, always `session_meta`. `id` is the filename's uuid. `sessionID`
  /// defaults to the same, as on a `user` thread (see `CodexRollouts`); pass another to model
  /// a `subagent` or `guardian_review` thread.
  static func sessionMeta(
    cwd: String = "/Users/x/repo",
    threadSource: String = "user",
    id: String = "01a00000-1111-7222-8333-444455556666",
    sessionID: String? = nil
  ) -> String {
    line([
      "timestamp": quoted(timestamp),
      "type": quoted("session_meta"),
      "payload": line([
        "session_id": quoted(sessionID ?? id),
        "id": quoted(id),
        "timestamp": quoted(timestamp),
        "cwd": quoted(cwd),
        "originator": quoted("codex-tui"),
        "thread_source": quoted(threadSource),
      ]),
    ])
  }

  // MARK: - `event_msg` / `item_completed`

  private static func itemCompleted(_ item: String) -> String {
    line([
      "timestamp": quoted(timestamp),
      "type": quoted("event_msg"),
      "payload": line(["type": quoted("item_completed"), "item": item]),
    ])
  }

  /// Something a person typed. Real records also carry `text_elements` byte ranges, which
  /// nothing reads.
  static func userMessage(_ text: String, id: String = "u1") -> String {
    itemCompleted(
      line([
        "type": quoted("UserMessage"),
        "id": quoted(id),
        "content": "[" + line(["type": quoted("text"), "text": quoted(text)]) + "]",
      ])
    )
  }

  /// A `UserMessage` with a skill reference beside its words. The skill block adds nothing to
  /// the turn.
  static func userMessageWithSkill(_ text: String, skill: String, id: String = "us1") -> String {
    itemCompleted(
      line([
        "type": quoted("UserMessage"),
        "id": quoted(id),
        "content": "[" + line(["type": quoted("text"), "text": quoted(text)]) + ","
          + line(["type": quoted("skill"), "name": quoted(skill)]) + "]",
      ])
    )
  }

  /// The agent's words. Capitalised `Text`, unlike `UserMessage`'s `text`; see
  /// `CodexContentBlock`.
  static func agentMessage(_ text: String, id: String = "a1") -> String {
    itemCompleted(
      line([
        "type": quoted("AgentMessage"),
        "id": quoted(id),
        "content": "[" + line(["type": quoted("Text"), "text": quoted(text)]) + "]",
        "phase": quoted("commentary"),
      ])
    )
  }

  /// The agent's working-out. The read selector drops its line before the parser sees it.
  static func reasoning(id: String = "rs1") -> String {
    itemCompleted(line(["type": quoted("Reasoning"), "id": quoted(id), "summary_text": "[]"]))
  }

  /// A shell command the TUI ran. Nothing joins it to the `custom_tool_call` that asked for
  /// it (see `CodexRecord`), so it produces no turn.
  static func commandExecution(_ command: [String], id: String = "exec-1") -> String {
    itemCompleted(
      line([
        "type": quoted("CommandExecution"),
        "id": quoted(id),
        "command": "[" + command.map(quoted).joined(separator: ",") + "]",
        "status": quoted("completed"),
      ])
    )
  }

  /// A full `CommandExecution` `item_completed` line with the fixed `["/bin/zsh", "-lc", …]`
  /// prefix every real item has (see `TranscriptCommands.codexOutcomeProgram`), and string
  /// `status` and `exit_code` so a test can pass a failure. `quoted` escapes `command` as
  /// the extractor's `scanStr` expects.
  static func itemCompletedCommandExecution(
    command: String, status: String = "completed", exitCode: String = "0", id: String = "exec-1"
  ) -> String {
    itemCompleted(
      line([
        "type": quoted("CommandExecution"),
        "id": quoted(id),
        "command": "[" + [quoted("/bin/zsh"), quoted("-lc"), quoted(command)].joined(separator: ",") + "]",
        "status": quoted(status),
        "exit_code": exitCode,
      ])
    )
  }

  static func fileChange(path: String, id: String = "fc1") -> String {
    itemCompleted(line(["type": quoted("FileChange"), "id": quoted(id), "path": quoted(path)]))
  }

  static func mcpToolCall(tool: String, id: String = "mcp1") -> String {
    itemCompleted(
      line(["type": quoted("McpToolCall"), "id": quoted(id), "tool_name": quoted(tool)])
    )
  }

  static func subAgentActivity(_ summary: String, id: String = "sub1") -> String {
    itemCompleted(
      line(["type": quoted("SubAgentActivity"), "id": quoted(id), "summary": quoted(summary)])
    )
  }

  /// A session hook prompt, never a turn.
  static func hookPrompt(id: String = "hook1") -> String {
    itemCompleted(line(["type": quoted("HookPrompt"), "id": quoted(id)]))
  }

  // MARK: - `response_item`

  /// The model's `exec` call, with raw shell text in `input`. Its `callID` never matches a
  /// `CommandExecution` item's `id`, which `CodexParserTests` pins.
  static func customToolCall(input: String, callID: String = "call_1", id: String = "ctc1") -> String {
    line([
      "timestamp": quoted(timestamp),
      "type": quoted("response_item"),
      "payload": line([
        "type": quoted("custom_tool_call"),
        "id": quoted(id),
        "call_id": quoted(callID),
        "name": quoted("exec"),
        "input": quoted(input),
      ]),
    ])
  }

  /// A `tools.exec_command({cmd:"…"})` call, the only shape that produces a
  /// `CommandExecution` item to join against. `quoted` matches a JS double-quoted literal's
  /// escaping, so the same text serves both sides of the join.
  static func execCommandToolCall(
    command: String, callID: String = "call_1", id: String = "ctc1"
  ) -> String {
    customToolCall(
      input: "const r = await tools.exec_command({cmd:\(quoted(command)),workdir:\"/repo\"});"
        + " text(r.output);",
      callID: callID, id: id
    )
  }

  /// The other real spelling, `tools.exec_command({"cmd":"…"})`, with the key quoted. Both
  /// spellings are common, and a join built for one silently misses the other. See
  /// `CodexRecord`.
  static func execCommandToolCallQuoted(
    command: String, callID: String = "call_1", id: String = "ctc1"
  ) -> String {
    customToolCall(
      input: "const r = await tools.exec_command({\"cmd\":\(quoted(command)),\"workdir\":\"/repo\"});"
        + " text(r.output);",
      callID: callID, id: id
    )
  }

  /// Two `exec_command` calls in one `Promise.all` body, so one call yields several
  /// `CommandExecution` completions.
  static func execCommandToolCallBatch(
    commands: [String], callID: String = "call_1", id: String = "ctc1"
  ) -> String {
    let calls = commands.map { "tools.exec_command({cmd:\(quoted($0))})" }.joined(separator: ",")
    return customToolCall(input: "const r = await Promise.all([\(calls)]);", callID: callID, id: id)
  }

  /// The host's compact answer about one `CommandExecution`, in
  /// `TranscriptCommands.codexOutcomeProgram`'s output shape, so a test can pin
  /// `TranscriptParser.codexOutcomes(in:)` without `awk`.
  /// `TranscriptCommandsTests.codexOutcomeProgramExtractsTheFourFields` proves the real
  /// program writes it.
  static func execOutcomeLine(
    command: String, status: String, exitCode: String = "0", id: String = "exec-1"
  ) -> String {
    "!\(id)\t\(status)\t\(exitCode)\t\(jsonEscaped(command))"
  }

  /// The marker the host prints before scanning for outcomes, so a window with no
  /// completions differs from one nobody looked at.
  static let execOutcomesScanned = TranscriptCommands.resultMark

  /// `quoted`'s per-scalar escaping without the surrounding quotes.
  private static func jsonEscaped(_ value: String) -> String {
    var out = ""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\\": out += "\\\\"
      case "\"": out += "\\\""
      case "\n": out += "\\n"
      case "\t": out += "\\t"
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out
  }

  /// A collaboration call such as `spawn_agent`, whose `arguments` is JSON Codex encoded.
  static func functionCall(name: String, arguments: [String: String], id: String = "fc_1") -> String {
    let encoded =
      "{" + arguments.map { "\"\($0.key)\":\(quoted($0.value))" }.sorted().joined(separator: ",") + "}"
    return line([
      "timestamp": quoted(timestamp),
      "type": quoted("response_item"),
      "payload": line([
        "type": quoted("function_call"),
        "id": quoted(id),
        "name": quoted(name),
        "arguments": quoted(encoded),
      ]),
    ])
  }

  // MARK: - Bookkeeping

  /// A top-level record type that is not conversation: `turn_context`,
  /// `token_usage_record`, `world_state`, `inter_agent_communication_metadata`.
  static func bookkeeping(_ type: String = "token_usage_record") -> String {
    line(["timestamp": quoted(timestamp), "type": quoted(type), "payload": line(["n": "1"])])
  }

  // MARK: - Whole sessions

  /// A `user`-thread rollout with one of everything: prose rare beside `Reasoning` and
  /// bookkeeping, tool calls from `response_item`, one `HookPrompt` and one subagent spawn.
  static func session() -> String {
    [
      sessionMeta(),
      userMessage("$example", id: "u1"),
      reasoning(),
      agentMessage("Running the check now.", id: "a1"),
      customToolCall(input: "echo hello\n", callID: "call_1"),
      commandExecution(["/bin/zsh", "-lc", "echo hello"], id: "exec-1"),
      bookkeeping("token_usage_record"),
      functionCall(name: "spawn_agent", arguments: ["task_name": "task_group_1", "agent_type": "worker"]),
      subAgentActivity("task_group_1 started", id: "sub1"),
      fileChange(path: "Notes/Backlog.md"),
      mcpToolCall(tool: "search_docs"),
      hookPrompt(),
      userMessageWithSkill("$review", skill: "review", id: "us1"),
      agentMessage("Finished and pushed.", id: "a2"),
      bookkeeping("turn_context"),
      bookkeeping("world_state"),
      bookkeeping("inter_agent_communication_metadata"),
    ].joined(separator: "\n") + "\n"
  }
}
