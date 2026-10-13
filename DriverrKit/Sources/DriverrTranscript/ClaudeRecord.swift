import Foundation

/// Claude Code's JSONL session format. These types are `internal` so the compiler keeps
/// them inside this module; they map to `DriverrCore` values at the boundary.
///
/// This is another vendor's private on-disk format with no version contract. Every field
/// is optional and unused fields are absent, so a file that adds a field, drops one or
/// writes an unknown record type keeps decoding after a `claude` upgrade.
struct ClaudeRecord: Decodable {
  /// `user`, `assistant`, `system`, or a bookkeeping kind such as `attachment` or
  /// `file-history-snapshot` that is not conversation.
  let type: String?
  /// On a `system` record, `turn_duration` is the one Driverr reads. The other kinds do not
  /// travel; see `TranscriptCommands.recordSelector`.
  let subtype: String?
  /// Used as the turn's id, so a page fetched twice answers with the same ids.
  let uuid: String?
  /// ISO 8601 with fractional seconds: `2026-08-24T15:04:04.988Z`.
  let timestamp: String?
  /// **Injected, not typed.** Set on skill bodies, `<system-reminder>` blocks, hook context
  /// and session-start text. Without this check a skill's instructions would show as
  /// something the user said.
  let isMeta: Bool?
  /// Set on every record in a sub-agent's own file, including its opening prompt. The
  /// opening prompt is told apart by `parentUuid`, not by this field. Dropped when reading
  /// a pane's own file, because a sub-agent's turns are not that session's conversation;
  /// see `TranscriptParser.page(from:forSubagentFile:)`.
  let isSidechain: Bool?
  /// `nil` only on the record that opens a file. Read to find a sub-agent's opening prompt,
  /// which has `parentUuid: null` and no `origin`.
  let parentUuid: String?
  /// **Who caused this record**, checked before anything else. `isMeta` is not enough: about
  /// half of the text-bearing, non-injected `user` records are the client's own machinery,
  /// mostly `task-notification`, and none of those was said by the person.
  let origin: ClaudeOrigin?
  /// A summary written when a conversation is compacted. Machine text in a `user` record.
  let isCompactSummary: Bool?
  /// Set on records that exist only so the transcript reads back. Means the same kind of
  /// thing as `isCompactSummary`.
  let isVisibleInTranscriptOnly: Bool?
  /// Present only on `user` records that are a tool's reply. Also carries an
  /// `AskUserQuestion` call's answers; see `ToolUseResult`.
  let toolUseResult: ToolUseResult?
  /// Milliseconds the agent worked on the preceding turn, the figure the terminal prints as
  /// `Crunched for 9m 50s`. Present only on a `system` record with `subtype ==
  /// "turn_duration"`.
  ///
  /// That record has no `message`, so `TranscriptParser` handles it before the guard that
  /// drops message-less records, and attaches the value to the assistant turn before it.
  let durationMs: LenientMilliseconds?
  /// Set on the `assistant` record Claude Code writes when an API request fails. Its model is
  /// `<synthetic>` and its text is the line the terminal prints. See `DriverrCore.AgentStop`.
  let isApiErrorMessage: LenientFlag?
  /// The failure's kind on an API-error record: `rate_limit`, `authentication_failed`,
  /// `server_error` or `unknown`.
  let error: LenientText?
  /// On a `rate_limit` record only, and optional there; without it the stop shows no reset
  /// time.
  let quotaLimits: ClaudeQuotaLimits?
  let message: ClaudeMessage?

  var isInjected: Bool { isMeta == true }
  var isAPIError: Bool { isApiErrorMessage?.value == true }
  var isSubagent: Bool { isSidechain == true }
  var isCompacted: Bool { isCompactSummary == true }
}

/// What caused a record to be written. `kind` is `human` for a person and a client name
/// such as `task-notification` otherwise. Older Claude Code versions omit it, so it is not
/// the only check; see `TranscriptParser.isClientEnvelope`.
struct ClaudeOrigin: Decodable {
  let kind: String?
}

struct ClaudeMessage: Decodable {
  let role: String?
  let content: ClaudeContent?
  /// `claude-opus-5`, `claude-fable-5-1`, or `<synthetic>`. Decoded but not shown yet.
  let model: String?
  /// What the request behind this record cost. Present on every assistant record.
  let usage: ClaudeUsage?

  private enum CodingKeys: String, CodingKey {
    case role, content, model, usage
  }

  /// `role` and `content` decode as the synthesised initialiser would, so they still fail
  /// the record when wrong. `model` and `usage` are `try?`: a wrong type there costs only
  /// that field.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    role = try container.decodeIfPresent(String.self, forKey: .role)
    content = try container.decodeIfPresent(ClaudeContent.self, forKey: .content)
    model = try? container.decodeIfPresent(String.self, forKey: .model)
    usage = try? container.decodeIfPresent(ClaudeUsage.self, forKey: .usage)
  }
}

/// A record's `message.usage`, reduced to the three fields that make up the context.
/// `output_tokens` is not read, because the reply joins the context only on the next
/// request, whose record counts it. Cannot throw, for `ImageSource`'s reason.
struct ClaudeUsage: Decodable {
  let inputTokens: Int?
  let cacheCreationInputTokens: Int?
  let cacheReadInputTokens: Int?

  private enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case cacheCreationInputTokens = "cache_creation_input_tokens"
    case cacheReadInputTokens = "cache_read_input_tokens"
  }

  init(from decoder: any Decoder) throws {
    let container = try? decoder.container(keyedBy: CodingKeys.self)
    func count(_ key: CodingKeys) -> Int? {
      try? container?.decode(Int.self, forKey: key)
    }
    inputTokens = count(.inputTokens)
    cacheCreationInputTokens = count(.cacheCreationInputTokens)
    cacheReadInputTokens = count(.cacheReadInputTokens)
  }
}

/// A message's content: a bare string on some records and an array of typed blocks on
/// others. Human turns come in both shapes.
enum ClaudeContent: Decodable {
  case text(String)
  case blocks([ClaudeBlock])

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let text = try? container.decode(String.self) {
      self = .text(text)
      return
    }
    // An undecodable block must not fail the whole message, so `ClaudeBlock` has no required
    // fields and this cannot throw today.
    self = .blocks(try container.decode([ClaudeBlock].self))
  }

  var blocks: [ClaudeBlock] {
    switch self {
    case .text: []
    case .blocks(let blocks): blocks
    }
  }

  var string: String? {
    switch self {
    case .text(let text): text
    case .blocks: nil
    }
  }
}

/// One content block: `text`, `tool_use`, `tool_result`, `thinking`, `image`. An unknown
/// type decodes with every field `nil` and is ignored.
struct ClaudeBlock: Decodable {
  let type: String?
  let text: String?
  /// The tool's name on a `tool_use` block: `Read`, `Bash`, `mcp__server__thing`.
  let name: String?
  /// The call's identifier on a `tool_use` block, such as `toolu_01AbCdEfGhIjKlMnOpQrStUv`.
  /// The only thing that joins a call to its outcome; see
  /// `TranscriptCommands.resultSelector`.
  let id: String?
  /// The tool's arguments, reduced as `ToolInput` describes.
  let input: ToolInput?
  /// Where an `image` block's pixels are.
  let source: ImageSource?
  /// The call a `tool_result` block answers. Read only to file an `AskUserQuestion` answer;
  /// the result lines `TranscriptCommands.resultSelector` writes carry the id for every
  /// other tool.
  let toolUseID: String?

  private enum CodingKeys: String, CodingKey {
    case type, text, name, id, input, source
    case toolUseID = "tool_use_id"
  }

  var isToolResult: Bool { type == "tool_result" }
  var isToolUse: Bool { type == "tool_use" }
  var isText: Bool { type == "text" }
  /// A pasted screenshot or diagram. A message can be only an image.
  var isImage: Bool { type == "image" }
}

/// An `image` block's `source`.
///
/// **This type cannot throw.** `ClaudeBlock` uses the synthesised decoder and blocks decode
/// as an array, so a throwing `source` would lose the whole message around the image.
///
/// The payload stays a `String` and becomes bytes in the parser. A base64 `Data` decode
/// here would turn a corrupt payload into a failed record instead of a missing image.
/// Real blocks are `type: "base64"` with `image/png` or `image/jpeg`; `path` and `url`
/// are decoded because the format documents them.
struct ImageSource: Decodable {
  let type: String?
  let mediaType: String?
  let data: String?
  let path: String?
  let url: String?

  private enum CodingKeys: String, CodingKey {
    case type
    case mediaType = "media_type"
    case data
    case path
    case url
  }

  init(from decoder: any Decoder) throws {
    guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
      // Not an object, such as a bare string. Nothing to read, and no reason to fail the block.
      type = nil
      mediaType = nil
      data = nil
      path = nil
      url = nil
      return
    }
    func string(_ key: CodingKeys) -> String? {
      try? container.decode(String.self, forKey: key)
    }
    type = string(.type)
    mediaType = string(.mediaType)
    data = string(.data)
    path = string(.path)
    url = string(.url)
  }
}

/// A tool's reply, decoded for its presence and for `AskUserQuestion`'s answers. The
/// answers map each question's text to its answer; a multi-select answer is the labels
/// joined by `", "`:
///
/// ```
/// "toolUseResult":{"questions":[…],"answers":{"Which fruit do you pick?":"Apple"},"annotations":{}}
/// ```
///
/// Cannot throw, for `ImageSource`'s reason. Other tools' replies land on `answers == nil`.
struct ToolUseResult: Decodable {
  let answers: [String: String]?

  private enum CodingKeys: String, CodingKey {
    case answers
  }

  init(from decoder: any Decoder) throws {
    let container = try? decoder.container(keyedBy: CodingKeys.self)
    answers = try? container?.decode([String: String].self, forKey: .answers)
  }
}

/// A millisecond count, or nothing when the value is not a number.
///
/// **This type cannot throw.** `ClaudeRecord`'s synthesised decoder uses `decodeIfPresent`,
/// which throws `typeMismatch` on a present key of the wrong type and fails the whole
/// record. The pane would then report a parse fault over a field Driverr barely uses.
struct LenientMilliseconds: Decodable {
  let value: Double?

  init(from decoder: any Decoder) throws {
    value = try? decoder.singleValueContainer().decode(Double.self)
  }
}

/// A bool, or nothing. Cannot throw, for `LenientMilliseconds`'s reason.
struct LenientFlag: Decodable {
  let value: Bool?

  init(from decoder: any Decoder) throws {
    value = try? decoder.singleValueContainer().decode(Bool.self)
  }
}

/// A string, or nothing. Cannot throw, for `LenientMilliseconds`'s reason.
struct LenientText: Decodable {
  let value: String?

  init(from decoder: any Decoder) throws {
    value = try? decoder.singleValueContainer().decode(String.self)
  }
}

/// A `rate_limit` record's `quotaLimits`, reduced to `resetsAt` (whole seconds since
/// 1970). `rateLimitType` is not read because every real record says `five_hour`, so a
/// title naming the window would be tested against one value. Cannot throw.
struct ClaudeQuotaLimits: Decodable {
  let resetsAt: Date?

  private enum CodingKeys: String, CodingKey {
    case resetsAt
  }

  init(from decoder: any Decoder) throws {
    let container = try? decoder.container(keyedBy: CodingKeys.self)
    let seconds = try? container?.decode(Double.self, forKey: .resetsAt)
    resetsAt = seconds.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
  }
}

/// One option an `AskUserQuestion` call offered beside its question.
struct ToolQuestionOption: Decodable {
  let label: String?
  /// The line the picker draws under the option.
  let description: String?
}

/// One question from `AskUserQuestion`'s input, the only place in the file where a
/// blocked pane's choices are typed. `TranscriptParser.replyQuestions(of:)` turns it into
/// `ToolCall.questions` for the reply chips.
///
/// One call carries one to four questions, each with its own options and multi-select
/// flag. A missing `multiSelect` means one answer, the tool's default.
struct ToolQuestion: Decodable {
  let question: String?
  /// The short label on the question's tab, such as `Fruit`.
  let header: String?
  let options: [ToolQuestionOption]?
  let multiSelect: Bool?
}

/// A tool call's arguments, reduced to what Driverr reads.
///
/// The string-valued members feed `TranscriptParser.target(of:)`; everything else is
/// dropped at the decode. `questions` is the exception, because `AskUserQuestion`'s input
/// is an array of objects and the string-only rule would lose the question.
struct ToolInput: Decodable {
  let values: [String: String]
  let questions: [ToolQuestion]
  /// `run_in_background` on a `Bash` call whose command outlives it. Usually a bool, but
  /// some calls write the string `"true"`, which counts too.
  let runsInBackground: Bool

  private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  private enum Structured: String, CodingKey {
    case questions
    case runInBackground = "run_in_background"
  }

  init(from decoder: any Decoder) throws {
    guard let container = try? decoder.container(keyedBy: AnyKey.self) else {
      // Not an object, such as a bare array or string. Nothing to read.
      values = [:]
      questions = []
      runsInBackground = false
      return
    }
    var found: [String: String] = [:]
    for key in container.allKeys {
      if let value = try? container.decode(String.self, forKey: key) {
        found[key.stringValue] = value
      }
    }
    values = found
    if let structured = try? decoder.container(keyedBy: Structured.self),
      let asked = try? structured.decode([ToolQuestion].self, forKey: .questions)
    {
      questions = asked
    } else {
      questions = []
    }
    runsInBackground =
      (try? decoder.container(keyedBy: Structured.self)
        .decode(Bool.self, forKey: .runInBackground)) ?? (found["run_in_background"] == "true")
  }

  subscript(key: String) -> String? { values[key] }
}
