import Foundation

/// What the pane screen says about a transcript, as values rather than as view code.
///
/// The rule every sentence on that screen follows: never present a guess as a fact. A
/// heuristic match says what it guessed from and how fresh the file is, a parse failure says
/// what failed, and an unresolvable directory refuses rather than drawing its newest file.
/// The sentences live here so `swift test` can assert them.

// MARK: - How old a file is

/// A file's age, in the largest unit that fits.
///
/// Sub-minute precision is the signal: `written 12s ago` means the session is live, and it
/// matches the one-minute window `TranscriptFile.isLive` uses. `WaitedFor` is a separate
/// formatter on purpose, because it says `just now` for anything under a minute. Do not
/// build either on the other.
public enum TranscriptAge {
  public static func phrase(for age: TimeInterval) -> String {
    // Built here so a file written this second does not read "written just now ago".
    let elapsed = elapsed(age)
    return elapsed == justNow ? "written \(elapsed)" : "written \(elapsed) ago"
  }

  /// What a file written this second reads as. Not `0s`, which reads as a stopped clock.
  static let justNow = "just now"

  /// Written on its own, for a line that already carries the word.
  public static func elapsed(_ age: TimeInterval) -> String {
    let seconds = max(0, age)
    if seconds < 1 { return justNow }
    if seconds < 60 { return "\(Int(seconds))s" }
    if seconds < 3600 { return "\(Int(seconds / 60))m" }
    if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
    return "\(Int(seconds / 86_400))d"
  }
}

// MARK: - The provenance header

/// The one row above the transcript, in its three variants.
///
/// One type with one `caption` and one `detail`, not an enum the view switches over,
/// because three layouts drift.
public struct TranscriptHeader: Equatable, Sendable {
  /// The agent's own name, so a Codex session is never labelled as Claude.
  public let agentName: String
  public let provenance: TranscriptProvenance
  /// The pane's working directory. Only the directory match uses it.
  public let directory: String
  public let fileName: String
  /// The file's age at the moment this header was built, not when the page was fetched.
  ///
  /// On a directory match this is the only freshness evidence, so a frozen age would vouch
  /// for a finished session. `asOf` is a parameter so a `TimelineView` can advance it and
  /// tests can inject a date.
  public let age: TimeInterval?
  /// The page's context count, drawn beside `caption`, never inside it. With a count, the
  /// phone elides the middle of the caption, and the count must not be what it eats.
  public let contextUsage: ContextUsage?
  /// Whether the session id came from Claude Code's own record, not from herdr.
  private let isFromClaudeRecord: Bool

  /// `session` is the pane's, because `provenance` does not say who named the session.
  public init(
    agentName: String,
    source: TranscriptSource,
    session: AgentSession? = nil,
    contextUsage: ContextUsage? = nil,
    asOf now: Date = Date()
  ) {
    self.agentName = agentName
    provenance = source.provenance
    directory = source.directory
    fileName = source.file.name
    age = source.age(asOf: now)
    self.contextUsage = contextUsage
    isFromClaudeRecord = session?.source == AgentSession.claudeRecordSource
  }

  /// The whole pinned row as one line: the kind of match and how fresh the file is.
  ///
  /// The row truncates in the middle, so the age stays the last segment and survives. The
  /// scope phrases are kept short so a row with no context count fits whole on a 402 pt
  /// phone, where the caption gets 341 pt. `TranscriptPresentationTests.theScopeLeavesRoomForTheAge`
  /// and `ProvenanceCaptionLayoutTests` pin both.
  public var caption: String {
    let scope: String
    switch provenance {
    // A continued session reads the same: Claude Code named the successor itself, so the
    // match is as exact as herdr's.
    case .reportedByHerdr, .continuedFromHerdrSession:
      scope = isFromClaudeRecord ? "from Claude's record" : "reported by herdr"
    // Keep this short. A longer phrase pushed the age off the end of the row on a phone.
    case .matchedByDirectory: scope = "matched by directory"
    case .chosenByHand: scope = "you picked this file"
    case .subagent: scope = "sub-agent"
    }
    let base = "\(agentName) session · \(scope)"
    guard let age else { return base }
    return "\(base) · \(TranscriptAge.phrase(for: age))"
  }

  /// The raw evidence `caption` leaves out (a uuid, a directory, a filename), behind a
  /// long-press. Never the age, which `caption` already states.
  public var detail: String {
    switch provenance {
    case .reportedByHerdr(let sessionID):
      sessionID
    // The session on screen, not the one herdr named, so it matches `fileName`.
    case .continuedFromHerdrSession(_, let sessionID):
      sessionID
    case .chosenByHand, .subagent:
      fileName
    case .matchedByDirectory:
      directory
    }
  }

  /// Whether this variant has nothing to caveat. Only the green check reads it.
  public var isExact: Bool {
    switch provenance {
    case .reportedByHerdr, .continuedFromHerdrSession, .subagent: return true
    case .matchedByDirectory, .chosenByHand: return false
    }
  }

  /// `caption` and `detail` together, because a long-press is not discoverable to VoiceOver.
  public var accessibilityLabel: String { "\(caption). \(detail)" }

  /// A value rather than a sibling element, so the row stays one element and its label
  /// still opens with the caption the UI tests match on.
  public var accessibilityValue: String? { contextUsage?.spoken }
}

// MARK: - Which absences deserve a notice at all

extension TranscriptAbsence {
  /// Whether Driverr will never read this agent's conversation, whatever the pane does.
  ///
  /// Only `agentNotSupported` is a fact about the agent kind, and most of herdr's agent
  /// kinds are in it permanently, so it must not be shown as an error. Every other absence
  /// is about this pane at this moment and keeps its notice.
  public var isUnreadableAgentKind: Bool {
    if case .agentNotSupported = self { return true }
    return false
  }
}

extension TranscriptResolution {
  /// Whether this answer is simply what this agent is. See
  /// `TranscriptAbsence.isUnreadableAgentKind`.
  public var isUnreadableAgentKind: Bool {
    guard case .absent(let absence) = self else { return false }
    return absence.isUnreadableAgentKind
  }
}

// MARK: - When there is no chat to draw

/// Something the chat surface says instead of a conversation: a parse failure, an absence
/// or a refusal.
///
/// One type because `Show the Screen` is the way out of every one of them, and it always
/// works where Driverr can read the pane's screen. A failure with no way out is a dead end.
public struct TranscriptNotice: Equatable, Sendable {
  /// `nil` where the notice sits under turns that did parse, so it does not read as a
  /// heading over the conversation.
  public let title: String?
  public let message: String
  /// Lines under the message: the ambiguity screen's candidate files, otherwise empty.
  public let evidence: [String]
  /// Whether the file picker is the primary way out. Only ambiguity has it.
  public let offersFilePicker: Bool
  /// Whether asking again could produce a different answer. Only a fault can.
  public let offersRetry: Bool
  /// Stored rather than constant so a failure with no screen behind it drops the exit
  /// instead of showing a button that does nothing.
  public let offersScreen: Bool
  /// The glyph `ContentUnavailableView` draws. Stored, not inferred from other fields, so it
  /// cannot drift when one of them changes.
  public let symbolName: String

  public init(
    title: String?,
    message: String,
    evidence: [String] = [],
    offersFilePicker: Bool = false,
    offersRetry: Bool = false,
    offersScreen: Bool = true,
    symbolName: String = "exclamationmark.triangle"
  ) {
    self.title = title
    self.message = message
    self.evidence = evidence
    self.offersFilePicker = offersFilePicker
    self.offersRetry = offersRetry
    self.offersScreen = offersScreen
    self.symbolName = symbolName
  }

  /// Never over a sub-agent's chat, because the captured screen is the pane's, not the
  /// sub-agent's. Never where Driverr cannot read the pane's screen, because the button would
  /// only fail: it has not implemented that for a herdr-core terminal.
  public func offersScreen(inSubagentChat: Bool, canReadScreen: Bool) -> Bool {
    offersScreen && !inSubagentChat && canReadScreen
  }

  /// The exits' titles, kept with the rest of the screen's copy.
  public static let showScreenTitle = "Show the Screen"
  public static let chooseFileTitle = "Choose a File"

  /// How a page ended, or `nil` for a clean page.
  ///
  /// A file that stops mid-record is what a session being written looks like, so a
  /// `.working` pane gets "still writing". Every other status, `nil` included, keeps the
  /// fault wording. `bytesFetched` goes through `ByteSize.phrase`, as `TranscriptPaging.held`
  /// does, so the two never disagree.
  public init?(
    outcome: TranscriptOutcome, turnCount: Int, bytesFetched: Int, agentStatus: AgentStatus?
  ) {
    switch outcome {
    case .parsed:
      return nil
    case .endsMidRecord:
      let turns = turnCount == 1 ? "1 turn" : "\(turnCount) turns"
      let held = "\(turns) · \(ByteSize.phrase(bytesFetched))"
      if agentStatus == .working {
        self.init(
          title: nil,
          message: "The agent is still writing. \(held) so far.",
          symbolName: "ellipsis.bubble"
        )
      } else {
        // The count says how much of the file the reader is looking at.
        self.init(
          title: nil,
          message: "The file ends mid-record. \(held) parsed. Anything after that is unreadable.",
          symbolName: "exclamationmark.triangle"
        )
      }
    case .noReadableTurns where agentStatus == .idle:
      self.init(
        title: "No turns yet",
        message: "Nothing has been said in this session.",
        symbolName: "ellipsis.bubble"
      )
    case .noReadableTurns:
      self.init(
        title: "No readable turns in this file",
        message:
          "Driverr read the file and found no conversation in it. It may belong to another "
          + "kind of agent.",
        symbolName: "doc.text.magnifyingglass"
      )
    }
  }

  /// Why a pane has no transcript at all.
  ///
  /// `agentStatus` decides whether a missing file is a wait or a fault. A session's file is
  /// written with its first prompt, so an idle agent with no file is waiting. A working or
  /// finished agent has had its prompt, so a missing file is a fault. A blocked agent keeps
  /// the wait, because a new Claude on its trust prompt reports blocked before any prompt
  /// (`FakeControl.treeWithUnstartedAgent`). No default, so a call site cannot forget it.
  ///
  /// `canReadScreen` is `offersScreen(inSubagentChat:canReadScreen:)`'s, so no sentence names
  /// a button that is not drawn.
  public init(absence: TranscriptAbsence, agentStatus: AgentStatus?, canReadScreen: Bool = true) {
    let leftTheDirectory = "If this pane has left the directory the agent started in,"
    let fileWillNotAppear = "the file will not appear here"
    switch absence {
    case .noSessionFiles(let directory) where Self.hasHadAPrompt(agentStatus),
      .reportedSessionMissing(_, let directory) where Self.hasHadAPrompt(agentStatus):
      // Both absences, because `TranscriptReader` maps a reported id in a directory with no
      // files to `noSessionFiles`. "for" rather than "in" and no agent named, because Codex
      // rollouts are matched by `cwd` rather than stored in the directory. Retry stays
      // because a file that lands late is a different answer.
      self.init(
        title: "The session file is missing",
        message:
          "The agent has started, but Driverr found no session file for \(directory). "
          + "\(leftTheDirectory) "
          + (canReadScreen ? "use \(Self.showScreenTitle)." : "\(fileWillNotAppear)."),
        offersRetry: true,
        symbolName: "exclamationmark.triangle"
      )
    case .paneHasNoAgent:
      // Unreachable from the pane screen, since a shell pane has no chat segment. Present so
      // the mapping is total.
      self.init(
        title: "No agent in this pane",
        message: "This pane is a plain shell, so there is no conversation to read.",
        symbolName: "terminal"
      )
    case .agentNotSupported(let agent):
      // `questionmark.bubble` joins `text.bubble` and `ellipsis.bubble` as the conversation
      // glyphs. `questionmark.circle` reads as "tap for help" and this does nothing on tap.
      self.init(
        title: "Driverr can't read \(agent)'s conversation",
        message:
          "Driverr reads session files written by \(TranscriptAgent.supportedNames). "
          + "\(agent) keeps its conversation somewhere else.",
        symbolName: "questionmark.bubble"
      )
    case .paneHasNoDirectory:
      self.init(
        title: "No directory for this pane",
        message:
          "Driverr finds a session file from the pane's working directory. herdr has not "
          + "reported one for this pane.",
        symbolName: "questionmark.folder"
      )
    case .noSessionFiles(let directory):
      // Offers retry because `loadIfNeeded` does not ask again on its own. The composer
      // below is live, so the message invites sending rather than reading as a dead end.
      self.init(
        title: "No session file yet",
        message:
          // "for", not "in": Codex reaches this case, and its rollouts are matched by `cwd`.
          "Driverr found no session file for \(directory). Send a message below to start "
          + "the conversation.",
        offersRetry: true,
        symbolName: "text.bubble"
      )
    case .reportedSessionMissing(_, let directory):
      // Never fall back to the newest file in the directory: it would draw another agent's
      // conversation.
      //
      // A wait, not a fault, for an agent that has not had its prompt. A new Claude session
      // is named before its file exists, so this is how every new session in a directory
      // with older ones looks. It shares `noSessionFiles`'s title, glyph and retry. No
      // session id, because a UUID wraps badly on a phone. The wording does not claim Codex
      // defers its file to the first prompt, which is not established. The last sentence
      // covers a pane that left the agent's directory, where the file never arrives.
      self.init(
        title: "No session file yet",
        message:
          "The agent has not written its session file for \(directory) yet. Send a message "
          + "below to start the conversation. \(leftTheDirectory) \(fileWillNotAppear)"
          + (canReadScreen ? ", so use \(Self.showScreenTitle)." : "."),
        offersRetry: true,
        symbolName: "text.bubble"
      )
    case .agentOnAddedMachine(let agent, let machine):
      // No `Show the Screen`: Driverr has not implemented reading a core terminal's screen,
      // so the button would only fail. No retry either, because the answer cannot change.
      self.init(
        title: "\(agent) is running on \(machine)",
        message:
          "Driverr reads conversations on the computer it connected to, and this terminal is "
          + "on \(machine).",
        offersScreen: false,
        symbolName: "desktopcomputer"
      )
    case .subagentFileNotFound:
      // No `Show the Screen`: the pane's screen is the parent's. The back bar is the exit.
      self.init(
        title: "No file for this agent yet",
        message:
          "Driverr found no session file for this agent. It may not have started writing "
          + "one yet.",
        offersRetry: true,
        offersScreen: false,
        symbolName: "text.bubble"
      )
    }
  }

  /// Whether an agent in this state has had its first prompt, and so has written its
  /// session file. Exhaustive, so a new status has to take a side. `unknown` and `nil` keep
  /// the wait, because calling a fault on a state Driverr does not understand is worse.
  private static func hasHadAPrompt(_ status: AgentStatus?) -> Bool {
    switch status {
    case .working, .done: true
    // Blocked can be a new session on its trust prompt, before any prompt.
    case .blocked, .error, .idle, .unknown, nil: false
    }
  }

  /// The host refused, or the link went away.
  ///
  /// Its own initialiser because it is the only fault: every other notice states something
  /// true about the pane, and asking again gives the same answer. This one might not.
  public init(failure: AppError) {
    self.init(
      title: "Driverr couldn't read the session file",
      // The error's own words. `AppError` already made them actionable.
      message: failure.errorDescription ?? "Something went wrong.",
      offersRetry: true,
      // Not `wifi.exclamationmark`: this also covers faults that are not network faults.
      // The triangle is shared with other faults that cannot be on screen together.
      symbolName: "exclamationmark.triangle"
    )
  }

  /// Two live sessions in one directory: a refusal.
  ///
  /// Nothing is drawn behind this, because a best guess would be another agent's
  /// conversation. The way out is the picker or the screen.
  ///
  /// The live count uses `TranscriptFile.isLive`, the resolver's own rule, over the whole
  /// directory. The list is `TranscriptPicker`'s, so what is read here is what is chosen
  /// from. It is bounded so the exits stay on screen, and the message says what was left
  /// out, because a silent cap reads as "these are all of them".
  public init?(ambiguous directory: String, candidates: [TranscriptFile]) {
    let live = candidates.filter(\.isLive).count
    let refusal =
      "The newest could belong to another agent, so Driverr won't pick for you."
    let cause =
      live > 1
      ? "\(live) session files in this directory were written in the last minute."
      // Not "0 files were written in the last minute", which invites "why not the newest?".
      : "Driverr couldn't read how recently these files were written."
    let picker = TranscriptPicker(directory: directory, candidates: candidates)
    self.init(
      title: "Driverr can't tell which session belongs to this pane",
      message: [cause, refusal, picker.omittedNote].compactMap { $0 }.joined(separator: " "),
      evidence: picker.candidates.map(\.detail),
      offersFilePicker: true,
      symbolName: "doc.on.doc"
    )
  }
}

// MARK: - Who said it

extension TranscriptTurn {
  /// The label above a turn: `You`, or the agent's own name.
  ///
  /// The cases come from typed fields in the session file. A tool run and an agent event
  /// have no speaker and return `nil`. A tool run is the agent working, not talking, and an
  /// agent event's words are another session's, so neither this agent's name nor `You`
  /// is true. `AgentEvent.line` names the sender.
  public func speaker(agentName: String) -> String? {
    switch speech {
    // The prompt a parent session wrote to open a sub-agent's file. Nobody typed it.
    case .human where isParentPrompt: TranscriptChatCopy.parentPrompt
    case .human: TranscriptChatCopy.human
    case .assistant: agentName
    case .tools, .agentEvent: nil
    }
  }

  /// `12s ago`, for the newest turn. Uses `TranscriptAge.elapsed`, because sub-minute
  /// precision is what says a conversation is live. `nil` when the record has no timestamp.
  public func relativeTime(asOf now: Date) -> String? {
    guard let at else { return nil }
    return TranscriptAge.elapsed(now.timeIntervalSince(at))
  }

  /// Whether a separator belongs before this turn: the turns are more than 30 minutes
  /// apart. `false` when either timestamp is missing.
  public func showsTimeSeparator(after previous: TranscriptTurn?) -> Bool {
    guard let at, let previousAt = previous?.at else { return false }
    return at.timeIntervalSince(previousAt) > 30 * 60
  }

  /// `1 image` or `3 images` for images the parser counted, or `nil` for none.
  public var attachedImagesLabel: String? {
    guard attachedImages > 0 else { return nil }
    return attachedImages == 1 ? "1 image" : "\(attachedImages) images"
  }

  /// `Crunched for 9m 50s`, the terminal's line under a long turn.
  ///
  /// The recorded duration, not the turn's age from `relativeTime(asOf:)`. Every unit below
  /// the largest prints even at zero (`1m 0s`), and the value is truncated, as the parser
  /// truncates milliseconds. `nil` for anything but an assistant turn, and for a value that
  /// is absent, negative or not finite.
  public var durationLabel: String? {
    guard case .assistant = speech else { return nil }
    guard let milliseconds = durationMs, milliseconds.isFinite, milliseconds >= 0 else {
      return nil
    }
    let total = Int(milliseconds / 1000)
    let spent: String
    if total < 60 {
      spent = "\(total)s"
    } else if total < 3600 {
      spent = "\(total / 60)m \(total % 60)s"
    } else {
      spent = "\(total / 3600)h \((total % 3600) / 60)m \(total % 60)s"
    }
    return "\(TranscriptChatCopy.crunchedFor) \(spent)"
  }

  /// How many of this turn's images have their bytes. A `.remote` image is not drawable,
  /// because nothing fetches one (see `TranscriptImage.Source.remote`).
  public var drawableImages: Int {
    images.filter { $0.inlineData != nil }.count
  }

  /// The caption under the thumbnails, or `nil` when every image is on screen.
  ///
  /// When some drew, it counts the missing ones as missing, because a bare `2 images` under
  /// one thumbnail reads as the total. When none drew, it is `attachedImagesLabel`.
  public var imagesNoticeLabel: String? {
    let drawn = drawableImages
    guard attachedImages > drawn else { return nil }
    guard drawn > 0 else { return attachedImagesLabel }
    let missing = attachedImages - drawn
    return missing == 1 ? "1 image not shown" : "\(missing) images not shown"
  }
}

extension TranscriptTurn.AgentEvent {
  /// The collapsed line, `eng-6: Fixes ready for another look`: the sender from the
  /// envelope, then its summary.
  ///
  /// A recipient prefix such as `[to ver-6]` in the summary stays, because without it the
  /// line reads as though the message came here.
  public var line: String { emphasised + trailing }

  /// The half of the line drawn with weight: the teammate's name, preceded by the verb for
  /// this session's own calls. `line` is exactly `emphasised + trailing`, so the view draws
  /// the sentence this type published. The verb is inside because `Started analyst-1` is
  /// one noun phrase.
  public var emphasised: String {
    guard !sender.isEmpty else { return "" }
    guard let verb = TranscriptChatCopy.verb(for: kind) else { return sender }
    return "\(verb) \(sender)"
  }

  /// The rest of the line. Empty for this session's own call with no summary, which is a
  /// whole sentence without a dangling separator.
  public var trailing: String {
    guard kind.isThisSessionsOwnCall else {
      return sender.isEmpty ? summaryLine : ": \(summaryLine)"
    }
    guard let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return ""
    }
    return sender.isEmpty ? summary : " \(TranscriptChatCopy.agentEventSeparator) \(summary)"
  }

  /// The summary, or a fallback when the envelope carried none.
  ///
  /// Only a relayed event has a fallback. Driverr's own calls already read as complete
  /// sentences. A relayed event with no summary is common, about half of those sampled.
  public var summaryLine: String {
    if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return summary
    }
    switch kind {
    case .idle: return TranscriptChatCopy.agentWentIdle
    case .message: return TranscriptChatCopy.agentSentAMessage
    case .spawned, .stopped, .sent: return ""
    }
  }
}

extension TaskProgress {
  /// `Running · 3m` or `Finished · 2m 41s`. The word alone when there is no time, and always
  /// for an idle teammate.
  ///
  /// A running time is in whole minutes because the label redraws on a thirty-second tick
  /// and seconds would jump. An ended time is exact.
  public func label(asOf now: Date) -> String {
    let word: String
    switch state {
    case .running: word = TranscriptChatCopy.taskRunning
    case .finished: word = TranscriptChatCopy.taskFinished
    // The word alone. A figure here would read as how long it has been idle.
    case .idle: return TranscriptChatCopy.taskIdle
    case .failed: word = TranscriptChatCopy.taskFailed
    case .stopped: word = TranscriptChatCopy.taskStopped
    }
    guard let seconds = elapsed(asOf: now) else { return word }
    let time: String
    if state == .running {
      time = seconds < 1 ? "0s" : TranscriptAge.elapsed(seconds)
    } else {
      let total = Int(seconds)
      if total < 60 {
        time = "\(total)s"
      } else if total < 3600 {
        time = "\(total / 60)m \(total % 60)s"
      } else {
        time = "\(total / 3600)h \((total % 3600) / 60)m"
      }
    }
    return "\(word) \(TranscriptChatCopy.agentEventSeparator) \(time)"
  }
}

/// The chat's fixed words: everything it says that is not derived from a transcript. Kept
/// here so `swift test` can assert them.
public enum TranscriptChatCopy {
  /// Not the person's name, and not "User".
  public static let human = "You"
  /// The label over a sub-agent's opening prompt, which the parent agent wrote.
  public static let parentPrompt = "Prompt from the parent agent"
  /// The back bar over a sub-agent's chat. Words, because a chevron would read as the
  /// system back button.
  public static let subagentBack = "Back to the pane's chat"
  /// Spoken after a spawn line's words when it opens a sub-agent's chat.
  public static let opensSubagent = "Opens this agent's conversation"
  /// The floating down button. Spoken, because VoiceOver reads an arrow glyph as its shape.
  public static let jumpToLatest = "Jump to the newest message"
  /// What the spinner says. It always resolves — see `PaneTranscriptModel`.
  public static let reading = "Reading the session file…"
  /// A wider page in flight. The same grammar as `reading`, because it is the same act.
  public static let loadingMore = "Reading earlier turns…"
  /// Under a Load-more control that failed, when the error has no `errorDescription`.
  public static let pagingFailed = "Couldn't read earlier turns."
  /// Expanding and collapsing a turn the view has bounded.
  public static let showAll = "Show All"
  public static let showLess = "Show Less"
  public static let retry = "Retry"
  /// A diff card's header when the patch has no file header, as in a bare hunk.
  public static let diffWithNoFile = "Diff"

  // MARK: - What a call with no result can be

  /// herdr reports the pane `blocked`, which means a person is needed.
  public static let pendingBlocked = "Waiting for permission"
  /// A herdr-core agent said it is blocked on signing in, which a chip cannot answer.
  public static let pendingAuth = "Waiting for you to sign in"
  /// The agent asked a question and no answer has arrived. Separate from `pendingBlocked`
  /// because this row has the answers under it.
  public static let pendingQuestion = "Waiting for your answer"
  /// Spoken before an answered question's answer. The check mark says it on screen.
  public static let answered = "Answered"
  /// herdr reports the pane `working`, so the tool is running.
  public static let pendingWorking = "Running"
  /// Neither: the result was not in the window when the file was read.
  public static let pendingUnanswered = "No result yet"

  /// `Bash cargo test`: a call named so the reader can tell which row it is. Plain text,
  /// because the label is drawn by a `Text` that does not parse markdown, and the call row
  /// above it already draws the target in monospace.
  public static func namingCall(_ call: ToolCall) -> String {
    guard let target = call.target, !target.isEmpty else { return call.name }
    return "\(call.name) \(target)"
  }
  /// Whether a run of tool calls is open. Spoken as the row's value, because the row is one
  /// accessibility element and a chevron is not a word.
  public static let runIsOpen = "Open"
  public static let runIsClosed = "Closed"

  // MARK: - What an inter-agent event says when it carried no summary

  /// An idle notification with no summary, which is common. It says only what the envelope
  /// says.
  public static let agentWentIdle = "went idle"
  /// A message with no summary. About the event, not its content.
  public static let agentSentAMessage = "sent a message"

  // MARK: - What this session's own agent traffic says

  /// An `Agent` call. Past tense, because the record is written after the fact.
  public static let agentSpawned = "Started"
  /// A `TaskStop` call.
  public static let agentStopped = "Stopped"
  /// A `SendMessage` call. A preposition, because the name after it is the recipient.
  public static let agentSentTo = "To"
  /// Between the name and the summary. Not a colon, which means "this teammate said".
  public static let agentEventSeparator = "·"

  // MARK: - How long a turn took

  /// The terminal's own word, so a reader recognises it as the same fact.
  public static let crunchedFor = "Crunched for"

  // MARK: - Where a spawned task has got to

  /// Nothing says it ended. The same word as `pendingWorking`.
  public static let taskRunning = pendingWorking
  public static let taskFinished = "Finished"
  /// The word a teammate's idle notification uses.
  public static let taskIdle = "Idle"
  public static let taskFailed = "Failed"
  /// A `TaskStop`, or a notification saying `killed`.
  public static let taskStopped = "Stopped"

  /// The word an event opens with, or `nil` for a relayed one, which opens with the
  /// teammate's name.
  public static func verb(for kind: TranscriptTurn.AgentEvent.Kind) -> String? {
    switch kind {
    case .message, .idle: nil
    case .spawned: agentSpawned
    case .stopped: agentStopped
    case .sent: agentSentTo
    }
  }
}

// MARK: - A run of tool calls, closed

extension ToolRun {
  /// `40 tool calls`, the closed row.
  public var summary: String {
    count == 1 ? "1 tool call" : "\(count) tool calls"
  }

  /// `Read ×18 · Edit ×9 · Bash ×7 · Grep ×6`, in `kinds`' own most-used-first order.
  public var kindsSummary: String {
    kinds.map { "\($0.name) ×\($0.count)" }.joined(separator: " · ")
  }

  /// `1 failed` or `3 failed`, or `nil` when nothing came back marked `is_error`.
  public var failureNote: String? {
    guard failedCount > 0 else { return nil }
    return failedCount == 1 ? "1 failed" : "\(failedCount) failed"
  }

  /// The same row in words. VoiceOver does not read `×` as "times", so the counts are
  /// spelled out.
  public var accessibilityLabel: String {
    let spoken = kinds.map { "\($0.name) \($0.count)" }.joined(separator: ", ")
    let base = spoken.isEmpty ? summary : "\(summary). \(spoken)."
    guard let failureNote else { return base }
    return "\(base) \(failureNote)."
  }

  /// The closed header's label: count and failures, without the tally only the open header
  /// draws.
  public var closedAccessibilityLabel: String {
    let parts = [summary, failureNote].compactMap { $0 }
    return parts.joined(separator: ". ") + "."
  }
}

// MARK: - The call with no result yet

/// The row under a run whose last call has no result.
///
/// The file cannot tell a running tool from one at a permission prompt, so the label comes
/// from herdr's `AgentStatus`. `.blocked` asks and offers Approve/Deny. `.working` says the
/// tool is running. Every other status says only that the result was not in the window.
/// Offering `y` outside `.blocked` would send a stray keystroke into whatever has the prompt.
///
/// An `AskUserQuestion` with parsed options is the exception. It is the agent asking the
/// reader by definition, so it outranks `AgentStatus`, which can lag a question or miss it.
///
/// A herdr-core agent can also say what it is blocked on. A question or a sign-in is not a
/// permission prompt, so the synthesised Approve/Deny pair is not offered for either: `y` is
/// not an answer to them. With no kind, which is every TUI pane, blocked reads as permission.
public struct PendingToolCallNotice: Hashable, Sendable {
  /// The row's words, naming the call.
  public let label: String
  /// Whether this row asks the reader something. Only a `.blocked` pane or a question asks.
  /// Stored, not derived from `groups` being empty.
  public let isAsking: Bool
  /// The answers offered under it, one group per question. Empty unless the row asks,
  /// because a chip into a working pane is a stray keystroke.
  public let groups: [ReplyChipGroup]

  /// Every chip, for callers that only ask whether there is anything to tap.
  public var chips: [ReplyChip] { groups.flatMap(\.chips) }

  /// `nil` for a pane with no agent, which differs from `.unknown`. See `AgentStatus`.
  public init(call: ToolCall, agentStatus: AgentStatus?, blockedKind: AgentBlockedKind? = nil) {
    let named = TranscriptChatCopy.namingCall(call)
    // The file's own answer first, whatever the status: a written question with no result
    // is unanswered.
    guard !call.asksItsOwnQuestions else {
      label = "\(TranscriptChatCopy.pendingQuestion) · \(named)"
      isAsking = true
      groups = call.replyChipGroups
      return
    }
    switch agentStatus {
    case .blocked:
      isAsking = true
      switch blockedKind {
      case .question:
        label = "\(TranscriptChatCopy.pendingQuestion) · \(named)"
        groups = []
      case .auth:
        label = "\(TranscriptChatCopy.pendingAuth) · \(named)"
        groups = []
      case .permission, nil:
        label = "\(TranscriptChatCopy.pendingBlocked) · \(named)"
        groups = call.replyChipGroups
      }
    case .working:
      label = "\(TranscriptChatCopy.pendingWorking) · \(named)"
      isAsking = false
      groups = []
    case .idle, .done, .error, .unknown, nil:
      label = "\(TranscriptChatCopy.pendingUnanswered) · \(named)"
      isAsking = false
      groups = []
    }
  }
}

extension ToolCall {
  /// The row this call gets under its run, which always names the call. There is no form
  /// without `agentStatus`, because a label built from a resultless call alone would claim
  /// a permission prompt that may not exist.
  public func pendingNotice(
    agentStatus: AgentStatus?,
    blockedKind: AgentBlockedKind? = nil
  ) -> PendingToolCallNotice {
    PendingToolCallNotice(call: self, agentStatus: agentStatus, blockedKind: blockedKind)
  }
}

// MARK: - A question somebody answered

/// One `AskUserQuestion` question and its recorded answer, drawn under the run.
///
/// The question is repeated beside the answer because the question's own turn is usually
/// scrolled off screen when the reader is at the bottom.
public struct AnsweredQuestion: Hashable, Sendable {
  /// The picker's short tab label, or `nil` when the agent wrote none.
  public let header: String?
  public let question: String
  /// The tool's own answer string. A multi-select answer is the labels joined by `", "`.
  public let answer: String

  public init(header: String?, question: String, answer: String) {
    self.header = header
    self.question = question
    self.answer = answer
  }

  /// Header, question and answer as one VoiceOver sentence, without doubled punctuation.
  public var accessibilityLabel: String {
    let parts = [header, question.isEmpty ? nil : question].compactMap { $0 }
      + ["\(TranscriptChatCopy.answered): \(answer)"]
    return parts.dropFirst().reduce(parts[0]) { spoken, part in
      let ended = spoken.last.map { ".?!:".contains($0) } ?? true
      return spoken + (ended ? " " : ". ") + part
    }
  }
}

extension ToolRun {
  /// Every answered question in this run, in the order asked. A question with no recorded
  /// answer is left out.
  public var answeredQuestions: [AnsweredQuestion] {
    calls.flatMap { call in
      call.questions.compactMap { asked in
        guard let answer = asked.answer?.trimmingCharacters(in: .whitespacesAndNewlines),
          !answer.isEmpty
        else { return nil }
        return AnsweredQuestion(header: asked.header, question: asked.question, answer: answer)
      }
    }
  }
}
