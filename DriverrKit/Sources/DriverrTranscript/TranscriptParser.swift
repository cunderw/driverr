import DriverrCore
import Foundation

/// Claude's records in, `DriverrCore` turns out.
///
/// A record is not a turn: a real session has dozens of records per turn, most of them
/// tool calls, tool results and injected text. The mapping between them is what the tests
/// cover.
///
/// **Never invent a speaker or a boundary.** Every decision is made on a typed field
/// (`type`, `isMeta`, `isSidechain`, a block's `type`), never on a glyph, colour or
/// indent as a screen reading would.
///
/// **Turns come from `user` and `assistant` records only.** The one `system` record read,
/// `turn_duration`, makes no turn; it annotates the assistant turn before it. Admitting a
/// second exception is a design decision.
enum TranscriptParser {
  struct Page {
    var turns: [TranscriptTurn] = []
    /// Lines that were not JSON. A count, because a byte tail usually starts mid-record.
    var unreadableRecords = 0
    /// Lines that parsed and carried no turn: tool results, bookkeeping, injected text.
    var records = 0
    /// The newest record's context count. See `contextUsage(of:)`.
    var contextUsage: ContextUsage?
    /// The failed API request the page ends on. See `agentStop(of:)`.
    var agentStop: AgentStop?
  }

  /// `forSubagentFile` is `true` only for a sub-agent's own file
  /// (`TranscriptFile.isSubagentFile`). It changes two things: sidechain records are kept,
  /// and the record with no `origin` and `parentUuid: null`, the file's opening prompt,
  /// becomes `TranscriptTurn.isParentPrompt` instead of a human turn.
  static func page(from text: String, forSubagentFile: Bool = false) -> Page {
    var page = Page()
    var run: OpenRun?
    /// Each `Agent` call's `name` to its description, so a later `TaskStop` can say what it
    /// stopped. A stop whose spawn fell off the front of the page keeps the bare id.
    var spawns: [String: String] = [:]
    /// Each spawn answer's `agentId` to the name it was spawned under. A `TaskStop` names
    /// either, depending on the Claude Code version; see `agentTraffic`.
    var agentNames: [String: String] = [:]
    /// The run this session's own agent traffic closed, while it is still the last run. See
    /// `closeRun`.
    var pendingCandidate: Int?

    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    let answers = results(in: lines)
    let asked = questionAnswers(in: lines)
    let ends = taskEnds(in: lines)
    /// Spawns only the rest of the page can settle. See `settleSpawns`.
    var unsettled: [(index: Int, kind: UnsettledSpawn)] = []
    /// The turns the standing `agentStop`'s record made. See `hideStopTurns`.
    var stopTurnIDs: Set<String> = []

    // A record can make several turns (a text block and a tool call) but has one uuid.
    var turnsFromThisRecord = 0

    /// A run is closed by the next thing somebody said, and by nothing else. Tool replies and
    /// injected text leave it open, which is what collapses many calls into a few runs.
    ///
    /// `atEndOfPage` is the one place where an unanswered call means the agent is waiting;
    /// see `ToolCall.Outcome.pending`.
    func closeRun(atEndOfPage: Bool = false) {
      guard let open = run else { return }
      var calls = open.calls
      let couldBeWaiting =
        answers.scanned && open.lastCallHasIdentifier && calls.last?.outcome == .unknown
      if atEndOfPage, couldBeWaiting, let last = calls.last {
        calls[calls.count - 1] = ToolCall(
          name: last.name, target: last.target, outcome: .pending, questions: last.questions,
          task: last.task
        )
      }
      page.turns.append(
        TranscriptTurn(id: open.id, speech: .tools(ToolRun(calls: calls)), at: open.at)
      )
      // **A run split off the end by this session's own agent traffic is still the end.** An
      // `Agent`, `TaskStop` or `SendMessage` block closes the run, often beside an
      // unanswered call issued in parallel. Its position is remembered, and
      // `waitingBehindAgentTraffic` upgrades it after the loop if only that traffic follows.
      pendingCandidate = couldBeWaiting && !atEndOfPage ? page.turns.count - 1 : nil
      run = nil
    }

    for (index, line) in lines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      // A result line is not a record. Counting it would inflate the record tally and make
      // a page that reached the front of the file look as though it had not.
      guard !trimmed.hasPrefix(TranscriptCommands.resultMark) else { continue }
      // Nor is a task line.
      guard !trimmed.hasPrefix(TranscriptCommands.taskMark) else { continue }
      guard let record = try? JSONDecoder().decode(ClaudeRecord.self, from: Data(trimmed.utf8)) else {
        page.unreadableRecords += 1
        continue
      }
      page.records += 1

      // Sidechain records are dropped only for a pane's own conversation. A sub-agent's file
      // flags every record, so dropping them there would leave it empty.
      if !forSubagentFile, record.isSubagent { continue }
      guard !record.isInjected else { continue }

      // **The one `system` record Driverr reads.** It has no `message`, so it is handled
      // before that guard, and it annotates the last assistant turn instead of making a row.
      // A backward scan agrees with the record's `parentUuid` in practice, so no uuid map.
      //
      // **It cannot cross a human turn.** A turn that ended in tool calls with no text has
      // no assistant turn of its own, and attaching its time to the previous exchange would
      // be wrong. That turn carries no duration.
      //
      // The run is **not** closed here, or a run of tool calls would split at the record
      // that says how long the turn took.
      if record.type == "system", record.subtype == "turn_duration" {
        guard let milliseconds = record.durationMs?.value, milliseconds.isFinite,
          milliseconds >= 0
        else { continue }
        attach(duration: milliseconds.rounded(.towardZero), in: &page)
        continue
      }

      guard let message = record.message else { continue }

      turnsFromThisRecord = 0
      let at = timestamp(record.timestamp)
      func nextID() -> String {
        let base = record.uuid.flatMap { $0.isEmpty ? nil : $0 } ?? "record-\(index)"
        defer { turnsFromThisRecord += 1 }
        return turnsFromThisRecord == 0 ? base : "\(base)#\(turnsFromThisRecord)"
      }

      switch record.type {
      case "user":
        // A tool's reply is not a turn. Both checks stay: the block is on every reply, and
        // the top-level key is what the selector matches, so a record with only one of them
        // still cannot arrive as speech.
        guard record.toolUseResult == nil else { continue }
        guard let content = message.content else { continue }
        if content.blocks.contains(where: \.isToolResult) { continue }
        // First, because a compacted summary is machine text even if it looks like a command
        // envelope.
        guard !record.isCompacted else { continue }
        let said = content.string ?? joinedText(content.blocks)
        let imageBlocks = content.blocks.filter(\.isImage)
        let images = imageBlocks.count

        // A command the person typed, unwrapped from the client's envelope. Checked before
        // `isHumanAuthored`, which drops every envelope; this is the subset that is a person.
        if let typed = commandTyped(in: said) {
          closeRun()
          page.agentStop = nil
          stopTurnIDs = []
          page.turns.append(
            TranscriptTurn(id: nextID(), speech: .human(sanitised(typed)), at: at, isCommand: true)
          )
          continue
        }

        // One agent talking to another. Before `isHumanAuthored`, which drops the envelope as
        // machine text; this is the subset worth a line on screen. `isClientEnvelope` still
        // drops these for the picker's brief.
        //
        // A record with two blocks becomes two turns: a teammate's message and its idle
        // notification often arrive together.
        let events = agentEvents(in: said)
        if !events.isEmpty {
          closeRun()
          for event in events {
            page.turns.append(TranscriptTurn(id: nextID(), speech: .agentEvent(event), at: at))
          }
          continue
        }

        // An image with no words is still something a person sent.
        guard !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || images > 0
        else { continue }
        guard isHumanAuthored(record, saying: said) else { continue }
        // After the command and agent checks, which need their envelope at the start of the
        // raw text. A paste opens with its own wrapper, so a pasted `<bash-input>` or relay
        // stays pasted text.
        let shown = pastedContent(in: said) ?? said
        guard !shown.isEmpty || images > 0 else { continue }
        closeRun()
        page.agentStop = nil
        stopTurnIDs = []
        // **Hoisted, because the image ids are built from it.** `nextID()` advances a counter,
        // so calling it in the argument list would tie image ids to evaluation order. An image
        // id must be the same on every read; `TranscriptImage`'s equality rests on it.
        let turnID = nextID()
        page.turns.append(
          TranscriptTurn(
            id: turnID,
            speech: .human(sanitised(shown)),
            at: at,
            attachedImages: images,
            images: mappedImages(imageBlocks, of: turnID),
            // In a sub-agent's file, the one record with no `origin` is the prompt the parent
            // wrote, not something the person said.
            isParentPrompt: forSubagentFile && record.origin == nil && record.parentUuid == nil
          )
        )

      case "assistant":
        if let usage = contextUsage(of: message) { page.contextUsage = usage }
        // **A failed request is the stop; any other assistant record ends it.** A reply after
        // a limit means the agent is running again. A human turn clears it too, above.
        //
        // **Nothing else clears it.** A limit is often followed by a task notification or
        // injected text and then another limit. Neither makes a turn, so clearing on any later
        // `user` record would drop a notice that comes straight back, or drop it for good if
        // the agent never retries.
        //
        // A sub-agent's stop is its own, not the pane agent's.
        page.agentStop =
          record.isAPIError && !record.isSubagent ? agentStop(of: record, message, at: at) : nil
        let turnsBefore = page.turns.count
        // Blocks in written order, because that order is the conversation.
        for block in message.content?.blocks ?? [] {
          if block.isText {
            let said = block.text ?? ""
            guard !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            closeRun()
            page.turns.append(
              TranscriptTurn(id: nextID(), speech: .assistant(sanitised(said)), at: at)
            )
          } else if block.isToolUse, let name = block.name, !name.isEmpty {
            // **This session's own agent traffic leaves the run.** A spawn, a stop and a message
            // to a teammate are drawn as event lines, not entries in a tally. `Agent`, `Bash`,
            // `Agent` becomes event, run, event, the order the terminal draws.
            if let spawned = spawn(of: block) {
              spawns[spawned.id] = spawned.description
            }
            if block.name == "Agent", let name = nonEmpty(block.input?["name"]),
              let agentID = block.id.flatMap({ answers.launches[$0]?.agentID }), !agentID.isEmpty
            {
              agentNames[agentID] = name
            }
            if var event = agentTraffic(of: block, spawns: spawns, agentNames: agentNames) {
              closeRun()
              if event.kind == .spawned {
                switch spawnProgress(of: block.id, at: at, answers: answers, ends: ends) {
                case .known(let task): event = event.with(task: task)
                case .unsettled(let kind): unsettled.append((page.turns.count, kind))
                case .unknown: break
                }
                if !forSubagentFile {
                  event = event.with(link: subagentLink(of: block, answers: answers))
                }
                if let agentID = block.id.flatMap({ answers.launches[$0]?.agentID }),
                  !agentID.isEmpty
                {
                  event = event.with(agentID: agentID)
                }
              }
              page.turns.append(TranscriptTurn(id: nextID(), speech: .agentEvent(event), at: at))
              continue
            }
            // A question the agent asked is its own words, written before the call that carries
            // it.
            if let asked = questions(of: block) {
              closeRun()
              page.turns.append(
                TranscriptTurn(id: nextID(), speech: .assistant(sanitised(asked)), at: at)
              )
            }
            if run == nil { run = OpenRun(id: nextID(), at: at) }
            run?.calls.append(
              ToolCall(
                name: name,
                target: target(of: block),
                outcome: answers.outcome(for: block.id),
                questions: replyQuestions(of: block, answers: block.id.flatMap { asked[$0] }),
                task: block.input?.runsInBackground == true
                  ? backgroundProgress(of: block.id, at: at, answers: answers, ends: ends) : nil
              )
            )
            run?.lastCallHasIdentifier = block.id?.isEmpty == false
          }
          // `thinking`, `image` and unknown blocks are neither a turn nor a boundary.
        }
        // Any other assistant record has cleared the stop, and the hiding goes with it.
        //
        // **A stop after a stop adds to the set.** Nothing cleared the first, so it is the same
        // standing event; hiding only the newest would leave the rest showing the host's clock
        // under the notice.
        //
        // Only assistant turns are named: a run `closeRun` appended here belongs to an earlier
        // record.
        if page.agentStop == nil {
          stopTurnIDs = []
        } else {
          stopTurnIDs.formUnion(page.turns[turnsBefore...].filter(\.isAssistant).map(\.id))
        }

      default:
        // An unknown record type. Counted and ignored, never an error, so a `claude` upgrade
        // cannot break the reader.
        continue
      }
    }

    closeRun(atEndOfPage: true)
    waitingBehindAgentTraffic(&page, candidate: pendingCandidate)
    settleSpawns(unsettled, in: &page)
    hideStopTurns(stopTurnIDs, in: &page)
    return page
  }

  /// Takes the standing stop's own turn off the page. The notice states the stop once, with
  /// the reset in the phone's clock; the record's text would repeat it in the host's. When a
  /// later record clears the stop, `ids` is empty and the turn returns.
  ///
  /// **Not when it is the only turn.** An empty page is `noReadableTurns`, which replaces
  /// the chat and the stop notice with a failure notice.
  ///
  /// Runs last, after every pass that holds an index into `page.turns`.
  private static func hideStopTurns(_ ids: Set<String>, in page: inout Page) {
    guard page.agentStop != nil, !ids.isEmpty else { return }
    let kept = page.turns.filter { !ids.contains($0.id) }
    if !kept.isEmpty { page.turns = kept }
  }

  /// A record's context count, or `nil` for one that says nothing.
  ///
  /// **A zero sum is nothing, not an empty context.** Claude Code's `<synthetic>` records
  /// carry all-zero usage, and one at the end of a page would read `0 context`. The caller
  /// keeps the newest non-zero sum.
  ///
  /// Read before the block loop, so a record carrying only a tool call still counts.
  static func contextUsage(of message: ClaudeMessage) -> ContextUsage? {
    guard let usage = message.usage else { return nil }
    let counted = ContextUsage(
      inputTokens: max(0, usage.inputTokens ?? 0),
      cacheCreationTokens: max(0, usage.cacheCreationInputTokens ?? 0),
      cacheReadTokens: max(0, usage.cacheReadInputTokens ?? 0)
    )
    return counted.totalTokens > 0 ? counted : nil
  }

  /// A failed request's stop. `kind` comes from the typed `error` field only; the text is
  /// carried for display, never matched. See `DriverrCore.AgentStop`.
  static func agentStop(of record: ClaudeRecord, _ message: ClaudeMessage, at: Date?) -> AgentStop {
    let said = message.content.map { $0.string ?? joinedText($0.blocks) } ?? ""
    return AgentStop(
      error: record.error?.value,
      resetsAt: record.quotaLimits?.resetsAt,
      message: sanitised(said),
      at: at
    )
  }

  /// Puts an elapsed time on the assistant turn the duration record follows. Walks back from
  /// the end, skipping tool runs and agent events, which the duration covers. A human turn
  /// stops the walk with nothing attached.
  private static func attach(duration: Double, in page: inout Page) {
    for index in page.turns.indices.reversed() {
      let turn = page.turns[index]
      if turn.isHuman { return }
      guard turn.isAssistant else { continue }
      page.turns[index] = TranscriptTurn(
        id: turn.id,
        speech: turn.speech,
        at: turn.at,
        isCommand: turn.isCommand,
        attachedImages: turn.attachedImages,
        images: turn.images,
        durationMs: duration
      )
      return
    }
  }

  /// Marks the last call of a run that this session's own agent traffic closed as pending.
  /// Only when everything after the run is that traffic: anything somebody said after it
  /// means the agent went on.
  private static func waitingBehindAgentTraffic(_ page: inout Page, candidate: Int?) {
    guard let index = candidate, index < page.turns.count else { return }
    guard
      page.turns[(index + 1)...].allSatisfy({
        $0.agentEvent?.kind.isThisSessionsOwnCall == true
      })
    else { return }
    let turn = page.turns[index]
    guard var calls = turn.toolRun?.calls, let last = calls.last else { return }
    calls[calls.count - 1] = ToolCall(
      name: last.name, target: last.target, outcome: .pending, questions: last.questions,
      task: last.task
    )
    page.turns[index] = TranscriptTurn(
      id: turn.id, speech: .tools(ToolRun(calls: calls)), at: turn.at
    )
  }

  // MARK: - What became of the calls

  /// The host's answer about tool results, read off the page's result lines.
  ///
  /// `scanned` separates "the host looked and found no results" from "nothing looked".
  /// Without it every run would end in a call that reads as waiting. See the bare `!` in
  /// `TranscriptCommands.readCommand`.
  struct Results {
    var scanned = false
    /// Call id to whether its result was an error. Absent means no result reached the page,
    /// which is conclusive only for the newest call.
    var failed: [String: Bool] = [:]
    /// Call id to how an `Agent` call launched, where the answer said.
    var launches: [String: Launch] = [:]

    func outcome(for id: String?) -> ToolCall.Outcome {
      guard let id, let failed = failed[id] else { return .unknown }
      return failed ? .failed : .succeeded
    }
  }

  /// A pass of its own, because result lines follow the records.
  static func results(in lines: [Substring]) -> Results {
    var results = Results()
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.hasPrefix(TranscriptCommands.resultMark) else { continue }
      results.scanned = true
      // Split on every tab. A spawn's answer has extra fields, and a two-way split would
      // glue the flag to them and read a failed spawn as a success.
      let fields = trimmed.dropFirst(TranscriptCommands.resultMark.count)
        .split(separator: TranscriptCommands.fieldSeparator, omittingEmptySubsequences: false)
        .map(String.init)
      guard let identifier = fields.first, !identifier.isEmpty else { continue }
      results.failed[identifier] = fields.count >= 2 && fields[1] == "1"
      if fields.count >= 3, !fields[2].isEmpty {
        results.launches[identifier] = Launch(
          status: fields[2],
          agentID: fields.count >= 4 && !fields[3].isEmpty ? fields[3] : nil,
          durationMs: fields.count >= 5 ? Double(fields[4]) : nil
        )
      }
    }
    return results
  }

  // MARK: - Where a spawned task has got to

  /// How an `Agent` call launched, from the fields `TranscriptCommands.resultSelector` adds.
  struct Launch {
    /// `async_launched`, `teammate_spawned` or `completed`.
    let status: String
    /// The spawned agent's id, which is what a handback names.
    let agentID: String?
    /// A sync spawn's `totalDurationMs`.
    let durationMs: Double?
  }

  /// What one task line said ended a task.
  struct TaskEnd {
    let state: TaskProgress.State
    let at: Date?
  }

  /// Every task line, keyed by the call id or `agentId` it names. **The newest wins**, because
  /// a task can notify again after it is sent another message.
  ///
  /// An unknown status ends nothing, so the task keeps what the rest of the page says.
  static func taskEnds(in lines: [Substring]) -> [String: TaskEnd] {
    var ends: [String: TaskEnd] = [:]
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.hasPrefix(TranscriptCommands.taskMark) else { continue }
      let fields = trimmed.dropFirst(TranscriptCommands.taskMark.count)
        .split(separator: TranscriptCommands.fieldSeparator, omittingEmptySubsequences: false)
        .map(String.init)
      guard fields.count >= 2, !fields[0].isEmpty, let state = taskState(fields[1]) else {
        continue
      }
      ends[fields[0]] = TaskEnd(state: state, at: fields.count >= 3 ? timestamp(fields[2]) : nil)
    }
    return ends
  }

  /// A notification's `<status>` as a state.
  static func taskState(_ status: String) -> TaskProgress.State? {
    switch status {
    case "completed": .finished
    case "failed": .failed
    case "killed", "stopped": .stopped
    default: nil
    }
  }

  /// A spawn the rest of the page has to settle.
  enum UnsettledSpawn {
    /// A call with no answer. Running only if nothing after it says the agent went on, the
    /// rule `ToolCall.Outcome.pending` follows.
    case unanswered
    /// A teammate, whose end is its own idle notification, joined by name.
    case teammate(TaskProgress)
  }

  enum SpawnProgress {
    case known(TaskProgress)
    case unsettled(UnsettledSpawn)
    case unknown
  }

  /// What the call's own answer and the task lines say about one spawn.
  static func spawnProgress(
    of id: String?, at: Date?, answers: Results, ends: [String: TaskEnd]
  ) -> SpawnProgress {
    guard let id, !id.isEmpty else { return .unknown }
    guard let failed = answers.failed[id] else {
      return answers.scanned ? .unsettled(.unanswered) : .unknown
    }
    if failed { return .known(TaskProgress(state: .failed, startedAt: at)) }
    guard let launch = answers.launches[id] else {
      // No launch fields: an older answer or an unrecognised result. The call came back,
      // and that is all it says.
      return .known(TaskProgress(state: .finished, startedAt: at))
    }
    switch launch.status {
    case "async_launched":
      let end = ends[id] ?? launch.agentID.flatMap { ends[$0] }
      guard let end else { return .known(TaskProgress(state: .running, startedAt: at)) }
      return .known(TaskProgress(state: end.state, startedAt: at, endedAt: end.at))
    case "teammate_spawned":
      return .unsettled(.teammate(TaskProgress(state: .running, startedAt: at)))
    default:
      return .known(
        TaskProgress(state: .finished, startedAt: at, durationMs: launch.durationMs))
    }
  }

  /// A `run_in_background` call's progress once its answer says it started. `nil` for an
  /// unanswered call, which may be waiting on permission, and for a failed launch, which its
  /// outcome already shows.
  static func backgroundProgress(
    of id: String?, at: Date?, answers: Results, ends: [String: TaskEnd]
  ) -> TaskProgress? {
    guard let id, answers.failed[id] == false else { return nil }
    guard let end = ends[id] else { return TaskProgress(state: .running, startedAt: at) }
    return TaskProgress(state: end.state, startedAt: at, endedAt: end.at)
  }

  /// Settles the spawns only the rest of the page can answer for.
  ///
  /// **An unanswered spawn** is running when everything after it is a tool run or this
  /// session's own agent traffic, which a parent blocked on it could still write. Anything
  /// somebody said after it means the answer fell outside the window.
  ///
  /// **A teammate** follows its name through the page: an idle notification pauses it, a
  /// `SendMessage` to it restarts it and its clock, and a `TaskStop` stops it. A later spawn
  /// under the same name owns everything after. A teammate whose idle notification fell off
  /// the front of the page reads as running.
  private static func settleSpawns(
    _ unsettled: [(index: Int, kind: UnsettledSpawn)], in page: inout Page
  ) {
    for (index, kind) in unsettled {
      let turn = page.turns[index]
      guard let event = turn.agentEvent else { continue }
      let later = page.turns[(index + 1)...]
      let task: TaskProgress?
      switch kind {
      case .unanswered:
        let blocked = later.allSatisfy {
          $0.toolRun != nil || $0.agentEvent?.kind.isThisSessionsOwnCall == true
        }
        task = blocked ? TaskProgress(state: .running, startedAt: turn.at) : nil
      case .teammate(let started):
        var progress = started
        walk: for next in later {
          guard let other = next.agentEvent, other.sender == event.sender else { continue }
          switch other.kind {
          case .spawned: break walk
          case .idle:
            progress = TaskProgress(state: .idle, startedAt: progress.startedAt, endedAt: next.at)
          case .sent:
            // Woken: the time is this stretch of work, not the whole life since the spawn.
            progress = TaskProgress(state: .running, startedAt: next.at)
          case .stopped:
            progress = TaskProgress(state: .stopped, startedAt: progress.startedAt, endedAt: next.at)
          case .message:
            break
          }
        }
        task = progress
      }
      page.turns[index] = TranscriptTurn(
        id: turn.id, speech: .agentEvent(event.with(task: task)), at: turn.at
      )
    }
  }

  /// Each answered `AskUserQuestion` call's answers, by call id.
  ///
  /// A pass of its own, because the answer is written after the call has joined its run.
  /// Only lines containing `"answers":` are decoded again, so a page with no answered
  /// question pays nothing.
  static func questionAnswers(in lines: [Substring]) -> [String: [String: String]] {
    var found: [String: [String: String]] = [:]
    for line in lines where line.contains(#""answers":"#) {
      guard
        let record = try? JSONDecoder().decode(ClaudeRecord.self, from: Data(line.utf8)),
        let answers = record.toolUseResult?.answers,
        let id = record.message?.content?.blocks.first(where: \.isToolResult)?.toolUseID,
        !id.isEmpty
      else { continue }
      found[id] = answers
    }
    return found
  }

  // MARK: - What a session was asked to do

  /// The first thing a person typed into a session, as one line: the picker's brief. Two
  /// sessions in one directory have uuid names and close mtimes, which do not tell them
  /// apart to a person.
  ///
  /// It reads the head of a file and applies the chat's typed-field checks, with one
  /// difference.
  ///
  /// **A slash command is a brief.** The chat treats `<command-name>` as client text, but a
  /// session opened with `/doc-check` was briefed by that command. Requiring prose instead
  /// would often mean reading hundreds of KB further into the file.
  ///
  /// **`/clear` is skipped by name**, and only it. Claude Code writes it at the head of the
  /// new file when the previous conversation was cleared, so it was never typed into this
  /// session, and it opens a large share of files.
  ///
  /// Any other client text stays machine text, and an unknown envelope is treated as machine
  /// text, the same direction `isClientEnvelope` errs in. A file with no human turn in the
  /// bounds of `TranscriptCommands.briefCommand` gets no brief.
  static func brief(from text: String) -> String? {
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty,
        let record = try? JSONDecoder().decode(ClaudeRecord.self, from: Data(trimmed.utf8))
      else { continue }
      guard record.type == "user", !record.isSubagent, !record.isInjected, !record.isCompacted,
        record.toolUseResult == nil
      else { continue }
      // `origin.kind`, as `isHumanAuthored` reads it. Older files lack it, which is why the
      // envelope rules below are still needed.
      if let kind = record.origin?.kind, kind != "human" { continue }
      guard let content = record.message?.content else { continue }
      if content.blocks.contains(where: \.isToolResult) { continue }
      let said = content.string ?? joinedText(content.blocks)
      // A paste is what the person pasted, so its body skips `openingLine`'s command and
      // markup rules.
      if !isClientEnvelope(said), let pasted = pastedContent(in: said) {
        if let brief = bounded(firstLine(sanitised(pasted))) { return brief }
        continue
      }
      if let brief = openingLine(sanitised(said)) { return brief }
    }
    return nil
  }

  /// One record's content reduced to the line a picker shows, or `nil` for machine text.
  static func openingLine(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    // Before the `<` check: a `<teammate-message>` record opens with a preface sentence,
    // which would otherwise become the row's brief.
    guard !opensWithTeammateMessage(trimmed[...]) else { return nil }
    guard trimmed.hasPrefix("<") else { return bounded(firstLine(trimmed)) }
    // `<command-name>` and `<command-message>` come in either order across versions, so
    // this looks for the tag.
    if let command = slashCommand(in: trimmed) { return bounded(command) }
    if let bash = tagged("bash-input", in: trimmed) { return bounded("!" + firstLine(bash)) }
    return nil
  }

  /// The one command that is never a brief. See `brief(from:)`.
  static let skippedCommands: Set<String> = ["clear"]

  /// `/code-review high --fix` out of the envelope Claude Code wraps a slash command in.
  private static func slashCommand(in text: String) -> String? {
    guard let name = tagged("command-name", in: text) else { return nil }
    let command = name.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\t"))
    guard !command.isEmpty, !skippedCommands.contains(command) else { return nil }
    let arguments = tagged("command-args", in: text)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return arguments.isEmpty ? "/\(command)" : "/\(command) \(arguments)"
  }

  /// A person's message with every pasted block replaced by its body, or `nil` if it holds
  /// no well-formed block.
  ///
  /// Claude Code stores a paste as `<pasted_content id="6e67">…</pasted_content id="6e67">`
  /// in a human record. The closing tag repeats the id, which `tagged` cannot handle. Ids
  /// repeat across records, so a block closes at the **next** closing tag with its id. A
  /// paste can sit mid-sentence, so every block is unwrapped in place.
  ///
  /// A mismatched id, an unclosed block and a bare mention stay as typed. In a nested block
  /// the outer one closes first and the inner wrapper is part of its body.
  ///
  /// **The closing tags are indexed in one pass.** Searching for each opener's close is
  /// quadratic when closes are missing, which takes seconds on thousands of openers.
  static func pastedContent(in text: String) -> String? {
    let closes = pastedCloses(in: text)
    var nextClose: [Substring: Int] = [:]
    var out = ""
    var cursor = text.startIndex
    var unwrapped = false
    var search = text.startIndex
    while case let (open, id, bodyStart)? = pastedTag(pastedOpener, in: text, from: search) {
      search = bodyStart
      guard let candidates = closes[id] else { continue }
      var index = nextClose[id] ?? 0
      while index < candidates.count, candidates[index].lowerBound < bodyStart { index += 1 }
      nextClose[id] = index
      guard index < candidates.count else { continue }
      let close = candidates[index]
      out += text[cursor..<open]
      out += text[bodyStart..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
      cursor = close.upperBound
      search = close.upperBound
      unwrapped = true
    }
    guard unwrapped else { return nil }
    out += text[cursor...]
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static let pastedOpener = "<pasted_content id=\""
  private static let pastedCloser = "</pasted_content id=\""

  /// Every well-formed closing tag, by id, in the order they appear.
  private static func pastedCloses(in text: String) -> [Substring: [Range<String.Index>]] {
    var closes: [Substring: [Range<String.Index>]] = [:]
    var search = text.startIndex
    while case let (start, id, end)? = pastedTag(pastedCloser, in: text, from: search) {
      closes[id, default: []].append(start..<end)
      search = end
    }
    return closes
  }

  /// The next `<prefix>ID">` at or after `from`: where it starts, its id, and where it ends.
  /// A candidate whose id is not closed by `">` is skipped.
  private static func pastedTag(
    _ prefix: String, in text: String, from: String.Index
  ) -> (String.Index, Substring, String.Index)? {
    var search = from
    while let tag = text.range(of: prefix, range: search..<text.endIndex) {
      search = tag.upperBound
      guard let quote = text[tag.upperBound...].firstIndex(of: "\"") else { return nil }
      let id = text[tag.upperBound..<quote]
      let afterQuote = text.index(after: quote)
      guard !id.contains("<"), !id.contains(">"), text[afterQuote...].hasPrefix(">") else {
        continue
      }
      return (tag.lowerBound, id, text.index(after: afterQuote))
    }
    return nil
  }

  /// The text between `<tag>` and `</tag>`, when both are there.
  private static func tagged(_ tag: String, in text: String) -> String? {
    guard let open = text.range(of: "<\(tag)>"),
      let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
    else { return nil }
    return String(text[open.upperBound..<close.lowerBound])
  }

  /// How long a brief may be. One line in a row, and a session can open with a very long
  /// prompt.
  static let briefLimit = 140

  private static func bounded(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard trimmed.count > briefLimit else { return trimmed }
    return trimmed.prefix(briefLimit - 1) + "…"
  }

  /// Whether a `user` record is a person, rather than the client wearing a `user` record.
  ///
  /// `isMeta` is not enough: nearly half of the text-bearing, non-injected `user` records are
  /// task notifications and command envelopes. Drawing one as "the user said…" invents a
  /// speaker.
  ///
  /// Checks, in order of trust:
  ///
  /// 1. A compacted summary is machine text.
  /// 2. `origin.kind` is authoritative where it exists: `human` is a person, anything else
  ///    is the client.
  /// 3. The client envelope (`<command-name>`, `<bash-input>` and kin), the only signal in
  ///    files written before `origin` existed. It is a machine-written wrapper, closer to a
  ///    typed field than to a glyph.
  ///
  /// The envelope check runs even when `origin` says `human`, because a person running
  /// `/summarize` produces content that is still `<command-message>summarize</…>`.
  ///
  /// **It errs toward dropping.** An unknown tag shows a machine's message as a person's; a
  /// person opening with a literal `<bash-input>` loses a turn. Only the first invents a
  /// speaker.
  ///
  /// `commandTyped(in:)` runs first and recovers the envelopes that wrap typed input. What
  /// reaches here is machine text.
  static func isHumanAuthored(_ record: ClaudeRecord, saying text: String) -> Bool {
    guard !record.isCompacted else { return false }
    if let kind = record.origin?.kind, kind != "human" { return false }
    return !isClientEnvelope(text)
  }

  /// The wrappers Claude Code puts around its own output in a `user` record.
  static let clientEnvelopes = [
    "task-notification",
    "command-name",
    "command-message",
    "command-args",
    "local-command-stdout",
    "bash-input",
    "bash-stdout",
  ]

  /// Whether `text` opens with a `<teammate-message>` wrapper: one agent relaying another's
  /// message. The tag always carries attributes, and Claude Code may write a preface
  /// sentence before it, so a bare prefix check misses it.
  ///
  /// Rather than match the preface's wording, this allows **one** arbitrary leading line
  /// before the tag. A boundary is required after the tag name so `<teammate-messages>` does
  /// not match.
  static func opensWithTeammateMessage(_ text: Substring) -> Bool {
    func tagAtStart(_ s: Substring) -> Bool {
      guard s.hasPrefix("<teammate-message") else { return false }
      let after = s.dropFirst("<teammate-message".count)
      return after.first == nil || after.first == ">" || after.first!.isWhitespace
    }
    if tagAtStart(text) { return true }
    // A paste's body starts on its second line, and a pasted relay is still something the
    // person pasted.
    if text.hasPrefix(pastedOpener) { return false }
    guard let newline = text.firstIndex(of: "\n") else { return false }
    let rest = text[text.index(after: newline)...].drop(while: \.isWhitespace)
    return tagAtStart(rest)
  }

  // MARK: - One agent talking to another

  /// Every `<teammate-message>` block in a record, as events worth a line on screen.
  ///
  /// Empty unless `opensWithTeammateMessage` accepts the text, so a person who quotes the
  /// tag mid-sentence keeps their turn.
  ///
  /// **The boilerplate is stripped by construction.** Claude Code writes its warning
  /// paragraph after the last closing tag, and nothing here reads past one, so no wording
  /// has to be matched.
  ///
  /// Two shapes: JSON in the block (`type`, `from`, `timestamp`, `idleReason`, `summary`,
  /// `result`), or markdown with the summary as a `summary="…"` attribute. A record with two
  /// blocks, a final message and an idle notification, yields two events.
  static func agentEvents(in text: String) -> [TranscriptTurn.AgentEvent] {
    guard opensWithTeammateMessage(text.drop(while: \.isWhitespace)) else { return [] }
    var events: [TranscriptTurn.AgentEvent] = []
    var cursor = text.startIndex
    while let open = text.range(of: "<teammate-message", range: cursor..<text.endIndex) {
      // The same tag-name boundary `opensWithTeammateMessage` requires.
      let after = text[open.upperBound...].first
      guard after == ">" || after?.isWhitespace == true else {
        cursor = open.upperBound
        continue
      }
      guard let tagEnd = endOfOpeningTag(in: text, from: open.upperBound),
        let close = text.range(of: "</teammate-message>", range: tagEnd..<text.endIndex)
      else {
        // A record cut off mid-envelope emits nothing and falls through to
        // `isHumanAuthored`, which drops it. A truncated body would be whatever the tail held.
        break
      }
      events.append(
        agentEvent(
          attributes: attributes(in: text[open.upperBound..<tagEnd]),
          body: String(text[tagEnd..<close.lowerBound])
        )
      )
      cursor = close.upperBound
    }
    return events
  }

  /// One block's attributes and body read as an event.
  private static func agentEvent(
    attributes: [String: String],
    body: String
  ) -> TranscriptTurn.AgentEvent {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    // Decoded rather than pattern-matched, so an absent field is not read as empty.
    if trimmed.hasPrefix("{"),
      let payload = try? JSONDecoder().decode(TeammateEnvelope.self, from: Data(trimmed.utf8))
    {
      return TranscriptTurn.AgentEvent(
        sender: nonEmpty(payload.from) ?? attributes["teammate_id"] ?? "",
        summary: nonEmpty(payload.summary).map(sanitised) ?? nonEmpty(attributes["summary"]),
        body: trimmedBody(payload.result ?? ""),
        // `idleReason` is what an idle notification carries; `type` is checked too so drift
        // in either alone does not break it.
        kind: payload.idleReason != nil || payload.type == "idle_notification"
          ? .idle : .message
      )
    }
    // The markdown shape. Never `.idle`: idle notifications are always JSON, and calling
    // this idle would say a teammate stopped when it spoke.
    return TranscriptTurn.AgentEvent(
      sender: attributes["teammate_id"] ?? "",
      summary: nonEmpty(attributes["summary"]),
      body: trimmedBody(body),
      kind: .message
    )
  }

  /// A block's body, sanitised and trimmed. The tag sits on its own line, so the body starts
  /// and ends with the envelope's newlines.
  private static func trimmedBody(_ body: String) -> String {
    sanitised(body).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The JSON an idle notification carries. Every field optional, since only `type` is
  /// reliably present.
  private struct TeammateEnvelope: Decodable {
    var type: String?
    var from: String?
    var summary: String?
    var result: String?
    var idleReason: String?
  }

  /// The index just past the `>` that closes an opening tag. Quote-aware, because a
  /// `summary="…"` attribute is prose and can contain `>`.
  private static func endOfOpeningTag(in text: String, from start: String.Index) -> String.Index? {
    var index = start
    var inQuotes = false
    while index < text.endIndex {
      let character = text[index]
      if character == "\"" {
        inQuotes.toggle()
      } else if character == ">", !inQuotes {
        return text.index(after: index)
      }
      index = text.index(after: index)
    }
    return nil
  }

  /// `teammate_id="eng-6" summary="…"` as a dictionary.
  ///
  /// **Only attribute values are entity-decoded.** A summary arrives with `&apos;` for an
  /// apostrophe. The body is markdown a teammate wrote, and a literal `&amp;` in it means
  /// `&amp;`.
  private static func attributes(in tag: Substring) -> [String: String] {
    var attributes: [String: String] = [:]
    var index = tag.startIndex
    while index < tag.endIndex {
      guard let equals = tag[index...].firstIndex(of: "="),
        let quote = tag[equals...].firstIndex(of: "\""),
        let end = tag[tag.index(after: quote)...].firstIndex(of: "\"")
      else { break }
      let name = tag[index..<equals].trimmingCharacters(in: .whitespaces)
      if !name.isEmpty {
        attributes[name] = entityDecoded(String(tag[tag.index(after: quote)..<end]))
      }
      index = tag.index(after: end)
    }
    return attributes
  }

  /// The five XML entities plus `&#39;`. `&amp;` is decoded **last**; decoding it first
  /// would turn `&amp;lt;` (the text `&lt;`) into `<`.
  static func entityDecoded(_ value: String) -> String {
    var out = value
    for (entity, character) in [
      ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
      ("&amp;", "&"),
    ] {
      out = out.replacingOccurrences(of: entity, with: character)
    }
    return out
  }

  static func isClientEnvelope(_ text: String) -> Bool {
    let trimmed = text.drop(while: \.isWhitespace)
    if opensWithTeammateMessage(trimmed) {
      return true
    }
    return clientEnvelopes.contains { trimmed.hasPrefix("<\($0)>") }
  }

  /// The envelopes that wrap something a person typed. A strict subset of
  /// `clientEnvelopes`: `<task-notification>` and `<local-command-stdout>` were typed by
  /// nobody, while `<command-name>` and `<bash-input>` wrap a person's keystrokes.
  static let commandEnvelopes = ["command-name", "command-message", "command-args", "bash-input"]

  /// What the person typed, out of a client envelope (`/run-tests`, `!git status`), or
  /// `nil`. Without this, a session driven by slash commands shows the agent answering
  /// questions nobody asked.
  ///
  /// Still refused:
  ///
  /// - `/clear`, which is never typed into this session; see `brief(from:)`. Skipped in
  ///   `slashCommand`.
  /// - Envelopes that are not commands, such as `local-command-stdout`.
  /// - A message that only mentions a tag. The envelope must open the message.
  ///
  /// The whole `bash-input` body is kept, unlike the brief, because a chat turn is not one
  /// line.
  static func commandTyped(in text: String) -> String? {
    let leading = text.drop(while: \.isWhitespace)
    guard commandEnvelopes.contains(where: { leading.hasPrefix("<\($0)>") }) else { return nil }
    let body = String(leading)
    if let command = slashCommand(in: body) { return command }
    if let bash = tagged("bash-input", in: body) {
      let typed = bash.trimmingCharacters(in: .whitespacesAndNewlines)
      return typed.isEmpty ? nil : "!" + typed
    }
    return nil
  }

  /// The question an `AskUserQuestion` call put to the person, or `nil`.
  ///
  /// Keyed on the typed field `questions[].question`, not on the tool's name. The agent
  /// wrote the input, so the words are the agent's. Several questions are joined by a blank
  /// line. `replyQuestions(of:answers:)` reads the options.
  static func questions(of block: ClaudeBlock) -> String? {
    let asked = (block.input?.questions ?? [])
      .compactMap(\.question)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !asked.isEmpty else { return nil }
    return asked.joined(separator: "\n\n")
  }

  /// The questions an `AskUserQuestion` call offered answers for, one entry each, for the
  /// reply chips.
  ///
  /// **Every question, not the first.** A call carries one to four, each with its own
  /// options and `multiSelect`, and the answer is keyed by question text.
  ///
  /// A question with no usable option label is dropped. If all drop, the result is `[]`,
  /// and `ToolCall.replyChipGroups` shows the generic Approve/Deny pair.
  ///
  /// Dropped entries still count: each option keeps its picker number and each question the
  /// call's question count, because the answer is typed by the picker's numbers and tabs.
  ///
  /// `answers` is the call's `toolUseResult.answers` once answered. The key is tried as
  /// written and then trimmed, because the question here is trimmed and the key is not.
  static func replyQuestions(
    of block: ClaudeBlock, answers: [String: String]? = nil
  ) -> [PendingQuestion] {
    let questions = block.input?.questions ?? []
    return questions.compactMap { asked in
      let numbered = (asked.options ?? []).enumerated().compactMap { index, option in
        let label = (option.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty
          ? nil : (number: index + 1, label: label, description: nonEmpty(option.description))
      }
      guard !numbered.isEmpty else { return nil }
      let question = (asked.question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let answer = asked.question.flatMap { answers?[$0] } ?? answers?[question]
      return PendingQuestion(
        question: question,
        options: numbered.map(\.label),
        allowsMultiple: asked.multiSelect ?? false,
        optionNumbers: numbered.map(\.number),
        askedInCall: questions.count,
        header: nonEmpty(asked.header),
        optionDescriptions: numbered.map(\.description),
        answer: answer
      )
    }
  }

  /// Terminal control sequences removed from text that will be read as prose. A person can
  /// paste coloured terminal output, and `\u{1B}[1m` as prose is garbage.
  ///
  /// **One scanner, shared with `PaneScreenParser`**, so the two escape grammars cannot
  /// drift. The screen semantics are not shared: a `PaneScreen` clamps columns and rows,
  /// which is wrong for a chat message.
  private static func sanitised(_ text: String) -> String {
    PaneScreenText.plain(text)
  }

  private struct OpenRun {
    let id: String
    let at: Date?
    var calls: [ToolCall] = []
    /// Whether the newest call has a `tool_use` id. Without one it can never be matched to
    /// a result, so it stays `.unknown` rather than pending.
    var lastCallHasIdentifier = false
  }

  private static func joinedText(_ blocks: [ClaudeBlock]) -> String {
    blocks.filter(\.isText).compactMap(\.text).joined(separator: "\n")
  }

  /// The `image` blocks of one record, as far as they can be drawn.
  ///
  /// **Fewer entries than blocks is ordinary.** Each missing entry is still counted in
  /// `TranscriptTurn.attachedImages`, which draws an `N images` label instead. No entry for:
  ///
  /// - an encoded payload over `TranscriptImage.maxEncodedBytes`, checked before decoding;
  /// - invalid base64. **Strict decoding**: `.ignoreUnknownCharacters` would make a corrupt
  ///   payload a wrong image, which is worse than a label. Real payloads are one unbroken
  ///   line;
  /// - an unknown `source.type`;
  /// - a `file`, `url` or `path` source with no path.
  ///
  /// A `file` source with a path becomes a `.remote` image, carried but not drawn; the turn
  /// shows its label. Fetching one is not built, because no real record has used it.
  ///
  /// The index counts **image** blocks only, since the caller passes
  /// `content.blocks.filter(\.isImage)`. So an image's id does not move when a text block
  /// beside it changes, and with the record's uuid it is stable across reads, which the
  /// byte-free `==` on `TranscriptImage` needs.
  private static func mappedImages(
    _ blocks: [ClaudeBlock],
    of turnID: String
  ) -> [TranscriptImage] {
    blocks.enumerated().compactMap { index, block in
      guard let source = block.source else { return nil }
      let id = "\(turnID)#image\(index)"
      // Empty rather than a default, per `TranscriptImage.mediaType`.
      let mediaType = source.mediaType ?? ""
      switch source.type {
      case "base64":
        guard let encoded = source.data,
          encoded.utf8.count <= TranscriptImage.maxEncodedBytes,
          let bytes = Data(base64Encoded: encoded),
          !bytes.isEmpty
        else { return nil }
        return TranscriptImage(
          id: id, mediaType: mediaType, byteCount: bytes.count, source: .inline(bytes))
      case "file", "path", "url":
        guard let located = nonEmpty(source.path) ?? nonEmpty(source.url) else { return nil }
        return TranscriptImage(
          id: id, mediaType: mediaType, byteCount: 0, source: .remote(path: located))
      default:
        return nil
      }
    }
  }

  /// A short name for what a tool call was about, or `nil`.
  ///
  /// Ordered by how much a field tells a reader: a path's last component identifies an
  /// `Edit`, and `Bash`'s `description` beats its `command`. `command` is late and
  /// first-line-only, because a heredoc is not a label.
  ///
  /// Not a general summary. A tool whose input is a structure, such as `AskUserQuestion`,
  /// yields nothing; its question becomes a turn in `questions(of:)`.
  static func target(of block: ClaudeBlock) -> String? {
    guard let input = block.input else { return nil }
    // `ScheduleWakeup` carries a one-line `reason` for a reader and a long `prompt` for an
    // agent. Reaching `prompt` through the shared chain would put it before every other
    // tool's arguments, so a name-keyed entry keeps it local.
    if let name = block.name, let keys = targetKeys[name] {
      for key in keys {
        if let value = nonEmpty(input[key]) { return shorten(firstLine(value)) }
      }
    }
    for key in ["file_path", "notebook_path", "path"] {
      if let value = nonEmpty(input[key]) { return shorten(lastPathComponent(value)) }
    }
    // `caption` to `summary` sit **after** `command`, as `description` sits before it: a
    // tool with a command has already said what it is about.
    for key in [
      "pattern", "query", "url", "skill", "description", "caption", "command", "title",
      "reason", "to", "summary",
    ] {
      if let value = nonEmpty(input[key]) { return shorten(firstLine(value)) }
    }
    return nil
  }

  /// Tools whose fields are read in their own order, ahead of the chain.
  private static let targetKeys: [String: [String]] = [
    "ScheduleWakeup": ["reason", "prompt"]
  ]

  // MARK: - This session's own agent traffic

  /// The three tools a session drives a team of agents with. Their calls leave the run and
  /// become lines of their own.
  ///
  /// Keyed on the **tool's name**, unlike the rest of this file. This is the difference
  /// between something that happened and a tool that was used, and only the name says
  /// which; the fields (`to`, `task_id`, `subagent_type`) are ordinary strings any tool may
  /// carry.
  static func agentTraffic(
    of block: ClaudeBlock,
    spawns: [String: String],
    agentNames: [String: String] = [:]
  ) -> TranscriptTurn.AgentEvent? {
    guard let name = block.name, let input = block.input else { return nil }
    switch name {
    case "Agent":
      // `name` is how the team addresses this agent and what its `TaskStop` names.
      // `subagent_type` stands in when there is no name.
      let spawned = nonEmpty(input["name"]) ?? nonEmpty(input["subagent_type"])
      let describes = label(input["description"])
      guard spawned != nil || describes != nil else { return nil }
      return TranscriptTurn.AgentEvent(
        sender: spawned ?? "", summary: describes, body: "", kind: .spawned
      )
    case "TaskStop":
      guard let id = nonEmpty(input["task_id"]) else { return nil }
      // **`task_id` has two shapes.** Claude Code wrote the teammate's name until about
      // 2026-10-13; by 2026-10-22 it writes the spawn answer's `agentId`
      // (`"a" + name + "-" + hex`). Either resolves to the name, which is what the spawn line
      // and `settleSpawns` key on.
      let stopped = agentNames[id] ?? id
      // The spawn's description when this page carried the spawn. **Never a guess**: a
      // stop whose spawn fell off the front of the page shows the bare id.
      return TranscriptTurn.AgentEvent(
        sender: stopped, summary: spawns[stopped], body: "", kind: .stopped
      )
    case "SendMessage":
      let to = nonEmpty(input["to"]) ?? nonEmpty(input["recipient"])
      // The tool's one-line summary first. The message is markdown whose first line is often
      // a heading, so it is only the fallback.
      let says = label(input["summary"]) ?? label(input["message"]) ?? label(input["content"])
      guard to != nil || says != nil else { return nil }
      return TranscriptTurn.AgentEvent(sender: to ?? "", summary: says, body: "", kind: .sent)
    default:
      return nil
    }
  }

  /// Which sub-agent file a spawn opens.
  ///
  /// **A teammate links by the name it was spawned under**, because its meta file has no
  /// `toolUseId`. Only `input["name"]` is used: the spawn line's `subagent_type` fallback is
  /// never a meta file's `name`, and could match a teammate named after a type.
  ///
  /// A spawn is a teammate when its answer says `teammate_spawned`. Every other spawn links
  /// by its `tool_use` id. `nil` when the field it would link by is empty.
  static func subagentLink(of block: ClaudeBlock, answers: Results) -> SubagentLink? {
    guard let id = nonEmpty(block.id) else { return nil }
    if answers.launches[id]?.status == "teammate_spawned" {
      return nonEmpty(block.input?["name"]).map { .teammate(name: $0) }
    }
    return .toolUse(id: id)
  }

  /// An `Agent` call's id and description, for the map a later `TaskStop` reads. `nil` if
  /// either is missing.
  static func spawn(of block: ClaudeBlock) -> (id: String, description: String)? {
    guard block.name == "Agent", let input = block.input,
      let id = nonEmpty(input["name"]), let description = label(input["description"])
    else { return nil }
    return (id, description)
  }

  /// A field as one readable line: escapes out, first line only, bounded like a target.
  private static func label(_ value: String?) -> String? {
    guard let value = nonEmpty(value) else { return nil }
    let line = firstLine(sanitised(value)).trimmingCharacters(in: .whitespacesAndNewlines)
    return line.isEmpty ? nil : shorten(line)
  }

  private static func lastPathComponent(_ value: String) -> String {
    value.split(separator: "/").last.map(String.init) ?? value
  }

  private static func firstLine(_ value: String) -> String {
    String(value.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
  }

  /// One line of a row. Cut on characters rather than words, because a target is a filename
  /// or command fragment with no useful word boundary.
  private static let targetLimit = 80

  private static func shorten(_ value: String) -> String {
    guard value.count > targetLimit else { return value }
    return value.prefix(targetLimit - 1) + "…"
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }

  // MARK: - Codex rollouts

  /// Codex's records in, `DriverrCore` turns out; the counterpart to `page(from:)`.
  ///
  /// `UserMessage` and `AgentMessage` items become human and assistant turns;
  /// `custom_tool_call` and `function_call` items become a tool run. Only an
  /// `exec_command`-shaped call can get an outcome other than `.unknown`; see
  /// `codexOutcomes(in:)`. A run is closed by the next thing somebody said, as for Claude.
  static func codexPage(from text: String) -> Page {
    var page = Page()
    var run: [ToolCall] = []
    // The opening call's item id and timestamp, so the run's id survives a moved byte
    // bound. A positional id would change every time the window grew.
    var runID: String?
    var runAt: Date?
    // Whether the run's last call can become `.pending`: an `exec_command`-shaped call
    // with no matched outcome. `apply_patch`, `web__run` and `write_stdin` never produce a
    // `CommandExecution`, so marking one pending would claim a wait nothing can confirm.
    var lastCallEligibleForPending = false

    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    var outcomes = codexOutcomes(in: lines)

    func closeRun(atEndOfPage: Bool = false) {
      guard !run.isEmpty else { return }
      if atEndOfPage, outcomes.scanned, lastCallEligibleForPending,
        let last = run.last, last.outcome == .unknown
      {
        run[run.count - 1] = ToolCall(
          name: last.name, target: last.target, outcome: .pending, questions: last.questions
        )
      }
      page.turns.append(
        TranscriptTurn(id: runID ?? "codex-run-\(page.turns.count)", speech: .tools(ToolRun(calls: run)), at: runAt)
      )
      run = []
      runID = nil
      runAt = nil
      lastCallEligibleForPending = false
    }

    for (index, line) in lines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      // An outcome line is not a record, as in `page(from:)`.
      guard !trimmed.hasPrefix(TranscriptCommands.resultMark) else { continue }
      guard let record = try? JSONDecoder().decode(CodexRecord.self, from: Data(trimmed.utf8))
      else {
        page.unreadableRecords += 1
        continue
      }
      page.records += 1
      guard let payload = record.payload else { continue }
      let at = timestamp(record.timestamp)

      switch record.type {
      case "event_msg":
        guard payload.type == "item_completed", let item = payload.item else { continue }
        switch item.type {
        case "UserMessage":
          let said = codexJoinedText(item.content)
          guard !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
          closeRun()
          page.turns.append(
            TranscriptTurn(
              id: item.id ?? "codex-record-\(index)", speech: .human(sanitised(said)), at: at)
          )
        case "AgentMessage":
          let said = codexJoinedText(item.content)
          guard !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
          closeRun()
          page.turns.append(
            TranscriptTurn(
              id: item.id ?? "codex-record-\(index)", speech: .assistant(sanitised(said)), at: at)
          )
        default:
          // The selector drops every other item type before it gets here.
          continue
        }

      case "response_item":
        switch payload.type {
        case "custom_tool_call":
          guard let name = payload.name, !name.isEmpty else { continue }
          if run.isEmpty {
            runID = payload.id
            runAt = at
          }
          let execCommands = codexExecCommandLiterals(in: payload.input)
          let outcome = codexOutcome(for: execCommands, outcomes: &outcomes)
          run.append(
            ToolCall(
              name: name, target: codexTarget(ofExecInput: payload.input), outcome: outcome
            )
          )
          lastCallEligibleForPending = !execCommands.isEmpty && outcome == .unknown
        case "function_call":
          guard let name = payload.name, !name.isEmpty else { continue }
          if run.isEmpty {
            runID = payload.id
            runAt = at
          }
          run.append(
            ToolCall(name: name, target: codexTarget(ofArguments: payload.arguments))
          )
          lastCallEligibleForPending = false
        default:
          continue
        }

      default:
        continue
      }
    }
    closeRun(atEndOfPage: true)
    return page
  }

  // MARK: - Codex tool outcomes

  /// The host's answer about `CommandExecution` completions, read off the outcome lines. The
  /// counterpart to `Results`, with the same `scanned` distinction.
  ///
  /// **A queue per command**, because two calls can run the identical command in one page,
  /// and completions answer them in order.
  struct CodexOutcomes {
    var scanned = false
    private var byCommand: [String: [ToolCall.Outcome]] = [:]

    mutating func add(command: String, outcome: ToolCall.Outcome) {
      byCommand[command, default: []].append(outcome)
    }

    /// Claims the oldest unclaimed outcome for this exact command text. `nil`, read as
    /// `.unknown`, when the completion is outside the window or the call was not an
    /// `exec_command`.
    mutating func consume(command: String) -> ToolCall.Outcome? {
      guard var queue = byCommand[command], !queue.isEmpty else { return nil }
      let outcome = queue.removeFirst()
      byCommand[command] = queue
      return outcome
    }
  }

  /// Parses `TranscriptCommands.codexOutcomeProgram`'s lines, in a pass of its own for
  /// `results(in:)`'s reason.
  static func codexOutcomes(in lines: [Substring]) -> CodexOutcomes {
    var outcomes = CodexOutcomes()
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.hasPrefix(TranscriptCommands.resultMark) else { continue }
      outcomes.scanned = true
      let fields = trimmed.dropFirst(TranscriptCommands.resultMark.count)
        .split(separator: TranscriptCommands.fieldSeparator, omittingEmptySubsequences: false)
      // `id`/`status`/`exit_code`/`command`. Only `status` and `command` (the join key) are
      // read.
      guard fields.count == 4 else { continue }
      let outcome: ToolCall.Outcome
      switch fields[1] {
      case "completed": outcome = .succeeded
      case "failed": outcome = .failed
      default: continue
      }
      guard let command = codexUnescape(String(fields[3])) else { continue }
      outcomes.add(command: command, outcome: outcome)
    }
    return outcomes
  }

  /// A call's outcome from its `exec_command` sub-calls. **Worst case wins**: a
  /// `Promise.all` batch with one failed command failed. `.unknown` when there are no
  /// sub-calls or none matched.
  ///
  /// **Every sub-call is consumed before deciding.** Returning early on a failure would
  /// leave later sub-calls' completions in the queue, and the next call running the same
  /// command would claim one that is not its own.
  private static func codexOutcome(
    for execCommands: [String], outcomes: inout CodexOutcomes
  ) -> ToolCall.Outcome {
    var matched: ToolCall.Outcome?
    for command in execCommands {
      guard let claimed = outcomes.consume(command: command) else { continue }
      if matched != .failed { matched = claimed }
    }
    return matched ?? .unknown
  }

  /// Every `exec_command` literal in a `custom_tool_call`'s JavaScript `input`, in order. A
  /// body can issue several through `Promise.all`. Empty for any other shape, which never
  /// produces a `CommandExecution`.
  private static func codexExecCommandLiterals(in input: String?) -> [String] {
    guard let input, !input.isEmpty, let regex = codexCmdLiteralRegex else { return [] }
    let range = NSRange(input.startIndex..<input.endIndex, in: input)
    return regex.matches(in: input, range: range).compactMap { match in
      guard match.numberOfRanges > 1, let group = Range(match.range(at: 1), in: input)
      else { return nil }
      return codexUnescape(String(input[group]))
    }
  }

  /// `cmd:"…"` **or** `"cmd":"…"`, capturing the still-escaped bytes between the quotes.
  /// Codex writes both spellings in roughly equal numbers, and missing either silently
  /// leaves those calls unjoinable.
  ///
  /// `(?:[^"\\]|\\.)*` is the usual quoted-string idiom, so an escaped quote never ends the
  /// match early.
  private static let codexCmdLiteralRegex = try? NSRegularExpression(
    pattern: #"(?:"cmd"|cmd)\s*:\s*"((?:[^"\\]|\\.)*)""#
  )

  /// Decodes the escaped bytes of one JSON or JS double-quoted string. Both sides of the
  /// `exec_command` join go through this so they compare like text. JS and JSON escapes
  /// agree for everything a shell command uses (`\"`, `\\`, `\n`, `\t`, `\r`). `nil` when the
  /// text does not decode, and the command is not joined.
  static func codexUnescape(_ raw: String) -> String? {
    guard let data = "\"\(raw)\"".data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(String.self, from: data)
  }

  /// A message's content blocks joined as one message. The block `type` is compared
  /// case-insensitively; see `CodexContentBlock`. A `skill` block has no text and adds
  /// nothing.
  private static func codexJoinedText(_ blocks: [CodexContentBlock]?) -> String {
    (blocks ?? [])
      .filter { ($0.type ?? "").lowercased() == "text" }
      .compactMap(\.text)
      .joined(separator: "\n")
  }

  /// A `custom_tool_call`'s target: the first line of its JavaScript `input`, since that is
  /// not JSON.
  private static func codexTarget(ofExecInput input: String?) -> String? {
    guard let input else { return nil }
    let firstLine = String(input.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
    let line = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    return line.isEmpty ? nil : shorten(line)
  }

  /// A `function_call`'s target, from its JSON `arguments`.
  ///
  /// **`target` is checked before `message`.** A `send_message` call carries both, and its
  /// `message` is ciphertext (`gAAAAABq…`), which must not become a row label.
  private static func codexTarget(ofArguments arguments: String?) -> String? {
    guard let arguments, let data = arguments.data(using: .utf8),
      let values = try? JSONDecoder().decode([String: CodexArgumentValue].self, from: data)
    else { return nil }
    for key in ["task_name", "agent_type", "target", "message", "query", "command", "name"] {
      if let value = values[key]?.string, !value.isEmpty {
        return shorten(firstLine(value))
      }
    }
    return nil
  }

  /// One argument value, read only when it is a string, as `ToolInput.values` does.
  private struct CodexArgumentValue: Decodable {
    let string: String?
    init(from decoder: any Decoder) throws {
      string = try? decoder.singleValueContainer().decode(String.self)
    }
  }

  /// `2026-08-24T15:04:04.988Z`, and the same without the fraction. Two styles, because the
  /// fractional one rejects a timestamp without a fraction, and a failed parse costs the
  /// turn its date.
  ///
  /// `Date.ISO8601FormatStyle` rather than `ISO8601DateFormatter`, a class with mutable
  /// options that cannot be an honest `static let` under strict concurrency.
  private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  private static let whole = Date.ISO8601FormatStyle()

  static func timestamp(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    return (try? fractional.parse(value)) ?? (try? whole.parse(value))
  }
}
