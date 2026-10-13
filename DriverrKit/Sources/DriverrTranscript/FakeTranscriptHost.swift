#if DEBUG
import DriverrCore
import Foundation

/// A host that answers `TranscriptReader`'s commands from a fixture, so a screen that
/// draws a transcript can be driven without a machine. It lives in this module because
/// Claude's JSONL is this module's to know.
///
/// It serves a **directory**, not a file, so the ambiguity refusal, the picker and the
/// pick are reachable without a host.
///
/// **Ages are relative to when the command runs.** A fixture pinned to a date would read
/// "4m" today and "223d" in six months, in every screenshot.
public struct FakeTranscriptHost: Sendable {
  /// A real 512x512 PNG as base64, about 4 KB encoded, for image blocks.
  ///
  /// **Real bytes a decoder accepts.** A payload that does not decode draws the same
  /// `N images` label an absent one does, so thumbnail tests would pass with decoding
  /// broken. It is a three-colour mark rather than a flat square, so a capture can be told
  /// from the placeholder, and 512 px so `ImageUpscaleCap` does not shrink it to nothing.
  /// It proves the shape; `TranscriptImage.maxEncodedBytes` is sized against real payloads.
  public static let tinyPNG = """
    iVBORw0KGgoAAAANSUhEUgAAAgAAAAIACAIAAAB7GkOtAAALcUlEQVR42u3VQQ2AMBQFwepABAKRgFKOXHoHFSRl\
    J1kF7c+bMee9RNtxSvq469z148YqADBAAoC6ADBAAoC6ADBAAoC6ADBAAoC6ADBAAoC6ADBAAoC6ADBAAoC6ADBA\
    AoC6ADBAAoC6ADBAAoC6ADBAAoC6ADBAAoC6ADBAAoC6ADBAAoC6ADBAAoC6ADBAAoC6ADBAAoC6ADBAAoC6ADBA\
    AoC6ADBAAoC6ADBAAoC6ADBAAoC6ADBAAoC6ADBAAoC6ADBAAoC6ADBAAoC6ADBAAoC6ADBAAgAAbgZIAgAAGCAJ\
    AABggAQAKwkABkgAEAAYIAFAAGCABAABgAESAAQABkgAEAAYIAFAAGCABAABgAESAAQABkgAEAAYIAFAAGCABAAB\
    gAESAAQABkgAEAAYIAFAAGCABAABgAESAAQABkgAEAAYIAFAAGCABAABgAESAAQABkgAAIAYIAEAAGKABAAAiAEC\
    gP4KwPvHhpsBEgCiADCAARIAugAwgAESALoAMIABEgC6ADCAARIAugAwgAESALoAMIABEgC6ADCAARIAugAwgAGS\
    iewCwAAGCADqAsAABggA6gLAAAYIAOoCwAAGCADqAsAABggA6gLAAAYIAOoCwAAGCADqAsAABggA6gLAAAYIAOoC\
    wAAGCADqAsAABggA6gLAAAYIAOoCwAAGCADqAsAABggA6gLAAAYIAOoCwAAGCADqAsAABggA6gLAAAYIAOoCwAAG\
    CADqAsAABggA6gLAAAYIAOoCwAAGCADqAsAABggA6gLAAAYIAOoCwAAGCADqAsAABggA6gLAAAYIAOoCwAAGCADq\
    AsAABggA6gLAAAYIAOoCwAAGCADqAsAABggA6gLAAAYIAOoCwAAGCADqAsAABggA6gLAAAYIAOoCwAAGCADqAsAA\
    BggA6gLAAAYIAOoCwAAGCADqAsAABggA6gLAAAYIAOoCwAAGCADqAsAABggA6gLAAAYIAOoCwAAGCADqAsAABggA\
    6gLAAAYIAOoCwAAGCADqAsAABggA6gLAAAYIAOoCwAAGCADqAsAABggA6gLAAAYIAOoCwAAGCADqAsAABggA6gLA\
    AAYIAOoCwAAGCADqAsAABggA6gLAAAYIAOoCwAAGCADqAsAABggA6gLAAAYIAOoCwAAGCADqAsAABggA6gLAAAYI\
    AOoCwAAGCADqAsAABggA6gLAAAYIAOoCwAAGCADqAsAABggA6gLAAAYIAOoCwAAGCADqAsAABggAGuXjNtwMEAAA\
    wAAxQAAAAAPEAAEAAAwQAwAgADBADACAAMAAMQAAAgADxABp3QDAAAZIABADGCABQIabARIAGCAGSABggBggAYAB\
    YoAEAAaIARIAGCAGSABggBggAYABYoAEAAaIARIAGCAGSABgAAMkAYABDJAEAAYwQBIAGMAASQBgAAMkAYABDJAE\
    AAYwQBIAGMAASQBgAAMkAYABDJAEAAYwQBIAGMAACQBiAAMkAIgBDJAAIAYwQAKAGMAACQBiAAMkAIgBDJAAIAYw\
    QAKAGMAACQBiAAMkAIgBDJAAIAYwQAIAA8QACQAMEAMkADBADJAAwAAxQAIAA8QACQAMEAMkADBADJAAwAAxQAIA\
    A8QACQAMYIAkADCAAZIAwAAGSADwBAxggAQAMYABEgDEAAZIABADGCABQAxggAQAMYABEgDEAAZIABADGCABQAxg\
    gAQAMYABEgDEAAZIABADGCABQAxggAQAMYABEgDEAAZIABADGCABQAxggAQAMYABEgDEAAZIABADGCABgAFigAQA\
    BogBEgAYIAZIAGCAGCAAiAFigAAgBogBAoAYIAYIAGKAGCAAiAFigAAgBjDARQkAYgADJACIAQyQACAGMEACgBjA\
    AAkAYgADJACIAQyQACAGMEACgBjAAAkAYgADJACIAQyQACAGMEACgBjAAAkAYgADJACIAQyQACAGMEACgBjAAAkA\
    YgADBACvIAYwQACQGMAAAUBiAAMEAIkBDBAAJAYwQAAQA2w3AwQAMUAMEADEADFAABADxAABQAwQAwQAMUAMEADE\
    ADFAABADxAABQAwQAwQAMUAMEADEAAZIABADGCABQAxggAQAMYABEgDEAAZIABADGCABQAxggAQAMYABEgDEAAYI\
    ABIDGCAASAxggAAgMYABAoDEAAYIABIDGCAASAxggAAgMYABAoDEAAYIABIDGCAASAxggAAgMYABAoDEAAYIABID\
    GCAASIabAQKAGCAGCABigBggAIgBYoAAIAaIAQKAGCAGCABigBggAIgBYoAAIAaIAQKAGCAGAMAriAEMEAAkBjBA\
    AJAYwAABQGIAAwQAiQEMEAAkBjBAAJAYwAABQGIAAwQAiQEMEAAkBjBAAJAYwAABQGIAAwQAiQEMEAAkBjBAAJAY\
    wAABQGIAAwQAiQEMEAAkBjBAAJAYwAABQGIAAwQAiQEMEAAkBjBAAJAYwAABQAwQAwAgMUAMAIDEADEAABIDxAAA\
    SAwQAwAgMUAMAIDEADEAABIDxAAASAwQAwAgMYABAoDEAAYIABIDGCAASAxggAAgMYABAoDEAAYIABIDGCAASAxg\
    gAAgMYABAoDEAAYIABIDGCAASAxggAAgMYABAoDEAAYIABIDGAAASQxgAAAkMYABAJDEAAYAQBIDGAAASQxgAAAk\
    MYABAJDEAAYAQBIDGAAAiQFiAAAkBogBAJAYIAYAQGKAGAAAiQFiAAAkBogBAJAYIAYAQGKAGAAAiQFiAAAkBjDA\
    RQFAYgADBACJAQwQACQGMEAAkBjAAAFAYgADBACJAQwAgCQGMAAAkhjAAABIYgADACCJAQwAgCQGMAAAkhjAAABI\
    YgADACCJAQwAgCQGMAAAkhjAAABIYgADACCJAQwAgCQGMAAAkhjAAABIYgADACCJAQwAgMQA280AAEgMEAMAIDFA\
    DACAxAAxAAASA8QAAEgMEAMAIDFAaQMAIDFAUQMAIDFAUQMAIDFAUQMAIDFAUQMAIDFAUQMAIDFAUQMAIDFAUQMA\
    IDFAUQMAIDFAUQMAIDFAUQMAIDFAUQMAIDFAUQMAIDFAUQMAIDFAUQMAIDFAUQMAIDFAUQMAIDFAUQMAIDHAdkcN\
    AIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQN\
    AIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQN\
    AIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQN\
    AIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQN\
    AIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQNAIAkBkQN\
    AIAkBkQNAIAkBkQNAIAkBkQDgCQGAECSGAAASWIAACSJAQCQJAYAQJIYAABJYgAAJIkBAJAkBgBAkhgAAEliAAAk\
    iQEAkCQGAECSGAAASWIAACSJAQCQJAYAQJIYAABJYgAAJIkBAJAkBgBAkhgAAEkMsP4AkMQAAEgSAwAgSQwAgCQx\
    AACSxAAASBIDACBJDACAJDEAAJLEAABIEgMAIEkMAIAkMQAAksQAAEgSAwAgSQwAgCQxAACSxAAASBIDACBJDACA\
    JDEAAJLEAABIEgMAIEkMAIAk5Q0AgCRFDQCAJEUNAIAkRQ0AgCRFDQCAJEUNAIAkRQ0AgCRFDQCAJEUNeAClWIpv\
    xllX/AAAAABJRU5ErkJggg==
    """

  public struct Turn: Sendable {
    public enum Speaker: Sendable {
      case human
      case assistant
      /// A consecutive run of tool calls, as one turn.
      ///
      /// The calls are written back out as `tool_use` blocks, so the fixture goes through the
      /// real parse. A run built directly would prove the view draws a value nothing
      /// produced; every fixture here follows that rule.
      ///
      /// **Each call's `outcome` decides its result line.** `.unknown` and `.succeeded` write
      /// one, `.failed` writes one marked as an error, and `.pending` writes none, which is
      /// the only way to get `Transcript.pendingToolCall` without a real permission prompt.
      case tools([ToolCall])
      /// One `user` record relaying one or more teammates' events.
      ///
      /// Written as the **whole envelope**: preface sentence, `<teammate-message>` tag
      /// with attributes, body, and the boilerplate after the closing tag. Without the
      /// boilerplate, a parser that renders it would pass. A list, because a record with two
      /// blocks catches a parse that takes only the first.
      case teammate([TeammateEvent])
      /// One assistant record's `tool_use` blocks: ordinary calls and this session's own agent
      /// traffic, mixed in the order made.
      ///
      /// `tools` cannot express these, because an `Agent` call has three separate fields and a
      /// `ToolCall` has one target. A mixed list, because `Agent`, `Bash`, `Agent` catches a
      /// parse that loses the order; it must come back as event, run, event.
      case toolBlocks([ToolBlock])
      /// A human turn typed as a command, `/run-tests` or `!git status`. Written as the
      /// client's envelope, so it goes through `TranscriptParser.commandTyped(in:)`.
      case command
      /// The record Claude Code writes when an API request fails. `text` is the terminal's
      /// line, `error` the typed kind, `status` the HTTP status if any, and `resetsAt` the
      /// `quotaLimits.resetsAt` (`nil` writes no `quotaLimits`). A date rather than an offset,
      /// so a fixture can put the same time in `text`. Written with the `<synthetic>` model and
      /// all-zero usage, since a non-zero count would become the page's context count.
      case apiError(error: String, status: Int?, resetsAt: Date?)
    }

    /// One `tool_use` block in a record that mixes them. Each case writes the input object that
    /// tool really writes.
    public enum ToolBlock: Sendable {
      /// An ordinary call, written exactly as `tools` writes one.
      case call(ToolCall)
      /// `Agent`: `subagent_type`, the name the team addresses it by, and its task. `launch` is
      /// what its answer says.
      case spawn(
        subagentType: String, name: String, description: String, launch: SpawnLaunch = .sync(durationMs: nil))
      /// A `Bash` call with `run_in_background`. `end` is the notification that ended it, or
      /// `nil` while it runs.
      case background(command: String, description: String, end: TaskEnd? = nil)
      /// `TaskStop`, naming an earlier spawn's `name`. Naming something never spawned gives
      /// the unresolvable case a tail page really holds.
      case stop(taskID: String)
      /// `SendMessage`. An empty `summary` writes only `message`, for the first-line fallback.
      case send(to: String, summary: String, message: String)

      var toolName: String {
        switch self {
        case .call(let call): call.name
        case .spawn: "Agent"
        case .background: "Bash"
        case .stop: "TaskStop"
        case .send: "SendMessage"
        }
      }

      /// What the fake says became of it. Agent traffic succeeds unless it is an unanswered
      /// spawn; a missing result would make the call before it read as waiting.
      var outcome: ToolCall.Outcome {
        switch self {
        case .call(let call): call.outcome
        case .spawn(_, _, _, .unanswered): .pending
        case .spawn, .background, .stop, .send: .succeeded
        }
      }
    }

    /// What an `Agent` call's answer says.
    public enum SpawnLaunch: Sendable {
      /// Answered when the agent was done, with the duration the file states.
      case sync(durationMs: Int?)
      /// Answered at once with `async_launched`; `end` is what later ended it, or `nil`
      /// while it runs.
      case async(agentID: String, end: TaskEnd? = nil)
      /// Answered with `teammate_spawned`. Its end is its own idle notification, which a
      /// `.teammate` turn writes.
      case teammate
      /// No answer yet: a sync spawn the session is still waiting on.
      case unanswered
    }

    /// The record that ended a task, as the task line the host writes for it.
    public struct TaskEnd: Sendable {
      /// The notification's word: `completed`, `failed`, `killed` or `stopped`.
      public let status: String
      public let secondsAgo: TimeInterval
      /// Written as a handback naming the `agentId`, not a notification naming the call.
      public let isHandback: Bool

      public init(status: String = "completed", secondsAgo: TimeInterval, isHandback: Bool = false) {
        self.status = status
        self.secondsAgo = secondsAgo
        self.isHandback = isHandback
      }
    }

    /// One `<teammate-message>` block, in either real shape.
    public struct TeammateEvent: Sendable {
      public enum Shape: Sendable {
        /// JSON inside the block. The only shape an idle notification takes.
        case idleNotification
        /// A `summary="…"` attribute on the tag and a markdown body.
        case message
      }

      public let sender: String
      /// `nil` writes a block with **no summary anywhere**, the commonest real shape and the
      /// only way to exercise the fallback wording.
      public let summary: String?
      public let body: String
      public let shape: Shape

      public init(sender: String, summary: String? = nil, body: String = "", shape: Shape) {
        self.sender = sender
        self.summary = summary
        self.body = body
        self.shape = shape
      }
    }

    public let speaker: Speaker
    /// The `tool_use` blocks this turn writes, or `nil`. One accessor, so the record writer
    /// and the result-line writer cannot disagree.
    var writtenBlocks: [ToolBlock]? {
      switch speaker {
      case .tools(let calls): calls.map(ToolBlock.call)
      case .toolBlocks(let blocks): blocks
      case .human, .assistant, .teammate, .command, .apiError: nil
      }
    }

    /// What was said. Empty for a tool run and for a teammate relay, which carries its own
    /// bodies.
    public let text: String
    /// How long before the command runs this record was written.
    public let secondsAgo: TimeInterval
    /// How many images travelled with a human turn, written as `image` blocks beside the text.
    public let attachedImages: Int
    /// Base64 payloads for the first `n` of those blocks.
    ///
    /// **Shorter than `attachedImages` on purpose** when a fixture wants the placeholder. A
    /// block with a payload draws a thumbnail; one without draws the `N images` label. Use
    /// `FakeTranscriptHost.tinyPNG` unless a test needs something else; an invalid string
    /// reaches the corrupt-payload path.
    public let imagePayloads: [String]
    /// How long the agent worked on this turn, in milliseconds. On an assistant turn it adds
    /// the `turn_duration` `system` record after it. `nil` writes nothing.
    public let durationMs: Double?

    public init(
      speaker: Speaker,
      text: String = "",
      secondsAgo: TimeInterval,
      attachedImages: Int = 0,
      imagePayloads: [String] = [],
      durationMs: Double? = nil
    ) {
      self.speaker = speaker
      self.text = text
      self.secondsAgo = secondsAgo
      self.attachedImages = attachedImages
      self.imagePayloads = imagePayloads
      self.durationMs = durationMs
    }
  }

  /// One session file in the fixture's directory.
  public struct Session: Sendable {
    /// The file's name without its extension. Match a pane's `agent_session` to get tier 1;
    /// differ to get the reported-session-missing path.
    public let sessionID: String
    /// Whether the file stops mid-record, the one chat failure drawn under turns that did
    /// parse.
    ///
    /// It sets the **header** and leaves the records whole. That is faithful: `readCommand`
    /// reports this from the final byte, and nothing infers it from a failed parse.
    public let endsMidRecord: Bool
    /// What the file says its size is, when larger than its records. Set it above the
    /// reader's ladder ceiling to get a page with something behind it; otherwise a fixture
    /// is always read to its front. Header only, like `endsMidRecord`.
    public let fileSizeInBytes: Int?
    /// The session this one was continued into. The fake answers the continuation command
    /// as a host whose file ends in `continued-in` would. Only meaningful with several
    /// sessions, since a handover names a sibling file.
    ///
    /// It answers the command rather than writing the record, which is faithful:
    /// `recordSelector` never sends a `continued-in` record either.
    public let continuedInto: String?
    public let turns: [Turn]

    public init(
      sessionID: String,
      turns: [Turn],
      endsMidRecord: Bool = false,
      fileSizeInBytes: Int? = nil,
      continuedInto: String? = nil
    ) {
      self.sessionID = sessionID
      self.turns = turns
      self.endsMidRecord = endsMidRecord
      self.fileSizeInBytes = fileSizeInBytes
      self.continuedInto = continuedInto
    }

    var fileName: String { "\(sessionID).\(ClaudeProjects.fileExtension)" }
  }

  /// One Codex rollout the fake serves.
  ///
  /// A separate type from `Session`, because a rollout shares almost nothing with it: no
  /// project directory, no continuation, no truncation or size seams. It shares `Turn`, so
  /// a test writes one conversation for either agent. The records follow the shape
  /// `CodexFixture` in `DriverrTranscriptTests` takes from a real rollout.
  public struct CodexSession: Sendable {
    /// The rollout's `payload.id`. Match a pane's session value to get tier 1; differ to
    /// get the `cwd` match.
    public let id: String
    /// The working directory, matched exactly against the pane's `directory`.
    public let cwd: String
    public let turns: [Turn]

    public init(id: String, cwd: String, turns: [Turn]) {
      self.id = id
      self.cwd = cwd
      self.turns = turns
    }

    /// `rollout-<timestamp>-<uuid>.jsonl` in a day directory, the real layout. The uuid sits
    /// mid-name, which is why tier 1 matches the header's `id`.
    var fileName: String { "rollout-2026-09-11T16-43-31-\(id).\(CodexRollouts.fileExtension)" }
    var path: String { "/home/carson/.codex/sessions/2026/09/11/\(fileName)" }
  }

  /// One sub-agent's own file, and the two fields its `.meta.json` links it by.
  ///
  /// A separate type, because a sub-agent file has `isSidechain:true` on every record and no
  /// `origin` on its opening prompt, which `Session`'s writer never produces.
  public struct SubagentFixture: Sendable {
    /// `agent-<agentID>.jsonl` beside `agent-<agentID>.meta.json`.
    public let agentID: String
    /// The meta file's `toolUseId`, or `nil` for a teammate, whose meta has none.
    public let toolUseID: String?
    /// The meta file's `name`. Only a teammate's is ever searched for.
    public let name: String?
    /// Whether the meta file's `taskKind` is `in_process_teammate`. Set explicitly, because
    /// a teammate's content does not differ from a plain sub-agent's.
    public let isTeammate: Bool
    /// How long ago the file was written; decides "the newest wins" when names collide.
    public let secondsAgo: TimeInterval
    /// The opening prompt, written by the parent, with `parentUuid: null` and no `origin`.
    public let prompt: String
    /// What the sub-agent said and did after its prompt. Only `.human`, `.assistant` and
    /// `.tools` are written; see `subagentRecord`.
    public let turns: [Turn]
    /// What the file says its size is, as `Session.fileSizeInBytes`.
    public let fileSizeInBytes: Int?

    public init(
      agentID: String,
      toolUseID: String? = nil,
      name: String? = nil,
      isTeammate: Bool = false,
      secondsAgo: TimeInterval = 60,
      prompt: String,
      turns: [Turn] = [],
      fileSizeInBytes: Int? = nil
    ) {
      self.agentID = agentID
      self.toolUseID = toolUseID
      self.name = name
      self.isTeammate = isTeammate
      self.secondsAgo = secondsAgo
      self.prompt = prompt
      self.turns = turns
      self.fileSizeInBytes = fileSizeInBytes
    }

    var fileName: String { "agent-\(agentID).jsonl" }
    var metaFileName: String { "agent-\(agentID).meta.json" }
  }

  /// One installed skill or command the host offers.
  ///
  /// **Written back out as frontmatter**, so `SkillFrontmatter` parses it as it would a real
  /// `SKILL.md`. The folded `description: >-` block is the shape a parser gets wrong.
  public struct Skill: Sendable {
    /// The bare name, no slash: `run-tests`, or `acme:sync-files` for a plugin's.
    public let name: String
    /// The description, or `nil` for a file with no frontmatter, the usual
    /// `.claude/commands/*.md`.
    public let description: String?
    /// Whether the description is a **folded block** across several lines. Most real user
    /// skills fold, and a parser that reads only the marker line gives them an empty caption.
    public let isFolded: Bool
    public let scope: Scope

    public enum Scope: Sendable {
      case user
      case project
      case command
      case plugin
    }

    public init(
      name: String,
      description: String? = nil,
      isFolded: Bool = false,
      scope: Scope = .user
    ) {
      self.name = name
      self.description = description
      self.isFolded = isFolded
      self.scope = scope
    }
  }

  /// The expanded project directory the listing echoes back, from which every absolute path
  /// is built.
  public let directory: String
  public let sessions: [Session]
  /// What this host has installed. Empty answers with no output, which is a host offering
  /// nothing, so the composer falls back to the transcript-mined list.
  public let skills: [Skill]
  /// Makes the host refuse the continuation command.
  ///
  /// Following a handover improves an answer the resolver already holds, so this failure
  /// must leave tier 1 as it was. The listing and read still work, so a test can tell "the
  /// redirect was skipped" from "the host is gone".
  public let continuationCommandFails: Bool
  /// The Codex rollouts this host holds. Empty answers the Codex listing with a clock and no
  /// candidates, so a Codex pane resolves `noSessionFiles`.
  public let codexSessions: [CodexSession]
  /// The sub-agent files this host holds. Empty answers the link commands with no candidates.
  ///
  /// Held flat rather than under a `Session`: the fake's link and read are keyed on the
  /// sub-agent filename and the meta literal, never on which session asked. Distinct
  /// filenames are enough for two sessions' traffic.
  public let subagents: [SubagentFixture]

  /// One session in a directory, the ordinary fixture.
  public init(
    sessionID: String,
    directory: String = "/home/carson/.claude/projects/-home-carson-dev-driverr",
    turns: [Turn],
    endsMidRecord: Bool = false,
    fileSizeInBytes: Int? = nil,
    codexSessions: [CodexSession] = [],
    subagents: [SubagentFixture] = []
  ) {
    self.init(
      directory: directory,
      sessions: [
        Session(
          sessionID: sessionID,
          turns: turns,
          endsMidRecord: endsMidRecord,
          fileSizeInBytes: fileSizeInBytes
        )
      ],
      codexSessions: codexSessions,
      subagents: subagents
    )
  }

  /// Several sessions in one directory.
  public init(
    directory: String = "/home/carson/.claude/projects/-home-carson-dev-driverr",
    sessions: [Session],
    continuationCommandFails: Bool = false,
    skills: [Skill] = [],
    codexSessions: [CodexSession] = [],
    subagents: [SubagentFixture] = []
  ) {
    self.directory = directory
    self.sessions = sessions
    self.continuationCommandFails = continuationCommandFails
    self.skills = skills
    self.codexSessions = codexSessions
    self.subagents = subagents
  }

  /// This fixture with installed skills behind it. A builder rather than an initialiser
  /// argument, because which conversation a launch serves and whether the host has skills
  /// are independent choices.
  public func offering(_ skills: [Skill]) -> FakeTranscriptHost {
    FakeTranscriptHost(
      directory: directory,
      sessions: sessions,
      continuationCommandFails: continuationCommandFails,
      skills: skills,
      codexSessions: codexSessions,
      subagents: subagents
    )
  }

  /// This fixture with Codex rollouts behind it. A builder, for `offering(_:)`'s reason.
  public func serving(_ codexSessions: [CodexSession]) -> FakeTranscriptHost {
    FakeTranscriptHost(
      directory: directory,
      sessions: sessions,
      continuationCommandFails: continuationCommandFails,
      skills: skills,
      codexSessions: codexSessions,
      subagents: subagents
    )
  }

  /// This fixture with sub-agent files behind it. A builder, for `offering(_:)`'s reason.
  public func serving(_ subagents: [SubagentFixture]) -> FakeTranscriptHost {
    FakeTranscriptHost(
      directory: directory,
      sessions: sessions,
      continuationCommandFails: continuationCommandFails,
      skills: skills,
      codexSessions: codexSessions,
      subagents: subagents
    )
  }

  /// The runner to hand `TranscriptReader(run:)`.
  ///
  /// It answers by **shape**, because each command carries a slug, a byte window or a file
  /// list, and keying on exact strings would mean rebuilding them here. Several commands
  /// share markers (`date +%s`, `tail -c`, `wc -c`, `stat -c %Y`), so **the branch order
  /// matters**: a branch reached too early answers the wrong question with a well-formed
  /// reply, and nothing reports it.
  public var run: CommandRunner {
    { command in
      let now = Date()
      // **Codex first.** The Codex listing carries `date +%s` and the Codex read carries
      // `tail -c` and `wc -c`. Keyed on the rollout root and the file path, which no Claude
      // command contains.
      if command.contains(CodexRollouts.root) { return ok(codexListing(asOf: now)) }
      if let session = codexSession(named: command) {
        // The growth probe also names the file; only it carries `stat`.
        if command.contains(TranscriptCommands.statModified) {
          return ok(codexStamp(of: session, asOf: now))
        }
        return ok(codexPage(of: session, for: command, asOf: now))
      }
      // **Before the listing and stamp branches**, because the link command carries both
      // `date +%s` and `stat -c %Y`. Keyed on `grep -lF` and `grep -rlF`, which nothing else
      // writes.
      if command.contains("grep -lF") || command.contains("grep -rlF") {
        return ok(subagentLinkAnswer(for: command, asOf: now))
      }
      if command.contains("date +%s") { return ok(listing(asOf: now)) }
      // Keyed on a mark no other command carries, so its position is a convenience.
      if command.contains(TranscriptCommands.frontmatterSelector) { return ok(skillsAnswer()) }
      // **Before the `tail -c` branch**, because the continuation command reads a byte tail
      // and would be answered with a page.
      if command.contains(TranscriptCommands.continuationSelector) {
        guard !continuationCommandFails else {
          // A dead channel, which the reader reads off the exit status.
          return CommandResult(
            standardOutput: "",
            standardError: "Connection closed by remote host\n",
            exitStatus: 255
          )
        }
        return ok(continuations(for: command))
      }
      // **Before the `tail -c` branch**, because the read also carries `wc -c`. Keyed on the
      // GNU `stat` spelling, which `listCommand` also carries; the listing is answered above.
      if command.contains(TranscriptCommands.statModified) {
        return ok(stamp(for: command, asOf: now))
      }
      if command.contains("tail -c") { return ok(page(for: command, asOf: now)) }
      if command.contains("FNR>") { return ok(briefs(for: command)) }
      // Anything else gets a shell's 127, which callers branching on exit status expect.
      return CommandResult(
        standardOutput: "",
        standardError: "\(command): command not found\n",
        exitStatus: 127
      )
    }
  }

  /// Which session a command is about. Every command that names a file names it by filename.
  private func session(named command: String) -> Session? {
    sessions.first { command.contains($0.fileName) }
  }

  /// Which sub-agent file a command is about, by the same rule.
  private func subagentFixture(named command: String) -> SubagentFixture? {
    subagents.first { command.contains($0.fileName) }
  }

  // MARK: - A sub-agent's own file

  /// The literal a `subagentLinkCommand` searched for, read back out of its `-e '<literal>'`.
  private static func subagentLinkLiteral(in command: String) -> String? {
    guard let open = command.range(of: "-e '") else { return nil }
    let rest = command[open.upperBound...]
    guard let close = rest.firstIndex(of: "'") else { return nil }
    return String(rest[rest.startIndex..<close])
  }

  /// `listCommand`'s shape, so `TranscriptReader.listing(from:)` reads it as a real answer.
  private func subagentLinkAnswer(for command: String, asOf now: Date) -> String {
    let epoch = Int(now.timeIntervalSince1970)
    let dir = "\(directory)/subagents"
    guard let literal = Self.subagentLinkLiteral(in: command) else {
      return [String(epoch), dir].joined(separator: "\n") + "\n"
    }
    let matches = subagents.filter { fixture in
      if let toolUseID = fixture.toolUseID, literal == #""toolUseId":"\#(toolUseID)""# {
        return true
      }
      if let name = fixture.name, literal == #""name":"\#(name)""# { return true }
      return false
    }
    let lines = matches.map { fixture -> String in
      let mtime = epoch - Int(fixture.secondsAgo)
      let size = fixture.fileSizeInBytes ?? subagentRecords(of: fixture, asOf: now).utf8.count
      return "\(mtime)\t\(size)\t\(fixture.fileName)"
    }
    return ([String(epoch), dir] + lines).joined(separator: "\n") + "\n"
  }

  /// The opening prompt (`parentUuid: null`, no `origin`), then the fixture's turns, every
  /// record with `isSidechain:true`. Written by hand, because `record(_:index:sessionID:asOf:)`
  /// always sets `origin.kind`.
  private func subagentRecords(of fixture: SubagentFixture, asOf now: Date) -> String {
    let promptID = "\(fixture.agentID)-0"
    let promptAt = now.addingTimeInterval(-fixture.secondsAgo).formatted(.iso8601)
    var lines = [
      """
      {"parentUuid":null,"isSidechain":true,"type":"user","uuid":"\(quoted(promptID))",\
      "timestamp":"\(quoted(promptAt))",\
      "message":{"role":"user","content":"\(quoted(fixture.prompt))"}}
      """
    ]
    var parent = promptID
    for (offset, turn) in fixture.turns.enumerated() {
      let id = "\(fixture.agentID)-\(offset + 1)"
      let at = now.addingTimeInterval(-turn.secondsAgo).formatted(.iso8601)
      let written = subagentRecord(turn, id: id, parent: parent, at: at)
      guard !written.isEmpty else { continue }
      lines.append(written)
      parent = id
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// One turn of a sub-agent's file: `.human` for a later message, `.assistant` for its
  /// words, `.tools` for a run. Empty for the pane-only shapes. No result or task lines are
  /// written, so every call reads `.unknown`.
  private func subagentRecord(_ turn: Turn, id: String, parent: String, at: String) -> String {
    switch turn.speaker {
    case .human:
      return """
        {"parentUuid":"\(quoted(parent))","isSidechain":true,"type":"user","uuid":"\(quoted(id))",\
        "timestamp":"\(quoted(at))","origin":{"kind":"human"},\
        "message":{"role":"user","content":"\(quoted(turn.text))"}}
        """
    case .assistant:
      return """
        {"parentUuid":"\(quoted(parent))","isSidechain":true,"type":"assistant","uuid":"\(quoted(id))",\
        "timestamp":"\(quoted(at))",\
        "message":{"role":"assistant","content":[{"type":"text","text":"\(quoted(turn.text))"}]}}
        """
    case .tools(let calls):
      let written = calls.enumerated().map { position, call in
        #"{"type":"tool_use","id":"subagent_\#(id)_\#(position)","name":"\#(quoted(call.name))","input":{"file_path":"\#(quoted(call.target ?? ""))"}}"#
      }
      return """
        {"parentUuid":"\(quoted(parent))","isSidechain":true,"type":"assistant","uuid":"\(quoted(id))",\
        "timestamp":"\(quoted(at))",\
        "message":{"role":"assistant","content":[\(written.joined(separator: ","))]}}
        """
    case .toolBlocks, .teammate, .command, .apiError:
      return ""
    }
  }

  // MARK: - Codex rollouts

  private func codexSession(named command: String) -> CodexSession? {
    codexSessions.first { command.contains($0.fileName) }
  }

  /// `date`, then one line per rollout. No directory line, because each rollout's full path
  /// is printed.
  private func codexListing(asOf now: Date) -> String {
    let epoch = Int(now.timeIntervalSince1970)
    let separator = String(TranscriptCommands.fieldSeparator)
    let lines = codexSessions.map { session -> String in
      let body = codexRecords(of: session, asOf: now)
      let youngest = session.turns.map(\.secondsAgo).min() ?? 0
      return [
        session.path,
        session.cwd,
        CodexRollouts.mainThreadSource,
        session.id,
        "\(epoch - Int(youngest))",
        "\(body.utf8.count)",
      ].joined(separator: separator)
    }
    return ([String(epoch)] + lines).joined(separator: "\n") + "\n"
  }

  /// `mtime<TAB>size`, from the same record body as the listing, for `stamp(for:asOf:)`'s
  /// reason.
  private func codexStamp(of session: CodexSession, asOf now: Date) -> String {
    let body = codexRecords(of: session, asOf: now)
    let youngest = session.turns.map(\.secondsAgo).min() ?? 0
    let modified = Int(now.timeIntervalSince1970) - Int(youngest)
    return "\(modified)\(TranscriptCommands.fieldSeparator)\(body.utf8.count)\n"
  }

  /// The header, the records, the bare `!`, then the outcome lines, as `codexReadCommand`
  /// prints them.
  private func codexPage(of session: CodexSession, for command: String, asOf now: Date) -> String
  {
    let bound = recordBound(from: command)
    let entries = codexEntries(of: session, asOf: now)
    let kept = bound.map { Array(entries.suffix($0)) } ?? entries
    let body = kept.map(\.record).joined(separator: "\n") + "\n"
    let size = codexRecords(of: session, asOf: now).utf8.count
    // Bounded again, because the real command bounds the outcome scan with its own `tail -n`.
    let answered = kept.compactMap(\.outcome)
    let outcomes = [TranscriptCommands.resultMark] + (bound.map { Array(answered.suffix($0)) } ?? answered)
    return "\(size)\tcomplete\n\(body)" + outcomes.joined(separator: "\n") + "\n"
  }

  /// Every turn as Codex records, the whole file, for the listing's and the probe's size.
  private func codexRecords(of session: CodexSession, asOf now: Date) -> String {
    codexEntries(of: session, asOf: now).map(\.record).joined(separator: "\n") + "\n"
  }

  /// One record per line, each with the outcome line the host's scan prints for it, if any.
  /// The page's bound applies to records, as the host's `tail -n` does, since a tool run is
  /// several records and one turn.
  private func codexEntries(
    of session: CodexSession, asOf now: Date
  ) -> [(record: String, outcome: String?)] {
    session.turns.enumerated().flatMap { index, turn in
      codexRecord(turn, index: index, asOf: now)
    }
  }

  /// One turn, as the records Codex writes for it: prose in `event_msg`, tool calls in
  /// `response_item`. `text` and `Text` are both real; see `CodexContentBlock`.
  private func codexRecord(
    _ turn: Turn, index: Int, asOf now: Date
  ) -> [(record: String, outcome: String?)] {
    let at = now.addingTimeInterval(-turn.secondsAgo).formatted(.iso8601)
    switch turn.speaker {
    case .human:
      return [
        (
          codexItem(
            type: "UserMessage", id: "u\(index)", blockType: "text", text: turn.text, at: at),
          nil
        )
      ]
    case .assistant:
      return [
        (
          codexItem(
            type: "AgentMessage", id: "a\(index)", blockType: "Text", text: turn.text, at: at),
          nil
        )
      ]
    case .tools(let calls):
      // **Each call's `outcome` decides its `input` and its outcome line.** `.unknown` writes
      // the command text alone, which has no `cmd:` literal to join, so it stays `.unknown`.
      // Any other outcome writes an `exec_command` call. `.succeeded` and `.failed` add a
      // completion. `.pending` adds none, and reads `.pending` only as the last call of a run
      // that ends the page.
      //
      // `input` is never prefixed with the tool's name. Codex puts the tool in `name`, and
      // the run row draws both, so `"exec ls pages"` would render as `exec  exec ls pages`.
      return calls.enumerated().map { callIndex, call in
        let command = call.target ?? call.name
        let input =
          call.outcome == .unknown
          ? command : "await tools.exec_command({cmd:\"\(quoted(command))\"})"
        let record = """
          {"timestamp":"\(at)","type":"response_item","payload":{          "type":"custom_tool_call","id":"ctc_\(index)_\(callIndex)",          "call_id":"call_\(index)_\(callIndex)","name":"\(quoted(call.name))",          "input":"\(quoted(input))"}}
          """
        let status: String? =
          switch call.outcome {
          case .succeeded: "completed\t0"
          case .failed: "failed\t1"
          case .unknown, .pending: nil
          }
        let outcome = status.map {
          "\(TranscriptCommands.resultMark)exec-\(index)-\(callIndex)\t\($0)\t\(quoted(command))"
        }
        return (record, outcome)
      }
    case .toolBlocks, .teammate, .command, .apiError:
      // Claude-only shapes. Writing nothing shows up as a missing turn rather than a record
      // Codex never writes.
      return []
    }
  }

  private func codexItem(
    type: String, id: String, blockType: String, text: String, at: String
  ) -> String {
    """
    {"timestamp":"\(at)","type":"event_msg","payload":{"type":"item_completed",    "item":{"type":"\(type)","id":"\(id)",    "content":[{"type":"\(blockType)","text":"\(quoted(text))"}]}}}
    """
  }

  private func ok(_ output: String) -> CommandResult {
    CommandResult(standardOutput: output, standardError: "", exitStatus: 0)
  }

  /// `date`, the expanded directory, then one line per session file.
  private func listing(asOf now: Date) -> String {
    let epoch = Int(now.timeIntervalSince1970)
    let lines = sessions.map { session -> String in
      let body = records(of: session, asOf: now, bound: nil)
      let youngest = session.turns.map(\.secondsAgo).min() ?? 0
      return [
        "\(epoch - Int(youngest))",
        "\(body.utf8.count)",
        session.fileName,
      ].joined(separator: String(TranscriptCommands.fieldSeparator))
    }
    return ([String(epoch), directory] + lines).joined(separator: "\n") + "\n"
  }

  /// What this host has installed, in the wire shape `skillsCommand` produces.
  ///
  /// **The frontmatter is written as YAML**, so it goes through `SkillFrontmatter`. A folded
  /// entry is `description: >-` with wrapped, indented lines, the shape a naive parser reads
  /// as empty.
  ///
  /// A skill with no description writes **no frontmatter block**, which is what a
  /// `.claude/commands/*.md` looks like.
  private func skillsAnswer() -> String {
    var lines: [String] = []
    for skill in skills {
      lines.append(
        TranscriptCommands.skillMark + scope(of: skill)
          + String(TranscriptCommands.fieldSeparator) + skill.name
      )
      guard let description = skill.description else { continue }
      lines.append(TranscriptCommands.frontmatterMark + "name: \(skill.name)")
      guard skill.isFolded else {
        lines.append(TranscriptCommands.frontmatterMark + "description: \(description)")
        continue
      }
      lines.append(TranscriptCommands.frontmatterMark + "description: >-")
      for chunk in Self.wrapped(description) {
        lines.append(TranscriptCommands.frontmatterMark + "  " + chunk)
      }
    }
    return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
  }

  /// The scope letter one fixture skill travels under.
  private func scope(of skill: Skill) -> String {
    switch skill.scope {
    case .user: return TranscriptCommands.userSkillScope
    case .project: return TranscriptCommands.projectSkillScope
    case .command: return TranscriptCommands.projectCommandScope
    case .plugin: return TranscriptCommands.pluginSkillScope
    }
  }

  /// Breaks a description into the lines of a folded block. The width is arbitrary; what
  /// matters is that the value continues over lines it did not open.
  private static func wrapped(_ text: String) -> [String] {
    var lines: [String] = []
    var current = ""
    for word in text.split(separator: " ") {
      if current.isEmpty {
        current = String(word)
      } else if current.count + 1 + word.count <= 90 {
        current += " " + word
      } else {
        lines.append(current)
        current = String(word)
      }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
  }

  /// `mtime<TAB>size` for the file the command names.
  ///
  /// **Computed from the same record body as the listing.** The growth watcher compares a
  /// probe with the listing's size, so two answers derived differently would report growth
  /// forever on an untouched file.
  ///
  /// `?` in both fields for a file this fake does not have, which is how a gone file looks.
  private func stamp(for command: String, asOf now: Date) -> String {
    if let fixture = subagentFixture(named: command) {
      let body = subagentRecords(of: fixture, asOf: now)
      let modified = Int(now.timeIntervalSince1970) - Int(fixture.secondsAgo)
      return "\(modified)\(TranscriptCommands.fieldSeparator)\(body.utf8.count)\n"
    }
    guard let session = session(named: command) else {
      return "?\(TranscriptCommands.fieldSeparator)?\n"
    }
    let body = records(of: session, asOf: now, bound: nil)
    let youngest = session.turns.map(\.secondsAgo).min() ?? 0
    let modified = Int(now.timeIntervalSince1970) - Int(youngest)
    return "\(modified)\(TranscriptCommands.fieldSeparator)\(body.utf8.count)\n"
  }

  /// The size-and-completeness header, then the records themselves.
  private func page(for command: String, asOf now: Date) -> String {
    // A sub-agent file is checked first. Its name never collides with a session's, and it
    // has none of a `Session`'s seams; see `subagentRecord`.
    if let fixture = subagentFixture(named: command) {
      let bound = recordBound(from: command)
      let full = subagentRecords(of: fixture, asOf: now)
      let body = bound.map { Self.tail(of: full, records: $0) } ?? full
      let size = fixture.fileSizeInBytes ?? full.utf8.count
      return "\(size)\tcomplete\n\(body)\(TranscriptCommands.resultMark)\n"
    }
    // A read naming no session is a gone file, shown by a `?` size.
    guard let session = session(named: command) else { return "?\tcomplete\n" }
    let bound = recordBound(from: command)
    let body = records(of: session, asOf: now, bound: bound)
    // The size is the **whole** file, never the page: `reachesStartOfFile` is
    // `bytes >= size`, so the page's own size would claim the front was reached.
    //
    // Result lines are not counted, because they never came off the file.
    let size = session.fileSizeInBytes ?? records(of: session, asOf: now, bound: nil).utf8.count
    return "\(size)\t\(session.endsMidRecord ? "partial" : "complete")\n\(body)"
      + resultLines(of: session, bound: bound)
      + taskLines(of: session, bound: bound, asOf: now)
  }

  /// The newest `bound` lines of a block of records. `subagentRecords` writes one line per
  /// record, so it slices lines rather than turns.
  private static func tail(of text: String, records bound: Int) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    return (lines.count > bound ? Array(lines.suffix(bound)) : lines).joined(separator: "\n") + "\n"
  }

  /// One `%` line per task a fixture says ended, as `TranscriptCommands.taskSelector` writes
  /// them. Keyed by call id, or by `agentId` for a handback.
  private func taskLines(of session: Session, bound: Int?, asOf now: Date) -> String {
    var lines: [String] = []
    for (offset, turn) in kept(session, bound: bound) {
      for (position, block) in (turn.writtenBlocks ?? []).enumerated() {
        let key: String
        let end: Turn.TaskEnd
        switch block {
        case .spawn(_, _, _, .async(let agentID, let ended?)):
          key = ended.isHandback ? agentID : callID(index: offset, position: position)
          end = ended
        case .background(_, _, let ended?):
          key = callID(index: offset, position: position)
          end = ended
        default:
          continue
        }
        let at = now.addingTimeInterval(-end.secondsAgo).formatted(.iso8601)
        lines.append(
          [TranscriptCommands.taskMark + key, end.isHandback ? "completed" : end.status, at]
            .joined(separator: String(TranscriptCommands.fieldSeparator)))
      }
    }
    return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
  }

  /// One line per file in the command that names a successor. Nothing for a file that was
  /// never continued.
  private func continuations(for command: String) -> String {
    let lines = sessions.compactMap { session -> String? in
      guard command.contains(session.fileName), let next = session.continuedInto else {
        return nil
      }
      return "\(TranscriptCommands.resultMark)\(session.fileName)"
        + "\(TranscriptCommands.fieldSeparator)\(next)"
    }
    return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
  }

  /// The bare mark that says the results were scanned, then one line per answered call.
  /// Bounded like the page, because the real command bounds both with `tail -n`.
  private func resultLines(of session: Session, bound: Int?) -> String {
    var lines = [TranscriptCommands.resultMark]
    for (offset, turn) in kept(session, bound: bound) {
      guard let blocks = turn.writtenBlocks else { continue }
      for (position, block) in blocks.enumerated() where block.outcome != .pending {
        let failed = block.outcome == .failed ? "1" : "0"
        var fields = ["\(TranscriptCommands.resultMark)\(callID(index: offset, position: position))", failed]
        // The launch fields `TranscriptCommands.resultSelector` adds to a spawn's answer.
        if case .spawn(_, _, _, let launch) = block {
          switch launch {
          case .sync(let durationMs?): fields += ["completed", "a0000000000000000", "\(durationMs)"]
          case .sync, .unanswered: break
          case .async(let agentID, _): fields += ["async_launched", agentID, ""]
          case .teammate: fields += ["teammate_spawned", "", ""]
          }
        }
        lines.append(fields.joined(separator: String(TranscriptCommands.fieldSeparator)))
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// One call's `tool_use` id, derived from its place in the fixture so the record and its
  /// result line cannot drift apart.
  private func callID(index: Int, position: Int) -> String {
    "toolu_\(index)_\(position)"
  }

  /// `name<TAB>record` for the head of every file the command named, as the real `awk`
  /// emits it. Only `user` records, bounded to `briefRecords`, so a brief cannot come from
  /// the assistant by accident.
  private func briefs(for command: String) -> String {
    let now = Date()
    let wanted = sessions.filter { command.contains($0.fileName) }
    let lines = wanted.flatMap { session in
      session.turns.enumerated()
        // `.command` as well as `.human`: both are `user` records the real `briefSelector`
        // keeps.
        .filter { _, turn in
          switch turn.speaker {
          // `.teammate` too: the real selector keeps it, and `TranscriptParser.openingLine`
          // refuses it. Filtering it here would move that refusal into the host.
          case .human, .command, .teammate: true
          case .assistant, .tools, .toolBlocks, .apiError: false
          }
        }
        .prefix(TranscriptCommands.briefRecords)
        .map { index, turn in
          "\(session.fileName)\t\(record(turn, index: index, sessionID: session.sessionID, asOf: now))"
        }
    }
    return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
  }

  /// The session's records, bounded by the command's `tail -n`.
  ///
  /// Honouring the bound is what makes a wider page wider; without it every page would be
  /// identical and a pager would seem to work while prepending nothing. The byte bound is
  /// not honoured, since it never leaves the host.
  ///
  /// **This fake does not run the `awk`.** A fixture exercises the parse, never the
  /// selector; `RecordSelectorTests` and `LiveTranscriptProbeTests` cover that.
  ///
  /// **The bound slices turns, not records**, so turns that write extra lines (a duration,
  /// an answer) make it slightly looser than `tail -n`. Only the paging ladder reads the
  /// record count, so this is accepted.
  private func records(of session: Session, asOf now: Date, bound: Int?) -> String {
    let kept = kept(session, bound: bound)
      .flatMap { index, turn -> [String] in
        let written = record(turn, index: index, sessionID: session.sessionID, asOf: now)
        let at = now.addingTimeInterval(-turn.secondsAgo).formatted(.iso8601)
        let answers = answerRecords(turn, index: index, sessionID: session.sessionID, at: at)
        guard let milliseconds = turn.durationMs else { return [written] + answers }
        return [written] + answers + [
          durationRecord(
            milliseconds,
            after: "\(session.sessionID)-\(index)",
            at: at,
            sessionID: session.sessionID
          )
        ]
      }
    return kept.joined(separator: "\n") + "\n"
  }

  /// The reply record for each answered `AskUserQuestion` call in a turn: a `tool_result`
  /// naming the call, and a `toolUseResult` whose first key is `questions` (what
  /// `recordSelector` keeps it by) carrying `answers` keyed by question text.
  private func answerRecords(
    _ turn: Turn, index: Int, sessionID: String, at: String
  ) -> [String] {
    (turn.writtenBlocks ?? []).enumerated().compactMap { position, block in
      guard case .call(let call) = block, call.outcome != .pending,
        call.questions.contains(where: { $0.answer != nil })
      else { return nil }
      let answered = call.questions.compactMap { question in
        question.answer.map { (question: question.question, answer: $0) }
      }
      let answers = answered
        .map { #""\#(quoted($0.question))":"\#(quoted($0.answer))""# }
        .joined(separator: ",")
      let sentence = answered
        .map { "\"\($0.question)\"=\"\($0.answer)\"" }
        .joined(separator: ", ")
      let content =
        "Your questions have been answered: \(sentence). "
        + "You can now continue with these answers in mind."
      let questions = String(askUserQuestionInput(call.questions).dropFirst().dropLast())
      return """
        {"type":"user","uuid":"\(quoted(sessionID))-\(index)-answer-\(position)",\
        "timestamp":"\(quoted(at))","isSidechain":false,\
        "message":{"role":"user","content":[{"type":"tool_result",\
        "content":"\(quoted(content))","tool_use_id":"\(callID(index: index, position: position))"}]},\
        "toolUseResult":{\(questions),"answers":{\(answers)},"annotations":{}}}
        """
    }
  }

  /// The elapsed-time record Claude Code writes after a turn, in its real shape: with
  /// `parentUuid`, `uuid`, `timestamp`, `messageCount`, and **no `message`**.
  ///
  /// `Int(milliseconds)` traps on `.infinity` or `.nan`. That is deliberate: such a fixture
  /// is a fixture bug, and trapping here reports it better than a duration that silently
  /// goes missing.
  private func durationRecord(
    _ milliseconds: Double, after parent: String, at: String, sessionID: String
  ) -> String {
    """
    {"parentUuid":"\(quoted(parent))","isSidechain":false,"type":"system",\
    "subtype":"turn_duration","durationMs":\(Int(milliseconds)),"messageCount":26,\
    "timestamp":"\(quoted(at))","uuid":"\(quoted(parent))-duration","isMeta":false,\
    "userType":"external","entrypoint":"cli","sessionId":"\(quoted(sessionID))"}
    """
  }

  /// The turns a bounded read keeps, each with its index in the whole file. Every id is
  /// derived from that index, so it must survive the cut.
  private func kept(_ session: Session, bound: Int?) -> [(offset: Int, element: Turn)] {
    let all = Array(session.turns.enumerated())
    return bound.map { Array(all.suffix($0)) } ?? all
  }

  /// The `N` of the command's **first** `tail -n N`. The read carries several, one per
  /// section, and the first bounds the records. They are equal today, which would hide a
  /// change.
  private func recordBound(from command: String) -> Int? {
    guard let range = command.range(of: "tail -n ") else { return nil }
    let digits = command[range.upperBound...].prefix { $0.isNumber }
    return Int(digits)
  }

  private func record(_ turn: Turn, index: Int, sessionID: String, asOf now: Date) -> String {
    let at = now.addingTimeInterval(-turn.secondsAgo).formatted(.iso8601)
    let uuid = "\(sessionID)-\(index)"
    switch turn.speaker {
    case .human where turn.attachedImages > 0:
      // The block-array shape, which every image-bearing record has. A block with no entry
      // in `imagePayloads` writes no `data`, the placeholder path.
      let text = turn.text.isEmpty
        ? []
        : [#"{"type":"text","text":"\#(quoted(turn.text))"}"#]
      let images = (0..<turn.attachedImages).map { index -> String in
        guard index < turn.imagePayloads.count else {
          return #"{"type":"image","source":{"type":"base64","media_type":"image/png"}}"#
        }
        let payload = quoted(turn.imagePayloads[index])
        return """
          {"type":"image","source":{"type":"base64","media_type":"image/png",\
          "data":"\(payload)"}}
          """
      }
      return """
        {"type":"user","uuid":"\(quoted(uuid))","timestamp":"\(quoted(at))",\
        "origin":{"kind":"human"},\
        "message":{"role":"user","content":[\((text + images).joined(separator: ","))]}}
        """
    case .human:
      // `origin.kind` written explicitly, so the fixture does not lean on the parser's
      // fallback for origin-less records.
      return """
        {"type":"user","uuid":"\(quoted(uuid))","timestamp":"\(quoted(at))",\
        "origin":{"kind":"human"},\
        "message":{"role":"user","content":"\(quoted(turn.text))"}}
        """
    case .command:
      return """
        {"type":"user","uuid":"\(quoted(uuid))","timestamp":"\(quoted(at))",\
        "origin":{"kind":"human"},\
        "message":{"role":"user","content":"\(quoted(commandEnvelope(turn.text)))"}}
        """
    case .teammate(let events):
      // **No `origin`.** Real relayed records never carry it, and writing one would let a
      // classification resting on `origin` pass.
      return """
        {"type":"user","uuid":"\(quoted(uuid))","timestamp":"\(quoted(at))",\
        "message":{"role":"user","content":"\(quoted(teammateEnvelope(events)))"}}
        """
    case .assistant:
      return """
        {"type":"assistant","uuid":"\(quoted(uuid))","timestamp":"\(quoted(at))",\
        "message":{"role":"assistant","model":"claude-opus-5",\(usage(index: index)),"content":[\
        {"type":"text","text":"\(quoted(turn.text))"}]}}
        """
    case .apiError(let error, let status, let resetsAt):
      let statusField = status.map { #""apiErrorStatus":\#($0),"# } ?? ""
      let quota = resetsAt.map {
        let seconds = Int($0.timeIntervalSince1970)
        return #""quotaLimits":{"status":"rejected","resetsAt":\#(seconds),"#
          + #""rateLimitType":"five_hour","overageStatus":"rejected","isUsingOverage":false},"#
      } ?? ""
      return """
        {"type":"assistant","uuid":"\(quoted(uuid))","timestamp":"\(quoted(at))",\
        "isSidechain":false,"isApiErrorMessage":true,"error":"\(quoted(error))",\(statusField)\(quota)\
        "message":{"role":"assistant","model":"<synthetic>",\
        "usage":{"input_tokens":0,"cache_creation_input_tokens":0,\
        "cache_read_input_tokens":0,"output_tokens":0},\
        "content":[{"type":"text","text":"\(quoted(turn.text))"}]}}
        """
    case .tools, .toolBlocks:
      // One record carrying every call. Real files also write a record per call; the parser
      // joins consecutive ones either way.
      let written = (turn.writtenBlocks ?? []).enumerated().map { position, block in
        // The id is what a result line names.
        #"{"type":"tool_use","id":"\#(callID(index: index, position: position))",""#
          + #"name":"\#(quoted(block.toolName))","input":\#(toolInput(block))}"#
      }
      return """
        {"type":"assistant","uuid":"\(quoted(uuid))","timestamp":"\(quoted(at))",\
        "message":{"role":"assistant","model":"claude-opus-5",\(usage(index: index)),\
        "content":[\(written.joined(separator: ","))]}}
        """
    }
  }

  /// `message.usage` for the assistant record at `index`. Every assistant record carries it,
  /// and it grows with the index as a real context does, so the count on screen comes from
  /// the page's last record. The context is `3 + 1,204 + (40,000 + 1,000 × index)`.
  private func usage(index: Int) -> String {
    #""usage":{"input_tokens":3,"cache_creation_input_tokens":1204,"#
      + #""cache_read_input_tokens":\#(40_000 + 1_000 * index),"output_tokens":412}"#
  }

  /// One block's `input` object, using the field names that tool really writes. The parse
  /// reads a different field per tool, so a single `file_path` for everything would test
  /// only one key. An unknown tool keeps `file_path`.
  private func toolInput(_ block: Turn.ToolBlock) -> String {
    switch block {
    case .background(let command, let description, _):
      return #"{"command":"\#(quoted(command))","description":"\#(quoted(description))","#
        + #""run_in_background":true}"#
    case .spawn(let subagentType, let name, let description, _):
      return #"{"subagent_type":"\#(quoted(subagentType))","name":"\#(quoted(name))",""#
        + #"description":"\#(quoted(description))","prompt":"\#(quoted(description))"}"#
    case .stop(let taskID):
      return #"{"task_id":"\#(quoted(taskID))"}"#
    case .send(let to, let summary, let message):
      let body = message.isEmpty ? summary : message
      let summaryField = summary.isEmpty ? "" : #""summary":"\#(quoted(summary))","#
      return #"{"to":"\#(quoted(to))",\#(summaryField)"message":"\#(quoted(body))"}"#
    case .call(let call):
      // A call with questions writes `AskUserQuestion`'s real input: one object per question
      // with its own `options` and `multiSelect`.
      guard call.questions.isEmpty else { return askUserQuestionInput(call.questions) }
      guard let target = call.target else { return "{}" }
      let key: String
      switch call.name {
      case "Bash": key = "description"
      case "Grep": key = "pattern"
      case "Glob": key = "pattern"
      case "WebFetch": key = "url"
      case "Skill": key = "skill"
      case "ScheduleWakeup": key = "reason"
      case "SendUserFile": key = "caption"
      default: key = "file_path"
      }
      return #"{"\#(key)":"\#(quoted(target))"}"#
    }
  }

  /// `AskUserQuestion`'s input, one object per question. `header` falls back to `Choice`,
  /// because a real call always carries one.
  private func askUserQuestionInput(_ questions: [PendingQuestion]) -> String {
    let written = questions.map { question -> String in
      let options = question.options.indices
        .map { at -> String in
          let label = #""label":"\#(quoted(question.options[at]))""#
          guard question.optionDescriptions.indices.contains(at),
            let description = question.optionDescriptions[at]
          else { return "{\(label)}" }
          return #"{\#(label),"description":"\#(quoted(description))"}"#
        }
        .joined(separator: ",")
      let header = question.header ?? "Choice"
      return #"{"question":"\#(quoted(question.question))","header":"\#(quoted(header))",""#
        + #"multiSelect":\#(question.allowsMultiple),"options":[\#(options)]}"#
    }
    return #"{"questions":[\#(written.joined(separator: ","))]}"#
  }

  /// A command wrapped in Claude Code's envelope. `!git status` becomes `<bash-input>`;
  /// anything else becomes the three-tag slash-command envelope with a real record's order
  /// and indentation, since the parser searches for the tags.
  private func commandEnvelope(_ typed: String) -> String {
    if typed.hasPrefix("!") {
      return "<bash-input> \(typed.dropFirst())</bash-input>"
    }
    let name = typed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? typed
    let arguments = typed.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
    return """
      <command-name>\(name)</command-name>
                  <command-message>\(name.drop(while: { $0 == "/" }))</command-message>
                  <command-args>\(arguments)</command-args>
      """
  }

  /// The whole record a relayed teammate event arrives in: preface sentence, one block per
  /// event, and the boilerplate after the **last** closing tag. A parser that failed to
  /// strip the boilerplate would then show it, which a test can catch.
  private func teammateEnvelope(_ events: [Turn.TeammateEvent]) -> String {
    let blocks = events.map(teammateBlock).joined(separator: "\n\n")
    return "Relayed from another session:\n" + blocks + "\n\n" + Self.teammateBoilerplate
  }

  /// A stand-in for the paragraph Claude Code appends after the last closing tag. Invented
  /// text.
  private static let teammateBoilerplate =
    "Fixture text after the last closing tag. A parser that reads past the tag would show "
    + "this sentence: relay-footer-sentinel."

  private func teammateBlock(_ event: Turn.TeammateEvent) -> String {
    switch event.shape {
    case .idleNotification:
      // Every field inside the block. The summary is omitted when there is none, as the
      // record does; an empty string would be a different fact.
      var fields = [
        #""type":"idle_notification""#,
        #""from":"\#(quoted(event.sender))""#,
        #""timestamp":"2026-09-06T09:41:12.004Z""#,
        #""idleReason":"available""#,
      ]
      if let summary = event.summary { fields.append(#""summary":"\#(quoted(summary))""#) }
      fields.append(#""result":"\#(quoted(event.body))""#)
      return """
        <teammate-message teammate_id="\(event.sender)" color="blue">
        {\(fields.joined(separator: ","))}
        </teammate-message>
        """
    case .message:
      // The summary rides on the tag, so it is XML-escaped, which is why the parser decodes
      // entities.
      let summary = event.summary.map { #" summary="\#(Self.xmlAttribute($0))""# } ?? ""
      return """
        <teammate-message teammate_id="\(event.sender)" color="purple"\(summary)>
        \(event.body)
        </teammate-message>
        """
    }
  }

  /// XML attribute escaping, the way the harness writes a summary into the tag.
  private static func xmlAttribute(_ value: String) -> String {
    var out = value.replacingOccurrences(of: "&", with: "&amp;")
    for (character, entity) in [("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"), ("'", "&apos;")] {
      out = out.replacingOccurrences(of: character, with: entity)
    }
    return out
  }

  /// JSON string escaping, **control characters included**. Without them an ANSI fixture is
  /// invalid JSON, the record fails to decode, and a sanitiser test passes on zero turns.
  private func quoted(_ text: String) -> String {
    var out = ""
    for character in text.unicodeScalars {
      switch character {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        if character.value < 0x20 {
          out += String(format: "\\u%04x", character.value)
        } else {
          out.unicodeScalars.append(character)
        }
      }
    }
    return out
  }
}
#endif
