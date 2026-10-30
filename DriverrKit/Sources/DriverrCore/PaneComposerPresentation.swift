import Foundation

/// Answering a pane, as a value: what is staged, what was attempted, and what happened.
///
/// The send states live here, not in the view, so `swift test` covers them:
///
/// - `sending` refuses to be re-entered. A disabled button is a rendering, and a tap that
///   lands before the redraw would send the same answer twice.
/// - `sent` means herdr took it and the agent has not spoken. It is its own state because
///   conflating the two is how a person sends twice.
/// - `failed` keeps the staged text, so `beginRetry()` can resend without retyping.
public struct PaneComposerState: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case editing
    case sending
    /// herdr took the reply. It says nothing about the agent having read it.
    case sent
    case failed(AppError)
  }

  /// One attempt, kept so a failure can be repeated exactly. The text excludes the
  /// submitting newline, which the sender appends, so a retry cannot add a second one.
  public enum Attempt: Equatable, Sendable {
    case text(String)
    case key(PaneKey)
    /// A whole `AskUserQuestion` answer as key presses. It gets the ordinary verdict.
    case keys([PaneKey])
  }

  public private(set) var phase: Phase = .editing

  /// The reply as typed, staged until something is done with it.
  ///
  /// Writing a new value is typing, so it clears the last verdict. Writing the same value is
  /// not, because a `TextField` binding writes on every redraw. `succeeded()` empties the
  /// field through the storage directly, so the clear cannot wipe out the fresh "Sent".
  public var text: String {
    get { staged }
    set {
      guard newValue != staged else { return }
      staged = newValue
      switch phase {
      case .sent, .failed:
        phase = .editing
        // Retry means "send that again", and what is staged is no longer that.
        attempt = nil
      case .editing, .sending:
        break
      }
    }
  }

  private var staged = ""
  /// What the last `begin…` staged, which is what a retry repeats.
  private var attempt: Attempt?

  /// Which key the reply being confirmed was, or `nil` for typed text, so the verdict comes
  /// from `PaneComposerCopy.sentVerdict(for:)`.
  private var sentKey: PaneKey?

  /// When `succeeded()` recorded the send, so the notice can age rather than vanish.
  public private(set) var sentAt: Date?
  /// What herdr said the pane was doing when the reply went over. `sent` stands until this
  /// changes. The aged sentence quotes it, so it must not invent a blocked report.
  private var sentAgainst: SendWitness?

  private struct SendWitness: Equatable, Sendable {
    let status: AgentStatus?
    let agentName: String?

    init(pane: Pane?) {
      status = pane?.agent?.status
      agentName = pane?.agent?.name
    }
  }

  public init() {}

  public var isSending: Bool { phase == .sending }

  /// Nothing to send is a disabled button, not an error.
  public var canSend: Bool {
    !isSending && !staged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  public var failure: AppError? {
    guard case .failed(let error) = phase else { return nil }
    return error
  }

  /// Stages the typed reply. `nil` when there is nothing to send, or one is in flight.
  public mutating func beginSending() -> Attempt? {
    guard canSend else { return nil }
    return begin(.text(staged))
  }

  /// Stages a key press, which needs nothing typed: a blocked agent is usually waiting on
  /// a keystroke a phone keyboard does not have.
  public mutating func beginSending(_ key: PaneKey) -> Attempt? {
    guard !isSending else { return nil }
    return begin(.key(key))
  }

  /// Stages several key presses as one attempt, so a retry repeats the whole sequence.
  public mutating func beginSending(_ keys: [PaneKey]) -> Attempt? {
    guard !isSending, !keys.isEmpty else { return nil }
    return begin(.keys(keys))
  }

  /// Stages a repeat of whatever failed. `nil` when nothing has failed or the failed text
  /// has since been edited.
  public mutating func beginRetry() -> Attempt? {
    guard case .failed = phase, let attempt else { return nil }
    return begin(attempt)
  }

  /// herdr took it, which is not the agent answering it.
  ///
  /// Typed text that is still staged is cleared, so a second tap cannot send it twice. A key
  /// press leaves a half-written reply alone. `at` and `pane` let the notice age and let
  /// `paneChanged(to:)` compare. Both default for callers with no clock or pane.
  public mutating func succeeded(at now: Date = Date(), pane: Pane? = nil) {
    if case .text(let sent) = attempt, staged == sent { staged = "" }
    phase = .sent
    sentAt = now
    sentAgainst = SendWitness(pane: pane)
    sentKey = if case .key(let key) = attempt { key } else { nil }
  }

  public mutating func failed(_ error: AppError) {
    phase = .failed(error)
  }

  /// The pane as the latest poll reports it. Retires `Sent` once the pane has moved.
  ///
  /// herdr leaving `blocked` is evidence the agent read the reply, and a clock is not. A
  /// `nil` pane holds the notice, because a missing snapshot is not an answer.
  public mutating func paneChanged(to pane: Pane?) {
    guard phase == .sent, pane != nil else { return }
    guard SendWitness(pane: pane) != sentAgainst else { return }
    clearSentNotice()
  }

  /// The conversation gained a turn since the reply went over. Needed because an agent can
  /// answer one permission prompt and go straight to the next, never leaving `blocked`.
  public mutating func transcriptAdvanced() {
    clearSentNotice()
  }

  /// Clears the `Sent` notice, and only that. A later send can have failed meanwhile, and
  /// its Retry must stay.
  public mutating func clearSentNotice() {
    guard phase == .sent else { return }
    phase = .editing
    sentAt = nil
    sentAgainst = nil
    sentKey = nil
  }

  /// What the composer says about its last attempt, now. The ageing path is
  /// `status(asOf:)`, driven from a ticking date.
  public var status: PaneComposerStatus? { status(asOf: Date()) }

  /// What the composer says about its last attempt, or `nil` when it has nothing to say.
  public func status(asOf now: Date) -> PaneComposerStatus? {
    switch phase {
    case .editing:
      nil
    case .sending:
      PaneComposerStatus(
        message: PaneComposerCopy.sending,
        detail: nil,
        tone: .progress,
        offersRetry: false
      )
    case .sent:
      sentStatus(asOf: now)
    case .failed(let error):
      // The headline is the part that is always true. herdr's own sentence goes underneath,
      // because "herdr did not answer" misdescribes a herdr that answered `no such pane`.
      PaneComposerStatus(
        message: PaneComposerCopy.failed,
        detail: error.errorDescription ?? PaneComposerCopy.noAnswer,
        tone: .failure,
        offersRetry: true
      )
    }
  }

  /// `Sent`, and once it has waited long enough, how long for.
  ///
  /// Ageing changes the sentence, not the phase. Reverting to the header instead would put
  /// "Claude is waiting for you." over the same question with an empty field, which invites
  /// sending the same answer twice.
  private func sentStatus(asOf now: Date) -> PaneComposerStatus {
    // Enter reads as `sent` because it answers what was on screen. Esc and Ctrl-C say what
    // they did.
    let verdict = PaneComposerCopy.sentVerdict(for: sentKey)
    // Only a reply that says it is waiting for the agent has a wait to age.
    guard
      verdict == PaneComposerCopy.sent,
      let sentAt,
      case let waited = now.timeIntervalSince(sentAt),
      waited >= PaneComposerCopy.sentAgeThreshold
    else {
      return PaneComposerStatus(
        message: verdict,
        detail: nil,
        tone: .success,
        offersRetry: false
      )
    }
    // Quotes herdr only when it reported the pane blocked when the reply went over.
    let detail =
      sentAgainst?.status == .blocked
      ? sentAgainst?.agentName.map(PaneComposerCopy.stillWaiting) : nil
    return PaneComposerStatus(
      message: PaneComposerCopy.sentAgo(TranscriptAge.elapsed(waited)),
      detail: detail,
      // Progress, not success: an unacknowledged reply is no longer good news.
      tone: .progress,
      offersRetry: false
    )
  }

  private mutating func begin(_ attempt: Attempt) -> Attempt {
    self.attempt = attempt
    phase = .sending
    return attempt
  }
}

/// One sentence about the last attempt, and how to draw it. A value, so the words and the
/// emphasis are asserted in `swift test`.
public struct PaneComposerStatus: Equatable, Sendable {
  /// How much weight the line carries. Never colour alone, as `AgentStatusBadge` requires.
  public enum Tone: Equatable, Sendable {
    case progress
    case success
    case failure
  }

  /// The line itself.
  public let message: String
  /// What the far side said, or `nil` when there is nothing to add.
  public let detail: String?
  public let tone: Tone
  /// Only a failure offers Retry. Retrying a send that worked would send it twice.
  public let offersRetry: Bool

  public init(message: String, detail: String?, tone: Tone, offersRetry: Bool) {
    self.message = message
    self.detail = detail
    self.tone = tone
    self.offersRetry = offersRetry
  }
}

/// Everything the composer says, in one place.
public enum PaneComposerCopy {
  public static let sending = "Sending…"
  /// herdr took the reply and the agent has not spoken. A bare "Sent" hides the difference,
  /// which is how an answer gets sent twice.
  public static let sent = "Sent · waiting for the agent"

  /// How far through a multi-question `AskUserQuestion` the reader is.
  ///
  /// With several groups, one answered question leaves the screen looking unanswered, so the
  /// count says more is wanted and how much. Only used for more than one question.
  public static func answered(chosen: Int, of questions: Int) -> String {
    "\(chosen) of \(questions) answered"
  }

  /// What a successful send says, for the thing that was sent.
  ///
  /// Typed text and Enter get `sent`, because Enter answers what was on screen. Esc and
  /// Ctrl-C have their own meaning, and "waiting for the agent" over a Ctrl-C reads as a
  /// reply. Ctrl-C says what it did.
  public static func sentVerdict(for key: PaneKey?) -> String {
    guard let key else { return sent }
    switch key {
    // A digit is an `AskUserQuestion` answer, and reads the way a multi-select one does.
    case .enter, .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9:
      return sent
    case .interrupt:
      return "Sent Ctrl-C · Claude was interrupted"
    case .esc, .up, .down, .left, .right, .tab, .yes, .no:
      return "Sent \(key.label)"
    }
  }

  public static let failed = "Send failed"
  /// What stands in when a failure carries no sentence of its own.
  public static let noAnswer = "herdr did not answer."
  public static let retry = "Retry"
  public static let send = "Send"
  /// The hint under a multi-select question's heading. Without it a multi-select group
  /// looks like a single-answer one. It goes once the group has an answer, because the
  /// chips' glyphs then say it.
  public static let chooseAny = "Choose any"
  /// The field's placeholder.
  public static let field = "Type a reply"
  /// What the key row is, said once under it.
  public static let keysFooter = "Sent as key presses, not as text."

  // MARK: - Slash command autocomplete

  /// The caption above the `/` completion list, and its dismiss control's label.
  ///
  /// `suggestionsLabel` is visible text: it makes a short capped list read as a summary
  /// rather than as a list that ran out. `dismissSuggestions` is spoken only, for an `xmark`.
  public static let suggestionsLabel = "Command suggestions"
  public static let dismissSuggestions = "Dismiss suggestions"

  // MARK: - Reply chips

  /// The pair a raw `y`/`n` prompt with no structured options gets. See
  /// `ToolCall.replyChips`.
  public static let approve = "Approve"
  public static let deny = "Deny"

  /// The two-step Ctrl-C confirm, in `PanePromptBar`'s shape.
  public static let interruptPrompt = "Interrupt Claude? This stops what it is doing."
  public static let interruptConfirm = "Interrupt"
  public static let cancel = "Cancel"

  /// How long an unacknowledged reply waits before the notice says so.
  ///
  /// The notice is retired by evidence (herdr leaving `blocked`, or a new turn), not by a
  /// clock. This only decides when it stops implying an answer is imminent: longer than an
  /// agent takes to acknowledge a keystroke, shorter than a person waits before doubting
  /// the tap.
  public static let sentAgeThreshold: TimeInterval = 30

  /// `Sent 40s ago`, the notice once nothing has confirmed it for a while.
  public static func sentAgo(_ elapsed: String) -> String { "Sent \(elapsed) ago" }

  /// What herdr still reports, said as a report. Driverr cannot know whether the agent read
  /// the reply.
  public static func stillWaiting(_ agent: String) -> String {
    "herdr still reports \(agent) as waiting."
  }

  /// How long a send waits for herdr before it is called a failure.
  ///
  /// Without a deadline a stalled channel leaves the pane's only composer spinning with
  /// every key disabled and no Retry. Twelve seconds lets a slow link finish before a person
  /// decides the app is broken.
  public static let sendDeadline: Duration = .seconds(12)
}

/// What the composer says about the pane it is attached to.
///
/// For a pane that is not blocked, the composer stays and this sentence changes. A reply
/// surface that vanished whenever the agent went back to work could never be relied on.
public struct PaneComposerHeader: Equatable, Sendable {
  /// What the pane is doing.
  public let state: String
  /// Why the composer is still here for a pane that has not asked anything. `nil` for a
  /// blocked pane and for a shell.
  public let invitation: String?
  /// Whether anything is running to interrupt. Only `.working` gets a `Stop`.
  public let isWorking: Bool

  public init(pane: Pane) {
    guard let agent = pane.agent else {
      // A shell: text typed here is a command, not an answer.
      state = "Anything sent here is typed into the pane."
      invitation = nil
      isWorking = false
      return
    }
    isWorking = agent.status == .working
    let name = agent.name
    switch agent.status {
    case .blocked:
      state = Self.blockedState(name, on: agent.blockedKind)
      invitation = nil
    case .working:
      state = "\(name) is working."
      invitation = "You can still say something."
    case .idle:
      state = "\(name) is idle."
      invitation = "You can still say something."
    case .done:
      state = "\(name) has finished."
      invitation = "You can still say something."
    case .error:
      state = "\(name) reported an error."
      invitation = "You can still say something."
    case .unknown:
      // `unknown` is an agent whose output nothing recognised, so claim nothing.
      state = "herdr can't say what \(name) is doing."
      invitation = "You can still say something."
    }
  }

  /// What a blocked agent is waiting for, when it said. Only a herdr-core agent can.
  private static func blockedState(_ name: String, on kind: AgentBlockedKind?) -> String {
    switch kind {
    case .permission: "\(name) is waiting for permission."
    case .question: "\(name) is waiting for your answer."
    case .auth: "\(name) is waiting for you to sign in."
    case nil: "\(name) is waiting for you."
    }
  }

  /// Both halves as one sentence for VoiceOver.
  public var accessibilityLabel: String {
    [state, invitation].compactMap { $0 }.joined(separator: " ")
  }
}

// MARK: - The reply chips a pending call's options become

/// One tappable answer to a pending call, drawn under the turn it answers
/// (`PaneChatView.replyRow`).
public struct ReplyChip: Hashable, Sendable, Identifiable {
  public enum Action: Hashable, Sendable {
    /// A key press: an Approve/Deny key, or an `AskUserQuestion` option's number.
    case key(PaneKey)
    /// Several key presses in order: a whole `AskUserQuestion` answer. See
    /// `ReplyChipSelection.reply`.
    ///
    /// There is no typed-text action. The picker ignores typed text and its Enter picks the
    /// highlighted option, so typing a label records the wrong answer.
    case keys([PaneKey])
  }

  public let label: String
  public let action: Action
  /// The option's description, drawn under the chip. `nil` for a chip Driverr made up and
  /// for an option with no description.
  public let detail: String?

  public init(label: String, action: Action, detail: String? = nil) {
    self.label = label
    self.action = action
    self.detail = detail
  }

  public var id: String { label }
}

extension ToolCall {
  /// Whether this call carries the agent's own answers, as opposed to the synthesised
  /// Approve/Deny pair. `PendingToolCallNotice` treats the former as evidence of a question.
  ///
  /// Still `true` when `replyChipGroups` offers no chips because digits cannot answer the
  /// call. The question is still waiting, and is answered in the terminal.
  public var asksItsOwnQuestions: Bool {
    questions.contains { !$0.options.isEmpty }
  }

  /// This call's questions as one group of chips each: `AskUserQuestion`'s own labels, or
  /// an Approve/Deny pair on `y`/`n` for a raw prompt.
  ///
  /// This is the mapping, not the decision to offer it. `PendingToolCallNotice` offers the
  /// agent's own questions whatever herdr says, and the synthesised pair only on a `blocked`
  /// pane, where `y`/`n` cannot land in a session that is not waiting.
  public var replyChipGroups: [ReplyChipGroup] {
    let asked = questions.filter { !$0.options.isEmpty }
    guard !asked.isEmpty else {
      return [
        ReplyChipGroup(
          index: 0,
          question: nil,
          chips: [
            ReplyChip(label: PaneComposerCopy.approve, action: .key(.yes)),
            ReplyChip(label: PaneComposerCopy.deny, action: .key(.no)),
          ]
        )
      ]
    }
    // No chips when a digit cannot answer every question. A missing question leaves a
    // picker tab no chip answers, so later keys land in the wrong question, and an option
    // past the ninth has no digit. Typed text is no fallback, because the picker ignores it.
    let keyable = asked.allSatisfy { question in
      (question.askedInCall.map { $0 == asked.count } ?? true)
        && question.optionNumbers.allSatisfy { PaneKey.digit($0) != nil }
    }
    guard keyable else { return [] }
    return asked.enumerated().map { index, question in
      ReplyChipGroup(
        index: index,
        // Labelled even for one question, because the chat rests at the band's top while a
        // question waits and the question's own turn is scrolled off. `nil` for empty text,
        // which would draw a blank line.
        question: question.question.isEmpty ? nil : question.question,
        // Each option's picker number, not its label. The picker ignores typed text, and a
        // digit selects by position.
        chips: question.options.indices.compactMap { at in
          PaneKey.digit(question.optionNumbers[at]).map {
            ReplyChip(
              label: question.options[at],
              action: .key($0),
              detail: question.optionDescriptions.indices.contains(at)
                ? question.optionDescriptions[at] : nil
            )
          }
        },
        allowsMultiple: question.allowsMultiple,
        // Drawn for one question too: it is the picker's tab label.
        header: question.header,
        pickerTab: question.pickerTab
      )
    }
  }

  /// Every chip this call offers, whatever question it belongs to. Only for callers that
  /// ask whether there is anything to tap. Anything that draws or sends takes
  /// `replyChipGroups`, because flattening loses which question a chip answers.
  public var replyChips: [ReplyChip] { replyChipGroups.flatMap(\.chips) }
}

// MARK: - Several questions in one call

/// One question's chips, drawn as a labelled row.
///
/// Each group carries its question because `AskUserQuestion`'s answer is keyed by question,
/// and a chip must say which question it answers.
public struct ReplyChipGroup: Hashable, Sendable, Identifiable {
  /// The group's position in the call, from zero. The identity, because a group with no
  /// heading has no text.
  public let index: Int
  /// The heading: the question's words, or `nil` when the agent wrote none.
  public let question: String?
  public let chips: [ReplyChip]
  /// `AskUserQuestion`'s `multiSelect` for this question.
  public let allowsMultiple: Bool
  /// `AskUserQuestion`'s short `header`. `nil` for the Approve/Deny pair and when absent.
  public let header: String?
  /// Where the picker is, for a question read off the pane's screen. `nil` for one from the
  /// transcript. See `ReplyChipSelection.reply`.
  public let pickerTab: PickerTab?

  public init(
    index: Int,
    question: String?,
    chips: [ReplyChip],
    allowsMultiple: Bool = false,
    header: String? = nil,
    pickerTab: PickerTab? = nil
  ) {
    self.index = index
    self.question = question
    self.chips = chips
    self.allowsMultiple = allowsMultiple
    self.header = header
    self.pickerTab = pickerTab
  }

  /// Whether any chip has a description, which lays the group out as a list.
  public var describesItsOptions: Bool { chips.contains { $0.detail != nil } }

  public var id: String { "q\(index)" }
}

/// What has been chosen so far, and the reply it becomes once every question is answered.
///
/// Nothing is sent until every group has a chosen chip, so a single-question call sends on
/// the first tap. A call with a multi-select question also waits for `confirm()`; see
/// `needsConfirmation`.
public struct ReplyChipSelection: Hashable, Sendable {
  public let groups: [ReplyChipGroup]
  /// Chosen labels per group id, in tap order. A single-answer group holds at most one.
  private var chosen: [String: [String]] = [:]
  /// Whether the composed reply has gone. The chosen chips stay on screen, and every chip
  /// stops taking taps, so the answer stays legible and cannot be sent again.
  public private(set) var hasSent = false
  /// Whether the reader has pressed Send. Only set by `confirm()`, which requires a
  /// complete selection.
  public private(set) var isConfirmed = false

  /// Starts from what the screen shows checked for a question read off the screen, so
  /// `reply` sends only the changes.
  public init(groups: [ReplyChipGroup] = []) {
    self.groups = groups
    for group in groups {
      let checked = group.checkedOnScreen
      if !checked.isEmpty { chosen[group.id] = checked }
    }
  }

  public func isChosen(_ chip: ReplyChip, in group: ReplyChipGroup) -> Bool {
    chosen[group.id]?.contains(chip.label) == true
  }

  /// Records a tap. A single-answer question replaces its choice. A multi-select one adds,
  /// and a second tap removes. A tap after the reply has gone changes nothing, and the guard
  /// is here so a view that forgot it cannot re-send.
  public mutating func toggle(_ chip: ReplyChip, in group: ReplyChipGroup) {
    guard !hasSent else { return }
    var labels = chosen[group.id] ?? []
    if let at = labels.firstIndex(of: chip.label) {
      labels.remove(at: at)
    } else if group.allowsMultiple {
      labels.append(chip.label)
    } else {
      labels = [chip.label]
    }
    chosen[group.id] = labels
  }

  /// Whether every question has an answer. False with no groups, a pane that is not asking.
  public var isComplete: Bool {
    !groups.isEmpty && groups.allSatisfy { !(chosen[$0.id] ?? []).isEmpty }
  }

  /// How many questions have an answer. A question with two answers counts once.
  public var answeredCount: Int {
    groups.count { !(chosen[$0.id] ?? []).isEmpty }
  }

  /// Whether this call needs a separate Send press rather than sending on completion.
  ///
  /// True when any group is multi-select, not only the one that completes the set. Which
  /// group completes depends on tap order, so sending on completion would cut a multi-select
  /// answer to one chip unpredictably. A call of single-answer questions has no Send.
  public var needsConfirmation: Bool { groups.contains(where: \.allowsMultiple) }

  /// Whether a complete answer is held back for a Send. `reply` guards on it.
  public var awaitsConfirmation: Bool { needsConfirmation && !isConfirmed }

  /// Records the reader pressing Send. A no-op on an incomplete selection, whatever the
  /// view does.
  ///
  /// `toggle` does not clear `isConfirmed`. That is safe only while the one caller,
  /// `PaneChatView.confirmReply`, confirms, reads `reply` and calls `markSent()` in one
  /// synchronous action. A caller that confirms without sending must make `toggle` clear
  /// `isConfirmed`, or the next tap sends with no second Send press.
  public mutating func confirm() {
    guard isComplete, !hasSent else { return }
    isConfirmed = true
  }

  /// Records that the composed reply has gone, so the answer stays on screen and cannot be
  /// sent again.
  public mutating func markSent() {
    hasSent = true
  }

  /// The reply to send, or `nil` while a question is unanswered or a confirmation is due.
  ///
  /// One single-answer question sends its own chip, so Approve stays a `y` and an option
  /// stays its digit. Every other `AskUserQuestion` answer is one key sequence, matching
  /// Claude Code 2.1.281's picker:
  /// - a single-select question takes its option's digit, which answers it and moves on;
  /// - a multi-select question takes one digit per chosen option, each a toggle, then
  ///   `right`;
  /// - after the last question the picker shows a review screen, where `1` is "Submit
  ///   answers". A lone single-select question has no review screen.
  ///
  /// The sequence assumes the picker is still on its first question with nothing toggled.
  /// The label is the chosen labels, one line per question, for tests and debugging only.
  public var reply: ReplyChip? {
    guard isComplete, !hasSent, !awaitsConfirmation else { return nil }
    if groups.count == 1, let group = groups.first, !group.allowsMultiple,
      group.pickerTab?.submitsAfter != true,
      let label = chosen[group.id]?.first,
      let chip = group.chips.first(where: { $0.label == label })
    {
      return chip
    }
    guard let keys = pickerKeys else { return nil }
    let label = groups.map { (chosen[$0.id] ?? []).joined(separator: ", ") }
      .joined(separator: "\n")
    return ReplyChip(label: label, action: .keys(keys))
  }

  /// The keys that answer the picker, or `nil` when a chosen chip is not an option digit.
  /// See `reply` for the sequence.
  private var pickerKeys: [PaneKey]? {
    if groups.count == 1, let group = groups.first, let tab = group.pickerTab {
      return keys(answering: group, on: tab)
    }
    var keys: [PaneKey] = []
    for group in groups {
      for label in chosen[group.id] ?? [] {
        guard case .key(let key) = group.chips.first(where: { $0.label == label })?.action,
          key.digitValue != nil
        else { return nil }
        keys.append(key)
      }
      if group.allowsMultiple { keys.append(.right) }
    }
    // The review screen's "Submit answers".
    keys.append(.digit1)
    return keys
  }

  /// The keys that answer one picker tab, for a question read off the screen.
  ///
  /// A multi-select question toggles only the options whose box must change, because the
  /// screen may already show some checked. `1` follows only when this tab reaches the review
  /// screen.
  private func keys(answering group: ReplyChipGroup, on tab: PickerTab) -> [PaneKey]? {
    var keys: [PaneKey] = []
    let chosenLabels = chosen[group.id] ?? []
    let before = group.checkedOnScreen
    for chip in group.chips {
      let changes =
        group.allowsMultiple
        ? chosenLabels.contains(chip.label) != before.contains(chip.label)
        : chosenLabels.contains(chip.label)
      guard changes else { continue }
      guard case .key(let key) = chip.action, key.digitValue != nil else { return nil }
      keys.append(key)
    }
    if group.allowsMultiple { keys.append(.right) }
    if tab.submitsAfter { keys.append(.digit1) }
    return keys
  }
}

extension ReplyChipGroup {
  /// The labels of the chips the screen shows checked. Empty for a transcript question.
  var checkedOnScreen: [String] {
    guard let checked = pickerTab?.checked, !checked.isEmpty else { return [] }
    return chips.compactMap { chip in
      guard case .key(let key) = chip.action, let digit = key.digitValue,
        checked.contains(digit)
      else { return nil }
      return chip.label
    }
  }
}
