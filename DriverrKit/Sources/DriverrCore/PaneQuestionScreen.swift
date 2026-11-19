/// A question an agent draws on the pane's screen and writes nowhere else, read so the chat can
/// offer its answers as chips. Three kinds, each from real captures; see `Kind`.
///
/// **Claude Code's `AskUserQuestion` picker.** Claude Code 2.1.281 and 2.1.282 write a pending
/// `AskUserQuestion` to the session file only after it is answered, unless a `PreToolUse` hook
/// matches the tool. Without the hook the question is only on the screen. The transcript wins
/// whenever it has the question; see `Transcript.questionCall`.
///
/// The rules follow `herdr pane read --format ansi` captures of Claude Code 2.1.282, kept in
/// `PaneQuestionScreenFixture`. What the picker draws:
///
/// ```
///  ☐ Fruit                                  ← tab row; `← ☒ Fruit  ☐ Color  ✔ Submit →`
///                                               with several questions or multi-select
/// Pick a fruit                              ← the question, wrapped with no indent
///
/// ❯ 1. Apple                                ← `N. [ ] label` for a multi-select question
///      A crisp, sweet red or green fruit    ← the description, wrapped at its indent
///   2. Banana
///   …
///   4. Type something.                      ← the picker's own; ends the options
/// ─────────────
///   5. Chat about this
///
/// Enter to select · ↑/↓ to navigate · Esc to cancel
/// ```
///
/// herdr's `live_blocked_form` rule also marks a permission prompt or a plan picker blocked, so
/// the parse answers `nil` unless it finds this footer, a tab row, and every option numbered
/// from 1 up to the `Type something` row. A screen too short to show all of that answers `nil`
/// too: an option whose number is not on screen cannot be offered as a digit.
///
/// **Codex's selection pickers** (`/permissions`, both stages of `/model`), from captures of
/// Codex CLI 0.170.0 in `CodexPickerScreenFixture`. See `codexPicker(in:)`.
///
/// **Claude Code's folder-trust dialog** (#122), which takes no digits. See `claudeTrust(in:)`.
public struct PaneQuestionScreen: Hashable, Sendable {
  /// Which agent's picker the screen shows. It decides when the screen is read
  /// (`Transcript.questionCall`) and whether the composer holds (`PaneComposerHold`).
  public enum Kind: Hashable, Sendable {
    /// Claude Code's `AskUserQuestion` picker. Read only on a `blocked` pane.
    case claudeQuestion
    /// Claude Code's folder-trust dialog. Read only on a `blocked` pane. Its chips move the
    /// cursor and press Enter; see `PickerTab.cursor`.
    case claudeTrust
    /// A Codex selection picker. herdr reports the pane `idle` while it is open, so it is read
    /// at any status. A digit alone picks an option.
    case codexPicker
  }

  public let kind: Kind

  /// The question on the active tab, with `pickerTab` set.
  public let question: PendingQuestion

  public init?(screen: PaneScreen) {
    let lines = screen.lines
    if let question = Self.claudeQuestion(in: lines) {
      kind = .claudeQuestion
      self.question = question
    } else if let question = Self.codexPicker(in: lines) {
      kind = .codexPicker
      self.question = question
    } else if let question = Self.claudeTrust(in: lines) {
      kind = .claudeTrust
      self.question = question
    } else {
      return nil
    }
  }

  /// The question as the call the chat's chips answer: an `AskUserQuestion` still waiting.
  ///
  /// Only Claude's picker is a tool call. The other kinds carry no tool name, so the chat's
  /// waiting line is the plain sentence (`PendingToolCallNotice`).
  public var call: ToolCall {
    ToolCall(
      name: kind == .claudeQuestion ? "AskUserQuestion" : "", outcome: .pending,
      questions: [question])
  }

  // MARK: - Claude Code's AskUserQuestion picker

  static func claudeQuestion(in lines: [PaneScreenLine]) -> PendingQuestion? {
    guard let footer = Self.footerStart(in: lines),
      let tabRow = lines[..<footer].lastIndex(where: Self.isTabRow),
      let tabs = Self.tabs(in: lines[tabRow]),
      let active = tabs.firstIndex(where: \.isActive)
    else { return nil }

    var questionRows: [String] = []
    var options: [(number: Int, label: String, isChecked: Bool?, detail: [String])] = []
    var endsAt: Int?
    for row in lines[(tabRow + 1)..<footer] {
      let text = row.text
      if let option = Self.option(in: text) {
        if Self.typeSomething.contains(option.label) {
          endsAt = option.number
          break
        }
        options.append((option.number, option.label, option.isChecked, []))
      } else if row.isBlank {
        continue
      } else if options.isEmpty {
        questionRows.append(text.trimmingCharacters(in: .whitespaces))
      } else {
        options[options.count - 1].detail.append(text.trimmingCharacters(in: .whitespaces))
      }
    }

    // Every option from 1, in order, and then the picker's own `Type something` row. Anything
    // else is a screen that has scrolled or a form that is not this picker.
    guard !options.isEmpty,
      options.map(\.number) == Array(1...options.count),
      endsAt == options.count + 1
    else { return nil }
    let checkboxes = options.map(\.isChecked)
    let allowsMultiple = checkboxes.allSatisfy { $0 != nil }
    guard allowsMultiple || checkboxes.allSatisfy({ $0 == nil }) else { return nil }

    let others = tabs.indices.filter { $0 != active }
    let submitsAfter =
      tabs.count == 1
      ? allowsMultiple
      : active == tabs.count - 1 && others.allSatisfy { tabs[$0].isAnswered }
    return PendingQuestion(
      question: questionRows.joined(separator: " "),
      options: options.map(\.label),
      allowsMultiple: allowsMultiple,
      header: tabs[active].header.isEmpty ? nil : tabs[active].header,
      optionDescriptions: options.map { $0.detail.isEmpty ? nil : $0.detail.joined(separator: " ") },
      pickerTab: PickerTab(
        index: active,
        count: tabs.count,
        submitsAfter: submitsAfter,
        checked: options.filter { $0.isChecked == true }.map(\.number)
      )
    )
  }

  /// A question's text with all whitespace removed, for comparing screen and transcript. The
  /// screen wraps the question (joined here with one space) and breaks a long word with no
  /// space, and neither is in the transcript.
  static func comparable(_ text: String) -> String {
    text.filter { !$0.isWhitespace }
  }

  /// The picker's free-text row. Single-select draws it with a full stop and multi-select
  /// without.
  static let typeSomething: Set<String> = ["Type something.", "Type something"]

  /// Where the footer starts, or `nil` when the screen does not end on it.
  ///
  /// A narrow pane wraps the footer (at 46 columns, `…Esc to` then `cancel`), so the last few
  /// rows are joined before comparing. The middle part varies: `↑/↓ to navigate` for one
  /// question, `Tab/Arrow keys to navigate` for several.
  static func footerStart(in lines: [PaneScreenLine]) -> Int? {
    var joined = ""
    var index = lines.count
    for _ in 0..<3 {
      guard let row = lines[..<index].lastIndex(where: { !$0.isBlank }) else { return nil }
      index = row
      let text = lines[row].text.trimmingCharacters(in: .whitespaces)
      joined = joined.isEmpty ? text : text + " " + joined
      if joined.hasPrefix("Enter to select ·") {
        return joined.hasSuffix("· Esc to cancel") ? row : nil
      }
    }
    return nil
  }

  /// A row that starts with a tab's box, or with the `←` in front of several tabs.
  static func isTabRow(_ line: PaneScreenLine) -> Bool {
    let text = line.text.trimmingCharacters(in: .whitespaces)
    guard let first = text.first else { return false }
    return tabBoxes.contains(first) || (first == "←" && text.contains(where: tabBoxes.contains))
  }

  /// `☐` for a question not yet answered, `☒` for one that is.
  static let tabBoxes: Set<Character> = ["☐", "☒"]

  struct Tab: Equatable {
    let header: String
    let isAnswered: Bool
    /// The picker draws the active tab on a background colour, and nothing else on the row
    /// has one.
    let isActive: Bool
  }

  /// The question tabs on the row, in order, or `nil` when not exactly one is active. The
  /// `✔ Submit` tab is not a question and is left out.
  ///
  /// A row that opens with `←` must close with `✔ Submit  →`, or it has wrapped. Claude Code
  /// shortens inactive headers to keep the row on one line, but a narrow enough pane still
  /// wraps it. A tab count from a wrapped row can be wrong, and a wrong count sends `1` into
  /// the next question as its answer, so a wrapped row reads as nothing.
  static func tabs(in line: PaneScreenLine) -> [Tab]? {
    let text = line.text.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("←") {
      guard text.hasSuffix("→"), text.contains("✔ Submit") else { return nil }
    }
    let characters = line.spans.flatMap { span in
      span.text.map { (character: $0, hasBackground: span.style.background != nil) }
    }
    var tabs: [Tab] = []
    var index = 0
    while index < characters.count {
      let box = characters[index]
      guard tabBoxes.contains(box.character) else {
        index += 1
        continue
      }
      var end = index + 1
      while end < characters.count, !tabBoxes.contains(characters[end].character),
        characters[end].character != "✔", characters[end].character != "→"
      {
        end += 1
      }
      let header = String(characters[(index + 1)..<end].map(\.character))
      tabs.append(
        Tab(
          header: header.trimmingCharacters(in: .whitespaces),
          isAnswered: box.character == "☒",
          isActive: box.hasBackground
        )
      )
      index = end
    }
    guard tabs.count(where: \.isActive) == 1 else { return nil }
    return tabs
  }

  /// One option row: `❯ 1. Apple`, `  2. [✔] Banana`, or `↓ 4. Mango` where the list scrolls.
  /// `isChecked` is `nil` for a row with no box.
  static func option(in text: String) -> (number: Int, label: String, isChecked: Bool?)? {
    var rest = Substring(text).drop(while: \.isWhitespace)
    if let first = rest.first, "❯↑↓".contains(first) {
      rest = rest.dropFirst().drop(while: \.isWhitespace)
    }
    let digits = rest.prefix(while: \.isASCII).prefix(while: \.isNumber)
    guard !digits.isEmpty, let number = Int(digits) else { return nil }
    rest = rest.dropFirst(digits.count)
    guard rest.first == ".", rest.dropFirst().first == " " else { return nil }
    rest = rest.dropFirst().drop(while: \.isWhitespace)
    var isChecked: Bool?
    if rest.hasPrefix("[ ] ") {
      isChecked = false
      rest = rest.dropFirst(4)
    } else if rest.hasPrefix("[✔] ") {
      isChecked = true
      rest = rest.dropFirst(4)
    }
    let label = rest.trimmingCharacters(in: .whitespaces)
    guard !label.isEmpty else { return nil }
    return (number, label, isChecked)
  }
}

extension PaneQuestionScreen {
  // MARK: - Codex's selection pickers

  /// A Codex selection picker, or `nil`.
  ///
  /// Measured on Codex CLI 0.170.0 under herdr 0.9.5 (#109). herdr reports the pane `idle`
  /// while it is open, the title does not change, and the rollout records nothing until a
  /// choice is made. What it draws, with the highlighted row in reverse video:
  ///
  /// ```
  ///   Update Model Permissions                ← the title, bold
  ///
  ///   1. Ask for approval   Read and edit…    ← `N. label`, two spaces, the description
  ///                         access or edits…  ← the description, wrapped at its column
  /// › 2. Approve for me     Only ask for…     ← `›` marks the highlighted row
  ///   …
  ///
  ///   enter select · esc back                 ← `enter default · s session · esc back` on
  ///                                               `/model`'s second stage
  /// ```
  ///
  /// The parse starts at the footer and walks up. The rows just above it are the options, and
  /// the first row of the paragraph above those is the title. So a reply above the picker
  /// that is a numbered list is never read as options. The options must run from 1 with no
  /// gap, and the title must be bold.
  static func codexPicker(in lines: [PaneScreenLine]) -> PendingQuestion? {
    guard let footer = lines.lastIndex(where: { isCodexFooter($0.text) }),
      let lastOption = lines[..<footer].lastIndex(where: { !$0.isBlank })
    else { return nil }
    let firstOption =
      (lines[..<lastOption].lastIndex(where: \.isBlank) ?? -1) + 1
    guard let headingEnd = lines[..<firstOption].lastIndex(where: { !$0.isBlank }) else {
      return nil
    }
    let title = (lines[..<headingEnd].lastIndex(where: \.isBlank) ?? -1) + 1
    guard isBold(lines[title]) else { return nil }

    var options: [(number: Int, label: String, detail: [String])] = []
    for row in lines[firstOption...lastOption] {
      if let option = codexOption(in: row.text) {
        options.append((option.number, option.label, option.detail.map { [$0] } ?? []))
      } else if !options.isEmpty, row.text.first?.isWhitespace == true {
        options[options.count - 1].detail.append(row.text.trimmingCharacters(in: .whitespaces))
      } else {
        return nil
      }
    }
    guard !options.isEmpty, options.map(\.number) == Array(1...options.count) else {
      return nil
    }
    return PendingQuestion(
      question: lines[title].text.trimmingCharacters(in: .whitespaces),
      options: options.map(\.label),
      optionDescriptions: options.map { $0.detail.isEmpty ? nil : $0.detail.joined(separator: " ") },
      // One question, and a digit picks its option with no Enter.
      pickerTab: PickerTab(index: 0, count: 1, submitsAfter: false, leavesNoRecord: true)
    )
  }

  /// `enter select · esc back`, or another middle such as `/model`'s second stage's
  /// `enter default · s session · esc back`.
  static func isCodexFooter(_ text: String) -> Bool {
    let text = text.trimmingCharacters(in: .whitespaces)
    return text.hasPrefix("enter ") && text.hasSuffix(" · esc back")
  }

  /// Whether every visible character on the row is bold.
  static func isBold(_ line: PaneScreenLine) -> Bool {
    let drawn = line.spans.filter { !$0.text.allSatisfy(\.isWhitespace) }
    return !drawn.isEmpty && drawn.allSatisfy(\.style.isBold)
  }

  /// One Codex option row: `  1. Ask for approval   Read and edit…`, or `› 2. …` where it is
  /// highlighted. The label ends at the first run of two or more spaces.
  static func codexOption(in text: String) -> (number: Int, label: String, detail: String?)? {
    var rest = Substring(text).drop(while: \.isWhitespace)
    if rest.first == "›" { rest = rest.dropFirst().drop(while: \.isWhitespace) }
    let digits = rest.prefix(while: \.isASCII).prefix(while: \.isNumber)
    guard !digits.isEmpty, let number = Int(digits) else { return nil }
    rest = rest.dropFirst(digits.count)
    guard rest.first == ".", rest.dropFirst().first == " " else { return nil }
    rest = rest.dropFirst(2)
    let body = rest.trimmingCharacters(in: .whitespaces)
    guard !body.isEmpty else { return nil }
    guard let gap = body.range(of: "  ") else { return (number, body, nil) }
    let detail = body[gap.upperBound...].trimmingCharacters(in: .whitespaces)
    return (
      number, String(body[..<gap.lowerBound]), detail.isEmpty ? nil : detail
    )
  }

  // MARK: - Claude Code's folder-trust dialog

  /// Claude Code's folder-trust dialog, or `nil`. The dialog's rows are `ClaudeTrustPrompt`'s.
  ///
  /// The dialog draws no numbers, and a digit does nothing on it. Measured on Claude Code
  /// 2.1.328 under herdr 0.9.5 (#109): `Down` then `Enter` trusted the folder. So each chip
  /// moves the cursor and presses Enter, with the arrows worked out from a read taken at the
  /// tap (`cursorKeys(to:on:)`). A dialog with no cursor on either option reads as `nil`, and
  /// the notice's Show the Screen is the way to answer it.
  ///
  /// The question is the dialog's first sentence, up to its `?`. The rest of the paragraph
  /// says to review the folder first.
  static func claudeTrust(in lines: [PaneScreenLine]) -> PendingQuestion? {
    let texts = lines.map(\.text)
    guard let rows = ClaudeTrustPrompt.rows(in: texts) else { return nil }
    let cursor = [rows.firstOption, rows.firstOption + 1].firstIndex { row in
      texts[row].trimmingCharacters(in: .whitespaces).hasPrefix(ClaudeTrustPrompt.cursor)
    }
    guard let cursor else { return nil }
    let paragraph = lines[rows.question...].prefix(while: { !$0.isBlank })
      .map { $0.text.trimmingCharacters(in: .whitespaces) }
      .joined(separator: " ")
    let question = paragraph.firstIndex(of: "?").map { String(paragraph[...$0]) } ?? paragraph
    return PendingQuestion(
      question: question,
      options: ClaudeTrustPrompt.options,
      pickerTab: PickerTab(index: 0, count: 1, submitsAfter: false, cursor: cursor + 1)
    )
  }

  /// The keys that move the trust dialog's cursor to `option` and press Enter, worked out
  /// from `screen`, a read taken right before the send. `nil` when that screen no longer
  /// shows the dialog, or shows no cursor on either option, so nothing is sent.
  ///
  /// The chips are drawn from a read up to one watch tick old, and the cursor can move in the
  /// terminal meanwhile. The dialog wraps at its ends, so arrows counted from a stale cursor
  /// can land Enter on "No, exit".
  public static func cursorKeys(to option: Int, on screen: PaneScreen) -> [PaneKey]? {
    guard let question = claudeTrust(in: screen.lines),
      let cursor = question.pickerTab?.cursor,
      question.optionNumbers.contains(option)
    else { return nil }
    return ToolCall.moves(from: cursor, to: option) + [.enter]
  }

  // MARK: - When to read the screen

  /// Whether the chat reads the pane's screen for a question, one `pane read` per tick of
  /// `PaneTranscriptModel.watchInterval`.
  ///
  /// A blocked pane is read, for Claude Code's pickers. So is a Codex that is not working,
  /// because herdr reports its picker `idle` (#109). A transcript whose pending call asks its
  /// own question stops the read, because the transcript wins (`Transcript.questionCall`).
  /// `PaneChatView` and `TerminalScreen` both ask this, so the chips, the composer's hold and
  /// its focus gate read the same screen.
  public static func watches(agent: Agent?, pendingCall: ToolCall?) -> Bool {
    guard let agent, pendingCall?.asksItsOwnQuestions != true else { return false }
    if agent.status == .blocked { return true }
    return agent.status != .working && TranscriptAgent(of: agent) == .codex
  }
}

/// Claude Code's folder-trust dialog, from a pane's visible screen.
///
/// Claude asks whether to trust a folder it has not opened before, and it writes no session
/// record until the user answers. Its title is not set either, so tmux shows its default, the
/// host's name, which a shell pane shows too. The screen is the only signal. `DriverrTmux`
/// reads it for a pane that Claude leads and whose record is missing (#122), and the chat
/// reads it as a question (`PaneQuestionScreen.claudeTrust(in:)`).
///
/// Measured on Claude Code 2.1.328 in tmux 3.7c, at 100 and at 40 columns, and in herdr 0.9.5:
///
/// ```
///  Quick safety check: Is this a project you created or one you trust? (Like your own code, a
///  ...
///  ❯ No, exit
///    Yes, I trust this folder
/// ```
///
/// The question wraps at 40 columns and the option lines do not. So the match is three whole
/// lines: one that starts with the question's opening words, then the two options on adjacent
/// lines below it. Each is trimmed, and the cursor may be on either option. A conversation that
/// quotes the question, or names the options in a sentence, does not match.
public enum ClaudeTrustPrompt {
  static let question = "Quick safety check:"
  /// The options in the order the dialog draws them.
  static let options = ["No, exit", "Yes, I trust this folder"]
  /// The mark in front of the option under the cursor.
  static let cursor = "❯"

  public static func isShowing(_ lines: [String]) -> Bool {
    rows(in: lines) != nil
  }

  /// The row that starts the question, and the row of the first option, or `nil`.
  static func rows(in lines: [String]) -> (question: Int, firstOption: Int)? {
    let lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }
    guard let asked = lines.firstIndex(where: { $0.hasPrefix(question) }) else { return nil }
    let below = lines.indices.dropFirst(asked + 1)
    guard
      let first = zip(below, below.dropFirst()).first(where: { first, second in
        option(lines[first]) == options[0] && option(lines[second]) == options[1]
      })?.0
    else { return nil }
    return (asked, first)
  }

  /// An option line without the cursor in front of it.
  private static func option(_ line: String) -> Substring {
    guard line.hasPrefix(cursor) else { return Substring(line) }
    return line.dropFirst().drop(while: \.isWhitespace)
  }
}

/// Where a question read off the screen sits in Claude Code's picker, which decides the keys
/// that answer it.
///
/// The screen shows one tab at a time, so a question read from it is answered one tab at a
/// time: the keys answer this tab, and the next read of the screen shows the next one. They
/// never replay from the first tab.
public struct PickerTab: Hashable, Sendable {
  /// This question's tab, from zero, among the question tabs.
  public let index: Int
  /// How many question tabs the picker has. The `Submit` tab is not counted.
  public let count: Int
  /// Whether answering this tab reaches the review screen, whose `1` is "Submit answers".
  ///
  /// True for a lone multi-select question, and for the last of several questions once
  /// every other one is answered. A lone single-select question submits on its digit.
  public let submitsAfter: Bool
  /// The options already checked on screen, by number, for a multi-select question. A digit
  /// toggles, so the keys have to start from these.
  public let checked: [Int]
  /// The option under the cursor, by number, for a picker that takes no digits: Claude Code's
  /// folder-trust dialog. Its chips carry their option (`ReplyChip.Action.cursorTo(option:)`),
  /// and the arrows come from a fresh read at the tap, not from this value. `nil` where a
  /// digit answers.
  public let cursor: Int?
  /// Whether the agent records nothing when this picker is answered, so the picker leaving
  /// the screen is the only sign the answer landed. True for Codex's pickers: herdr keeps the
  /// pane `idle` and the rollout gains no turn (#109). See
  /// `ReplyChipGroup.screenQuestionAdvanced(from:to:)`.
  public let leavesNoRecord: Bool

  public init(
    index: Int, count: Int, submitsAfter: Bool, checked: [Int] = [], cursor: Int? = nil,
    leavesNoRecord: Bool = false
  ) {
    self.index = index
    self.count = count
    self.submitsAfter = submitsAfter
    self.checked = checked
    self.cursor = cursor
    self.leavesNoRecord = leavesNoRecord
  }
}

extension Transcript {
  /// The call the chat's chips answer: the transcript's own pending question, or else one
  /// read off the pane's screen. `transcript` is `nil` while the pane has no session file, as
  /// a new Codex has none before its first prompt and Claude has none on its trust dialog.
  ///
  /// The transcript wins whenever it holds the question, because it has the agent's own
  /// words. The screen is read only when the transcript's pending call carries no questions.
  /// Claude Code's pickers are read only on a pane herdr reports blocked. Codex's picker is
  /// read at any status, because herdr reports it `idle`.
  ///
  /// A question already recorded since the last human turn is left out. Right after an answer
  /// the screen and herdr's status can lag the transcript by a poll, and the card would draw
  /// twice.
  public static func questionCall(
    in transcript: Transcript?, screen: PaneScreen?, agentStatus: AgentStatus?
  ) -> ToolCall? {
    let pending = transcript?.pendingToolCall
    if let pending, pending.asksItsOwnQuestions { return pending }
    guard let screen, let read = PaneQuestionScreen(screen: screen),
      read.kind == .codexPicker || agentStatus == .blocked
    else { return pending }
    if let turns = transcript?.turns {
      let exchange = turns.suffix(from: (turns.lastIndex(where: \.isHuman) ?? -1) + 1)
      let recorded = exchange.compactMap(\.toolRun).flatMap(\.calls).flatMap(\.questions)
        .map { PaneQuestionScreen.comparable($0.question) }
      guard !recorded.contains(PaneQuestionScreen.comparable(read.question.question)) else {
        return pending
      }
    }
    return read.call
  }

  /// `questionCall(in:screen:agentStatus:)` for this transcript.
  public func questionCall(screen: PaneScreen?, agentStatus: AgentStatus?) -> ToolCall? {
    Self.questionCall(in: self, screen: screen, agentStatus: agentStatus)
  }
}

extension ReplyChipGroup {
  /// Whether the screen moved from one question to another. The next tab appearing shows the
  /// last answer landed, like a new transcript turn, so it retires the `Sent` notice. Both
  /// sides must come from the screen: a question the transcript takes over is the same
  /// question, and an answered call's evidence arrives through the transcript.
  ///
  /// One exception: a picker whose answer leaves no record (`PickerTab.leavesNoRecord`,
  /// Codex's) going from the screen is its answer landing, because nothing else will say so.
  public static func screenQuestionAdvanced(from old: [ReplyChipGroup], to new: [ReplyChipGroup])
    -> Bool
  {
    guard old.contains(where: { $0.pickerTab != nil }) else { return false }
    if new.isEmpty { return old.contains { $0.pickerTab?.leavesNoRecord == true } }
    return new.contains { $0.pickerTab != nil } && old != new
  }
}
