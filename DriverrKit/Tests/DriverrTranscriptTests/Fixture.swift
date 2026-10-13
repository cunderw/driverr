import Foundation

@testable import DriverrTranscript

/// Claude Code session records, hand-built line by line.
///
/// Never commit a real session file. One holds its author's working directories and
/// conversations, and this repository is public. The records here are written by hand, and
/// only their shape follows Claude Code's. `LiveTranscriptProbeTests`, opt-in, checks that
/// shape against the files in this machine's own `~/.claude/projects`.
enum Fixture {
  static func line(_ fields: [String: String], raw: [String: String] = [:]) -> String {
    let quoted = fields.map { "\"\($0.key)\":\"\(escaped($0.value))\"" }
    let verbatim = raw.map { "\"\($0.key)\":\($0.value)" }
    return "{" + (quoted + verbatim).sorted().joined(separator: ",") + "}"
  }

  /// JSON string escaping, control characters included. A raw control character in a JSON
  /// string is invalid, and Claude writes `\u001b` for pasted terminal escapes, so emitting
  /// the raw byte would decode to an empty page.
  static func escaped(_ value: String) -> String {
    var out = ""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\\": out += "\\\\"
      case "\"": out += "\\\""
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        if scalar.value < 0x20 || scalar.value == 0x7F {
          out += String(format: "\\u%04x", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out
  }

  // MARK: - Records

  /// Something a person typed, as most are recorded: content as a bare string.
  static func human(_ text: String, uuid: String = "u1", at: String = timestamp) -> String {
    line(
      ["type": "user", "uuid": uuid, "timestamp": at],
      raw: ["isSidechain": "false", "message": "{\"role\":\"user\",\"content\":\"\(escaped(text))\"}"]
    )
  }

  /// The other human-turn shape: an array of `text` blocks, used whenever an image travels
  /// with the message.
  static func humanBlocks(_ text: String, uuid: String = "ub1", at: String = timestamp) -> String {
    line(
      ["type": "user", "uuid": uuid, "timestamp": at],
      raw: [
        "isSidechain": "false",
        "message": "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"\(escaped(text))\"}]}",
      ]
    )
  }

  /// A person, marked by `origin`, which current Claude Code writes on every prompt record.
  static func humanWithOrigin(
    _ text: String,
    kind: String = "human",
    promptSource: String = "typed",
    uuid: String = "ho1"
  ) -> String {
    line(
      ["type": "user", "uuid": uuid, "timestamp": timestamp, "promptSource": promptSource],
      raw: [
        "isSidechain": "false",
        "origin": "{\"kind\":\"\(escaped(kind))\"}",
        "message": "{\"role\":\"user\",\"content\":\"\(escaped(text))\"}",
      ]
    )
  }

  /// A sub-agent's opening prompt: `parentUuid: null`, `isSidechain: true`, no `origin`. The
  /// one record `TranscriptParser.page(from:forSubagentFile:)` labels
  /// `TranscriptTurn.isParentPrompt`, once per real sub-agent file.
  static func subagentPrompt(_ text: String, uuid: String = "sp1", at: String = timestamp) -> String {
    line(
      ["type": "user", "uuid": uuid, "timestamp": at],
      raw: [
        "parentUuid": "null",
        "isSidechain": "true",
        "message": "{\"role\":\"user\",\"content\":\"\(escaped(text))\"}",
      ]
    )
  }

  /// A later record in a sub-agent's file: it names a `parentUuid`. No `origin` either, so the
  /// guard must refuse it without relying on `origin`.
  static func subagentFollowUp(
    _ text: String, parent: String, uuid: String = "sf1", at: String = timestamp
  ) -> String {
    line(
      ["type": "user", "uuid": uuid, "timestamp": at, "parentUuid": parent],
      raw: [
        "isSidechain": "true",
        "message": "{\"role\":\"user\",\"content\":\"\(escaped(text))\"}",
      ]
    )
  }

  /// `subagentPrompt`'s shape plus an `origin`, which no real file has. It isolates the
  /// guard's `origin == nil` half, because every other later-turn fixture is already refused
  /// by its non-null `parentUuid`.
  static func subagentPromptWithOrigin(
    _ text: String, uuid: String = "spo1", at: String = timestamp
  ) -> String {
    line(
      ["type": "user", "uuid": uuid, "timestamp": at],
      raw: [
        "parentUuid": "null",
        "isSidechain": "true",
        "origin": "{\"kind\":\"human\"}",
        "message": "{\"role\":\"user\",\"content\":\"\(escaped(text))\"}",
      ]
    )
  }

  /// A later record that names its parent and carries `origin`, such as a teammate's further
  /// message. `FakeTranscriptHost.subagentRecord` never writes this for `.human`.
  static func subagentHumanFollowUp(
    _ text: String, parent: String, uuid: String = "shf1", at: String = timestamp
  ) -> String {
    line(
      ["type": "user", "uuid": uuid, "timestamp": at, "parentUuid": parent],
      raw: [
        "isSidechain": "true",
        "origin": "{\"kind\":\"human\"}",
        "message": "{\"role\":\"user\",\"content\":\"\(escaped(text))\"}",
      ]
    )
  }

  /// A background task reporting to the agent: the most common non-person `user` record, not
  /// marked `isMeta`. Carries the `<tool-use-id>` every real one has, because task lines join
  /// on it.
  static func taskNotification(
    uuid: String = "tn1",
    taskID: String = "b0a1b2c3d",
    toolUseID: String = "toolu_bg",
    status: String = "completed",
    at: String = timestamp
  ) -> String {
    line(
      ["type": "user", "uuid": uuid, "timestamp": at, "promptSource": "system"],
      raw: [
        "isSidechain": "false",
        "origin": "{\"kind\":\"task-notification\"}",
        "message": "{\"role\":\"user\",\"content\":\"\(escaped(notificationBody(taskID: taskID, toolUseID: toolUseID, status: status)))\"}",
      ]
    )
  }

  /// The same notification as a `queued_command` attachment, the only trace for many async
  /// spawns. Written in the real key order, which `line(_:raw:)` would sort away.
  static func queuedTaskNotification(
    taskID: String = "a0000000000000001",
    toolUseID: String,
    status: String = "completed",
    at: String = timestamp,
    uuid: String = "qc1"
  ) -> String {
    let body = escaped(notificationBody(taskID: taskID, toolUseID: toolUseID, status: status))
    return """
      {"parentUuid":"p1","isSidechain":false,"attachment":{"type":"queued_command",\
      "prompt":"\(body)","source_uuid":"s1","commandMode":"task-notification",\
      "timestamp":"\(at)"},"type":"attachment","uuid":"\(uuid)","timestamp":"\(at)",\
      "userType":"external","entrypoint":"cli","sessionId":"s"}
      """
  }

  /// A sub-agent's report handed back as a `queued_command` attachment whose `origin` names
  /// only the `agentId`. Some async spawns finish with only this.
  static func handback(from agentID: String, at: String = timestamp, uuid: String = "hb1") -> String {
    """
    {"parentUuid":"p1","isSidechain":false,"attachment":{"type":"queued_command",\
    "prompt":"<agent-message>The report.</agent-message>","source_uuid":"s1",\
    "commandMode":"prompt","origin":{"kind":"peer","from":"\(agentID)",\
    "senderTaskId":"\(agentID)","body":"The report.","handback":true},\
    "timestamp":"\(at)","isMeta":true},"type":"attachment","uuid":"\(uuid)",\
    "timestamp":"\(at)","userType":"external","entrypoint":"cli","sessionId":"s"}
    """
  }

  /// A task notification's text, as Claude Code 2.1.27x writes it.
  static func notificationBody(taskID: String, toolUseID: String, status: String) -> String {
    "<task-notification>\n<task-id>\(taskID)</task-id>\n<tool-use-id>\(toolUseID)</tool-use-id>\n"
      + "<output-file>/tmp/tasks/\(taskID).output</output-file>\n<status>\(status)</status>\n"
      + "<summary>Agent \"Plan it\" finished</summary>\n</task-notification>"
  }

  /// An `Agent` call's reply, with the `toolUseResult` each launch kind writes. `status` is
  /// `async_launched`, `teammate_spawned` or `completed`, keys in the real order.
  static func agentResult(
    id: String,
    status: String,
    agentID: String? = nil,
    durationMs: Int? = nil,
    failed: Bool = false,
    uuid: String = "ar1"
  ) -> String {
    var fields: [String] = []
    if status == "async_launched" { fields.append("\"isAsync\":true") }
    fields.append("\"status\":\"\(status)\"")
    fields.append("\"prompt\":\"Read the issue\"")
    if status == "teammate_spawned" {
      fields.append("\"teammate_id\":\"analyst-4@session-1\",\"name\":\"analyst-4\"")
    }
    if let agentID { fields.append("\"agentId\":\"\(agentID)\"") }
    if let durationMs { fields.append("\"totalDurationMs\":\(durationMs)") }
    let error = failed ? ",\"is_error\":true" : ""
    return line(
      ["type": "user", "uuid": uuid, "timestamp": timestamp],
      raw: [
        "isSidechain": "false",
        "toolUseResult": "{\(fields.joined(separator: ","))}",
        "message":
          "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"\(id)\","
          + "\"content\":\"Launched\"\(error)}]}",
      ]
    )
  }

  /// A `run_in_background` `Bash` call's reply, naming the task it started.
  static func backgroundBashResult(id: String, taskID: String, uuid: String = "bb1") -> String {
    line(
      ["type": "user", "uuid": uuid, "timestamp": timestamp],
      raw: [
        "isSidechain": "false",
        "toolUseResult":
          "{\"stdout\":\"\",\"stderr\":\"\",\"interrupted\":false,\"backgroundTaskId\":\"\(taskID)\"}",
        "message":
          "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"\(id)\","
          + "\"content\":\"Command running in background\",\"is_error\":false}]}",
      ]
    )
  }

  /// Slash-command and bash-mode envelopes, from a Claude Code old enough to write no
  /// `origin`.
  static func clientEnvelope(_ body: String, uuid: String = "ce1") -> String {
    line(
      ["type": "user", "uuid": uuid, "timestamp": timestamp],
      raw: [
        "isSidechain": "false",
        "message": "{\"role\":\"user\",\"content\":\"\(escaped(body))\"}",
      ]
    )
  }

  /// The summary written when a conversation is compacted.
  static func compactSummary(_ text: String, uuid: String = "cs1") -> String {
    line(
      ["type": "user", "uuid": uuid, "timestamp": timestamp],
      raw: [
        "isSidechain": "false",
        "isCompactSummary": "true",
        "isVisibleInTranscriptOnly": "true",
        "message": "{\"role\":\"user\",\"content\":\"\(escaped(text))\"}",
      ]
    )
  }

  /// Injected text in a `user` record: a skill body, a `<system-reminder>`, hook context.
  /// Only `isMeta` separates it from a person's.
  static func injected(_ text: String, uuid: String = "m1") -> String {
    line(
      ["type": "user", "uuid": uuid, "timestamp": timestamp],
      raw: [
        "isMeta": "true",
        "isSidechain": "false",
        "message": "{\"role\":\"user\",\"content\":\"\(escaped(text))\"}",
      ]
    )
  }

  /// A tool's reply, with both real markers: the `tool_result` block and the top-level
  /// `toolUseResult`.
  static func toolResult(id: String, output: String = "ok", uuid: String = "r1") -> String {
    line(
      ["type": "user", "uuid": uuid, "timestamp": timestamp],
      raw: [
        "isSidechain": "false",
        "toolUseResult": "{\"stdout\":\"\(escaped(output))\"}",
        "message":
          "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"\(id)\","
          + "\"content\":\"\(escaped(output))\"}]}",
      ]
    )
  }

  /// A tool's reply that came back an error.
  static func failedToolResult(id: String, uuid: String = "rf1") -> String {
    line(
      ["type": "user", "uuid": uuid, "timestamp": timestamp],
      raw: [
        "isSidechain": "false",
        "toolUseResult": "{\"stdout\":\"\",\"stderr\":\"boom\"}",
        "message":
          "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"\(id)\","
          + "\"content\":\"boom\",\"is_error\":true}]}",
      ]
    )
  }

  /// A tool's reply whose `toolUseResult` names a second call id. The selector takes the
  /// first `"tool_use_id":"`, the block's, because `message` precedes `toolUseResult`. Without
  /// this fixture, taking the last would pass.
  static func toolResultQuotingAnotherID(id: String, other: String, uuid: String = "rq1") -> String {
    line(
      ["type": "user", "uuid": uuid, "timestamp": timestamp],
      raw: [
        "isSidechain": "false",
        "message":
          "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"\(id)\","
          + "\"content\":\"ok\"}]}",
        "toolUseResult": "{\"tool_use_id\":\"\(other)\",\"stdout\":\"ok\"}",
      ]
    )
  }

  /// A tool's reply with bare-string content. Never observed, but here only the top-level
  /// `toolUseResult` says it is a tool's output rather than typed text.
  static func toolResultAsString(_ output: String, uuid: String = "rs1") -> String {
    line(
      ["type": "user", "uuid": uuid, "timestamp": timestamp],
      raw: [
        "isSidechain": "false",
        "toolUseResult": "{\"stdout\":\"\(escaped(output))\"}",
        "message": "{\"role\":\"user\",\"content\":\"\(escaped(output))\"}",
      ]
    )
  }

  /// A tool's reply with a `text` block beside the `tool_result` and no top-level
  /// `toolUseResult`. Never observed, but Claude appends `<system-reminder>` text to other
  /// records, and on a tool result a top-level-only check would show it as something the user
  /// said. Without this fixture the block check could be deleted with every test passing.
  static func toolResultWithText(id: String, text: String, uuid: String = "rb1") -> String {
    line(
      ["type": "user", "uuid": uuid, "timestamp": timestamp],
      raw: [
        "isSidechain": "false",
        "message":
          "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"\(escaped(text))\"},"
          + "{\"type\":\"tool_result\",\"tool_use_id\":\"\(id)\",\"content\":\"output\"}]}",
      ]
    )
  }

  static func assistant(_ text: String, uuid: String = "a1", at: String = timestamp) -> String {
    line(
      ["type": "assistant", "uuid": uuid, "timestamp": at],
      raw: [
        "isSidechain": "false",
        "message":
          "{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"\(escaped(text))\"}]}",
      ]
    )
  }

  /// The agent's working-out. Never rendered, never a turn boundary.
  static func thinking(_ text: String = "considering", uuid: String = "t1") -> String {
    line(
      ["type": "assistant", "uuid": uuid, "timestamp": timestamp],
      raw: [
        "isSidechain": "false",
        "message":
          "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"\(escaped(text))\","
          + "\"signature\":\"sig\"}]}",
      ]
    )
  }

  static func toolUse(
    _ name: String,
    input: String = "{}",
    id: String = "toolu_1",
    uuid: String = "tu1"
  ) -> String {
    line(
      ["type": "assistant", "uuid": uuid, "timestamp": timestamp],
      raw: [
        "isSidechain": "false",
        "message":
          "{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"\(id)\","
          + "\"name\":\"\(escaped(name))\",\"input\":\(input)}]}",
      ]
    )
  }

  /// Several `tool_use` blocks in one record, in order, as when a session spawns two agents
  /// at once. Ids are `toolu_1`, `toolu_2`, … so a `result` line can name any of them.
  static func toolUses(_ calls: [(name: String, input: String)], uuid: String = "tum1") -> String {
    let blocks = calls.enumerated().map { position, call in
      "{\"type\":\"tool_use\",\"id\":\"toolu_\(position + 1)\","
        + "\"name\":\"\(escaped(call.name))\",\"input\":\(call.input)}"
    }
    return line(
      ["type": "assistant", "uuid": uuid, "timestamp": timestamp],
      raw: [
        "isSidechain": "false",
        "message":
          "{\"role\":\"assistant\",\"content\":[\(blocks.joined(separator: ","))]}",
      ]
    )
  }

  /// A `tool_use` block with no `id`. Never observed, but such a call can never be matched to
  /// a result, and without this fixture the branch keeping it `.unknown` could be deleted.
  static func toolUseWithoutIdentifier(_ name: String, uuid: String = "tun1") -> String {
    line(
      ["type": "assistant", "uuid": uuid, "timestamp": timestamp],
      raw: [
        "isSidechain": "false",
        "message":
          "{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\","
          + "\"name\":\"\(escaped(name))\",\"input\":{}}]}",
      ]
    )
  }

  /// A message and a tool call in one record, the reason the parse walks blocks.
  static func assistantThenTool(
    _ text: String,
    tool: String,
    uuid: String = "at1"
  ) -> String {
    line(
      ["type": "assistant", "uuid": uuid, "timestamp": timestamp],
      raw: [
        "isSidechain": "false",
        "message":
          "{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"\(escaped(text))\"},"
          + "{\"type\":\"tool_use\",\"id\":\"toolu_x\",\"name\":\"\(tool)\",\"input\":{}}]}",
      ]
    )
  }

  /// A subagent's turn. Real Claude writes these elsewhere, so the filter dropping them has
  /// no live evidence behind it.
  static func subagent(_ text: String, uuid: String = "s1") -> String {
    line(
      ["type": "assistant", "uuid": uuid, "timestamp": timestamp],
      raw: [
        "isSidechain": "true",
        "message":
          "{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"\(escaped(text))\"}]}",
      ]
    )
  }

  /// The elapsed time the terminal prints under a turn, the one `system` record Driverr
  /// reads.
  ///
  /// Written to the real shape: `parentUuid`, `uuid`, `timestamp`, `messageCount`,
  /// `isSidechain` and `isMeta` beside `type`, `subtype` and `durationMs`, and no `message`.
  /// A three-field fixture would let a parse keyed on a missing field pass. The record before
  /// it is always the assistant record its `parentUuid` names, hence the default.
  ///
  /// `value` is raw JSON, so a caller can write a string, object, bool or `null`. A key
  /// `extra` restates is dropped from the base, because which duplicate key wins is the
  /// decoder's business.
  static func turnDuration(
    _ value: String,
    subtype: String = "turn_duration",
    parentUuid: String = "a1",
    uuid: String = "d1",
    at: String = timestamp,
    extra: String = ""
  ) -> String {
    var fields = [
      "\"parentUuid\":\"\(escaped(parentUuid))\"",
      "\"isSidechain\":false",
      "\"type\":\"system\"",
      "\"subtype\":\"\(escaped(subtype))\"",
      "\"durationMs\":\(value)",
      "\"messageCount\":26",
      "\"timestamp\":\"\(escaped(at))\"",
      "\"uuid\":\"\(escaped(uuid))\"",
      "\"isMeta\":false",
      "\"userType\":\"external\"",
      "\"entrypoint\":\"cli\"",
      "\"cwd\":\"/repo\"",
      "\"sessionId\":\"session-1\"",
      "\"version\":\"2.1.251\"",
      "\"gitBranch\":\"main\"",
    ]
    // Splits on every comma, so `extra` must be scalar pairs. A structured value would split
    // into fragments and its key would be written twice; add a parameter for that instead.
    let restated = extra.split(separator: ",")
      .compactMap { $0.split(separator: ":").first }
      .filter { !$0.isEmpty }
    fields.removeAll { field in restated.contains { field.hasPrefix($0) } }
    return "{" + fields.joined(separator: ",") + extra + "}"
  }

  /// One of the dozen record kinds that are not conversation.
  static func bookkeeping(_ kind: String = "custom-title") -> String {
    line(["type": kind, "sessionId": "s", "customTitle": "driverr"])
  }

  /// The agent putting a question to the person, as `AskUserQuestion`'s input.
  ///
  /// `options` and `multiSelect` are per question, so a parse reading only
  /// `questions.first` fails. Both default to `Yes`/`No`, single-select.
  /// `describedOptions` and `caller` add the fields Claude Code 2.x writes (an option's
  /// `description`, the block's `caller`), which the parse must ignore. Both default off.
  static func askUserQuestion(
    _ asked: [String],
    options: [[String]]? = nil,
    multiSelect: [Bool]? = nil,
    describedOptions: Bool = false,
    caller: String? = nil,
    id: String = "toolu_q",
    uuid: String = "q1"
  ) -> String {
    let questions = asked.enumerated().map { index, question -> String in
      let labels = options?[safe: index] ?? ["Yes", "No"]
      let many = multiSelect?[safe: index] ?? false
      let offered = labels.map { label in
        describedOptions
          ? "{\"label\":\"\(escaped(label))\",\"description\":\"What \(escaped(label)) does.\"}"
          : "{\"label\":\"\(escaped(label))\"}"
      }.joined(separator: ",")
      return "{\"question\":\"\(escaped(question))\",\"header\":\"Choice\","
        + "\"multiSelect\":\(many),\"options\":[\(offered)]}"
    }
    let calling = caller.map { "\"caller\":\"\(escaped($0))\"," } ?? ""
    return line(
      ["type": "assistant", "uuid": uuid, "timestamp": timestamp],
      raw: [
        "isSidechain": "false",
        "message":
          "{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\(calling)\"id\":\"\(id)\","
          + "\"name\":\"AskUserQuestion\",\"input\":{\"questions\":[\(questions.joined(separator: ","))]}}]}",
      ]
    )
  }

  /// The reply to an `AskUserQuestion` call, as Claude Code 2.1.274 and 2.1.281 write it:
  ///
  /// - the `tool_result` block's `content` is the sentence the agent reads,
  ///   `Your questions have been answered: "<q>"="<a>". You can now continue…`;
  /// - `toolUseResult` holds `questions` (the call's input), then `answers` keyed by each
  ///   question's text, then an empty `annotations`.
  ///
  /// A multi-select answer is the labels joined by `", "`. `answers` is a list so the wire
  /// order is fixed.
  static func askUserQuestionAnswer(
    id: String,
    answers: [(question: String, answer: String)],
    header: String = "Choice",
    uuid: String = "qa1"
  ) -> String {
    let asked = answers.map { pair in
      "{\"question\":\"\(escaped(pair.question))\",\"header\":\"\(escaped(header))\","
        + "\"options\":[{\"label\":\"\(escaped(pair.answer))\",\"description\":\"The answer.\"}],"
        + "\"multiSelect\":false}"
    }
    let answered = answers.map { "\"\(escaped($0.question))\":\"\(escaped($0.answer))\"" }
    let sentence = answers.map { "\"\($0.question)\"=\"\($0.answer)\"" }.joined(separator: ", ")
    let content =
      "Your questions have been answered: \(sentence). You can now continue with these answers in mind."
    return line(
      ["type": "user", "uuid": uuid, "timestamp": timestamp],
      raw: [
        "isSidechain": "false",
        "message":
          "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\"\(escaped(content))\","
          + "\"tool_use_id\":\"\(id)\"}]}",
        "toolUseResult":
          "{\"questions\":[\(asked.joined(separator: ","))],"
          + "\"answers\":{\(answered.joined(separator: ","))},\"annotations\":{}}",
      ]
    )
  }

  /// A message with an image, in the block-array shape every real one uses.
  static func imageMessage(text: String? = nil, images: Int = 1, uuid: String = "im1") -> String {
    imageMessage(
      text: text,
      sources: Array(repeating: base64Source(), count: images),
      uuid: uuid
    )
  }

  /// The same record with each image `source` written verbatim. Raw JSON, because the cases
  /// worth testing are the ones a typed builder would refuse: non-base64 data, an unknown
  /// `source.type`, a `file` source with no path.
  static func imageMessage(text: String?, sources: [String], uuid: String = "im1") -> String {
    let words = text.map { ["{\"type\":\"text\",\"text\":\"\(escaped($0))\"}"] } ?? []
    let pictures = sources.map { "{\"type\":\"image\",\"source\":\($0)}" }
    return line(
      ["type": "user", "uuid": uuid, "timestamp": timestamp],
      raw: [
        "isSidechain": "false",
        "origin": "{\"kind\":\"human\"}",
        "message": "{\"role\":\"user\",\"content\":[\((words + pictures).joined(separator: ","))]}",
      ]
    )
  }

  /// A `base64` image source. `data` defaults to the eight bytes of a PNG signature, which
  /// decode.
  static func base64Source(
    data: String = "iVBORw0KGgo=",
    mediaType: String? = "image/png"
  ) -> String {
    let type = mediaType.map { ",\"media_type\":\"\(escaped($0))\"" } ?? ""
    return "{\"type\":\"base64\"\(type),\"data\":\"\(escaped(data))\"}"
  }

  /// A file-path image source. No real image block has been seen to use it.
  static func fileSource(path: String, mediaType: String = "image/png") -> String {
    "{\"type\":\"file\",\"media_type\":\"\(escaped(mediaType))\",\"path\":\"\(escaped(path))\"}"
  }

  // MARK: - Result lines

  /// The mark the host prints after scanning for tool results. Its absence matters: an
  /// unscanned page must not read as every tail call unanswered.
  static let resultsScanned = TranscriptCommands.resultMark

  /// One call's answer, as the host writes it: `!<id><TAB><0|1>`.
  static func result(id: String, failed: Bool = false) -> String {
    "\(TranscriptCommands.resultMark)\(id)\(TranscriptCommands.fieldSeparator)\(failed ? "1" : "0")"
  }

  /// An `Agent` call's answer with its launch fields:
  /// `!<id><TAB><0|1><TAB><status><TAB><agentId><TAB><totalDurationMs>`.
  static func spawnResult(
    id: String,
    status: String,
    agentID: String = "",
    durationMs: String = "",
    failed: Bool = false
  ) -> String {
    [result(id: id, failed: failed), status, agentID, durationMs]
      .joined(separator: String(TranscriptCommands.fieldSeparator))
  }

  /// One task line, as the host writes it: `%<tool-use-id or agentId><TAB><status><TAB><time>`.
  static func task(_ key: String, status: String = "completed", at: String = timestamp) -> String {
    [TranscriptCommands.taskMark + key, status, at]
      .joined(separator: String(TranscriptCommands.fieldSeparator))
  }

  static let timestamp = "2026-08-24T15:04:04.988Z"

  // MARK: - Whole sessions

  /// Many records, few turns: 14 turns against 482 records, 80 `tool_use` and 80
  /// `tool_result`, plus injected text and bookkeeping. Built to the ratio of a real session.
  static func longSession() -> String {
    var lines: [String] = []
    var toolIndex = 0
    for turn in 0..<spokenExchanges {
      lines.append(human("do the thing \(turn)", uuid: "h\(turn)"))
      lines.append(injected("<system-reminder>a reminder</system-reminder>", uuid: "m\(turn)"))
      // Bookkeeping records outnumber everything anybody said.
      for filler in 0..<bookkeepingPerExchange {
        lines.append(bookkeeping(bookkeepingKinds[filler % bookkeepingKinds.count]))
      }
      lines.append(thinking(uuid: "t\(turn)"))
      for call in 0..<(turn < 3 ? 12 : 11) {
        let name = ["Read", "Edit", "Bash", "Grep"][call % 4]
        lines.append(
          toolUse(
            name,
            input: "{\"file_path\":\"/repo/File\(call).swift\"}",
            id: "toolu_\(toolIndex)",
            uuid: "tu\(toolIndex)"
          )
        )
        lines.append(toolResult(id: "toolu_\(toolIndex)", uuid: "r\(toolIndex)"))
        toolIndex += 1
      }
      lines.append(assistant("done with \(turn)", uuid: "a\(turn)"))
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static let bookkeepingKinds = [
    "attachment", "mode", "permission-mode", "last-prompt", "custom-title", "agent-name",
  ]
  private static let bookkeepingPerExchange = 42

  /// The counts `longSession` writes, named so the ratio is asserted.
  static let spokenExchanges = 7
  static let longSessionRecords = 482
  static let longSessionToolCalls = 80
  static let longSessionSpokenTurns = spokenExchanges * 2
}

extension Array {
  /// The element at `index`, or nil, so `askUserQuestion` callers need not give one entry per
  /// question.
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
