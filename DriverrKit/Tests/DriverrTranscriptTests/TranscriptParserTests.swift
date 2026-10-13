import DriverrCore
import Foundation
import Testing

@testable import DriverrTranscript

/// The terminal-shaped bounds a chat message is deliberately not held to.
enum PaneScreenLimits {
  static let lineLength = PaneScreen.maximumLineLength
}

/// What a turn is, and mostly what it is not. A real session held 482 records for 14 turns,
/// so most assertions are exclusions, each on a typed field rather than a glyph.
struct TranscriptParserTests {
  @Test("a separate terminal duration record annotates the preceding assistant without becoming a row")
  func recordedTurnDuration() throws {
    let page = TranscriptParser.page(from: [
      Fixture.human("go"), Fixture.assistant("done", uuid: "answer"), Fixture.turnDuration("590000"),
    ].joined(separator: "\n"))
    #expect(page.records == 3)
    #expect(page.unreadableRecords == 0)
    #expect(page.turns.map(\.id) == ["u1", "answer"])
    #expect(page.turns.first?.durationMs == nil)
    #expect(page.turns.last?.durationMs == 590000)
  }

  @Test("duration belongs to the last assistant speech and skips tools and agent events")
  func durationSpeechOwnership() throws {
    let page = TranscriptParser.page(from: [
      Fixture.assistant("first", uuid: "a1"), Fixture.assistant("last", uuid: "a2"),
      Fixture.toolUse("Read"), Fixture.toolUse("Agent", input: #"{"name":"finder","description":"Inspect"}"#, uuid: "agent"),
      Fixture.turnDuration("1200"),
    ].joined(separator: "\n"))
    #expect(page.turns.filter(\.isAssistant).map(\.durationMs) == [nil, 1200])
    #expect(page.turns.filter { !$0.isAssistant }.allSatisfy { $0.durationMs == nil })
    #expect(page.turns.compactMap(\.toolRun).flatMap(\.calls).map(\.name) == ["Read"])
    #expect(page.turns.compactMap(\.agentEvent).count == 1)
  }

  @Test("duration cannot cross a human turn or attach to a tools-only tail")
  func durationDoesNotCrossHuman() {
    for lines in [
      [Fixture.assistant("old"), Fixture.human("next"), Fixture.turnDuration("590000")],
      [Fixture.toolUse("Read"), Fixture.turnDuration("590000")],
      [Fixture.turnDuration("590000"), Fixture.assistant("later")],
    ] {
      #expect(TranscriptParser.page(from: lines.joined(separator: "\n")).turns.allSatisfy { $0.durationMs == nil })
    }
  }

  @Test("duration decoding is tolerant and only the exact main-session subtype is eligible")
  func durationValidation() {
    for record in [Fixture.turnDuration("-1"), Fixture.turnDuration("\"590000\""), Fixture.turnDuration("null"),
      Fixture.turnDuration("{}"), Fixture.turnDuration("true"), Fixture.turnDuration("590000", subtype: "other"),
      Fixture.turnDuration("590000", extra: ",\"isSidechain\":true"),
      Fixture.turnDuration("590000", extra: ",\"isMeta\":true")]
    {
      let page = TranscriptParser.page(from: Fixture.assistant("done") + "\n" + record)
      #expect(page.unreadableRecords == 0)
      #expect(page.turns.count == 1)
      #expect(page.turns.first?.durationMs == nil)
    }
    for (raw, expected) in [("0", 0.0), ("1234.9", 1234.0)] {
      let page = TranscriptParser.page(from: Fixture.assistant("done") + "\n" + Fixture.turnDuration(raw))
      #expect(page.turns.first?.durationMs == expected)
    }
  }

  @Test("the fixture has the shape the measurement named")
  func fixtureShape() {
    let lines = Fixture.longSession().split(separator: "\n")
    #expect(lines.count == Fixture.longSessionRecords)
    #expect(lines.filter { $0.contains("\"type\":\"tool_use\"") }.count == Fixture.longSessionToolCalls)
    #expect(lines.filter { $0.contains("\"tool_result\"") }.count == Fixture.longSessionToolCalls)
  }

  @Test("482 records become 14 spoken turns and one run per exchange")
  func longSessionCollapses() {
    let page = TranscriptParser.page(from: Fixture.longSession())

    #expect(page.records == Fixture.longSessionRecords)
    #expect(page.unreadableRecords == 0)

    let spoken = page.turns.filter { $0.isHuman || $0.isAssistant }
    #expect(spoken.count == Fixture.longSessionSpokenTurns)

    let runs = page.turns.compactMap(\.toolRun)
    #expect(runs.count == Fixture.spokenExchanges)
    #expect(runs.reduce(0) { $0 + $1.count } == Fixture.longSessionToolCalls)
  }

  @Test("a tool result is never a human turn")
  func toolResultsAreNotHumanTurns() {
    let page = TranscriptParser.page(
      from: [
        Fixture.human("start"),
        Fixture.toolUse("Read", id: "toolu_1"),
        Fixture.toolResult(id: "toolu_1", output: "a file"),
      ].joined(separator: "\n")
    )
    #expect(page.turns.filter(\.isHuman).map(\.text) == ["start"])
  }

  /// Only the block marker catches text riding along with a tool result. See
  /// `Fixture.toolResultWithText`.
  @Test("text riding along with a tool result is not a human turn either")
  func toolResultCarryingText() {
    let page = TranscriptParser.page(
      from: [
        Fixture.toolResultWithText(id: "toolu_1", text: "<system-reminder>be careful</system-reminder>"),
        Fixture.human("the real one"),
      ].joined(separator: "\n")
    )
    #expect(page.turns.map(\.text) == ["the real one"])
    #expect(page.records == 2)
  }

  /// Only the top-level marker catches a tool result recorded as a bare string. See
  /// `Fixture.toolResultAsString`.
  @Test("a tool result recorded as a string is not a human turn")
  func toolResultAsStringContent() {
    let page = TranscriptParser.page(
      from: [
        Fixture.toolResultAsString("total 48\ndrwxr-xr-x  12 me  staff"),
        Fixture.human("the real one"),
      ].joined(separator: "\n")
    )
    #expect(page.turns.map(\.text) == ["the real one"])
    #expect(page.records == 2)
  }

  @Test("injected text is never a human turn")
  func injectedTextIsNotAHumanTurn() {
    let page = TranscriptParser.page(
      from: [
        Fixture.injected("<system-reminder>The user named this session driverr.</system-reminder>"),
        Fixture.human("the real question"),
      ].joined(separator: "\n")
    )
    #expect(page.turns.count == 1)
    #expect(page.turns.first?.text == "the real question")
    // The count proves the injected record was parsed and rejected.
    #expect(page.records == 2)
  }

  /// Only about half of `user` records with text were typed by a person, and none of the
  /// rest is marked `isMeta`.
  @Test("origin says who caused a record, and only a person is a human turn")
  func originDecidesAuthorship() {
    let page = TranscriptParser.page(
      from: [
        Fixture.humanWithOrigin("what I actually typed", uuid: "real"),
        Fixture.taskNotification(),
      ].joined(separator: "\n")
    )
    #expect(page.turns.map(\.text) == ["what I actually typed"])
    #expect(page.records == 2)
  }

  /// `origin` catches machine records with no recognisable envelope. Real
  /// `task-notification`s all carry their tag, so without this fixture the origin check
  /// looks removable.
  @Test("a non-human origin is refused even when the content looks like prose")
  func originCatchesWhatTheEnvelopeListCannot() {
    let page = TranscriptParser.page(
      from: [
        Fixture.humanWithOrigin(
          "Background task finished in 4m 12s.",
          kind: "some-future-machine-kind",
          promptSource: "system",
          uuid: "m"
        ),
        Fixture.human("the real one", uuid: "h"),
      ].joined(separator: "\n")
    )
    #expect(page.turns.map(\.text) == ["the real one"])
    #expect(page.records == 2)
  }

  @Test("a prompt from the queue or an accepted suggestion is still a person")
  func otherHumanPromptSources() {
    let page = TranscriptParser.page(
      from: [
        Fixture.humanWithOrigin("queued one", promptSource: "queued", uuid: "q"),
        Fixture.humanWithOrigin("accepted one", promptSource: "suggestion_accepted", uuid: "s"),
      ].joined(separator: "\n")
    )
    #expect(page.turns.map(\.text) == ["queued one", "accepted one"])
  }

  /// Older files have no `origin`, so the envelope is their only signal. `<command-name>`
  /// and `<bash-input>` wrap something typed and become turns (see `CommandTurnTests`); a
  /// command's output and a background task's notice yield nothing.
  @Test("the client's own output is not a human turn, even with no origin field")
  func clientEnvelopesAreNotHumanTurns() {
    let envelopes = [
      "<local-command-stdout>Set model to Opus 5</local-command-stdout>",
      "<bash-stdout>M  file.swift</bash-stdout>",
      "<task-notification>\n<task-id>x</task-id>\n</task-notification>",
    ]
    for (index, envelope) in envelopes.enumerated() {
      let page = TranscriptParser.page(
        from: [
          Fixture.clientEnvelope(envelope, uuid: "e\(index)"),
          Fixture.human("the real one", uuid: "h\(index)"),
        ].joined(separator: "\n")
      )
      #expect(page.turns.map(\.text) == ["the real one"], "\(envelope) was read as a person")
    }
  }

  /// Claude Code writes a relayed teammate message as one `user` record with no `origin`: a
  /// preface sentence, `<teammate-message teammate_id="…">` with attributes, the content, the
  /// closing tag and a warning paragraph. An exact-tag match or a bare prefix misses that
  /// shape. The record becomes an `agentEvent` turn (see `TranscriptAgentEventTests`) and
  /// must never be a person.
  @Test("a relayed teammate message is not a human turn, whatever it carries")
  func teammateMessageIsNotAHumanTurn() {
    let relayed = "Relayed from another session:\n"
      + "<teammate-message teammate_id=\"verifier-9\" color=\"blue\">\n"
      + "{\"type\":\"idle_notification\",\"from\":\"verifier-9\",\"idleReason\":\"available\"}\n"
      + "</teammate-message>\n\n"
      + "Fixture text after the last closing tag."
    let page = TranscriptParser.page(
      from: [
        Fixture.clientEnvelope(relayed, uuid: "tm1"),
        Fixture.human("the real one", uuid: "h"),
      ].joined(separator: "\n")
    )
    #expect(page.turns.first?.isHuman == false)
    #expect(page.turns.first?.agentEvent?.sender == "verifier-9")
    // Only the following record carries words a person typed.
    #expect(page.turns.compactMap(\.text) == ["the real one"])
    #expect(page.turns.filter(\.isHuman).count == 1)
    #expect(page.records == 2)
  }

  /// `<teammate-message` prefixes `<teammate-messages>` and `<teammate-message-foo>`, so the
  /// check needs `>` or whitespace after the tag name.
  @Test("only the real tag is recognised, not a name it happens to prefix")
  func teammateMessageTagBoundary() {
    let page = TranscriptParser.page(
      from: Fixture.human("<teammate-messages>not the real tag</teammate-messages>")
    )
    #expect(page.turns.map(\.text) == ["<teammate-messages>not the real tag</teammate-messages>"])
  }

  /// A person running `/summarize` produces machine text, so the envelope check runs even when
  /// `origin` says `human`.
  @Test("an envelope is machine text whoever set it off")
  func envelopeWinsOverOrigin() {
    let page = TranscriptParser.page(
      from: Fixture.humanWithOrigin("<command-message>summarize</command-message>", uuid: "c")
    )
    #expect(page.turns.isEmpty)
    #expect(page.records == 1)
  }

  @Test("a compacted summary is not something anybody said")
  func compactSummaryIsNotAHumanTurn() {
    let page = TranscriptParser.page(
      from: [Fixture.compactSummary("Earlier, the user asked for…"), Fixture.human("now this")]
        .joined(separator: "\n")
    )
    #expect(page.turns.map(\.text) == ["now this"])
  }

  /// The check is a prefix, so an envelope has to open the message.
  @Test("talking about an envelope is not being one")
  func mentioningATagIsNotAnEnvelope() {
    let page = TranscriptParser.page(
      from: Fixture.human("the parser drops <bash-input> records, right?")
    )
    #expect(page.turns.count == 1)
  }

  @Test("a human turn is read from a string content and from text blocks alike")
  func bothHumanShapes() {
    let page = TranscriptParser.page(
      from: [
        Fixture.human("as a string", uuid: "one"),
        Fixture.humanBlocks("as blocks", uuid: "two"),
      ].joined(separator: "\n")
    )
    #expect(page.turns.map(\.text) == ["as a string", "as blocks"])
  }

  @Test("a subagent's turns are not this session's")
  func subagentTurnsAreExcluded() {
    let page = TranscriptParser.page(
      from: [Fixture.subagent("I am a Task"), Fixture.assistant("I am the session")]
        .joined(separator: "\n")
    )
    #expect(page.turns.map(\.text) == ["I am the session"])
  }

  @Test("thinking is neither a turn nor a boundary")
  func thinkingIsIgnored() {
    let page = TranscriptParser.page(
      from: [
        Fixture.toolUse("Read", id: "t1", uuid: "x1"),
        Fixture.thinking(),
        Fixture.toolUse("Edit", id: "t2", uuid: "x2"),
      ].joined(separator: "\n")
    )
    // Thinking between two calls does not split them.
    #expect(page.turns.count == 1)
    #expect(page.turns.first?.toolRun?.count == 2)
  }

  @Test("a tool result between two calls does not split the run")
  func toolResultsDoNotSplitARun() {
    let page = TranscriptParser.page(
      from: [
        Fixture.toolUse("Read", id: "t1", uuid: "x1"),
        Fixture.toolResult(id: "t1", uuid: "r1"),
        Fixture.toolUse("Read", id: "t2", uuid: "x2"),
        Fixture.toolResult(id: "t2", uuid: "r2"),
      ].joined(separator: "\n")
    )
    #expect(page.turns.count == 1)
    #expect(page.turns.first?.toolRun?.count == 2)
  }

  @Test("a human turn closes an open run, and the run keeps its place before it")
  func humanSpeechClosesTheRun() throws {
    let page = TranscriptParser.page(
      from: [
        Fixture.toolUse("Read", id: "t1", uuid: "x1"),
        Fixture.toolUse("Edit", id: "t2", uuid: "x2"),
        Fixture.human("stop, do this instead", uuid: "h"),
        Fixture.toolUse("Bash", id: "t3", uuid: "x3"),
      ].joined(separator: "\n")
    )
    try #require(page.turns.count == 3)
    #expect(page.turns[0].toolRun?.count == 2)
    #expect(page.turns[1].text == "stop, do this instead")
    #expect(page.turns[2].toolRun?.count == 1)
  }

  @Test("something said closes the run, and the run keeps its place before it")
  func speechClosesTheRun() throws {
    let page = TranscriptParser.page(
      from: [
        Fixture.human("go", uuid: "h"),
        Fixture.toolUse("Read", id: "t1", uuid: "x1"),
        Fixture.toolUse("Edit", id: "t2", uuid: "x2"),
        Fixture.assistant("finished", uuid: "a"),
        Fixture.toolUse("Bash", id: "t3", uuid: "x3"),
      ].joined(separator: "\n")
    )
    try #require(page.turns.count == 4)
    #expect(page.turns[0].isHuman)
    #expect(page.turns[1].toolRun?.count == 2)
    #expect(page.turns[2].text == "finished")
    #expect(page.turns[3].toolRun?.count == 1)
  }

  @Test("one record that speaks and then calls a tool produces both, in that order")
  func speechThenToolInOneRecord() throws {
    let page = TranscriptParser.page(from: Fixture.assistantThenTool("on it", tool: "Bash"))
    try #require(page.turns.count == 2)
    #expect(page.turns[0].text == "on it")
    #expect(page.turns[1].toolRun?.calls.map(\.name) == ["Bash"])
    // Distinct ids from one record's uuid, because a list needs unique identities.
    #expect(page.turns[0].id != page.turns[1].id)
  }

  @Test("a turn's id is the record's own, so the same page fetched twice matches")
  func idsComeFromTheRecord() {
    let text = Fixture.human("hello", uuid: "abc-123")
    #expect(TranscriptParser.page(from: text).turns.first?.id == "abc-123")
    #expect(
      TranscriptParser.page(from: text).turns.first?.id
        == TranscriptParser.page(from: text).turns.first?.id
    )
  }

  @Test("a record type this build has never seen is counted and ignored")
  func unknownRecordKinds() {
    let page = TranscriptParser.page(
      from: [
        Fixture.line(["type": "some-future-kind", "uuid": "z"]),
        Fixture.assistant("still here"),
      ].joined(separator: "\n")
    )
    #expect(page.turns.map(\.text) == ["still here"])
    #expect(page.records == 2)
    #expect(page.unreadableRecords == 0)
  }

  @Test("a line that is not JSON is counted, not thrown")
  func unreadableLines() {
    let page = TranscriptParser.page(
      from: ["type\":\"assistant\",\"uuid\":\"half\"}", Fixture.assistant("whole")]
        .joined(separator: "\n")
    )
    #expect(page.unreadableRecords == 1)
    #expect(page.turns.map(\.text) == ["whole"])
  }

  @Test("blank turns are not turns")
  func blankTextIsNotATurn() {
    let page = TranscriptParser.page(
      from: [Fixture.human("   "), Fixture.assistant("\n\n")].joined(separator: "\n")
    )
    #expect(page.turns.isEmpty)
    #expect(page.records == 2)
  }

  /// A person can paste coloured output into a prompt.
  @Test("terminal control sequences never reach the text a view renders")
  func ansiIsStripped() throws {
    let page = TranscriptParser.page(
      from: [
        Fixture.human("Set model to \u{1B}[1mOpus 5\u{1B}[22m today", uuid: "h"),
        Fixture.assistant("done \u{1B}]0;window title\u{7}now", uuid: "a"),
      ].joined(separator: "\n")
    )
    try #require(page.turns.count == 2)
    #expect(page.turns[0].text == "Set model to Opus 5 today")
    #expect(page.turns[1].text == "done now")
    #expect(page.turns.allSatisfy { !($0.text ?? "").contains("\u{1B}") })
  }

  /// A screen row is clamped to 512 columns because a terminal has columns; prose does not,
  /// and some assistant messages run past 4,000 characters.
  @Test("a long message is not cut to a terminal's width")
  func longMessagesAreNotClamped() throws {
    // The control character forces the text through the scanner; clean text short-circuits and
    // would hide a clamp bug.
    let long = String(repeating: "word ", count: 400) + "\u{1B}[0mend"
    let page = TranscriptParser.page(from: Fixture.assistant(long))
    let text = try #require(page.turns.first?.text)
    #expect(text.count == long.count - 4)
    #expect(text.hasSuffix("end"))
    #expect(text.count > PaneScreenLimits.lineLength)
  }

  @Test("text with nothing to sanitise is returned exactly as it was")
  func ordinaryTextIsUntouched() {
    let text = "a normal message — with an em dash, an emoji 🎉 and\ntwo lines"
    let page = TranscriptParser.page(from: Fixture.assistant(text))
    #expect(page.turns.first?.text == text)
  }

  @Test("timestamps parse with and without a fraction")
  func timestamps() {
    #expect(TranscriptParser.timestamp("2026-08-24T15:04:04.988Z") != nil)
    #expect(TranscriptParser.timestamp("2026-08-24T15:04:04Z") != nil)
    #expect(TranscriptParser.timestamp("not a date") == nil)
    #expect(TranscriptParser.timestamp(nil) == nil)
  }
}

/// `TranscriptTurn.isParentPrompt` requires both `record.origin == nil` and
/// `record.parentUuid == nil`. Each test below isolates one half.
struct SubagentParentPromptTests {
  @Test("a sub-agent's opening prompt is labelled the parent's own")
  func opensAsTheParentsPrompt() throws {
    let page = TranscriptParser.page(
      from: Fixture.subagentPrompt("Implement the retry fix end to end."), forSubagentFile: true)
    let turn = try #require(page.turns.first)
    #expect(turn.isParentPrompt)
  }

  /// The ordinary later-turn shape: an `origin` and a named parent. `parentUuidAloneIsNotEnough`
  /// isolates the `origin` half.
  @Test("a later human turn with an origin and a named parent is not the parent's prompt")
  func laterHumanTurnIsNotTheParentsPrompt() throws {
    let page = TranscriptParser.page(
      from: [
        Fixture.subagentPrompt("Implement the retry fix end to end.", uuid: "sp1"),
        Fixture.subagentHumanFollowUp("One more thing — also update the changelog.", parent: "sp1"),
      ].joined(separator: "\n"),
      forSubagentFile: true
    )
    try #require(page.turns.count == 2)
    #expect(page.turns[0].isParentPrompt)
    #expect(!page.turns[1].isParentPrompt)
  }

  /// No `origin` and a named parent. A guard checking only `origin == nil` would flag it.
  @Test("an origin-less record with a named parent is not the parent's prompt")
  func parentUuidAloneIsNotEnough() throws {
    let page = TranscriptParser.page(
      from: [
        Fixture.subagentPrompt("Implement the retry fix end to end.", uuid: "sp1"),
        Fixture.subagentFollowUp("A record naming its parent, still no origin.", parent: "sp1"),
      ].joined(separator: "\n"),
      forSubagentFile: true
    )
    try #require(page.turns.count == 2)
    #expect(page.turns[0].isParentPrompt)
    #expect(!page.turns[1].isParentPrompt)
  }

  /// A null parent with an `origin`. Real files never have this, but only such a record
  /// isolates the guard's `origin == nil` half.
  @Test("a record naming no parent but carrying an origin is not the parent's prompt")
  func originAloneIsNotEnough() throws {
    let page = TranscriptParser.page(
      from: Fixture.subagentPromptWithOrigin("Not the file's real opening prompt."),
      forSubagentFile: true
    )
    let turn = try #require(page.turns.first)
    #expect(!turn.isParentPrompt)
  }

  @Test("the same records read without the sub-agent flag are ordinary human turns")
  func withoutTheFlagNothingIsFlagged() throws {
    let page = TranscriptParser.page(
      from: Fixture.subagentPrompt("Implement the retry fix end to end.")
    )
    // Without the flag, `isSidechain: true` drops the record entirely.
    #expect(page.turns.isEmpty)
  }
}

/// What a tool call is called and what it was about.
struct ToolTargetTests {
  private func target(_ name: String, input: String) -> String? {
    let page = TranscriptParser.page(from: Fixture.toolUse(name, input: input))
    return page.turns.first?.toolRun?.calls.first?.target
  }

  @Test("a path target is its last component")
  func pathTargets() {
    #expect(target("Edit", input: #"{"file_path":"/repo/Sources/PTYBridge.swift"}"#) == "PTYBridge.swift")
    #expect(target("Read", input: #"{"file_path":"/a/b/c.txt","limit":40}"#) == "c.txt")
  }

  @Test("a Bash call is named by its description rather than its command")
  func bashTargets() {
    #expect(
      target("Bash", input: #"{"command":"git status --porcelain","description":"Check the tree"}"#)
        == "Check the tree"
    )
  }

  @Test("a command with no description falls back to its first line only")
  func multilineCommands() {
    #expect(target("Bash", input: #"{"command":"one\ntwo\nthree"}"#) == "one")
  }

  @Test("an input with nothing worth naming has no target")
  func structuredInputsHaveNoTarget() {
    #expect(target("AskUserQuestion", input: #"{"questions":[{"header":"Auth"}]}"#) == nil)
    #expect(target("Read", input: "{}") == nil)
    #expect(target("Read", input: #"{"file_path":"   "}"#) == nil)
  }

  @Test("a long target is cut to one line's worth")
  func longTargetsAreShortened() {
    let long = String(repeating: "x", count: 300)
    let value = target("Bash", input: #"{"description":"\#(long)"}"#)
    #expect(value?.count == 80)
    #expect(value?.hasSuffix("…") == true)
  }

  @Test("the tool's own name is kept exactly, MCP spelling and all")
  func namesAreNotRewritten() {
    let page = TranscriptParser.page(from: Fixture.toolUse("mcp__claude-in-chrome__navigate"))
    #expect(page.turns.first?.toolRun?.calls.first?.name == "mcp__claude-in-chrome__navigate")
  }
}

/// What the agent is waiting on, and what went wrong on the way. A permission prompt writes
/// nothing to the session file until answered, so its only trace is a `tool_use` with no
/// result.
struct PendingToolCallTests {
  /// `pendingToolCall` is derived from the turns, so the page is built as a whole value.
  private func transcript(_ lines: [String]) -> Transcript {
    Transcript(turns: TranscriptParser.page(from: lines.joined(separator: "\n")).turns, window: .none)
  }

  @Test("a tail call with no result is the call the agent is waiting on")
  func tailCallWithNoResult() throws {
    let page = transcript([
      Fixture.human("run the tests", uuid: "h"),
      Fixture.toolUse("Bash", input: #"{"description":"cargo test"}"#, id: "toolu_1", uuid: "x1"),
      Fixture.resultsScanned,
    ])
    let pending = try #require(page.pendingToolCall)
    #expect(pending.name == "Bash")
    #expect(pending.target == "cargo test")
    #expect(pending.outcome == .pending)
  }

  @Test("a tail call whose result came back is not pending")
  func tailCallAnswered() {
    let page = transcript([
      Fixture.human("run the tests", uuid: "h"),
      Fixture.toolUse("Bash", input: #"{"description":"cargo test"}"#, id: "toolu_1", uuid: "x1"),
      Fixture.resultsScanned,
      Fixture.result(id: "toolu_1"),
    ])
    #expect(page.pendingToolCall == nil)
    #expect(page.turns.last?.toolRun?.calls.last?.outcome == .succeeded)
  }

  /// Without the scan mark, every finished conversation would show a permission prompt.
  @Test("a page nobody scanned reports nothing rather than everything")
  func noScanMeansNoAnswer() {
    let page = transcript([
      Fixture.human("run the tests", uuid: "h"),
      Fixture.toolUse("Bash", input: #"{"description":"cargo test"}"#, id: "toolu_1", uuid: "x1"),
    ])
    #expect(page.pendingToolCall == nil)
    #expect(page.turns.last?.toolRun?.calls.last?.outcome == .unknown)
  }

  @Test("a page that ends on something said is not waiting on a tool")
  func speechAfterTheRun() {
    let page = transcript([
      Fixture.toolUse("Bash", input: #"{"description":"cargo test"}"#, id: "toolu_1", uuid: "x1"),
      Fixture.assistant("all green", uuid: "a"),
      Fixture.resultsScanned,
    ])
    #expect(page.pendingToolCall == nil)
  }

  /// A result is written after its call, so only the newest call's absence means anything.
  /// An older call whose result fell outside the window stays unknown.
  @Test("an older call in the run is never reported as pending")
  func onlyTheTailCallCounts() throws {
    let page = transcript([
      Fixture.toolUse("Read", id: "toolu_1", uuid: "x1"),
      Fixture.toolUse("Bash", input: #"{"description":"cargo test"}"#, id: "toolu_2", uuid: "x2"),
      Fixture.resultsScanned,
      Fixture.result(id: "toolu_2"),
    ])
    #expect(page.pendingToolCall == nil)
    let run = try #require(page.turns.last?.toolRun)
    #expect(run.calls.map(\.outcome) == [.unknown, .succeeded])
  }

  /// A call with no id can never be matched to a result.
  @Test("a call with no identifier is unknown rather than pending")
  func callWithoutAnIdentifier() {
    let page = transcript([
      Fixture.toolUseWithoutIdentifier("Bash"),
      Fixture.resultsScanned,
    ])
    #expect(page.pendingToolCall == nil)
    #expect(page.turns.last?.toolRun?.calls.last?.outcome == .unknown)
  }

  @Test("a result line is not a record and is not counted as one")
  func resultLinesAreNotRecords() {
    let page = TranscriptParser.page(
      from: [
        Fixture.human("go"),
        Fixture.resultsScanned,
        Fixture.result(id: "toolu_1"),
        Fixture.result(id: "toolu_2", failed: true),
      ].joined(separator: "\n")
    )
    #expect(page.records == 1)
    #expect(page.unreadableRecords == 0)
  }

  @Test("task lines are neither records nor unreadable")
  func taskLinesAreNotRecords() {
    let page = TranscriptParser.page(
      from: [
        Fixture.human("go"),
        Fixture.resultsScanned,
        Fixture.task("toolu_1"),
        Fixture.task("a1b2c3", status: "failed"),
      ].joined(separator: "\n")
    )
    #expect(page.records == 1)
    #expect(page.unreadableRecords == 0)
  }

  /// A spawn's result line carries three more fields. Splitting once and requiring two
  /// fields read a failed spawn as a success.
  @Test("a result line with launch fields still says whether the call failed")
  func resultLineWithLaunchFields() {
    let run = TranscriptParser.page(
      from: [
        Fixture.toolUse("Bash", input: #"{"command":"ls"}"#, id: "toolu_1"),
        Fixture.resultsScanned,
        Fixture.spawnResult(id: "toolu_1", status: "completed", agentID: "a1", failed: true),
      ].joined(separator: "\n")
    ).turns.last?.toolRun
    #expect(run?.calls.first?.outcome == .failed)
  }
}

/// A run that errored must not read like one that did not.
struct ToolRunFailureTests {
  private func lastRun(_ lines: [String]) -> ToolRun? {
    TranscriptParser.page(from: lines.joined(separator: "\n")).turns.last?.toolRun
  }

  @Test("a result marked is_error makes the call failed, and the run counts it")
  func failedCalls() throws {
    let run = try #require(
      lastRun([
        Fixture.toolUse("Read", id: "toolu_1", uuid: "x1"),
        Fixture.toolUse("Bash", id: "toolu_2", uuid: "x2"),
        Fixture.toolUse("Edit", id: "toolu_3", uuid: "x3"),
        Fixture.resultsScanned,
        Fixture.result(id: "toolu_1"),
        Fixture.result(id: "toolu_2", failed: true),
        Fixture.result(id: "toolu_3"),
      ])
    )
    #expect(run.failedCount == 1)
    #expect(run.calls.map(\.outcome) == [.succeeded, .failed, .succeeded])
  }

  /// The floor, not the total: over-reporting marks a call that worked.
  @Test("a call whose result did not travel is not counted as failed")
  func uncoveredCallsAreNotFailures() throws {
    let run = try #require(
      lastRun([
        Fixture.toolUse("Read", id: "toolu_1", uuid: "x1"),
        Fixture.toolUse("Bash", id: "toolu_2", uuid: "x2"),
        Fixture.resultsScanned,
        Fixture.result(id: "toolu_2", failed: true),
      ])
    )
    #expect(run.failedCount == 1)
    #expect(run.calls.first?.outcome == .unknown)
  }

  @Test("a run nobody scanned reports no failures")
  func noScanNoFailures() throws {
    let run = try #require(lastRun([Fixture.toolUse("Bash", id: "toolu_1", uuid: "x1")]))
    #expect(run.failedCount == 0)
  }
}

/// The agent's question, when it asked one through a tool. Rare, and the one blocked shape
/// whose words are a typed field.
struct AskUserQuestionTests {
  @Test("an AskUserQuestion record yields an assistant turn whose text is its question")
  func questionBecomesSpeech() throws {
    let page = TranscriptParser.page(
      from: Fixture.askUserQuestion(["Which pane should win the focus?"])
    )
    try #require(page.turns.count == 2)
    #expect(page.turns[0].isAssistant)
    #expect(page.turns[0].text == "Which pane should win the focus?")
    // The call is still a call, or the tally would disagree with the file.
    #expect(page.turns[1].toolRun?.calls.map(\.name) == ["AskUserQuestion"])
  }

  @Test("the question is said before the call that carried it")
  func questionComesFirst() throws {
    let page = TranscriptParser.page(
      from: [
        Fixture.toolUse("Read", id: "toolu_1", uuid: "x1"),
        Fixture.askUserQuestion(["Proceed?"], id: "toolu_2", uuid: "x2"),
      ].joined(separator: "\n")
    )
    try #require(page.turns.count == 3)
    #expect(page.turns[0].toolRun?.calls.map(\.name) == ["Read"])
    #expect(page.turns[1].text == "Proceed?")
    #expect(page.turns[2].toolRun?.calls.map(\.name) == ["AskUserQuestion"])
    #expect(page.turns[1].id != page.turns[2].id)
  }

  @Test("several questions in one call are all kept")
  func severalQuestions() {
    let page = TranscriptParser.page(
      from: Fixture.askUserQuestion(["Which host?", "And which pane?"])
    )
    #expect(page.turns.first?.text == "Which host?\n\nAnd which pane?")
  }

  @Test("a call with no question in it says nothing")
  func questionlessCalls() {
    let empty = TranscriptParser.page(from: Fixture.askUserQuestion(["   "]))
    #expect(empty.turns.count == 1)
    #expect(empty.turns.first?.toolRun != nil)

    let ordinary = TranscriptParser.page(from: Fixture.toolUse("Read"))
    #expect(ordinary.turns.count == 1)
    #expect(ordinary.turns.first?.toolRun != nil)
  }

  /// Carried through to `ToolCall.questions` for the reply chips.
  @Test("the call's options come through in the order the agent listed them")
  func optionsCarryThrough() {
    let page = TranscriptParser.page(from: Fixture.askUserQuestion(["Proceed?"]))
    #expect(page.turns.last?.toolRun?.calls.last?.questions.first?.options == ["Yes", "No"])
  }

  @Test("an ordinary tool call carries no questions")
  func ordinaryCallHasNoOptions() {
    let page = TranscriptParser.page(from: Fixture.toolUse("Read"))
    #expect(page.turns.first?.toolRun?.calls.first?.questions == [])
  }

  /// One entry per question, each with its own options and `multiSelect`.
  @Test("every question comes through with its own options, not only the first's")
  func everyQuestionsOptions() throws {
    let page = TranscriptParser.page(
      from: Fixture.askUserQuestion(
        ["Which branch?", "Run the tests?", "Which reviewers?"],
        options: [["main", "release"], ["Yes", "No"], ["Ann", "Bo"]],
        multiSelect: [false, false, true]
      )
    )
    let call = try #require(page.turns.last?.toolRun?.calls.last)
    #expect(call.questions.map(\.question) == ["Which branch?", "Run the tests?", "Which reviewers?"])
    #expect(call.questions.map(\.options) == [["main", "release"], ["Yes", "No"], ["Ann", "Bo"]])
    #expect(call.questions.map(\.allowsMultiple) == [false, false, true])
  }

  @Test("a single-question call yields exactly one question")
  func singleQuestionUnchanged() throws {
    let page = TranscriptParser.page(from: Fixture.askUserQuestion(["Proceed?"]))
    let call = try #require(page.turns.last?.toolRun?.calls.last)
    #expect(
      call.questions == [
        PendingQuestion(
          question: "Proceed?", options: ["Yes", "No"], askedInCall: 1, header: "Choice")
      ]
    )
  }

  /// A question with no answers cannot be tapped, so it is not kept as an empty heading.
  @Test("a question with no options is dropped rather than kept empty")
  func optionlessQuestionsDropped() throws {
    let page = TranscriptParser.page(
      from: Fixture.askUserQuestion(["Which branch?", "Anything else?"], options: [["main"], []])
    )
    let call = try #require(page.turns.last?.toolRun?.calls.last)
    #expect(call.questions.map(\.question) == ["Which branch?"])
    // The dropped question still has a picker tab; see `aDroppedQuestionFailsClosed`.
    #expect(call.replyChipGroups.isEmpty)
  }

  /// The picker numbers an option the parse drops. Renumbered, a tap on Cherry would press 2
  /// and answer the blank option.
  @Test("an option with no usable label is dropped, and the options after it keep their numbers")
  func aDroppedOptionKeepsLaterNumbers() throws {
    let page = TranscriptParser.page(
      from: Fixture.askUserQuestion(["Pick a fruit"], options: [["Apple", "  ", "Cherry"]])
    )
    let call = try #require(page.turns.last?.toolRun?.calls.last)
    #expect(call.questions.map(\.options) == [["Apple", "Cherry"]])
    #expect(call.questions.map(\.optionNumbers) == [[1, 3]])
    #expect(call.replyChips.map(\.action) == [.key(.digit1), .key(.digit3)])
  }

  /// A dropped question still has a picker tab that no chip can answer, so keys would land in
  /// the wrong question. The call offers no chips and waits to be answered in the terminal.
  @Test("a dropped question takes every chip off the call")
  func aDroppedQuestionFailsClosed() throws {
    for options in [[["main"], [], ["Ann"]], [["main"], ["Ann"], []], [[], ["main"], ["Ann"]]] {
      let page = TranscriptParser.page(
        from: Fixture.askUserQuestion(["Which branch?", "Who reviews?", "Anything else?"], options: options)
      )
      let call = try #require(page.turns.last?.toolRun?.calls.last)
      #expect(call.questions.count == 2)
      #expect(call.questions.allSatisfy { $0.askedInCall == 3 })
      #expect(call.replyChipGroups.isEmpty, "\(options): \(call.replyChips.map(\.action))")
      let notice = call.pendingNotice(agentStatus: .blocked)
      #expect(notice.isAsking)
      #expect(notice.chips.isEmpty, "not even the generic Approve/Deny pair")
    }
  }

  @Test("a pending AskUserQuestion keeps its options")
  func pendingCallKeepsOptions() throws {
    let transcript = Transcript(
      turns: TranscriptParser.page(
        from: [Fixture.askUserQuestion(["Proceed?"]), Fixture.resultsScanned].joined(separator: "\n")
      ).turns,
      window: .none
    )
    let pending = try #require(transcript.pendingToolCall)
    #expect(pending.name == "AskUserQuestion")
    #expect(pending.questions.first?.options == ["Yes", "No"])
  }

  /// Two `AskUserQuestion` calls on one page: the first answered (its result line present,
  /// the `tool_result` record dropped by `TranscriptCommands.recordSelector`), the second
  /// with nothing behind it. The live call must reach `.pending` with both questions' chips.
  /// The record shape matches the real one, including ignored fields such as an option's
  /// `description` and the block's `caller`.
  @Test("an answered question followed by a live one leaves the live one pending")
  func aSecondQuestionAfterAnAnsweredOneIsPending() throws {
    let transcript = Transcript(
      turns: TranscriptParser.page(
        from: [
          Fixture.human("Walk through the open questions with me", uuid: "h1"),
          Fixture.askUserQuestion(
            ["Fruit: which one next?"],
            options: [["Apple now", "Banana first", "Neither"]],
            describedOptions: true,
            caller: "assistant",
            id: "toolu_answered",
            uuid: "q-answered"
          ),
          Fixture.askUserQuestion(
            ["Colour check: does the red one pass?", "Fruit: which ones are still ripe?"],
            options: [["Passed", "Failed", "Not tried"], ["Apple", "Banana", "None"]],
            multiSelect: [false, true],
            describedOptions: true,
            caller: "assistant",
            id: "toolu_live",
            uuid: "q-live"
          ),
          Fixture.resultsScanned,
          Fixture.result(id: "toolu_answered"),
        ].joined(separator: "\n")
      ).turns,
      window: .none
    )

    // Both questions arrive as the agent's words, ahead of their runs.
    #expect(transcript.turns.map(\.isAssistant) == [false, true, false, true, false])
    #expect(transcript.turns[1].text?.hasPrefix("Fruit: which one next") == true)
    #expect(transcript.turns[2].toolRun?.calls.last?.outcome == .succeeded)

    let pending = try #require(transcript.pendingToolCall)
    #expect(pending.name == "AskUserQuestion")
    #expect(pending.questions.map(\.options.count) == [3, 3])
    #expect(pending.questions.map(\.allowsMultiple) == [false, true])
    #expect(pending.replyChipGroups.map(\.chips.count) == [3, 3])
  }

  /// A Claude Code 2.1.281 page. The record shape and its keys are 2.1.281's, and the questions
  /// are written for the test: three single-select questions with long markdown text and
  /// described options, a thinking-only record before the call, and the two keys 2.1.281 adds
  /// to an assistant record, `wireToolInputs` and a `session_id` that differs from `sessionId`.
  @Test("a 2.1.281 three-question call parses to a pending prompt with every group")
  func aClaudeCode2_1_281ThreeQuestionCallIsPending() throws {
    let input =
      ##"{"questions":["##
      + ##"{"question":"The stand opens at eight, and the first crate goes on the `front` table before then. Which fruit should that table carry this week?","header":"Front table","multiSelect":false,"options":["##
      + ##"{"label":"Apples (Recommended)","description":"They keep all day in the sun."},"##
      + ##"{"label":"Pears","description":"Ripe now, and bruised by noon."},"##
      + ##"{"label":"Plums","description":"Only when the `back` table is full."}]},"##
      + ##"{"question":"The price board says `per kilo` on every row but one, and cherries are packed `per punnet`. How should the board price cherries?","header":"Cherries","multiSelect":false,"options":["##
      + ##"{"label":"Per kilo","description":"The unit every other row uses."},"##
      + ##"{"label":"Per punnet (Recommended)","description":"As they are packed today."},"##
      + ##"{"label":"Both","description":"Two prices on one row."}]},"##
      + ##"{"question":"Fruit of the week, Apple or Banana: where should the spare Apple go?","header":"Spare fruit","multiSelect":false,"options":["##
      + ##"{"label":"No shelf (Recommended)","description":"Keep it on the counter."},"##
      + ##"{"label":"Friday's special","description":"Move it to the last open slot."},"##
      + ##"{"label":"Give it away","description":"Hand it to the next customer."},"##
      + ##"{"label":"Keep it in the cooler","description":"No change."}]}]}"##
    let call =
      ##"{"parentUuid":"t-q3","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_q3","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_q3","name":"AskUserQuestion","input":"##
      + input
      + ##","caller":{"type":"direct"}}],"stop_reason":"tool_use"},"wireToolInputs":{"toolu_q3":"##
      + input
      + ##"},"apiBlockIndex":1,"type":"assistant","uuid":"q-q3","timestamp":"2026-01-01T00:00:00.000Z","session_id":"6e7f8a9b-0000-4000-8000-000000000000","userType":"external","entrypoint":"cli","cwd":"/tmp/repo","sessionId":"0c1d2e3f-0000-4000-8000-000000000000","version":"2.1.281","gitBranch":"main"}"##
    let records = [
      Fixture.humanWithOrigin("ask them one at a time", uuid: "h-q3"),
      Fixture.thinking(uuid: "t-q3"),
      call,
    ]

    // The host scanned for results and found none for this call.
    let pending = Transcript(
      turns: TranscriptParser.page(from: (records + [Fixture.resultsScanned]).joined(separator: "\n"))
        .turns,
      window: .none
    )
    try #require(pending.turns.count == 3)
    #expect(pending.turns[1].isAssistant)
    #expect(pending.turns[1].text?.hasPrefix("The stand opens at eight") == true)
    #expect(pending.turns[1].text?.contains("Fruit of the week, Apple or Banana") == true)
    let asked = try #require(pending.pendingToolCall)
    #expect(asked.name == "AskUserQuestion")
    #expect(asked.questions.map(\.options.count) == [3, 3, 4])
    #expect(asked.questions.map(\.allowsMultiple) == [false, false, false])
    // The header and each option's description, which the picker draws.
    #expect(asked.questions.map(\.header) == ["Front table", "Cherries", "Spare fruit"])
    #expect(
      asked.questions[0].optionDescriptions == [
        "They keep all day in the sun.",
        "Ripe now, and bruised by noon.",
        "Only when the `back` table is full.",
      ])
    #expect(asked.questions[2].optionDescriptions.last == "No change.")
    #expect(asked.questions.allSatisfy { $0.answer == nil })
    let groups = asked.pendingNotice(agentStatus: .blocked).groups
    #expect(groups.map(\.header) == ["Front table", "Cherries", "Spare fruit"])
    #expect(groups[1].chips[1].detail == "As they are packed today.")
    // Offered whatever herdr says about the pane.
    for status in [AgentStatus.working, .idle, .blocked, .unknown] {
      #expect(asked.pendingNotice(agentStatus: status).groups.map(\.chips.count) == [3, 3, 4])
    }

    // Answered in the terminal: the question stays and the call closes.
    let answered = Transcript(
      turns: TranscriptParser.page(
        from: (records + [Fixture.resultsScanned, Fixture.result(id: "toolu_q3")])
          .joined(separator: "\n")
      ).turns,
      window: .none
    )
    #expect(answered.turns[1].text?.hasPrefix("The stand opens at eight") == true)
    #expect(answered.turns.last?.toolRun?.calls.last?.outcome == .succeeded)
    #expect(answered.pendingToolCall == nil)

    // With the reply record on the page, the run knows the answers, keyed by question text.
    let reply = Fixture.askUserQuestionAnswer(
      id: "toolu_q3",
      answers: [
        (
          question: "The stand opens at eight, and the first crate goes on the `front` table before then. Which fruit should that table carry this week?",
          answer: "Apples (Recommended)"
        ),
        (
          question: "The price board says `per kilo` on every row but one, and cherries are packed `per punnet`. How should the board price cherries?",
          answer: "Per punnet (Recommended)"
        ),
        (question: "Fruit of the week, Apple or Banana: where should the spare Apple go?", answer: "Give it away"),
      ]
    )
    let replied = TranscriptParser.page(
      from: (records + [reply, Fixture.resultsScanned, Fixture.result(id: "toolu_q3")])
        .joined(separator: "\n")
    )
    // The reply makes no turn of its own.
    #expect(replied.turns.count == 3)
    let run = try #require(replied.turns.last?.toolRun)
    #expect(
      run.calls.last?.questions.map(\.answer)
        == ["Apples (Recommended)", "Per punnet (Recommended)", "Give it away"])
    #expect(run.answeredQuestions.map(\.header) == ["Front table", "Cherries", "Spare fruit"])
  }

  /// A multi-select answer is the labels joined by `", "`, as the tool writes it.
  @Test("an answered call carries each question's answer from its reply record")
  func anAnsweredCallCarriesItsAnswers() throws {
    let page = TranscriptParser.page(
      from: [
        Fixture.askUserQuestion(
          ["Pick a fruit", "Pick fruits"],
          options: [["Apple", "Banana", "Cherry"], ["Apple", "Banana", "Cherry"]],
          multiSelect: [false, true],
          describedOptions: true,
          id: "toolu_a"
        ),
        Fixture.askUserQuestionAnswer(
          id: "toolu_a",
          answers: [(question: "Pick a fruit", answer: "Banana"), (question: "Pick fruits", answer: "Apple, Cherry")]
        ),
        Fixture.resultsScanned,
        Fixture.result(id: "toolu_a"),
      ].joined(separator: "\n")
    )
    let call = try #require(page.turns.last?.toolRun?.calls.last)
    #expect(call.outcome == .succeeded)
    #expect(call.questions.map(\.answer) == ["Banana", "Apple, Cherry"])
    #expect(call.questions.map(\.header) == ["Choice", "Choice"])
    #expect(call.questions[0].optionDescriptions == ["What Apple does.", "What Banana does.", "What Cherry does."])
  }

  @Test("an answer reaches only the call and the question it names")
  func anAnswerReachesOnlyItsOwnCall() throws {
    let page = TranscriptParser.page(
      from: [
        Fixture.askUserQuestion(["Pick a fruit", "Pick a color"], id: "toolu_a", uuid: "qa"),
        Fixture.askUserQuestionAnswer(
          id: "toolu_a", answers: [(question: "Pick a fruit", answer: "Yes")], uuid: "ra"),
        Fixture.askUserQuestion(["Pick again"], id: "toolu_b", uuid: "qb"),
        Fixture.askUserQuestionAnswer(
          id: "toolu_other", answers: [(question: "Pick again", answer: "No")], uuid: "rb"),
        Fixture.resultsScanned,
        Fixture.result(id: "toolu_a"),
      ].joined(separator: "\n")
    )
    let runs = page.turns.compactMap(\.toolRun)
    try #require(runs.count == 2)
    #expect(runs[0].calls[0].questions.map(\.answer) == ["Yes", nil])
    #expect(runs[1].calls[0].questions.map(\.answer) == [nil])
  }

  /// Claude Code writes a bare string for a refused call.
  @Test("a reply with no answers in it answers nothing and fails nothing")
  func aReplyWithNoAnswersIsHarmless() throws {
    let page = TranscriptParser.page(
      from: [
        Fixture.askUserQuestion(["Pick a fruit"], id: "toolu_a"),
        Fixture.line(
          ["type": "user", "uuid": "rs2", "timestamp": Fixture.timestamp],
          raw: [
            "toolUseResult": #""Error: User rejected tool use""#,
            "message":
              #"{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_a","#
              + #""content":"rejected","is_error":true,"answers":{"Pick a fruit":"Yes"}}]}"#,
          ]
        ),
        Fixture.toolResult(id: "toolu_a", output: "\"answers\": is only text here"),
      ].joined(separator: "\n")
    )
    #expect(page.unreadableRecords == 0)
    #expect(page.turns.last?.toolRun?.calls.last?.questions.map(\.answer) == [nil])
  }
}

/// Human turns typed as a command. Dropped, a skill-driven session renders with no human
/// turn anywhere.
struct CommandTurnTests {
  private func turns(_ text: String, uuid: String = "c1") -> [TranscriptTurn] {
    TranscriptParser.page(from: Fixture.clientEnvelope(text, uuid: uuid)).turns
  }

  @Test("a slash command becomes a human turn flagged as a command")
  func slashCommands() throws {
    let page = turns("<command-name>/run-tests</command-name>\n<command-message>run-tests</command-message>")
    try #require(page.count == 1)
    #expect(page[0].text == "/run-tests")
    #expect(page[0].isHuman)
    #expect(page[0].isCommand)
  }

  @Test("its arguments come with it")
  func slashCommandArguments() {
    let page = turns(
      "<command-message>code-review</command-message>\n"
        + "<command-name>/code-review</command-name>\n"
        + "<command-args>high --fix</command-args>"
    )
    #expect(page.map(\.text) == ["/code-review high --fix"])
  }

  @Test("a bash-mode line becomes a human turn too, with its bang")
  func bashInput() throws {
    let page = turns("<bash-input> git status</bash-input>")
    try #require(page.count == 1)
    #expect(page[0].text == "!git status")
    #expect(page[0].isCommand)
  }

  /// Claude Code writes `/clear` at the head of the new file when the previous conversation
  /// was cleared, so it was never typed into this session.
  @Test("/clear is still not a turn")
  func clearIsSkipped() {
    #expect(turns("<command-name>/clear</command-name>\n<command-message>clear</command-message>").isEmpty)
  }

  @Test("a command's own output is still not a turn")
  func outputIsStillDropped() {
    #expect(turns("<local-command-stdout>Set model to Opus 5</local-command-stdout>").isEmpty)
    #expect(turns("<bash-stdout>M  file.swift</bash-stdout>").isEmpty)
    #expect(turns("<task-notification>\n<task-id>x</task-id>\n</task-notification>").isEmpty)
  }

  @Test("an envelope with no command in it is not a turn either")
  func envelopeWithoutACommand() {
    #expect(turns("<command-message>summarize</command-message>").isEmpty)
    #expect(turns("<command-args>high --fix</command-args>").isEmpty)
  }

  @Test("prose that merely mentions the tag is an ordinary turn")
  func mentioningTheTag() throws {
    let page = TranscriptParser.page(from: Fixture.human("does <command-name> survive the parse?"))
    try #require(page.turns.count == 1)
    #expect(page.turns[0].isCommand == false)
  }

  @Test("a compacted summary wearing a command envelope is still machine text")
  func compactedCommands() {
    let page = TranscriptParser.page(
      from: Fixture.compactSummary("<command-name>/summarize</command-name>")
    )
    #expect(page.turns.isEmpty)
    #expect(page.records == 1)
  }

  @Test("an ordinary human turn is not flagged as a command")
  func ordinaryTurnsAreNotCommands() {
    let page = TranscriptParser.page(from: Fixture.human("fix the focus bug"))
    #expect(page.turns.first?.isCommand == false)
  }
}

/// A message that carried an image. Text beside an image must not lose the image, and an
/// image alone must still draw something.
struct ImageTurnTests {
  @Test("an image-only message is still something a person sent")
  func imageOnly() throws {
    let page = TranscriptParser.page(from: Fixture.imageMessage())
    try #require(page.turns.count == 1)
    #expect(page.turns[0].isHuman)
    #expect(page.turns[0].attachedImages == 1)
    #expect(page.turns[0].isImageOnly)
    // The placeholder is the view's copy; the parser reports an image and no words.
    #expect(page.turns[0].text == "")
  }

  @Test("text and an image keeps the text and reports the image")
  func textWithAnImage() throws {
    let page = TranscriptParser.page(
      from: Fixture.imageMessage(text: "this is what the strip looks like")
    )
    try #require(page.turns.count == 1)
    #expect(page.turns[0].text == "this is what the strip looks like")
    #expect(page.turns[0].attachedImages == 1)
    #expect(page.turns[0].isImageOnly == false)
  }

  @Test("several images are counted rather than flagged")
  func severalImages() {
    let page = TranscriptParser.page(from: Fixture.imageMessage(text: "before and after", images: 2))
    #expect(page.turns.first?.attachedImages == 2)
  }

  @Test("a turn with no image reports none")
  func noImages() {
    #expect(TranscriptParser.page(from: Fixture.human("hi")).turns.first?.attachedImages == 0)
    #expect(TranscriptParser.page(from: Fixture.human("hi")).turns.first?.isImageOnly == false)
    #expect(TranscriptParser.page(from: Fixture.human("hi")).turns.first?.images.isEmpty == true)
  }
}

/// The image's bytes, carried through the parse. Every test here that yields no
/// `TranscriptImage` also asserts `attachedImages`, the count the chat's placeholder uses.
struct TranscriptImageMappingTests {
  @Test("a base64 payload becomes an inline image with its media type and decoded size")
  func base64BecomesInline() throws {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    let page = TranscriptParser.page(
      from: Fixture.imageMessage(
        text: "look at this",
        sources: [Fixture.base64Source(data: png.base64EncodedString())]
      )
    )
    let turn = try #require(page.turns.first)
    #expect(turn.attachedImages == 1)
    try #require(turn.images.count == 1)
    let image = turn.images[0]
    #expect(image.mediaType == "image/png")
    #expect(image.byteCount == png.count)
    #expect(image.inlineData == png)
    #expect(image.remotePath == nil)
    // From the turn's id, so two reads of one file agree, which `TranscriptImage`'s equality
    // relies on.
    #expect(image.id.hasPrefix(turn.id))
  }

  @Test("two images beside text are both carried, and the turn is not image-only")
  func twoImagesBesideText() throws {
    let page = TranscriptParser.page(
      from: Fixture.imageMessage(
        text: "before and after",
        sources: [Fixture.base64Source(), Fixture.base64Source()]
      )
    )
    let turn = try #require(page.turns.first)
    #expect(turn.attachedImages == 2)
    #expect(turn.images.count == 2)
    #expect(turn.isImageOnly == false)
    // Distinct ids, or the strip draws one thumbnail twice and `ForEach` warns.
    #expect(Set(turn.images.map(\.id)).count == 2)
  }

  @Test("an image-only message still carries its bytes")
  func imageOnlyCarriesBytes() throws {
    let page = TranscriptParser.page(
      from: Fixture.imageMessage(text: nil, sources: [Fixture.base64Source()])
    )
    let turn = try #require(page.turns.first)
    #expect(turn.isImageOnly)
    #expect(turn.images.count == 1)
  }

  @Test("a payload over the encoded cap leaves the count standing on its own")
  func overTheCapDrawsTheLabel() throws {
    // Built inline: `Fixture.base64Source` escapes one scalar at a time, which is slow over
    // eight megabytes.
    let huge = String(repeating: "A", count: TranscriptImage.maxEncodedBytes + 4)
    let page = TranscriptParser.page(
      from: Fixture.imageMessage(
        text: "a frame dump",
        sources: ["{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"\(huge)\"}"]
      )
    )
    let turn = try #require(page.turns.first)
    // The block is still reported, which is why the count is not `images.count`.
    #expect(turn.attachedImages == 1)
    #expect(turn.images.isEmpty)
  }

  @Test("a payload that is not base64 is a missing image, never a failed record")
  func corruptPayloadDoesNotFailTheRecord() throws {
    let page = TranscriptParser.page(
      from: Fixture.imageMessage(
        text: "this should still read",
        sources: [Fixture.base64Source(data: "not base64 at all !!!")]
      )
    )
    // The record parsed, and nothing was counted unreadable.
    #expect(page.unreadableRecords == 0)
    let turn = try #require(page.turns.first)
    #expect(turn.text == "this should still read")
    #expect(turn.attachedImages == 1)
    #expect(turn.images.isEmpty)
  }

  @Test("a source type this build has never heard of yields no image and no crash")
  func unknownSourceType() throws {
    let page = TranscriptParser.page(
      from: Fixture.imageMessage(
        text: "from somewhere new",
        sources: ["{\"type\":\"holo\",\"media_type\":\"image/png\",\"frames\":7}"]
      )
    )
    let turn = try #require(page.turns.first)
    #expect(turn.attachedImages == 1)
    #expect(turn.images.isEmpty)
  }

  @Test("a source that is not an object at all still leaves a readable turn")
  func nonObjectSource() throws {
    let page = TranscriptParser.page(
      from: Fixture.imageMessage(text: "odd shape", sources: ["\"/tmp/a.png\""])
    )
    #expect(page.unreadableRecords == 0)
    let turn = try #require(page.turns.first)
    #expect(turn.text == "odd shape")
    #expect(turn.images.isEmpty)
  }

  @Test("a file source becomes a remote image carrying its path")
  func fileSourceBecomesRemote() throws {
    let page = TranscriptParser.page(
      from: Fixture.imageMessage(
        text: "the screenshot is on the box",
        sources: [Fixture.fileSource(path: "/tmp/a.png")]
      )
    )
    let turn = try #require(page.turns.first)
    try #require(turn.images.count == 1)
    #expect(turn.images[0].remotePath == "/tmp/a.png")
    #expect(turn.images[0].inlineData == nil)
    // Not known until the image is fetched.
    #expect(turn.images[0].byteCount == 0)
  }

  @Test("a file source with no path yields no image and keeps the count")
  func fileSourceWithNoPath() throws {
    let page = TranscriptParser.page(
      from: Fixture.imageMessage(text: "where", sources: ["{\"type\":\"file\"}"])
    )
    let turn = try #require(page.turns.first)
    #expect(turn.attachedImages == 1)
    #expect(turn.images.isEmpty)
  }

  @Test("a record with no media_type says so rather than guessing one")
  func missingMediaType() throws {
    let page = TranscriptParser.page(
      from: Fixture.imageMessage(
        text: "unlabelled",
        sources: [Fixture.base64Source(mediaType: nil)]
      )
    )
    let turn = try #require(page.turns.first)
    try #require(turn.images.count == 1)
    #expect(turn.images[0].mediaType == "")
  }

  /// A byte tail starts mid-record, so a split image block fails `JSONDecoder` and is counted,
  /// never half-parsed. Image payloads are large enough that a page boundary often lands in
  /// one.
  @Test("a truncated image record is one unreadable record and costs nothing after it")
  func aTruncatedImageRecordIsTheOrdinaryTailCase() throws {
    let whole = Fixture.imageMessage(text: "whole", sources: [Fixture.base64Source()], uuid: "im2")
    let cut = String(
      Fixture.imageMessage(text: "cut", sources: [Fixture.base64Source()]).dropFirst(60)
    )
    let page = TranscriptParser.page(from: [cut, whole].joined(separator: "\n"))
    #expect(page.unreadableRecords == 1)
    try #require(page.turns.count == 1)
    #expect(page.turns[0].text == "whole")
    #expect(page.turns[0].images.count == 1)
  }
}

/// Text a person pasted into Claude Code: a `user` record with `origin.kind: "human"`,
/// wrapped in `<pasted_content id="…">` whose closing tag repeats the id. Anything that is
/// not a well-formed pair stays raw.
struct PastedContentTests {
  private func said(_ text: String) -> [String?] {
    TranscriptParser.page(from: Fixture.humanWithOrigin(text)).turns.map(\.text)
  }

  @Test("a message that is one pasted block shows its body")
  func wholeMessage() {
    #expect(
      said("\n\n<pasted_content id=\"6e67\">\nline one\nline two\n</pasted_content id=\"6e67\">\n")
        == ["line one\nline two"])
  }

  @Test("two pasted blocks both lose their wrappers")
  func twoBlocks() {
    #expect(
      said(
        "<pasted_content id=\"a\">\nfirst\n</pasted_content id=\"a\">\n\n"
          + "<pasted_content id=\"b\">\nsecond\n</pasted_content id=\"b\">")
        == ["first\n\nsecond"])
  }

  /// A paste can sit inside a sentence.
  @Test("a pasted block inside a sentence is unwrapped in place")
  func insideASentence() {
    #expect(
      said("look at this <pasted_content id=\"c1\">\nerror: boom\n</pasted_content id=\"c1\"> and fix it")
        == ["look at this error: boom and fix it"])
  }

  @Test("a closing tag with another id leaves the text as typed")
  func mismatchedIDs() {
    let text = "<pasted_content id=\"a\">\nbody\n</pasted_content id=\"b\">"
    #expect(said(text) == [text])
  }

  @Test("an unclosed block leaves the text as typed")
  func unclosed() {
    let text = "before <pasted_content id=\"a\">\nbody with no end"
    #expect(said(text) == [text])
  }

  @Test("a message that only mentions the tag is left alone")
  func bareMention() {
    let text = "why does <pasted_content> show up in the chat?"
    #expect(said(text) == [text])
  }

  @Test("a paste with an empty body draws no bubble")
  func emptyBody() {
    #expect(said("<pasted_content id=\"e\">\n\n</pasted_content id=\"e\">").isEmpty)
  }

  /// A pasted relay starts on the paste's second line, where `opensWithTeammateMessage` allows
  /// the tag, but it is still pasted text.
  @Test("a pasted teammate message stays the person's text")
  func pastedTeammateMessage() throws {
    let page = TranscriptParser.page(
      from: Fixture.humanWithOrigin(
        "\n\n<pasted_content id=\"t\">\n<teammate-message teammate_id=\"main\">\nhi\n"
          + "</teammate-message>\n</pasted_content id=\"t\">\n"))
    try #require(page.turns.count == 1)
    #expect(page.turns[0].isHuman)
    #expect(page.turns[0].text == "<teammate-message teammate_id=\"main\">\nhi\n</teammate-message>")
  }

  @Test("a pasted bash-input stays pasted text and is not a command")
  func pastedBashInput() throws {
    let page = TranscriptParser.page(
      from: Fixture.humanWithOrigin(
        "\n\n<pasted_content id=\"b\">\n<bash-input>ls</bash-input>\n</pasted_content id=\"b\">\n"))
    try #require(page.turns.count == 1)
    #expect(!page.turns[0].isCommand)
    #expect(page.turns[0].text == "<bash-input>ls</bash-input>")
  }

  /// The outer block closes first, so the inner wrapper stays raw in its body.
  @Test("a nested block unwraps the outer one only")
  func nested() {
    #expect(
      said(
        "<pasted_content id=\"a\">x <pasted_content id=\"b\">y</pasted_content id=\"b\"> z"
          + "</pasted_content id=\"a\">")
        == ["x <pasted_content id=\"b\">y</pasted_content id=\"b\"> z"])
  }

  /// Matching each opener by searching the rest of the text is quadratic: 8,000 openers took
  /// 9.5 s, and 30,000 would exceed the limit.
  @Test("many unclosed openers are matched in one pass", .timeLimit(.minutes(1)))
  func manyUnclosedOpeners() {
    let same = String(repeating: "<pasted_content id=\"a\">x ", count: 30_000)
    #expect(TranscriptParser.pastedContent(in: same) == nil)
  }

  @Test("a body padded with no-break spaces is trimmed")
  func noBreakSpace() {
    #expect(
      said("<pasted_content id=\"n\">\u{00A0}\nbody\n\u{00A0}</pasted_content id=\"n\">")
        == ["body"])
  }
}
