import Foundation

/// Codex CLI's rollout format. These types never leave this module, as with `ClaudeRecord`.
///
/// Line 1 of every rollout is a `session_meta` record (see `CodexRollouts`). Two streams
/// follow, told apart by top-level `type`:
///
/// - `response_item` is the model's conversation history, including content the client
///   injected ahead of a turn. Its `payload.type` is the item kind: `message`,
///   `reasoning`, `custom_tool_call`, `function_call`, their `_output`s, `agent_message`.
/// - `event_msg` is the TUI's item model, free of injected content. `item_completed`
///   events carry an item whose `type` is `UserMessage`, `AgentMessage`,
///   `CommandExecution`, `FileChange`, `McpToolCall` and others.
///
/// Prose is read only from `event_msg` `UserMessage` and `AgentMessage` items, because
/// `response_item` messages still hold injected text (`ClaudeRecord.isMeta`'s problem).
/// Tool calls are read from `response_item`.
///
/// **`custom_tool_call.input` is JavaScript source, not JSON.** Every `custom_tool_call`
/// seen so far is named `exec`, and its body is a sandboxed script that may call several primitives.
/// Only `tools.exec_command` produces a `CommandExecution` item; `apply_patch`,
/// `write_stdin` and `web__run` do not.
///
/// Outcomes are joined by command text, not by id: a call's `call_id` (`call_…`) never
/// matches a `CommandExecution` `id` (`exec-…`). The join extracts each `cmd` literal,
/// written either `cmd:"…"` or `"cmd":"…"`, and matches it against the last element of
/// the completion's `["/bin/zsh","-lc","<command>"]`. It pairs about 97% of
/// `exec_command` calls, which are about three quarters of all calls. Every other call
/// keeps `ToolCall.Outcome.unknown`. See `TranscriptCommands.codexOutcomeProgram` and
/// `TranscriptParser.codexOutcomes(in:)`.
///
/// Every field is optional and unused fields are absent, so a rollout that adds, drops
/// or invents a record type keeps decoding.
struct CodexRecord: Decodable {
  /// `session_meta`, `event_msg`, `response_item`, `turn_context`, and whatever Codex adds.
  let type: String?
  let payload: CodexPayload?
  /// Present on every record, unlike Claude's per-block timestamp. Read for
  /// `TranscriptTurn.at`.
  let timestamp: String?
}

/// A record's payload. `type` means two things: on an `event_msg` it is the event kind
/// and the item is under `item`; on a `response_item` it is the item kind and the item's
/// fields sit on this struct. One struct, because the decoder cannot choose between two
/// before it has read the record.
struct CodexPayload: Decodable {
  let type: String?
  /// Present on an `event_msg` record whose `type` is `item_completed`.
  let item: CodexItem?
  /// A call's item identifier (`ctc_…` or `fc_…`), used as the turn's id because it stays
  /// stable when a page's byte bound moves. Distinct from `callID`.
  let id: String?
  /// `call_…`. Never matches a `CommandExecution` item's `id`.
  let callID: String?
  let name: String?
  /// JavaScript source, not JSON. See this file's header.
  let input: String?
  /// A `function_call`'s arguments, as a JSON string, reduced to a short target in
  /// `TranscriptParser`.
  let arguments: String?

  private enum CodingKeys: String, CodingKey {
    case type, item, id, name, input, arguments
    case callID = "call_id"
  }
}

/// One `event_msg` item. `TranscriptParser.codexPage(from:)` says which item types become
/// a turn.
struct CodexItem: Decodable {
  let type: String?
  let id: String?
  let content: [CodexContentBlock]?
  let command: [String]?
  /// Decoded but not yet used.
  let path: String?
  /// Decoded but not yet used.
  let toolName: String?
  /// Decoded but not yet used.
  let summary: String?

  private enum CodingKeys: String, CodingKey {
    case type, id, content, command, path, summary
    case toolName = "tool_name"
  }
}

/// One block of a message's `content`. `UserMessage` writes `text` (and `skill`),
/// `AgentMessage` writes `Text`, so `TranscriptParser` compares case-insensitively.
struct CodexContentBlock: Decodable {
  let type: String?
  let text: String?
}
