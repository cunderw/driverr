/// An `AskUserQuestion` read off the pane's screen, for when the session file does not have
/// it yet.
///
/// Claude Code 2.1.281 and 2.1.282 write a pending `AskUserQuestion` to the session file only
/// after it is answered, unless a `PreToolUse` hook matches the tool. Without the hook the
/// question is only on the screen. The transcript wins whenever it has the question; see
/// `Transcript.questionCall`.
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
public struct PaneQuestionScreen: Hashable, Sendable {
  /// The question on the active tab, with `pickerTab` set.
  public let question: PendingQuestion

  public init?(screen: PaneScreen) {
    let lines = screen.lines
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
    question = PendingQuestion(
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

  /// The question as the call the chat's chips answer: an `AskUserQuestion` still waiting.
  public var call: ToolCall {
    ToolCall(name: "AskUserQuestion", outcome: .pending, questions: [question])
  }

  // MARK: - The parse

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

  public init(index: Int, count: Int, submitsAfter: Bool, checked: [Int] = []) {
    self.index = index
    self.count = count
    self.submitsAfter = submitsAfter
    self.checked = checked
  }
}

extension Transcript {
  /// The call the chat's chips answer: the transcript's own pending question, or else one
  /// read off the pane's screen.
  ///
  /// The transcript wins whenever it holds the question, because it has the agent's own
  /// words. The screen is read only on a pane herdr reports blocked, and only when the
  /// transcript's pending call carries no questions.
  ///
  /// A question already recorded since the last human turn is left out. Right after an answer
  /// the screen and herdr's status can lag the transcript by a poll, and the card would draw
  /// twice.
  public func questionCall(screen: PaneScreen?, agentStatus: AgentStatus?) -> ToolCall? {
    let pending = pendingToolCall
    if let pending, pending.asksItsOwnQuestions { return pending }
    guard agentStatus == .blocked, let screen,
      let read = PaneQuestionScreen(screen: screen)
    else { return pending }
    let exchange = turns.suffix(from: (turns.lastIndex(where: \.isHuman) ?? -1) + 1)
    let recorded = exchange.compactMap(\.toolRun).flatMap(\.calls).flatMap(\.questions)
      .map { PaneQuestionScreen.comparable($0.question) }
    guard !recorded.contains(PaneQuestionScreen.comparable(read.question.question)) else {
      return pending
    }
    return read.call
  }
}

extension ReplyChipGroup {
  /// Whether the screen moved from one question to another. The next tab appearing shows the
  /// last answer landed, like a new transcript turn, so it retires the `Sent` notice. Both
  /// sides must come from the screen: a question the transcript takes over is the same
  /// question, and an answered call's evidence arrives through the transcript.
  public static func screenQuestionAdvanced(from old: [ReplyChipGroup], to new: [ReplyChipGroup])
    -> Bool
  {
    old.contains { $0.pickerTab != nil } && new.contains { $0.pickerTab != nil } && old != new
  }
}
