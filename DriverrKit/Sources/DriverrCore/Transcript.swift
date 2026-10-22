import Foundation

/// One tool call an agent made, as much of it as is worth showing.
///
/// `target` is what the call was about (a filename, a search, a URL), kept short so a reader
/// can tell one `Edit` from the next. `nil` when the call carried nothing worth naming.
public struct ToolCall: Hashable, Sendable {
  /// What became of a call, as far as the page can say.
  ///
  /// Not a `Bool`, because "no result" and "no answer about the result" differ. A pane at a
  /// permission prompt writes nothing until answered, so a resultless call is the only trace
  /// of it.
  public enum Outcome: Hashable, Sendable {
    /// Nothing is known: the page had no result data, or this call's result was outside the
    /// window. Never rendered as success.
    case unknown
    /// The page's result data covered this call and there was no result: the agent is
    /// waiting on it.
    ///
    /// Only set on the last call of the last run in the page. A result is written after its
    /// call, so only the newest call's answer is exact. An older call stays `.unknown`.
    ///
    /// It does not say whether the wait is a permission prompt or a running tool, and the
    /// file cannot. `PendingToolCallNotice` decides the row's wording from `AgentStatus`.
    case pending
    case succeeded
    /// The result came back marked `is_error`.
    case failed
  }

  /// The tool's name exactly as recorded, such as `mcp__some-server__some_tool`. Shortening
  /// is left to the view, so the `Read ×18` count matches what ran.
  public let name: String
  public let target: String?
  public let outcome: Outcome
  /// The questions an `AskUserQuestion` call asked, each with its own options and
  /// multi-select flag. Empty for every other tool.
  ///
  /// A list because the tool takes one to four questions and keys its answer by question
  /// text, so each question needs its own chips. Carried on every call; `pendingCall`
  /// already narrows to the one that matters.
  public let questions: [PendingQuestion]
  /// What became of the work a `run_in_background` `Bash` call started, or `nil`.
  ///
  /// Separate from `outcome`: the call's own result comes back at once and succeeded, while
  /// the command runs on. Folding them together would show a launched task as finished.
  public let task: TaskProgress?

  public init(
    name: String,
    target: String? = nil,
    outcome: Outcome = .unknown,
    questions: [PendingQuestion] = [],
    task: TaskProgress? = nil
  ) {
    self.name = name
    self.target = target
    self.outcome = outcome
    self.questions = questions
    self.task = task
  }
}

/// Work that outlives the call that started it (a sub-agent, a teammate or a background
/// command), and where it has got to.
///
/// The call answers at once, so only a later record says the work ended: a task
/// notification, a sub-agent's handback, or a teammate's idle notification. Every field is
/// read off such a record, never inferred from elapsed time.
public struct TaskProgress: Hashable, Sendable {
  public enum State: Hashable, Sendable {
    /// Started, and nothing in the page says it ended.
    case running
    /// Ended on its own: a `completed` notification, a handback, or a sync spawn's result.
    case finished
    /// A teammate that has gone idle. Not `finished`, because the next message wakes it.
    case idle
    /// A notification saying `failed`, or a spawn whose result came back an error.
    case failed
    /// Something stopped it: a `killed` or `stopped` notification, or a `TaskStop` naming a
    /// teammate. It neither did its job nor failed at it.
    case stopped
  }

  public let state: State
  /// When the starting call was written, by the host's clock.
  public let startedAt: Date?
  /// When the ending record was written. `nil` while running, or when it carried no time.
  public let endedAt: Date?
  /// A sync spawn's `totalDurationMs`. Wins over the timestamps, because Claude Code
  /// measured it.
  public let durationMs: Double?

  public init(
    state: State,
    startedAt: Date? = nil,
    endedAt: Date? = nil,
    durationMs: Double? = nil
  ) {
    self.state = state
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.durationMs = durationMs
  }

  /// How long it ran, or has run as of `now`, in seconds. `nil` without a stated duration
  /// or both ends. A running task's figure includes any skew between the reader's clock and
  /// the host's.
  public func elapsed(asOf now: Date) -> TimeInterval? {
    if let durationMs, durationMs.isFinite, durationMs >= 0 { return durationMs / 1000 }
    guard let startedAt, let end = state == .running ? now : endedAt else { return nil }
    return max(0, end.timeIntervalSince(startedAt))
  }
}

/// One question an `AskUserQuestion` call asked, with the options it offered.
///
/// The options belong to the question, not the call. Each question has its own `options`
/// and `multiSelect`, and the tool's answer is keyed by the question's text.
public struct PendingQuestion: Hashable, Sendable, Identifiable {
  /// The question's exact words. The tool files its answer under this key.
  public let question: String
  /// The labels this question offered, in the order the agent listed them.
  public let options: [String]
  /// Whether this question accepts more than one option. One call can mix both kinds.
  public let allowsMultiple: Bool
  /// Each option's number in Claude Code's picker, from 1, in step with `options`. Not
  /// always 1, 2, 3: the parse drops an option with no usable label, and the picker still
  /// numbers it.
  public let optionNumbers: [Int]
  /// How many questions the call asked, counting any the parse dropped, or `nil` when
  /// unrecorded. The picker still has a tab for a dropped question.
  public let askedInCall: Int?
  /// The picker's tab label for this question, such as `Fruit`, or `nil`.
  public let header: String?
  /// The line under each option, in step with `options`, `nil` where there is none.
  public let optionDescriptions: [String?]
  /// The answer as the tool recorded it, or `nil` while unanswered.
  ///
  /// Kept as the tool's string: a multi-select answer joins labels with `", "`, and a label
  /// can contain `", "`, so splitting it would guess. A typed answer matches no option.
  public let answer: String?
  /// Where the picker is, for a question read off the pane's screen, or `nil` for one from
  /// the transcript. See `PaneQuestionScreen`.
  public let pickerTab: PickerTab?

  public init(
    question: String,
    options: [String],
    allowsMultiple: Bool = false,
    optionNumbers: [Int]? = nil,
    askedInCall: Int? = nil,
    header: String? = nil,
    optionDescriptions: [String?]? = nil,
    answer: String? = nil,
    pickerTab: PickerTab? = nil
  ) {
    self.question = question
    self.options = options
    self.allowsMultiple = allowsMultiple
    self.optionNumbers = optionNumbers ?? options.indices.map { $0 + 1 }
    self.askedInCall = askedInCall
    self.header = header
    self.optionDescriptions = optionDescriptions ?? options.map { _ in nil }
    self.answer = answer
    self.pickerTab = pickerTab
  }

  /// The question's text. The tool keys its answer by it, so it is unique within a call.
  public var id: String { question }
}

/// How many times one tool was used in a run: the `Read ×18` in a run's summary.
public struct ToolKindCount: Hashable, Sendable {
  public let name: String
  public let count: Int

  public init(name: String, count: Int) {
    self.name = name
    self.count = count
  }
}

/// A consecutive run of tool calls, as one value.
///
/// Real sessions are mostly tool records, so one row per call would be screens of noise.
/// Where a run starts and ends is decided by the records at parse time, not by the view.
/// Every call is kept, so the view decides how many to show.
public struct ToolRun: Hashable, Sendable {
  public let calls: [ToolCall]

  public init(calls: [ToolCall]) {
    self.calls = calls
  }

  public var count: Int { calls.count }

  /// The kinds in the run, most-used first: `Read ×18 · Edit ×9 · Bash ×7`. Ties keep first
  /// appearance order, so the summary is stable across re-reads.
  public var kinds: [ToolKindCount] {
    var counts: [String: Int] = [:]
    var order: [String] = []
    for call in calls {
      if counts[call.name] == nil { order.append(call.name) }
      counts[call.name, default: 0] += 1
    }
    return order.enumerated()
      .sorted {
        let left = counts[$0.element] ?? 0
        let right = counts[$1.element] ?? 0
        return left == right ? $0.offset < $1.offset : left > right
      }
      .map { ToolKindCount(name: $0.element, count: counts[$0.element] ?? 0) }
  }

  /// The last `limit` calls, in the order they were made.
  public func mostRecent(_ limit: Int) -> [ToolCall] {
    guard limit > 0 else { return [] }
    return Array(calls.suffix(limit))
  }

  /// How many calls came back marked `is_error`.
  ///
  /// A floor, not a total: a failure whose result fell outside the window is not counted.
  /// Under-reporting is the safer error, because over-reporting marks a call that succeeded.
  /// In practice a first page's window covers almost every call's result.
  public var failedCount: Int {
    calls.filter { $0.outcome == .failed }.count
  }

  /// The call the agent is waiting on, when this run ends the page. See
  /// `ToolCall.Outcome.pending` for why only the last call can carry it.
  public var pendingCall: ToolCall? {
    guard let last = calls.last, last.outcome == .pending else { return nil }
    return last
  }
}

/// How a spawn line finds the sub-agent's own file.
///
/// A plain `Agent` call's meta file carries the unique `toolUseId`, so it is searched for
/// across the project directory. An in-process teammate's meta carries only its `name`,
/// which is unique within one session, so it is searched for under the spawning session.
/// See `TranscriptReader.subagentFile`.
public enum SubagentLink: Hashable, Sendable {
  /// The spawn's own `tool_use` id.
  case toolUse(id: String)
  /// A teammate's `name`, from the call's `input["name"]`.
  case teammate(name: String)
  /// The sub-agent's own `agentId`, which names its file, `agent-<agentId>.jsonl`. Exact, so
  /// the chat's sub-agent list links by it: a teammate respawned under one name has a file
  /// per spawn, and a name would open only the newest.
  case agent(id: String)
}

/// One turn in a conversation: something a person said, something the agent said, or a
/// run of tool calls between the two.
///
/// Every case is decided by a typed field in the session file (`type`, `isMeta`, the
/// block's `type`), never by a glyph, colour or indent. On the pane's screen, composer text
/// carries the same `❯` as a sent turn.
public struct TranscriptTurn: Identifiable, Hashable, Sendable {
  public enum Speech: Hashable, Sendable {
    /// Something a person typed. Not injected text, and not a tool result.
    case human(String)
    /// The agent's words: the `text` of an assistant record, without its thinking.
    case assistant(String)
    case tools(ToolRun)
    /// One agent talking to another, relayed into this session. Never a person, and never
    /// this pane's own agent.
    case agentEvent(AgentEvent)
  }

  /// One inter-agent event, as much of it as is worth showing.
  ///
  /// A `<teammate-message>` envelope is machine text, so drawing it as speech would invent a
  /// speaker, and dropping it would hide most of a team session. It is drawn as a muted line.
  ///
  /// Every field is read off the envelope. The sender is the wrapper's `teammate_id`. The
  /// summary is the JSON's `summary` or the tag's `summary` attribute, and `nil` when
  /// neither exists, which is common. `TranscriptChatCopy` decides what a `nil` shows as.
  public struct AgentEvent: Hashable, Sendable {
    /// Which shape the record carried. An idle notification and a message read differently
    /// when there is no summary, so getting this wrong states something that did not happen.
    public enum Kind: Hashable, Sendable {
      /// A teammate sending words to this session.
      case message
      /// A teammate reporting that it has gone idle: `idleReason` on the embedded JSON.
      case idle
      /// This session spawning a sub-agent: an `Agent` call.
      ///
      /// This and the next two are this session's side of the same traffic. They come from
      /// a `tool_use` block rather than an envelope, and draw as the same muted line.
      case spawned
      /// This session stopping a sub-agent: a `TaskStop` call.
      case stopped
      /// This session messaging a teammate: a `SendMessage` call.
      case sent

      /// Whether this event came from a `tool_use` block rather than a relayed envelope.
      /// `Transcript.pendingToolCall` needs it, because such an event can end the page
      /// after the run it split.
      public var isThisSessionsOwnCall: Bool {
        switch self {
        case .message, .idle: false
        case .spawned, .stopped, .sent: true
        }
      }
    }

    /// The sending teammate's id, `eng-6`. Empty when the envelope named nobody, and the
    /// line then leaves it out.
    public let sender: String
    /// The one-line summary the envelope carried, or `nil` when it carried none.
    public let summary: String?
    /// The full body, shown when the line is expanded. An empty body offers no expansion.
    ///
    /// The harness boilerplate after the closing tag is never in here, because the parse
    /// takes only what is between the tags.
    public let body: String
    public let kind: Kind
    /// Where the spawned agent has got to. Only a `.spawned` event carries one, and only when
    /// the page says. `nil` makes no claim.
    public let task: TaskProgress?
    /// Which sub-agent file this spawn opens. Only a `.spawned` event in a pane's own
    /// conversation carries one, when the record gave something to link by. `nil` is not
    /// tappable.
    public let link: SubagentLink?
    /// The spawned agent's `agentId`, from the spawn's answer, when the page carried it. Only a
    /// `.spawned` event carries one. It names the agent's file, so the chat's sub-agent list
    /// joins a row to its own spawn line by it; see `SubagentList.rows(merging:asOf:)`.
    public let agentID: String?

    public init(
      sender: String, summary: String?, body: String, kind: Kind, task: TaskProgress? = nil,
      link: SubagentLink? = nil, agentID: String? = nil
    ) {
      self.sender = sender
      self.summary = summary
      self.body = body
      self.kind = kind
      self.task = task
      self.link = link
      self.agentID = agentID
    }

    /// The same event, with `task` replaced. Keeps the link and the agent id, because
    /// `settleSpawns` rebuilds every teammate through here.
    public func with(task: TaskProgress?) -> AgentEvent {
      AgentEvent(
        sender: sender, summary: summary, body: body, kind: kind, task: task, link: link,
        agentID: agentID)
    }

    /// The same event, with `agentID` replaced.
    public func with(agentID: String?) -> AgentEvent {
      AgentEvent(
        sender: sender, summary: summary, body: body, kind: kind, task: task, link: link,
        agentID: agentID)
    }

    /// The back bar's title for this spawn's sub-agent: the spawn's name, or its description
    /// when `sender` is empty.
    public var subagentTitle: String {
      sender.isEmpty ? (summary ?? "") : sender
    }

    /// The same event, with `link` replaced.
    public func with(link: SubagentLink?) -> AgentEvent {
      AgentEvent(
        sender: sender, summary: summary, body: body, kind: kind, task: task, link: link,
        agentID: agentID)
    }

    /// Whether there is anything to reveal, so a view knows whether the line is tappable.
    public var hasBody: Bool {
      !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  /// The session file's own record identifier, so re-reads answer with the same ids and a
  /// pager can join overlapping pages.
  ///
  /// A run takes the id of the record that opened it, so a run cut by the page boundary
  /// gets a different id from the whole one. The join has to tolerate that.
  public let id: String
  public let speech: Speech
  /// When the record was written, or `nil` if it did not say.
  public let at: Date?
  /// Whether this human turn is a slash command (`/run-tests`) or a `!` bash line.
  ///
  /// Read from Claude Code's own envelope (`<command-name>`, `<bash-input>`), not guessed
  /// from the text, so "/run-tests" inside a sentence is an ordinary turn. Commands are
  /// common and read badly as prose.
  public let isCommand: Bool
  /// How many images travelled with this turn. A count so a view can say `2 images`, and
  /// separate from the text so an image-only message still becomes a turn.
  public let attachedImages: Int
  /// The images whose pixels arrived, in record order.
  ///
  /// Differs from `attachedImages`: an oversized image, corrupt base64 and a host path all
  /// count there and are absent here. So `images.count <= attachedImages`, and the count
  /// keeps the `N images` label honest. See `TranscriptImage`.
  public let images: [TranscriptImage]
  /// How long the agent worked on this turn, in milliseconds, when the file said.
  ///
  /// From Claude Code's `system` record with subtype `turn_duration`, never from
  /// timestamps, whose difference includes the person's own time. `nil` for any turn that
  /// is not the agent's words, and when the record was outside the page.
  public let durationMs: Double?
  /// Whether this human-shaped turn is the prompt a parent session wrote.
  ///
  /// Only `true` inside a sub-agent file (`TranscriptFile.isSubagentFile`, read by
  /// `TranscriptParser.page(from:forSubagentFile:)`). The record is the one with
  /// `parentUuid: null` and no `origin`, which tells it apart from a later message sent to
  /// the sub-agent. A `Bool` rather than a `Speech` case, so views that switch over
  /// `Speech` stay unchanged.
  public let isParentPrompt: Bool

  public init(
    id: String,
    speech: Speech,
    at: Date? = nil,
    isCommand: Bool = false,
    attachedImages: Int = 0,
    images: [TranscriptImage] = [],
    durationMs: Double? = nil,
    isParentPrompt: Bool = false
  ) {
    self.id = id
    self.speech = speech
    self.at = at
    self.isCommand = isCommand
    self.attachedImages = attachedImages
    self.images = images
    self.durationMs = durationMs
    self.isParentPrompt = isParentPrompt
  }

  /// What was said, for a human or assistant turn.
  ///
  /// Not for an agent event. Readers of this quote what someone in this conversation said,
  /// and returning a teammate's body would put another session's words in this agent's
  /// mouth. The body is reached through `agentEvent`.
  public var text: String? {
    switch speech {
    case .human(let text), .assistant(let text): text
    case .tools, .agentEvent: nil
    }
  }

  /// The inter-agent event this turn is, or `nil` for every turn that is not one.
  public var agentEvent: AgentEvent? {
    guard case .agentEvent(let event) = speech else { return nil }
    return event
  }

  public var toolRun: ToolRun? {
    guard case .tools(let run) = speech else { return nil }
    return run
  }

  public var isHuman: Bool {
    guard case .human = speech else { return false }
    return true
  }

  public var isAssistant: Bool {
    guard case .assistant = speech else { return false }
    return true
  }

  /// A turn that is only an image, so a view draws a placeholder rather than an empty row.
  public var isImageOnly: Bool {
    guard attachedImages > 0 else { return false }
    return (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

/// What Driverr fetched to produce a page, in bytes it can prove. The pager prices itself
/// from this rather than from a literal.
public struct TranscriptWindow: Hashable, Sendable {
  /// What crossed the wire for this page.
  public let bytesFetched: Int
  /// How much of the file's tail the host read to produce it. Usually much larger than
  /// `bytesFetched`, and free, because it never leaves the host.
  public let bytesRead: Int
  /// The whole file as it was when this page was fetched.
  public let fileSizeInBytes: Int
  /// Records the page carried, and the ones Driverr could not read. A byte tail starts
  /// mid-record, so one unreadable record is ordinary. More than one means something else.
  public let records: Int
  public let unreadableRecords: Int
  /// Whether this page reaches the file's first record, so a pager stops offering more.
  public let reachesStartOfFile: Bool
  /// Whether the reader stopped growing this page before it held the turns asked for, with
  /// file still behind it.
  ///
  /// The reader's window climbs a bounded ladder, so a file dense in bytes per turn runs out
  /// of rungs. Without this bit, `Last 2 turns` from that case reads like a two-turn
  /// session. Never `true` with `reachesStartOfFile`.
  public let stoppedShort: Bool

  public init(
    bytesFetched: Int,
    bytesRead: Int,
    fileSizeInBytes: Int,
    records: Int,
    unreadableRecords: Int = 0,
    reachesStartOfFile: Bool = false,
    stoppedShort: Bool = false
  ) {
    self.bytesFetched = bytesFetched
    self.bytesRead = bytesRead
    self.fileSizeInBytes = fileSizeInBytes
    self.records = records
    self.unreadableRecords = unreadableRecords
    self.reachesStartOfFile = reachesStartOfFile
    self.stoppedShort = stoppedShort && !reachesStartOfFile
  }

  public static let none = TranscriptWindow(
    bytesFetched: 0,
    bytesRead: 0,
    fileSizeInBytes: 0,
    records: 0
  )

  /// The same window, marked as stopped short. A rebuild, because the reader learns this one
  /// round trip after building the window.
  public func stoppingShort() -> TranscriptWindow {
    TranscriptWindow(
      bytesFetched: bytesFetched,
      bytesRead: bytesRead,
      fileSizeInBytes: fileSizeInBytes,
      records: records,
      unreadableRecords: unreadableRecords,
      reachesStartOfFile: reachesStartOfFile,
      stoppedShort: true
    )
  }
}

/// How a page ended. A value rather than a thrown error, because all three are ordinary and
/// the UI draws each differently.
public enum TranscriptOutcome: Hashable, Sendable {
  /// Turns parsed, and the file ends on a record boundary.
  case parsed
  /// Turns parsed, then the file stops mid-record: a session being written, or an agent
  /// killed mid-write. Show what parsed and name the tail.
  case endsMidRecord
  /// Records parsed and none was a turn. Most likely another agent's file.
  case noReadableTurns
}

/// A page of an agent's conversation, and what is needed to say what it is.
public struct Transcript: Hashable, Sendable {
  public let turns: [TranscriptTurn]
  public let outcome: TranscriptOutcome
  public let window: TranscriptWindow
  /// How much context the conversation fills, from the newest record in the page that says.
  /// `nil` for Codex and for pages with no usage.
  ///
  /// On the page, not a turn: a record carrying only a tool call joins the open run and
  /// makes no turn, and it is often the newest record with usage.
  public let contextUsage: ContextUsage?
  /// Set when the agent's newest record is a failed API request. See `AgentStop`. On the
  /// page for `contextUsage`'s reason.
  public let agentStop: AgentStop?

  /// `outcome` is derived, so it cannot disagree: no turns is `noReadableTurns`, and a clean
  /// tail with turns is `parsed`.
  public init(
    turns: [TranscriptTurn],
    endsMidRecord: Bool = false,
    window: TranscriptWindow,
    contextUsage: ContextUsage? = nil,
    agentStop: AgentStop? = nil
  ) {
    self.turns = turns
    self.window = window
    self.contextUsage = contextUsage
    self.agentStop = agentStop
    if turns.isEmpty {
      outcome = .noReadableTurns
    } else {
      outcome = endsMidRecord ? .endsMidRecord : .parsed
    }
  }

  public static let empty = Transcript(turns: [], window: .none)

  /// The same page with its window marked as stopped short. `endsMidRecord` is recovered
  /// from `outcome`. `contextUsage` and `agentStop` carry over, because it is still the
  /// newest page.
  public func stoppingShort() -> Transcript {
    Transcript(
      turns: turns,
      endsMidRecord: outcome == .endsMidRecord,
      window: window.stoppingShort(),
      contextUsage: contextUsage,
      agentStop: agentStop
    )
  }

  /// The agent's last words, for the Needs-you row. `nil` when the page has none, with no
  /// fallback to the screen.
  ///
  /// A standing stop is the last word, because the parser hides the stop's own turn.
  public var lastAssistantMessage: String? {
    if let agentStop, !agentStop.message.isEmpty { return agentStop.message }
    return turns.last { $0.isAssistant }?.text
  }

  /// The last thing a person typed.
  public var lastHumanMessage: String? {
    turns.last { $0.isHuman }?.text
  }

  /// When anything was last written to this conversation, for how long a pane has waited.
  ///
  /// The last dated turn, not the last assistant message, because a pane at a permission
  /// prompt went quiet when its tool run stopped. Dated, because one undated tail record
  /// would otherwise erase the age. This is the host's clock. A standing stop's time counts
  /// too, taking the later of the two, because a relayed event can arrive after it.
  public var lastActivity: Date? {
    let turnActivity = turns.reversed().first { $0.at != nil }?.at
    guard let stoppedAt = agentStop?.at else { return turnActivity }
    return max(stoppedAt, turnActivity ?? stoppedAt)
  }

  /// The tool call the agent is waiting on, when the page ends on one.
  ///
  /// A permission prompt writes nothing until answered, so on disk it is a trailing
  /// `tool_use` with no `tool_result`. This names the call, so the reader can see what they
  /// are approving. Derived from the last run's `pendingCall`, so it cannot disagree with
  /// the turns. An `AskUserQuestion` not yet written to the file is
  /// `questionCall(screen:agentStatus:)`'s job.
  public var pendingToolCall: ToolCall? {
    // Search back past agent events: `Agent`, `TaskStop` and `SendMessage` leave the run and
    // become their own turns, so the page can end on one after a pending run. Only the last
    // run can carry a pending call, so this cannot report an older one.
    turns.reversed().first { $0.toolRun != nil }?.toolRun?.pendingCall
  }
}
