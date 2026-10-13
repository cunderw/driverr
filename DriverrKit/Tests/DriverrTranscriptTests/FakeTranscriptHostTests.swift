import DriverrCore
import Foundation
import Testing

@testable import DriverrTranscript

/// The fixture host must survive the real reader. A fake whose JSON did not decode would
/// render no quote, which is also the correct outcome for a pane with no readable
/// transcript, so a UI test could not tell the failure from the feature.
@Suite("FakeTranscriptHost")
struct FakeTranscriptHostTests {
  private let sessionID = "3f8c1d20-0000-4000-8000-000000000002"

  private func pane(session: String?) -> Pane {
    Pane(
      id: "w1:p2",
      tabID: "w1:t1",
      workspaceID: "w1",
      title: "needs a decision",
      agent: Agent(
        name: "Claude",
        kind: "claude",
        status: .blocked,
        session: session.map { AgentSession(agent: "claude", kind: "id", value: $0) }
      ),
      directory: "~/dev/driverr"
    )
  }

  private var host: FakeTranscriptHost {
    FakeTranscriptHost(
      sessionID: sessionID,
      turns: [
        .init(speaker: .human, text: "Two panes claim focus. Fix it.", secondsAgo: 600),
        .init(
          speaker: .assistant,
          text: "Two panes claim focus after a close.\nWhich one should win?",
          secondsAgo: 240
        ),
      ]
    )
  }

  @Test("the reader resolves the fixture's file as the one herdr reported")
  func resolvesTierOne() async throws {
    let reader = TranscriptReader(run: host.run)
    let resolution = try await reader.resolve(for: pane(session: sessionID))
    let source = try #require(resolution.source)
    #expect(source.provenance == .reportedByHerdr(sessionID: sessionID))
    #expect(source.file.name == "\(sessionID).jsonl")
    // The mtime tracks the newest record, so a four-minute-old last turn lists a
    // four-minute-old file. Not `isLive`, whose one-minute window only settles ambiguity.
    #expect(source.file.age == 240)
  }

  /// Every assistant record carries usage, so a UI test cannot pass on a blank count.
  @Test("the fixture's assistant records carry a context count")
  func carriesAContextCount() async throws {
    let reader = TranscriptReader(run: host.run)
    let source = try #require(try await reader.resolve(for: pane(session: sessionID)).source)
    let transcript = try await reader.read(source.file)
    // The assistant turn is index 1: 3 + 1,204 + 41,000.
    #expect(transcript.contextUsage?.totalTokens == 42_207)
    #expect(transcript.contextUsage?.compact == "42k context")
  }

  /// The usage-limit record reads as a live stop, and its all-zero usage does not become the
  /// context count.
  @Test("the fixture's API-error record reads as a live stop")
  func carriesAnAgentStop() async throws {
    let limited = FakeTranscriptHost(
      sessionID: sessionID,
      turns: [
        .init(speaker: .assistant, text: "working", secondsAgo: 600),
        .init(
          speaker: .apiError(
            error: "rate_limit", status: 429, resetsAt: Date().addingTimeInterval(7_200)),
          text: "You've hit your session limit · resets 5:40pm (America/Chicago)",
          secondsAgo: 300
        ),
      ]
    )
    let reader = TranscriptReader(run: limited.run)
    let source = try #require(try await reader.resolve(for: pane(session: sessionID)).source)
    let transcript = try await reader.read(source.file)
    let stop = try #require(transcript.agentStop)
    #expect(stop.kind == .rateLimit)
    #expect(stop.isLive(at: Date()))
    #expect(stop.isLive(at: Date().addingTimeInterval(7_300)) == false)
    // The assistant turn is index 0: 3 + 1,204 + 40,000.
    #expect(transcript.contextUsage?.totalTokens == 41_207)
  }

  @Test("a pane with no reported session still matches the fixture by its directory")
  func resolvesTierTwo() async throws {
    let reader = TranscriptReader(run: host.run)
    let resolution = try await reader.resolve(for: pane(session: nil))
    let source = try #require(resolution.source)
    #expect(source.provenance == .matchedByDirectory)
  }

  /// `look.sh` captures the answered state from this, so a dropped reply record would capture
  /// nothing.
  @Test("an answered question's reply record parses back with its answers")
  func anAnsweredQuestionParsesBack() async throws {
    let asked = [
      PendingQuestion(
        question: "Which branch?", options: ["main", "release"], header: "Branch",
        optionDescriptions: ["As it stands.", nil], answer: "release"),
      PendingQuestion(
        question: "Who reviews it?", options: ["Ann", "Bo"], allowsMultiple: true,
        answer: "Ann, Bo"),
    ]
    let answered = FakeTranscriptHost(
      sessionID: sessionID,
      turns: [
        .init(speaker: .human, text: "get the release branch ready", secondsAgo: 90),
        .init(
          speaker: .tools([ToolCall(name: "AskUserQuestion", outcome: .succeeded, questions: asked)]),
          secondsAgo: 10
        ),
      ]
    )
    let reader = TranscriptReader(run: answered.run)
    let source = try #require(try await reader.resolve(for: pane(session: sessionID)).source)
    let transcript = try await reader.read(source.file)

    let run = try #require(transcript.turns.last?.toolRun)
    #expect(run.calls.last?.outcome == .succeeded)
    #expect(run.calls.last?.questions.map(\.answer) == ["release", "Ann, Bo"])
    #expect(run.calls.last?.questions.map(\.header) == ["Branch", "Choice"])
    #expect(run.calls.last?.questions.first?.optionDescriptions == ["As it stands.", nil])
    #expect(run.answeredQuestions.map(\.answer) == ["release", "Ann, Bo"])
    #expect(transcript.pendingToolCall == nil)
  }

  @Test("and the records it writes parse back into the turns it was given")
  func parsesBack() async throws {
    let reader = TranscriptReader(run: host.run)
    let source = try #require(try await reader.resolve(for: pane(session: sessionID)).source)
    let transcript = try await reader.read(source.file)

    #expect(transcript.outcome == .parsed)
    #expect(transcript.turns.count == 2)
    #expect(transcript.lastHumanMessage == "Two panes claim focus. Fix it.")
    #expect(
      transcript.lastAssistantMessage
        == "Two panes claim focus after a close.\nWhich one should win?"
    )
    #expect(transcript.window.unreadableRecords == 0)
  }

  /// The fake writes the `system` duration record and the real parser must put its value on
  /// the right turn with no row of its own. The `awk` clause admitting it is
  /// `RecordSelectorTests`'s.
  @Test("a fixture turn's elapsed time reaches the page on that turn and makes no row")
  func durationParsesBack() async throws {
    let fixture = FakeTranscriptHost(
      sessionID: sessionID,
      turns: [
        .init(speaker: .human, text: "go", secondsAgo: 600),
        .init(speaker: .assistant, text: "done", secondsAgo: 240, durationMs: 590_000),
      ]
    )
    let reader = TranscriptReader(run: fixture.run)
    let source = try #require(try await reader.resolve(for: pane(session: sessionID)).source)
    let transcript = try await reader.read(source.file)

    #expect(transcript.outcome == .parsed)
    #expect(transcript.turns.count == 2)
    #expect(transcript.window.unreadableRecords == 0)
    #expect(transcript.turns.map(\.durationMs) == [nil, 590_000])
    #expect(transcript.turns.last?.durationLabel == "Crunched for 9m 50s")
  }

  /// A fixture pinned to a wall-clock date would read "written 4m ago" today and "written
  /// 223d ago" months later, unnoticed in a screenshot tour.
  @Test("an age is measured off the fixture's own timestamps, and moves with the clock")
  func agesAreRelative() async throws {
    let reader = TranscriptReader(run: host.run)
    let source = try #require(try await reader.resolve(for: pane(session: sessionID)).source)

    // The youngest record is 240 s old. The window bounds the test's own scheduling.
    let age = try #require(source.file.age)
    #expect(age > 235 && age < 265)
    #expect(TranscriptAge.phrase(for: age) == "written 4m ago")
  }

  @Test("a pane whose reported session is not the fixture's is reported, not substituted")
  func reportedSessionMissing() async throws {
    // Taking the directory's newest file when the named one is absent would draw another
    // agent's conversation.
    let reader = TranscriptReader(run: host.run)
    let resolution = try await reader.resolve(for: pane(session: "some-other-session"))
    #expect(resolution.source == nil)
    guard case .absent(.reportedSessionMissing) = resolution else {
      Issue.record("Expected the reported session to be named as missing, got \(resolution)")
      return
    }
  }

  /// A fixture handing the view a `ToolRun` directly would prove a value no host produces.
  @Test("a run of tool calls comes back through the parser as one turn")
  func toolRunsSurviveTheParser() async throws {
    let host = FakeTranscriptHost(
      sessionID: sessionID,
      turns: [
        .init(speaker: .human, text: "look at the strip", secondsAgo: 600),
        .init(
          speaker: .tools(
            [
              ToolCall(name: "Read", target: "PaneStripView.swift"),
              ToolCall(name: "Read", target: "PaneStripModel.swift"),
              ToolCall(name: "Grep", target: "focus"),
            ]
          ),
          secondsAgo: 300
        ),
        .init(speaker: .assistant, text: "herdr's focus wins.", secondsAgo: 240),
      ]
    )
    let reader = TranscriptReader(run: host.run)
    let resolution = try await reader.resolve(for: pane(session: sessionID))
    let source = try #require(resolution.source)

    let transcript = try await reader.read(source.file)

    #expect(transcript.turns.count == 3)
    let run = try #require(transcript.turns[1].toolRun)
    #expect(run.count == 3)
    #expect(run.kinds.map(\.name) == ["Read", "Grep"])
    // The target survives through `tool_use.input`, so an opened run has something to show.
    #expect(run.calls.first?.target == "PaneStripView.swift")
    // Every call is answered, as in a real file except for the one call being waited on.
    #expect(run.calls.allSatisfy { $0.outcome == .succeeded })
    #expect(run.failedCount == 0)
  }

  /// A permission prompt writes nothing until answered, so this is the only fixture shape
  /// that produces a pending call.
  @Test("a call the fixture leaves pending comes back as the pane's pending call")
  func pendingCallSurvivesTheParser() async throws {
    let host = FakeTranscriptHost(
      sessionID: sessionID,
      turns: [
        .init(speaker: .command, text: "/run-tests", secondsAgo: 900),
        .init(speaker: .human, text: "run the tests", secondsAgo: 600),
        .init(speaker: .assistant, text: "Running them now.", secondsAgo: 420),
        .init(
          speaker: .tools([
            ToolCall(name: "Read", target: "Cargo.toml"),
            ToolCall(name: "Edit", target: "pool.rs", outcome: .failed),
            ToolCall(name: "Bash", target: "cargo test", outcome: .pending),
          ]),
          secondsAgo: 120
        ),
      ]
    )
    let reader = TranscriptReader(run: host.run)
    let source = try #require(try await reader.resolve(for: pane(session: sessionID)).source)
    let transcript = try await reader.read(source.file)

    let pending = try #require(transcript.pendingToolCall)
    #expect(pending.name == "Bash")
    #expect(pending.target == "cargo test")
    // The failed call in the run is counted and the one before it is not.
    #expect(transcript.turns.last?.toolRun?.failedCount == 1)
  }

  /// The Codex counterpart. `.pending` needs the host's `!` mark, which says the outcomes
  /// were scanned, and an `exec_command` call with no completion at the end of the page.
  @Test("a Codex call the fixture leaves pending comes back as the pane's pending call")
  func codexPendingCallSurvivesTheParser() async throws {
    let rollout = FakeTranscriptHost.CodexSession(
      id: "01a00000-1111-7222-8333-444455556666",
      cwd: "/Users/x/Dev/tower",
      turns: [
        .init(speaker: .human, text: "sync the schema", secondsAgo: 300),
        .init(
          speaker: .tools([
            ToolCall(name: "exec", target: "ls migrations"),
            ToolCall(name: "exec", target: "psql -c \"select 1\"", outcome: .succeeded),
            ToolCall(name: "exec", target: "psql -f bad.sql", outcome: .failed),
            ToolCall(name: "exec", target: "psql -f schema.sql", outcome: .pending),
          ]),
          secondsAgo: 240
        ),
      ]
    )
    let served = FakeTranscriptHost(sessionID: sessionID, turns: [], codexSessions: [rollout])
    let codexPane = Pane(
      id: "w2:p1",
      tabID: "w2:t1",
      workspaceID: "w2",
      title: "schema sync",
      agent: Agent(name: "Codex", kind: "codex", status: .working, session: nil),
      directory: rollout.cwd
    )
    let reader = TranscriptReader(run: served.run)
    let source = try #require(try await reader.resolve(for: codexPane).source)
    let transcript = try await reader.read(source.file)

    let run = try #require(transcript.turns.last?.toolRun)
    #expect(run.calls.map(\.outcome) == [.unknown, .succeeded, .failed, .pending])
    let pending = try #require(transcript.pendingToolCall)
    #expect(pending.target?.contains("psql -f schema.sql") == true)
  }

  /// If the states did not survive the reader, a capture of the chat fixture would show no
  /// task state.
  @Test("spawned work comes back in the state the fixture wrote for it")
  func taskStatesSurviveTheReader() async throws {
    let host = FakeTranscriptHost(
      sessionID: sessionID,
      turns: [
        .init(
          speaker: .toolBlocks([
            .spawn(
              subagentType: "analyst", name: "p-1", description: "Plan it",
              launch: .async(agentID: "a1", end: .init(secondsAgo: 300))),
            .spawn(
              subagentType: "finder", name: "s-1", description: "Survey it",
              launch: .async(agentID: "a2", end: .init(secondsAgo: 400, isHandback: true))),
            .spawn(
              subagentType: "engineer", name: "e-1", description: "Build it", launch: .teammate),
            .spawn(
              subagentType: "guide", name: "g-1", description: "Look it up",
              launch: .async(agentID: "a3")),
            .spawn(
              subagentType: "fixer", name: "f-1", description: "Fix it",
              launch: .sync(durationMs: 9406)),
          ]),
          secondsAgo: 600
        ),
        .init(
          speaker: .toolBlocks([
            .background(command: "make", description: "Build", end: .init(status: "killed", secondsAgo: 100)),
            .background(command: "make test", description: "Test"),
          ]),
          secondsAgo: 200
        ),
      ]
    )
    let reader = TranscriptReader(run: host.run)
    let source = try #require(try await reader.resolve(for: pane(session: sessionID)).source)
    let transcript = try await reader.read(source.file)

    let spawns = transcript.turns.compactMap(\.agentEvent).map(\.task?.state)
    #expect(spawns == [.finished, .finished, .running, .running, .finished])
    let finished = try #require(transcript.turns.first?.agentEvent?.task)
    #expect(finished.elapsed(asOf: .now).map { $0.rounded() } == 300)
    let background = transcript.turns.last?.toolRun?.calls.map(\.task?.state)
    #expect(background == [.stopped, .running])
  }

  /// Written as the client's own envelope, so it goes through the real unwrapping.
  @Test("a command turn comes back as what the person typed")
  func commandTurnsSurviveTheParser() async throws {
    let host = FakeTranscriptHost(
      sessionID: sessionID,
      turns: [
        .init(speaker: .command, text: "/run-tests", secondsAgo: 900),
        .init(speaker: .command, text: "!git status", secondsAgo: 700),
        .init(speaker: .assistant, text: "The suite passed.", secondsAgo: 600),
      ]
    )
    let reader = TranscriptReader(run: host.run)
    let source = try #require(try await reader.resolve(for: pane(session: sessionID)).source)
    let transcript = try await reader.read(source.file)

    #expect(transcript.turns.map(\.text) == ["/run-tests", "!git status", "The suite passed."])
    #expect(transcript.turns.map(\.isCommand) == [true, true, false])
    // The picker keys on the same record: a session opened with a command was briefed by it.
    let briefs = try await reader.briefs(in: host.directory, for: [source.file])
    #expect(briefs[source.file.name] == "/run-tests")
  }

  @Test("an image travelling with a message reaches the page as an attachment")
  func imagesSurviveTheParser() async throws {
    let host = FakeTranscriptHost(
      sessionID: sessionID,
      turns: [
        .init(speaker: .human, text: "look at this", secondsAgo: 600, attachedImages: 1),
        .init(speaker: .human, secondsAgo: 500, attachedImages: 2),
      ]
    )
    let reader = TranscriptReader(run: host.run)
    let source = try #require(try await reader.resolve(for: pane(session: sessionID)).source)
    let transcript = try await reader.read(source.file)

    #expect(transcript.turns.map(\.attachedImages) == [1, 2])
    #expect(transcript.turns.map(\.isImageOnly) == [false, true])
    // No payload was asked for, so the chat draws the count label.
    #expect(transcript.turns.allSatisfy { $0.images.isEmpty })
  }

  /// An undecodable payload draws the same `1 image` label an absent one does, so without
  /// real bytes every strip check would pass with no image decoding.
  @Test("a fixture payload reaches the page as bytes a decoder accepts")
  func imagePayloadsSurviveTheParser() async throws {
    let host = FakeTranscriptHost(
      sessionID: sessionID,
      turns: [
        .init(
          speaker: .human,
          text: "here is the screen",
          secondsAgo: 600,
          attachedImages: 2,
          // One payload for two blocks: the first draws, the second falls back to the label.
          imagePayloads: [FakeTranscriptHost.tinyPNG]
        )
      ]
    )
    let reader = TranscriptReader(run: host.run)
    let source = try #require(try await reader.resolve(for: pane(session: sessionID)).source)
    let transcript = try await reader.read(source.file)

    let turn = try #require(transcript.turns.first)
    #expect(turn.attachedImages == 2)
    try #require(turn.images.count == 1)
    #expect(turn.images[0].mediaType == "image/png")
    let bytes = try #require(turn.images[0].inlineData)
    #expect(bytes.count == 2986)
    // A real PNG signature, not merely valid base64.
    #expect(Array(bytes.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
  }

  /// `PaneTranscriptModel` compares a probe with the listing's size for the page on screen.
  /// If they were derived differently, every tick would fetch a page forever while every
  /// "new turn arrived" test still passed.
  @Test("a probe answers the same size the listing reported")
  func probeAgreesWithTheListing() async throws {
    let reader = TranscriptReader(run: host.run)
    let source = try #require(try await reader.resolve(for: pane(session: sessionID)).source)

    let stamp = try #require(try await reader.probe(source.file))

    #expect(stamp.sizeInBytes == source.file.sizeInBytes)
  }

  @Test("a turn appended to the fixture moves the probe")
  func growthMovesTheProbe() async throws {
    let before = host
    let after = FakeTranscriptHost(
      sessionID: sessionID,
      turns: before.sessions[0].turns + [
        .init(speaker: .assistant, text: "The left one wins.", secondsAgo: 1)
      ]
    )
    let file = try #require(
      try await TranscriptReader(run: before.run).resolve(for: pane(session: sessionID)).source
    ).file

    let first = try #require(try await TranscriptReader(run: before.run).probe(file))
    let second = try #require(try await TranscriptReader(run: after.run).probe(file))

    #expect(second.sizeInBytes > first.sizeInBytes)
  }

  // MARK: - A sub-agent's own file

  private var subagentDirectory: String { "\(host.directory)/subagents" }

  @Test("a spawn's tool-use id links to its own sub-agent file")
  func linksByToolUseID() async throws {
    let served = host.serving([
      FakeTranscriptHost.SubagentFixture(
        agentID: "a0000000000000004",
        toolUseID: "toolu_01ZyXwVuTsRqPoNmLkJiHgFe",
        prompt: "Implement the retry fix end to end, on your own branch."
      )
    ])
    let reader = TranscriptReader(run: served.run)

    let file = try await reader.subagentFile(
      toolUseID: "toolu_01ZyXwVuTsRqPoNmLkJiHgFe",
      directory: host.directory,
      sessionID: sessionID
    )

    #expect(file?.name == "agent-a0000000000000004.jsonl")
    #expect(file?.isSubagentFile == true)
  }

  /// A teammate's meta has only `name`, and a respawn under the same name leaves several
  /// files; the newest wins, an accepted risk.
  @Test("a teammate with no tool-use id links by name, and the newest file wins")
  func linksTeammateByNameNewestWins() async throws {
    let served = host.serving([
      FakeTranscriptHost.SubagentFixture(
        agentID: "aver-7-old",
        name: "ver-7",
        isTeammate: true,
        secondsAgo: 3600,
        prompt: "Review the retry fix."
      ),
      FakeTranscriptHost.SubagentFixture(
        agentID: "aver-7-new",
        name: "ver-7",
        isTeammate: true,
        secondsAgo: 60,
        prompt: "Review the retry fix, second pass after the respawn."
      ),
    ])
    let reader = TranscriptReader(run: served.run)

    let file = try await reader.subagentFile(
      teammateName: "ver-7", directory: host.directory, sessionID: sessionID
    )

    #expect(file?.name == "agent-aver-7-new.jsonl")
  }

  @Test("a link nothing in the directory answers comes back not found, not a crash")
  func unresolvedLinkIsNotFound() async throws {
    let served = host.serving([
      FakeTranscriptHost.SubagentFixture(
        agentID: "a1", toolUseID: "toolu_present", prompt: "Do the thing."
      )
    ])
    let reader = TranscriptReader(run: served.run)

    let byToolUseID = try await reader.subagentFile(
      toolUseID: "toolu_absent", directory: host.directory, sessionID: sessionID
    )
    let byName = try await reader.subagentFile(
      teammateName: "nobody-spawned-this", directory: host.directory, sessionID: sessionID
    )
    let withNeither = try await reader.subagentFile(
      directory: host.directory, sessionID: sessionID
    )

    #expect(byToolUseID == nil)
    #expect(byName == nil)
    #expect(withNeither == nil)
  }

  /// Every record in a sub-agent's file has `isSidechain:true`, which a pane's read drops,
  /// and the one with no `origin` is the parent's prompt.
  @Test("reading a sub-agent's file keeps its records and labels the opening prompt")
  func readsTheSubagentFileKeepingSidechain() async throws {
    let served = host.serving([
      FakeTranscriptHost.SubagentFixture(
        agentID: "a0000000000000004",
        toolUseID: "toolu_01ZyXwVuTsRqPoNmLkJiHgFe",
        prompt: "Implement the retry fix end to end, on your own branch.",
        turns: [
          .init(
            speaker: .assistant, text: "Made the branch and started on the fix.", secondsAgo: 30
          )
        ]
      )
    ])
    let reader = TranscriptReader(run: served.run)
    let file = try #require(
      try await reader.subagentFile(
        toolUseID: "toolu_01ZyXwVuTsRqPoNmLkJiHgFe", directory: host.directory,
        sessionID: sessionID
      )
    )

    let transcript = try await reader.read(file)

    #expect(transcript.turns.count == 2)
    let prompt = try #require(transcript.turns.first)
    #expect(prompt.isParentPrompt)
    #expect(prompt.text == "Implement the retry fix end to end, on your own branch.")
    #expect(transcript.turns.last?.text == "Made the branch and started on the fix.")
  }

  /// A teammate's further message carries an `origin` and names a parent. It comes from
  /// `FakeTranscriptHost.subagentRecord`'s `.human` case, which writes both.
  @Test("a later human turn in a sub-agent's file is not the parent's prompt")
  func laterHumanTurnIsNotFlaggedEither() async throws {
    let served = host.serving([
      FakeTranscriptHost.SubagentFixture(
        agentID: "aver-7",
        name: "ver-7",
        isTeammate: true,
        prompt: "Review the retry fix.",
        turns: [.init(speaker: .human, text: "Also check the migration.", secondsAgo: 30)]
      )
    ])
    let reader = TranscriptReader(run: served.run)
    let file = try #require(
      try await reader.subagentFile(teammateName: "ver-7", directory: host.directory, sessionID: sessionID)
    )

    let transcript = try await reader.read(file)

    #expect(transcript.turns.count == 2)
    #expect(transcript.turns.first?.isParentPrompt == true)
    #expect(transcript.turns.last?.isParentPrompt == false)
    #expect(transcript.turns.last?.text == "Also check the migration.")
  }

  /// Read without `forSubagentFile`, every record is dropped, which proves the flag does the
  /// work.
  @Test("the same file read without the sub-agent flag keeps nothing")
  func readingWithoutTheFlagDropsSidechainRecords() async throws {
    let served = host.serving([
      FakeTranscriptHost.SubagentFixture(
        agentID: "a0000000000000004",
        toolUseID: "toolu_01ZyXwVuTsRqPoNmLkJiHgFe",
        prompt: "Implement the retry fix end to end, on your own branch."
      )
    ])
    let reader = TranscriptReader(run: served.run)
    let linked = try #require(
      try await reader.subagentFile(
        toolUseID: "toolu_01ZyXwVuTsRqPoNmLkJiHgFe", directory: host.directory,
        sessionID: sessionID
      )
    )
    let asAPane = TranscriptFile(
      path: linked.path, sizeInBytes: linked.sizeInBytes, age: linked.age
    )

    let transcript = try await reader.read(asAPane)

    #expect(transcript.turns.isEmpty)
  }

  /// Bounded by the same growth ladder as a pane's own file (see `TranscriptReaderTests`).
  @Test("a sub-agent file's read is bounded by the reader's own growth ladder")
  func subagentReadIsBounded() async throws {
    let served = host.serving([
      FakeTranscriptHost.SubagentFixture(
        agentID: "abig",
        toolUseID: "toolu_big",
        prompt: "A sub-agent working a very long task.",
        turns: (0..<20).map { .init(speaker: .assistant, text: "Step \($0).", secondsAgo: TimeInterval(20 - $0)) },
        fileSizeInBytes: 300_000_000
      )
    ])
    let reader = TranscriptReader(run: served.run)
    let file = try #require(
      try await reader.subagentFile(
        toolUseID: "toolu_big", directory: host.directory, sessionID: sessionID
      )
    )

    // More turns than the fixture holds, so every rung is climbed without reaching the front
    // of a 300 MB file.
    let transcript = try await reader.read(file, turns: 50)

    #expect(transcript.window.stoppedShort)
  }
}
