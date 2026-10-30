import Foundation
import Testing

@testable import DriverrCore

/// Every word the pane screen shows about a transcript. Each sentence is a pure function
/// of a value, so it is asserted here rather than in a UI test.
@Suite("Transcript presentation")
struct TranscriptPresentationTests {
  private func file(
    _ name: String = "3f8c1d20-0000-4000-8000-000000000002.jsonl",
    age: TimeInterval? = 12,
    size: Int = 541_536
  ) -> TranscriptFile {
    TranscriptFile(path: "/Users/x/.claude/projects/-x-driverr/\(name)", sizeInBytes: size, age: age)
  }

  // MARK: - The provenance header

  @Test("the exact variant credits herdr and shows the session id")
  func exactVariantNamesHerdr() {
    let header = TranscriptHeader(
      agentName: "Claude",
      source: TranscriptSource(
        file: file(),
        provenance: .reportedByHerdr(sessionID: "3f8c1d20-0000-4000-8000-000000000002"),
        directory: "/Users/x/Dev/driverr"
      )
    )
    #expect(header.caption == "Claude session · reported by herdr · written 12s ago")
    #expect(header.detail == "3f8c1d20-0000-4000-8000-000000000002")
    #expect(header.isExact)
  }

  /// Claude Code named the successor itself, so the answer is as exact as herdr's and the
  /// wording does not change.
  @Test("a continued session reads exactly like the session herdr reported")
  func continuedVariantSaysTheSameThing() {
    let continued = TranscriptHeader(
      agentName: "Claude",
      source: TranscriptSource(
        file: file("3f8c1d20-0000-4000-8000-000000000003.jsonl"),
        provenance: .continuedFromHerdrSession(
          reportedID: "3f8c1d20-0000-4000-8000-000000000002",
          sessionID: "3f8c1d20-0000-4000-8000-000000000003"
        ),
        directory: "/Users/x/Dev/driverr"
      )
    )
    #expect(continued.caption == "Claude session · reported by herdr · written 12s ago")
    #expect(continued.isExact)
    // The session on screen, not the one herdr named, so the row holds one file's evidence.
    #expect(continued.detail == "3f8c1d20-0000-4000-8000-000000000003")
  }

  /// Tier 2 is a guess, so it names its evidence instead of claiming a match.
  @Test("the matched variant names the directory and the file's age")
  func matchedVariantNamesItsEvidence() {
    let header = TranscriptHeader(
      agentName: "Claude",
      source: TranscriptSource(
        file: file(age: 12),
        provenance: .matchedByDirectory,
        directory: "/Users/x/Dev/projects/driverr-wt-terminal"
      )
    )
    #expect(header.caption == "Claude session · matched by directory · written 12s ago")
    #expect(header.detail == "/Users/x/Dev/projects/driverr-wt-terminal")
    #expect(!header.isExact)
  }

  @Test("a matched file with no readable age states the directory alone")
  func matchedVariantWithoutAnAge() {
    let header = TranscriptHeader(
      agentName: "Claude",
      source: TranscriptSource(
        file: file(age: nil),
        provenance: .matchedByDirectory,
        directory: "/Users/x/Dev/driverr"
      )
    )
    #expect(header.caption == "Claude session · matched by directory")
    #expect(header.detail == "/Users/x/Dev/driverr")
  }

  /// A picked session must not present itself as a tier-2 match.
  @Test("the picked variant credits the choice and names the file")
  func pickedVariantCreditsTheChoice() {
    let header = TranscriptHeader(
      agentName: "Claude",
      source: TranscriptSource(
        file: file("a1b2c3d4-0000-4000-8000-00000000000a.jsonl"),
        provenance: .chosenByHand,
        directory: "/Users/x/Dev/driverr"
      )
    )
    #expect(header.caption == "Claude session · you picked this file · written 12s ago")
    #expect(header.detail == "a1b2c3d4-0000-4000-8000-00000000000a.jsonl")
    #expect(!header.isExact)
  }

  @Test("the header speaks the agent's own name")
  func headerSpeaksTheAgentsName() {
    let header = TranscriptHeader(
      agentName: "Codex",
      source: TranscriptSource(
        file: file(),
        provenance: .matchedByDirectory,
        directory: "/Users/x/Dev/driverr"
      )
    )
    #expect(header.caption == "Codex session · matched by directory · written 12s ago")
  }

  /// The caption's scope phrase, and the cap on it in `theScopeLeavesRoomForTheAge` holds for
  /// these too. `ProvenanceCaptionLayoutTests` measures the new one.
  private func header(_ provenance: TranscriptProvenance, session: AgentSession?) -> String {
    TranscriptHeader(
      agentName: "Claude",
      source: TranscriptSource(
        file: file(age: 12), provenance: provenance, directory: "/Users/x/Dev/driverr"),
      session: session,
      asOf: Date(timeIntervalSince1970: 1_000)
    ).caption.components(separatedBy: " \u{00B7} ")[1]
  }

  /// That caption exists to name the evidence, and on a core herdr gave none.
  @Test(
    "a session read from Claude's record says so, however it got here",
    arguments: [
      TranscriptProvenance.reportedByHerdr(sessionID: "s"),
      .continuedFromHerdrSession(reportedID: "s", sessionID: "t"),
    ])
  func captionNamesClaudesRecord(provenance: TranscriptProvenance) {
    let record = AgentSession(
      agent: "claude", kind: "id", value: "s", source: AgentSession.claudeRecordSource)
    #expect(header(provenance, session: record) == "from Claude's record")
  }

  @Test(
    "a session herdr reported still credits herdr",
    arguments: [
      AgentSession?.none,
      AgentSession(agent: "claude", kind: "id", value: "s"),
      AgentSession(agent: "claude", kind: "id", value: "s", source: "herdr:claude"),
    ])
  func captionKeepsCreditingHerdr(session: AgentSession?) {
    #expect(header(.reportedByHerdr(sessionID: "s"), session: session) == "reported by herdr")
  }

  /// The pane's session is passed for every page, and only a reported page is about it.
  @Test(
    "the record is named only where the session is the evidence",
    arguments: [
      (TranscriptProvenance.matchedByDirectory, "matched by directory"),
      (.chosenByHand, "you picked this file"),
      (.subagent, "sub-agent"),
    ])
  func captionOtherwiseUnchanged(provenance: TranscriptProvenance, scope: String) {
    let record = AgentSession(
      agent: "claude", kind: "id", value: "s", source: AgentSession.claudeRecordSource)
    #expect(header(provenance, session: record) == scope)
  }

  /// `ProvenanceRow` truncates in the middle, so the age stays last and the scope phrase is
  /// held to the longest one that fits. At 12 pt the caption has 341 pt on a 402 pt phone,
  /// measured by `ProvenanceCaptionLayoutTests`. "matched by this pane's directory" ran the
  /// caption 40.7 pt over and pushed the age out.
  @Test("the age is the caption's last segment, and the scope leaves room for it")
  func theScopeLeavesRoomForTheAge() {
    let variants: [(TranscriptProvenance, String)] = [
      (.reportedByHerdr(sessionID: "3f8c1d20-0000-4000-8000-000000000002"), "reported by herdr"),
      (
        .continuedFromHerdrSession(
          reportedID: "3f8c1d20-0000-4000-8000-000000000002",
          sessionID: "3f8c1d20-0000-4000-8000-000000000003"
        ), "reported by herdr"
      ),
      (.matchedByDirectory, "matched by directory"),
      (.chosenByHand, "you picked this file"),
    ]
    for (provenance, scope) in variants {
      let header = TranscriptHeader(
        agentName: "Claude",
        source: TranscriptSource(
          file: file(age: 0),
          provenance: provenance,
          directory: "/Users/x/Dev/driverr"
        )
      )
      let segments = header.caption.components(separatedBy: " \u{00B7} ")

      #expect(
        segments.count == 3,
        """
        \(provenance) captions as \(segments.count) segments, not three. The row truncates in \
        the middle so that the agent's name leads and the age trails; a caption of some other \
        shape has no guarantee about which part survives.
        """
      )
      #expect(
        segments.last == "written just now",
        """
        \(provenance) puts "\(segments.last ?? "")" last, not the age. Middle truncation only \
        protects the ends, so an age anywhere else is the segment that gets \
        clipped.
        """
      )
      #expect(
        segments.dropFirst().first == scope,
        """
        \(provenance) scopes as "\(segments.dropFirst().first ?? "")", expected "\(scope)".
        """
      )
      #expect(
        scope.count <= 20,
        """
        The scope phrase "\(scope)" is \(scope.count) characters, past the 20 the longest \
        phrase in this table runs to. The cap is a prompt, not a width: a character count \
        cannot stand in for one in a proportional font, and the two 20-character scopes here \
        measure 105.8 pt and 120.7 pt. Measure the new phrase against the 341 pt the row has \
        at 402 pt — `ProvenanceCaptionLayoutTests` is what reads that budget back — and move \
        this cap to whatever the longest one that still fits comes to.
        """
      )
    }
  }

  @Test("the header is spoken as one sentence")
  func headerIsSpokenAsOneSentence() {
    let header = TranscriptHeader(
      agentName: "Claude",
      source: TranscriptSource(
        file: file(age: 90),
        provenance: .matchedByDirectory,
        directory: "/Users/x/Dev/driverr"
      )
    )
    #expect(
      header.accessibilityLabel
        == "Claude session · matched by directory · written 1m ago. /Users/x/Dev/driverr"
    )
  }

  // MARK: - The header's age advances

  /// The age is the only freshness evidence a tier-2 header has, so a value frozen at fetch
  /// time vouches for a session that may have ended.
  @Test("the header's age advances with the clock rather than staying at the fetch")
  func headerAgeAdvances() {
    let readAt = Date(timeIntervalSince1970: 1_800_000_000)
    let source = TranscriptSource(
      file: file(age: 12),
      provenance: .matchedByDirectory,
      directory: "/Users/x/Dev/driverr",
      readAt: readAt
    )

    #expect(TranscriptHeader(agentName: "Claude", source: source, asOf: readAt).age == 12)
    #expect(
      TranscriptHeader(agentName: "Claude", source: source, asOf: readAt.addingTimeInterval(288))
        .caption == "Claude session · matched by directory · written 5m ago"
    )
  }

  /// The phone supplies only elapsed time since the read, so a device clock that is off
  /// from the host's cannot make a live session look stale.
  @Test("the file's modified date is the host's age carried back from the read")
  func modifiedDateComesOffTheHostsClock() {
    let readAt = Date(timeIntervalSince1970: 1_800_000_000)
    let source = TranscriptSource(
      file: file(age: 90),
      provenance: .matchedByDirectory,
      directory: "/Users/x/Dev/driverr",
      readAt: readAt
    )

    #expect(source.modifiedAt == readAt.addingTimeInterval(-90))
  }

  @Test("a file with no readable age has no modified date and no age at any time")
  func noAgeStaysNoAge() {
    let source = TranscriptSource(
      file: file(age: nil),
      provenance: .matchedByDirectory,
      directory: "/Users/x/Dev/driverr",
      readAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    #expect(source.modifiedAt == nil)
    #expect(TranscriptHeader(agentName: "Claude", source: source, asOf: .now).age == nil)
    #expect(
      TranscriptHeader(agentName: "Claude", source: source, asOf: .now).caption
        == "Claude session · matched by directory"
    )
  }

  /// A phone that resynced its clock mid-session.
  @Test("a clock that went backwards reads as just now, never as the future")
  func ageNeverGoesNegative() {
    let readAt = Date(timeIntervalSince1970: 1_800_000_000)
    let source = TranscriptSource(
      file: file(age: 5),
      provenance: .matchedByDirectory,
      directory: "/Users/x/Dev/driverr",
      readAt: readAt
    )

    let header = TranscriptHeader(
      agentName: "Claude", source: source, asOf: readAt.addingTimeInterval(-600))
    #expect(header.age == 0)
    #expect(header.caption == "Claude session · matched by directory · written just now")
  }

  // MARK: - How old a file is

  @Test(
    "an age reads in the largest unit that fits",
    arguments: [
      (TimeInterval(0), "written just now"),
      (TimeInterval(12), "written 12s ago"),
      (TimeInterval(59), "written 59s ago"),
      (TimeInterval(60), "written 1m ago"),
      (TimeInterval(3599), "written 59m ago"),
      (TimeInterval(3600), "written 1h ago"),
      (TimeInterval(86_399), "written 23h ago"),
      (TimeInterval(86_400), "written 1d ago"),
      (TimeInterval(604_800), "written 7d ago"),
    ]
  )
  func ageReadsInTheLargestUnitThatFits(age: TimeInterval, expected: String) {
    #expect(TranscriptAge.phrase(for: age) == expected)
  }

  // MARK: - The two chat failures

  @Test("a file that ends mid-record names how many turns survived and their size")
  func endsMidRecordNamesTheSurvivors() {
    let notice = TranscriptNotice(
      outcome: .endsMidRecord, turnCount: 2, bytesFetched: 61_440, agentStatus: nil
    )
    #expect(notice?.title == nil)
    #expect(
      notice?.message
        == "The file ends mid-record. 2 turns · 60.0 KB parsed. Anything after that is "
        + "unreadable."
    )
    #expect(notice?.offersFilePicker == false)
  }

  @Test("one surviving turn is singular")
  func endsMidRecordIsSingularForOne() {
    #expect(
      TranscriptNotice(
        outcome: .endsMidRecord, turnCount: 1, bytesFetched: 512, agentStatus: nil
      )?.message
        == "The file ends mid-record. 1 turn · 512 B parsed. Anything after that is "
        + "unreadable."
    )
  }

  /// A file that stops mid-record is what a session being written looks like.
  @Test("mid-record reads as in progress when the agent is working")
  func endsMidRecordReadsAsInProgressWhenWorking() {
    let notice = TranscriptNotice(
      outcome: .endsMidRecord, turnCount: 2, bytesFetched: 61_440, agentStatus: .working
    )
    #expect(notice?.message == "The agent is still writing. 2 turns · 60.0 KB so far.")
    #expect(notice?.message.contains("ends mid-record") == false)
  }

  @Test(
    "every status but working keeps the fault wording",
    arguments: [AgentStatus?.none, .idle, .done, .blocked, .unknown])
  func endsMidRecordKeepsFaultWordingOtherwise(status: AgentStatus?) {
    let notice = TranscriptNotice(
      outcome: .endsMidRecord, turnCount: 2, bytesFetched: 61_440, agentStatus: status
    )
    #expect(notice?.message.contains("ends mid-record") == true)
  }

  @Test("a file that parses to nothing says so and guesses why")
  func noReadableTurnsSaysWhy() {
    let notice = TranscriptNotice(
      outcome: .noReadableTurns, turnCount: 0, bytesFetched: 0, agentStatus: nil
    )
    #expect(notice?.title == "No readable turns in this file")
    #expect(
      notice?.message
        == "Driverr read the file and found no conversation in it. It may belong to another "
        + "kind of agent."
    )
  }

  @Test("a page that parsed cleanly carries no notice")
  func aCleanPageCarriesNoNotice() {
    #expect(
      TranscriptNotice(outcome: .parsed, turnCount: 6, bytesFetched: 0, agentStatus: nil) == nil)
  }

  /// It needs nothing installed and always works.
  @Test("every failure offers the screen as a way out")
  func everyFailureOffersTheScreen() {
    let notices: [TranscriptNotice] =
      [
        TranscriptNotice(
          outcome: .endsMidRecord, turnCount: 2, bytesFetched: 61_440, agentStatus: nil),
        TranscriptNotice(
          outcome: .noReadableTurns, turnCount: 0, bytesFetched: 0, agentStatus: nil),
        TranscriptNotice(ambiguous: "/Users/x/Dev/driverr", candidates: []),
      ].compactMap { $0 } + [
        TranscriptNotice(absence: .agentNotSupported(agent: "Gemini"), agentStatus: nil),
        TranscriptNotice(absence: .paneHasNoDirectory, agentStatus: nil),
        TranscriptNotice(
          absence: .noSessionFiles(directory: "/Users/x/Dev/driverr"), agentStatus: nil),
        TranscriptNotice(
          absence: .reportedSessionMissing(sessionID: "abc", directory: "/Users/x/Dev/driverr"),
          agentStatus: nil
        ),
      ]
    #expect(notices.count == 7)
    #expect(notices.allSatisfy { $0.offersScreen })
  }

  // MARK: - Why there is no transcript at all

  /// The fixture is an agent with no reader. With "Codex" the message would name it twice,
  /// once as the pane's agent and once as a readable one, and neither check could fail.
  @Test("an unsupported agent is named rather than blamed")
  func unsupportedAgentIsNamed() {
    let notice = TranscriptNotice(absence: .agentNotSupported(agent: "Gemini"), agentStatus: nil)
    #expect(notice.title == "Driverr can't read Gemini's conversation")
    #expect(notice.message.contains("Gemini keeps its conversation somewhere else"))
    #expect(notice.message.contains("written by Claude Code and Codex."))
  }

  @Test("the unsupported-agent message names every agent this build reads")
  func unsupportedAgentMessageNamesEveryReadableAgent() {
    let notice = TranscriptNotice(absence: .agentNotSupported(agent: "Gemini"), agentStatus: nil)
    for agent in TranscriptAgent.allCases {
      #expect(notice.message.contains(agent.displayName), "\(agent) is missing")
    }
  }

  @Test("a pane with no working directory says what is missing")
  func noDirectorySaysWhatIsMissing() {
    let notice = TranscriptNotice(absence: .paneHasNoDirectory, agentStatus: nil)
    #expect(notice.title == "No directory for this pane")
  }

  @Test("an empty project directory names the directory it looked in")
  func noSessionFilesNamesTheDirectory() {
    let notice = TranscriptNotice(
      absence: .noSessionFiles(directory: "/Users/x/Dev/driverr"), agentStatus: nil)
    #expect(notice.title == "No session file yet")
    #expect(notice.message.contains("/Users/x/Dev/driverr"))
  }

  /// The composer below this notice is not gated on the transcript, so sending already works.
  @Test("an empty project directory says a message below can start the conversation")
  func noSessionFilesInvitesTheFirstMessage() {
    let notice = TranscriptNotice(
      absence: .noSessionFiles(directory: "/Users/x/Dev/driverr"), agentStatus: nil)
    #expect(notice.message.contains("Send a message below to start the conversation"))
  }

  /// Without a retry, a pane whose agent has not written its first record is stuck here.
  @Test("an empty project directory offers a retry, unlike the other absences")
  func noSessionFilesOffersARetry() {
    #expect(
      TranscriptNotice(absence: .noSessionFiles(directory: "/p"), agentStatus: nil).offersRetry)
  }

  /// A new session's file is written with its first prompt, so this is an ordinary start.
  /// No session id, which breaks mid-group on a phone. No agent name and "for" rather than
  /// "in", because Codex resolves here too.
  @Test("a named session with no file yet invites the first message and names the way out")
  func reportedSessionMissingInvitesTheFirstMessage() {
    let notice = TranscriptNotice(
      absence: .reportedSessionMissing(sessionID: "3f8c1d20", directory: "/Users/x/Dev/driverr"),
      agentStatus: .idle
    )
    #expect(notice.title == "No session file yet")
    #expect(notice.message.contains("session file for /Users/x/Dev/driverr"))
    #expect(notice.message.contains("Send a message below to start the conversation"))
    #expect(notice.message.contains("left the directory the agent started in"))
    #expect(notice.message.contains(TranscriptNotice.showScreenTitle))
    #expect(!notice.message.contains("3f8c1d20"))
    #expect(!notice.message.contains("Claude"))
    #expect(notice.offersRetry)
  }

  /// Codex rollouts are matched by `cwd` rather than stored in the directory.
  @Test("the two no-file-yet notices name no agent and say what the file is for")
  func theNoFileYetNoticesHoldForCodex() {
    let notices = [
      TranscriptNotice(absence: .noSessionFiles(directory: "/p"), agentStatus: nil),
      TranscriptNotice(
        absence: .reportedSessionMissing(sessionID: "s", directory: "/p"), agentStatus: nil),
    ]
    for notice in notices {
      #expect(notice.message.contains("session file for /p"))
      #expect(!notice.message.contains("Claude"))
    }
  }

  /// A shell pane never reaches the chat surface. This keeps the mapping total.
  @Test("a pane with no agent has a sentence rather than a crash")
  func paneWithNoAgentIsStillTotal() {
    #expect(
      TranscriptNotice(absence: .paneHasNoAgent, agentStatus: nil).title
        == "No agent in this pane")
  }

  // MARK: - Refusing to guess

  /// The count uses the same `isLive` rule the resolver used to call this ambiguous.
  @Test("an ambiguous directory refuses, counts the live files, and offers the picker")
  func ambiguityRefusesAndOffersThePicker() {
    let candidates = [
      TranscriptFile(path: "/p/a.jsonl", sizeInBytes: 10, age: 4),
      TranscriptFile(path: "/p/b.jsonl", sizeInBytes: 10, age: 21),
      TranscriptFile(path: "/p/c.jsonl", sizeInBytes: 10, age: 90_000),
    ]
    let notice = TranscriptNotice(ambiguous: "/Users/x/Dev/driverr", candidates: candidates)
    #expect(notice?.title == "Driverr can't tell which session belongs to this pane")
    #expect(
      notice?.message
        == "2 session files in this directory were written in the last minute. The newest "
        + "could belong to another agent, so Driverr won't pick for you."
    )
    #expect(notice?.offersFilePicker == true)
    // The picker is what adds each file's first human line.
    #expect(
      notice?.evidence == [
        "a.jsonl · written 4s ago",
        "b.jsonl · written 21s ago",
        "c.jsonl · written 1d ago",
      ]
    )
  }

  @Test("ages Driverr could not read are reported as unreadable, not as zero")
  func unreadableAgesAreNotCountedAsZero() {
    let candidates = [
      TranscriptFile(path: "/p/a.jsonl", sizeInBytes: 10, age: nil),
      TranscriptFile(path: "/p/b.jsonl", sizeInBytes: 10, age: 21),
    ]
    let notice = TranscriptNotice(ambiguous: "/Users/x/Dev/driverr", candidates: candidates)
    #expect(
      notice?.message
        == "Driverr couldn't read how recently these files were written. The newest could belong "
        + "to another agent, so Driverr won't pick for you."
    )
    // `TranscriptFile.newestFirst`, the order the picker uses, so an unreadable age sorts last.
    #expect(notice?.evidence == ["b.jsonl · written 21s ago", "a.jsonl"])
  }

  /// A project directory can hold dozens of session files. An unbounded list would push the
  /// exits off screen, and a silent cap would read as the whole list.
  @Test("a directory of many files lists the newest few and says what it left out")
  func manyCandidatesAreBoundedAndSaidSo() {
    let candidates = (0..<33).map {
      TranscriptFile(path: "/p/f\($0).jsonl", sizeInBytes: 10, age: TimeInterval($0))
    }
    let notice = TranscriptNotice(ambiguous: "/Users/x/Dev/driverr", candidates: candidates)
    #expect(notice?.evidence.count == TranscriptPicker.limit)
    #expect(notice?.evidence.first == "f0.jsonl · written just now")
    #expect(notice?.message.hasSuffix("27 older files in this directory aren't listed.") == true)
    // The live count is about the directory, not the rows shown.
    #expect(
      notice?.message.hasPrefix(
        "33 session files in this directory were written in the last minute.")
        == true
    )
  }

  // MARK: - A run of tool calls, closed

  @Test("a run of tool calls says how many and of what")
  func aRunSaysHowManyAndOfWhat() {
    let run = ToolRun(
      calls: Array(repeating: ToolCall(name: "Read", target: "a.swift"), count: 18)
        + Array(repeating: ToolCall(name: "Edit", target: "b.swift"), count: 9)
        + Array(repeating: ToolCall(name: "Bash"), count: 7)
        + Array(repeating: ToolCall(name: "Grep"), count: 6)
    )
    #expect(run.summary == "40 tool calls")
    #expect(run.kindsSummary == "Read ×18 · Edit ×9 · Bash ×7 · Grep ×6")
  }

  @Test("one call is singular")
  func oneCallIsSingular() {
    let run = ToolRun(calls: [ToolCall(name: "Read", target: "a.swift")])
    #expect(run.summary == "1 tool call")
    #expect(run.kindsSummary == "Read ×1")
  }

  /// VoiceOver does not read `×` as "times".
  @Test("a run is spoken in words rather than in multiplication signs")
  func aRunIsSpokenInWords() {
    let run = ToolRun(
      calls: [
        ToolCall(name: "Read", target: "a.swift"),
        ToolCall(name: "Read", target: "b.swift"),
        ToolCall(name: "Bash"),
      ]
    )
    #expect(run.accessibilityLabel == "3 tool calls. Read 2, Bash 1.")
    #expect(run.closedAccessibilityLabel == "3 tool calls.")
  }

  // MARK: - A run with a failed call

  @Test("a run with no failures has no failure note")
  func noFailuresNoNote() {
    let run = ToolRun(calls: [ToolCall(name: "Read", outcome: .succeeded)])
    #expect(run.failureNote == nil)
    #expect(run.accessibilityLabel == "1 tool call. Read 1.")
  }

  @Test("a run with one failed call says so, singular")
  func oneFailureIsSingular() {
    let run = ToolRun(calls: [ToolCall(name: "Bash", outcome: .failed)])
    #expect(run.failureNote == "1 failed")
    #expect(run.accessibilityLabel == "1 tool call. Bash 1. 1 failed.")
    #expect(run.closedAccessibilityLabel == "1 tool call. 1 failed.")
  }

  @Test("a run with several failed calls counts them")
  func severalFailuresAreCounted() {
    let run = ToolRun(
      calls: [
        ToolCall(name: "Bash", outcome: .failed),
        ToolCall(name: "Bash", outcome: .succeeded),
        ToolCall(name: "Edit", outcome: .failed),
      ]
    )
    #expect(run.failureNote == "2 failed")
  }

  // MARK: - The call with no result yet, in words

  @Test("a blocked pane's pending call names itself and its target")
  func pendingLabelNamesItsTarget() {
    let call = ToolCall(name: "Bash", target: "cargo test", outcome: .pending)
    #expect(
      call.pendingNotice(agentStatus: .blocked).label
        == "Waiting for permission · Bash cargo test"
    )
  }

  /// With no kind, which is every TUI pane, nothing changes.
  @Test("a blocked pane that said nothing about why still reads as permission")
  func pendingWithNoBlockedKind() {
    let call = ToolCall(name: "Bash", target: "cargo test", outcome: .pending)
    let notice = call.pendingNotice(agentStatus: .blocked, blockedKind: nil)
    #expect(notice == call.pendingNotice(agentStatus: .blocked))
    #expect(notice.label == "Waiting for permission · Bash cargo test")
    #expect(notice.chips.map(\.label) == ["Approve", "Deny"])
    #expect(notice.isAsking)
  }

  @Test("a permission prompt offers Approve and Deny")
  func pendingPermission() {
    let call = ToolCall(name: "Bash", target: "cargo test", outcome: .pending)
    let notice = call.pendingNotice(agentStatus: .blocked, blockedKind: .permission)
    #expect(notice.label == "Waiting for permission · Bash cargo test")
    #expect(notice.chips.map(\.label) == ["Approve", "Deny"])
  }

  /// `y` is not an answer to either, and a chip would send it.
  @Test(
    "a question or a sign-in asks, with no chips",
    arguments: [
      (AgentBlockedKind.question, "Waiting for your answer · Bash cargo test"),
      (.auth, "Waiting for you to sign in · Bash cargo test"),
    ])
  func pendingWithNoChips(kind: AgentBlockedKind, label: String) {
    let call = ToolCall(name: "Bash", target: "cargo test", outcome: .pending)
    let notice = call.pendingNotice(agentStatus: .blocked, blockedKind: kind)
    #expect(notice.label == label)
    #expect(notice.isAsking)
    #expect(notice.chips.isEmpty)
  }

  @Test("a kind means nothing on a pane that is not blocked")
  func blockedKindNeedsBlocked() {
    let call = ToolCall(name: "Bash", target: "cargo test", outcome: .pending)
    #expect(
      call.pendingNotice(agentStatus: .working, blockedKind: .question)
        == call.pendingNotice(agentStatus: .working))
  }

  @Test("a pending call with no target names itself alone")
  func pendingLabelWithNoTarget() {
    let call = ToolCall(name: "AskUserQuestion", outcome: .pending)
    #expect(
      call.pendingNotice(agentStatus: .blocked).label == "Waiting for permission · AskUserQuestion"
    )
  }

  /// The call carrying the agent's questions says it waits for an answer. An
  /// `AskUserQuestion` whose options never parsed offers the synthesised pair and keeps the
  /// permission wording.
  @Test("a question says it is waiting for an answer rather than for permission")
  func aQuestionSaysWhatItIsWaitingFor() {
    let call = ToolCall(
      name: "AskUserQuestion", outcome: .pending,
      questions: [PendingQuestion(question: "Which branch?", options: ["main", "release"])]
    )
    #expect(
      call.pendingNotice(agentStatus: .blocked).label == "Waiting for your answer · AskUserQuestion"
    )
    #expect(
      call.pendingNotice(agentStatus: .working).label == "Waiting for your answer · AskUserQuestion"
    )
  }

  /// With permission prompts auto-accepted, a working pane is the common case. It must not
  /// read as a permission prompt.
  @Test("a working pane's pending call says the tool is running, and asks nothing")
  func pendingOnAWorkingPaneIsARunningTool() {
    let call = ToolCall(name: "Bash", target: "cargo test", outcome: .pending)
    let notice = call.pendingNotice(agentStatus: .working)
    #expect(notice.label == "Running · Bash cargo test")
    #expect(notice.isAsking == false)
    #expect(notice.chips.isEmpty)
  }

  /// A chip under a pane that is not waiting sends `y` into whatever has the prompt.
  @Test("only a blocked pane is offered an answer", arguments: AgentStatus.allCases)
  func chipsAreOfferedOnlyWhereThePaneIsBlocked(status: AgentStatus) {
    let call = ToolCall(name: "Bash", target: "cargo test", outcome: .pending)
    let notice = call.pendingNotice(agentStatus: status)
    #expect(notice.isAsking == (status == .blocked))
    #expect(notice.chips.isEmpty == (status != .blocked))
  }

  @Test("a blocked pane still gets the chips the call's options become")
  func blockedKeepsItsChips() {
    let call = ToolCall(
      name: "AskUserQuestion", target: "which branch", outcome: .pending,
      questions: [PendingQuestion(question: "Which branch?", options: ["main", "release"])])
    let notice = call.pendingNotice(agentStatus: .blocked)
    #expect(notice.isAsking)
    #expect(notice.groups == call.replyChipGroups)
    #expect(notice.chips.map(\.label) == ["main", "release"])
  }

  /// herdr's status can lag a question or miss it. A call carrying questions with options
  /// and no result is the evidence that the agent is asking, so the chips show whatever the
  /// status says.
  @Test(
    "a question the agent wrote keeps its chips whatever herdr says",
    arguments: [AgentStatus.blocked, .working, .idle, .done, .unknown, nil] as [AgentStatus?]
  )
  func aWrittenQuestionIsAnsweredWhateverTheStatus(status: AgentStatus?) {
    let call = ToolCall(
      name: "AskUserQuestion", outcome: .pending,
      questions: [
        PendingQuestion(question: "Which fruit?", options: ["Apple", "Banana"]),
        PendingQuestion(
          question: "Which colours?", options: ["Red", "Green"],
          allowsMultiple: true
        ),
      ]
    )
    let notice = call.pendingNotice(agentStatus: status)
    #expect(notice.isAsking)
    #expect(notice.groups == call.replyChipGroups)
    #expect(
      notice.chips.map(\.label) == ["Apple", "Banana", "Red", "Green"])
  }

  /// Unreadable options are not evidence, so the status gate applies as for any other call.
  @Test("a question with no usable options is still gated on the status")
  func aQuestionWithNoOptionsKeepsTheGate() {
    let call = ToolCall(
      name: "AskUserQuestion", outcome: .pending,
      questions: [PendingQuestion(question: "Which branch?", options: [])]
    )
    #expect(call.pendingNotice(agentStatus: .working).chips.isEmpty)
    #expect(call.pendingNotice(agentStatus: .working).isAsking == false)
    #expect(call.pendingNotice(agentStatus: .blocked).chips.map(\.label) == ["Approve", "Deny"])
  }

  /// A pane with no agent is `nil` rather than `.unknown`; the answer is the same.
  @Test("a status that decides neither states only that no result arrived")
  func pendingWithNothingToDecideItSaysSo() {
    let call = ToolCall(name: "Read", target: "Package.swift", outcome: .pending)
    for status: AgentStatus? in [.idle, .done, .unknown, nil] {
      let notice = call.pendingNotice(agentStatus: status)
      #expect(notice.label == "No result yet · Read Package.swift")
      #expect(notice.isAsking == false)
      #expect(notice.chips.isEmpty)
    }
  }

  // MARK: - When the conversation last moved

  @Test("the last activity is the newest turn that carried a timestamp")
  func lastActivityIsTheNewestDatedTurn() {
    let early = Date(timeIntervalSince1970: 1_000_000)
    let late = Date(timeIntervalSince1970: 1_000_600)
    let transcript = Transcript(
      turns: [
        TranscriptTurn(id: "1", speech: .human("go"), at: early),
        TranscriptTurn(id: "2", speech: .assistant("done"), at: late),
      ],
      window: .none
    )
    #expect(transcript.lastActivity == late)
  }

  /// An undated record leaves `at` nil, and one at the tail must not erase the page's age.
  @Test("an undated tail record does not erase the page's age")
  func anUndatedTailDoesNotEraseTheAge() {
    let at = Date(timeIntervalSince1970: 1_000_600)
    let transcript = Transcript(
      turns: [
        TranscriptTurn(id: "1", speech: .assistant("done"), at: at),
        TranscriptTurn(id: "2", speech: .tools(ToolRun(calls: [ToolCall(name: "Read")]))),
      ],
      window: .none
    )
    #expect(transcript.lastActivity == at)
  }

  @Test("a page with no timestamps anywhere has no age rather than a guessed one")
  func noTimestampsMeansNoAge() {
    let transcript = Transcript(
      turns: [TranscriptTurn(id: "1", speech: .human("go"))],
      window: .none
    )
    #expect(transcript.lastActivity == nil)
  }

  // MARK: - Who said it

  /// A run of tool calls has no speaker: the agent was working, not talking.
  @Test("a turn is attributed to the person, the agent, or nobody")
  func turnsAreAttributedByTypeNotByAppearance() {
    let human = TranscriptTurn(id: "1", speech: .human("go"))
    let assistant = TranscriptTurn(id: "2", speech: .assistant("done"))
    let tools = TranscriptTurn(id: "3", speech: .tools(ToolRun(calls: [ToolCall(name: "Read")])))

    #expect(human.speaker(agentName: "Claude") == "You")
    #expect(assistant.speaker(agentName: "Claude") == "Claude")
    #expect(assistant.speaker(agentName: "Codex") == "Codex")
    #expect(tools.speaker(agentName: "Claude") == nil)
  }

  // MARK: - One agent talking to another

  /// A relayed teammate event is nobody's turn on this screen. The sender is in the line.
  @Test("an agent event wears no speaker label at all")
  func anAgentEventHasNoSpeaker() {
    let event = TranscriptTurn(
      id: "e",
      speech: .agentEvent(
        TranscriptTurn.AgentEvent(
          sender: "eng-6", summary: "Merged", body: "It is in.", kind: .message))
    )

    #expect(event.speaker(agentName: "Claude") == nil)
    // A Needs-you row must not quote a teammate as the agent's last words.
    #expect(event.text == nil)
    #expect(event.isHuman == false)
    #expect(event.isAssistant == false)
  }

  @Test("the collapsed line is the sender and what the envelope summarised")
  func theCollapsedLineNamesTheSenderAndTheSummary() {
    let summarised = TranscriptTurn.AgentEvent(
      sender: "eng-6", summary: "[to ver-6] Fixes ready", body: "…", kind: .idle)
    // The recipient prefix stays; without it the line reads as addressed to this session.
    #expect(summarised.line == "eng-6: [to ver-6] Fixes ready")

    let idle = TranscriptTurn.AgentEvent(sender: "finder-6", summary: nil, body: "", kind: .idle)
    #expect(idle.line == "finder-6: went idle")

    let spoke = TranscriptTurn.AgentEvent(
      sender: "qa-6", summary: nil, body: "Looks right.", kind: .message)
    #expect(spoke.line == "qa-6: sent a message")
  }

  /// Inventing a sender is the same fault as inventing a speaker.
  @Test("an event with no sender is just its summary")
  func anEventWithNoSenderIsJustTheSummary() {
    let event = TranscriptTurn.AgentEvent(sender: "", summary: nil, body: "", kind: .message)
    #expect(event.line == "sent a message")
  }

  @Test("only an event carrying a body offers one")
  func onlyAnEventWithABodyExpands() {
    #expect(
      TranscriptTurn.AgentEvent(sender: "a", summary: nil, body: "", kind: .idle).hasBody == false)
    #expect(
      TranscriptTurn.AgentEvent(sender: "a", summary: nil, body: "  \n ", kind: .idle).hasBody
        == false)
    #expect(
      TranscriptTurn.AgentEvent(sender: "a", summary: nil, body: "Done.", kind: .idle).hasBody)
  }

  // MARK: - This session's own agent traffic

  @Test("a spawn, a stop and a message out each say what happened and to whom")
  func thisSessionsOwnCallsSayWhatHappened() {
    let spawned = TranscriptTurn.AgentEvent(
      sender: "analyst-1", summary: "Plan the async pool migration", body: "",
      kind: .spawned)
    #expect(spawned.line == "Started analyst-1 · Plan the async pool migration")

    let stopped = TranscriptTurn.AgentEvent(
      sender: "analyst-1", summary: "Plan the async pool migration", body: "",
      kind: .stopped)
    #expect(stopped.line == "Stopped analyst-1 · Plan the async pool migration")

    let sent = TranscriptTurn.AgentEvent(
      sender: "ana-8", summary: "Ask for the rest of the list", body: "", kind: .sent)
    #expect(sent.line == "To ana-8 · Ask for the rest of the list")
  }

  /// Unlike a relayed event there is no fallback wording, because the name alone is already a
  /// sentence.
  @Test("one of this session's own calls with nothing to summarise says the name alone")
  func thisSessionsOwnCallsHaveNoFallbackWording() {
    let unresolved = TranscriptTurn.AgentEvent(
      sender: "verifier-3", summary: nil, body: "", kind: .stopped)
    #expect(unresolved.line == "Stopped verifier-3")
    #expect(unresolved.trailing.isEmpty)

    let blank = TranscriptTurn.AgentEvent(
      sender: "engineer-2", summary: "   ", body: "", kind: .spawned)
    #expect(blank.line == "Started engineer-2")
  }

  @Test("the emphasised half and the trailing half are the whole line")
  func theTwoHalvesConcatenateToTheLine() {
    let events = [
      TranscriptTurn.AgentEvent(
        sender: "eng-6", summary: "Fixes ready", body: "x",
        kind: .message),
      TranscriptTurn.AgentEvent(sender: "finder-6", summary: nil, body: "", kind: .idle),
      TranscriptTurn.AgentEvent(sender: "", summary: nil, body: "", kind: .message),
      TranscriptTurn.AgentEvent(
        sender: "analyst-1", summary: "Plan it", body: "",
        kind: .spawned),
      TranscriptTurn.AgentEvent(sender: "analyst-1", summary: nil, body: "", kind: .stopped),
      TranscriptTurn.AgentEvent(
        sender: "", summary: "Ask for the remainder", body: "",
        kind: .sent),
    ]
    for event in events {
      #expect(event.emphasised + event.trailing == event.line)
    }
    #expect(events[3].emphasised == "Started analyst-1")
    #expect(events[3].trailing == " · Plan it")
    #expect(events[0].emphasised == "eng-6")
    #expect(events[0].trailing == ": Fixes ready")
  }

  /// A relayed event opens with the teammate's name instead.
  @Test("only this session's own calls open with a verb")
  func onlyOwnCallsCarryAVerb() {
    #expect(TranscriptChatCopy.verb(for: .message) == nil)
    #expect(TranscriptChatCopy.verb(for: .idle) == nil)
    #expect(TranscriptChatCopy.verb(for: .spawned) == "Started")
    #expect(TranscriptChatCopy.verb(for: .stopped) == "Stopped")
    #expect(TranscriptChatCopy.verb(for: .sent) == "To")
    #expect(TranscriptTurn.AgentEvent.Kind.message.isThisSessionsOwnCall == false)
    #expect(TranscriptTurn.AgentEvent.Kind.idle.isThisSessionsOwnCall == false)
    #expect(TranscriptTurn.AgentEvent.Kind.spawned.isThisSessionsOwnCall)
    #expect(TranscriptTurn.AgentEvent.Kind.stopped.isThisSessionsOwnCall)
    #expect(TranscriptTurn.AgentEvent.Kind.sent.isThisSessionsOwnCall)
  }

  @Test("this session's own calls carry no body to open")
  func ownCallsHaveNoBody() {
    #expect(
      TranscriptTurn.AgentEvent(sender: "a", summary: "b", body: "", kind: .spawned).hasBody
        == false)
  }

  // MARK: - When a turn was said, relative to now

  @Test("terminal elapsed time is exact recorded duration, independent of turn age")
  func turnDurationCaption() {
    for (milliseconds, expected) in [
      (0.0, "Crunched for 0s"), (999.9, "Crunched for 0s"),
      (1000, "Crunched for 1s"), (59999, "Crunched for 59s"),
      (60000, "Crunched for 1m 0s"), (590000, "Crunched for 9m 50s"),
      (3600000, "Crunched for 1h 0m 0s"),
    ] {
      #expect(TranscriptTurn(id: "a", speech: .assistant("done"), durationMs: milliseconds).durationLabel == expected)
    }
    for invalid in [-1.0, Double.nan, Double.infinity] {
      #expect(TranscriptTurn(id: "a", speech: .assistant("done"), durationMs: invalid).durationLabel == nil)
    }
    #expect(TranscriptTurn(id: "a", speech: .assistant("done")).durationLabel == nil)
    #expect(TranscriptTurn(id: "h", speech: .human("go"), durationMs: 590000).durationLabel == nil)
    #expect(TranscriptTurn(id: "t", speech: .tools(ToolRun(calls: [])), durationMs: 590000).durationLabel == nil)
  }

  @Test("the newest turn's relative time shares TranscriptAge's own words")
  func relativeTimeReadsLikeTheProvenanceHeader() {
    let now = Date(timeIntervalSince1970: 1_000_060)
    let turn = TranscriptTurn(
      id: "1", speech: .human("go"), at: Date(timeIntervalSince1970: 1_000_000))
    #expect(turn.relativeTime(asOf: now) == "1m")
  }

  @Test("a turn with no timestamp has no relative time")
  func undatedTurnHasNoRelativeTime() {
    let turn = TranscriptTurn(id: "1", speech: .human("go"))
    #expect(turn.relativeTime(asOf: Date()) == nil)
  }

  @Test("a separator belongs between turns more than 30 minutes apart")
  func separatorAfterAGap() {
    let early = TranscriptTurn(id: "1", speech: .human("go"), at: Date(timeIntervalSince1970: 0))
    let late = TranscriptTurn(
      id: "2", speech: .assistant("back"), at: Date(timeIntervalSince1970: 31 * 60)
    )
    #expect(late.showsTimeSeparator(after: early))
  }

  @Test("no separator for turns inside the 30-minute window")
  func noSeparatorInsideTheWindow() {
    let early = TranscriptTurn(id: "1", speech: .human("go"), at: Date(timeIntervalSince1970: 0))
    let late = TranscriptTurn(
      id: "2", speech: .assistant("back"), at: Date(timeIntervalSince1970: 29 * 60)
    )
    #expect(!late.showsTimeSeparator(after: early))
  }

  @Test("no separator when either turn has no timestamp")
  func noSeparatorWithoutBothTimestamps() {
    let undated = TranscriptTurn(id: "1", speech: .human("go"))
    let dated = TranscriptTurn(id: "2", speech: .assistant("back"), at: Date())
    #expect(!dated.showsTimeSeparator(after: undated))
    #expect(!undated.showsTimeSeparator(after: dated))
  }

  @Test("the first turn has nothing before it to separate from")
  func firstTurnNeverSeparates() {
    let only = TranscriptTurn(id: "1", speech: .human("go"), at: Date())
    #expect(!only.showsTimeSeparator(after: nil))
  }

  // MARK: - An image travelling with a turn

  @Test("a turn with no images has no image label")
  func noImagesNoLabel() {
    let turn = TranscriptTurn(id: "1", speech: .human("go"))
    #expect(turn.attachedImagesLabel == nil)
  }

  @Test("one image is singular, several are counted")
  func imageLabelsAreCounted() {
    let one = TranscriptTurn(id: "1", speech: .human("go"), attachedImages: 1)
    let three = TranscriptTurn(id: "2", speech: .human("go"), attachedImages: 3)
    #expect(one.attachedImagesLabel == "1 image")
    #expect(three.attachedImagesLabel == "3 images")
  }

  // MARK: - A fetch that failed

  /// A fault, so asking again could produce a different answer. `.noSessionFiles` and
  /// `.reportedSessionMissing` also offer a retry, because the watcher still polls for them.
  @Test("a failed read carries the error's own words and offers a retry")
  func aFailedReadOffersARetry() {
    let notice = TranscriptNotice(
      failure: .transcriptUnreadable(reason: "The host exited with 1.")
    )
    #expect(notice.title == "Driverr couldn't read the session file")
    #expect(notice.message.contains("The host exited with 1."))
    #expect(notice.offersRetry)
    #expect(notice.offersScreen)
  }

  @Test("the failure message does not repeat the notice's own title")
  func theFailureMessageDoesNotRepeatTheTitle() {
    let notice = TranscriptNotice(
      failure: .transcriptUnreadable(reason: "The host exited with 1.")
    )
    #expect(notice.message == "The host exited with 1.")
  }

  /// No fixed headline in front of the reason that contradicts it.
  @Test("a dropped-link failure names the host with no contradicting headline")
  func aDroppedLinkNamesTheHost() {
    let notice = TranscriptNotice(failure: .notConnected(host: "workbox"))
    #expect(notice.message == "Driverr isn't connected to workbox.")
  }

  /// Asking again would say the same thing.
  @Test("an answer about the pane offers no retry")
  func answersDoNotOfferARetry() {
    #expect(!TranscriptNotice(absence: .paneHasNoDirectory, agentStatus: nil).offersRetry)
    #expect(
      TranscriptNotice(outcome: .noReadableTurns, turnCount: 0, bytesFetched: 0, agentStatus: nil)?
        .offersRetry == false)
    #expect(
      TranscriptNotice(ambiguous: "/p", candidates: [])?.offersRetry == false
    )
  }

  // MARK: - Which absences deserve a notice at all

  /// An agent with no reader is a permanent, normal state and draws the captured screen with
  /// no notice.
  @Test("an agent Driverr has no reader for is the agent's permanent state")
  func anUnsupportedAgentIsPermanent() {
    #expect(TranscriptAbsence.agentNotSupported(agent: "Gemini").isUnreadableAgentKind)
    #expect(TranscriptResolution.absent(.agentNotSupported(agent: "Gemini")).isUnreadableAgentKind)
  }

  @Test("every other absence is about this pane and keeps its notice")
  func otherAbsencesKeepTheirNotice() {
    #expect(!TranscriptAbsence.paneHasNoAgent.isUnreadableAgentKind)
    #expect(!TranscriptAbsence.paneHasNoDirectory.isUnreadableAgentKind)
    #expect(!TranscriptAbsence.noSessionFiles(directory: "/p").isUnreadableAgentKind)
    #expect(
      !TranscriptAbsence.reportedSessionMissing(sessionID: "s", directory: "/p")
        .isUnreadableAgentKind
    )
  }

  @Test("a resolved or ambiguous file is never the agent's permanent state")
  func onlyAbsencesCanBePermanent() {
    #expect(!TranscriptResolution.ambiguous(directory: "/p", candidates: []).isUnreadableAgentKind)
    #expect(!TranscriptResolution.absent(.paneHasNoDirectory).isUnreadableAgentKind)
  }

  // MARK: - One glyph per notice

  /// `ContentUnavailableView` draws one symbol, so the states would otherwise differ only by
  /// their words.
  @Test("every notice on the hero surface names its own symbol, except the shared fault glyph")
  func everyNoticeNamesItsOwnSymbol() {
    let distinguishable: [TranscriptNotice] = [
      TranscriptNotice(absence: .paneHasNoAgent, agentStatus: nil),
      TranscriptNotice(absence: .agentNotSupported(agent: "Gemini"), agentStatus: nil),
      TranscriptNotice(absence: .paneHasNoDirectory, agentStatus: nil),
      TranscriptNotice(absence: .noSessionFiles(directory: "/p"), agentStatus: nil),
    ]
    let symbols = Set(distinguishable.map(\.symbolName))
    #expect(symbols.count == distinguishable.count, "every notice must have its own symbol")
  }

  /// Faults share `exclamationmark.triangle` because no two are on screen together: a failed
  /// read has no page at all. `reportedSessionMissing` shares the wait glyph unless the agent
  /// has had its prompt.
  @Test("every genuine fault shares one glyph, since none of them are ever on screen together")
  func everyFaultSharesOneGlyph() throws {
    let failed = TranscriptNotice(failure: .disconnected(reason: "offline"))
    let midRecord = try #require(
      TranscriptNotice(outcome: .endsMidRecord, turnCount: 1, bytesFetched: 1, agentStatus: nil)
    )
    let missing = TranscriptNotice(
      absence: .reportedSessionMissing(sessionID: "s", directory: "/p"), agentStatus: .working)
    #expect(failed.symbolName == "exclamationmark.triangle")
    #expect(midRecord.symbolName == "exclamationmark.triangle")
    #expect(missing.symbolName == "exclamationmark.triangle")
  }

  @Test(
    "a named session with no file yet shares the empty directory's glyph",
    arguments: [AgentStatus.blocked, .idle, .unknown, nil])
  func aNamedSessionWithNoFileYetSharesTheWaitGlyph(status: AgentStatus?) {
    let named = TranscriptNotice(
      absence: .reportedSessionMissing(sessionID: "s", directory: "/p"), agentStatus: status)
    let empty = TranscriptNotice(absence: .noSessionFiles(directory: "/p"), agentStatus: status)
    #expect(named.symbolName == "text.bubble")
    #expect(named.symbolName == empty.symbolName)
  }

  /// A new Claude Code session is named before its file exists, and the file appears with
  /// the first prompt. In a directory with older sessions that wait resolves to
  /// `reportedSessionMissing`.
  @Test("a named session with no file yet reads as a wait, not a fault")
  func aNamedSessionWithNoFileYetIsNotAFault() {
    let waiting = TranscriptNotice(
      absence: .reportedSessionMissing(
        sessionID: "7b1e4c90-0000-4000-8000-000000000001",
        directory: "/Users/x/Dev/driverr"
      ),
      agentStatus: .idle
    )
    #expect(waiting.symbolName != "exclamationmark.triangle")
  }

  /// A working agent has had its first prompt, so its file is not coming.
  @Test("a working agent's missing session file is a fault")
  func aWorkingAgentsMissingFileIsAFault() {
    let notice = TranscriptNotice(
      absence: .reportedSessionMissing(sessionID: "s", directory: "/p"),
      agentStatus: .working
    )
    #expect(notice.symbolName == "exclamationmark.triangle")
  }

  /// A working or finished agent has had its prompt and gets the fault. Every other status
  /// keeps the wait: a new Claude on its trust prompt reports blocked before any prompt
  /// (`FakeControl.treeWithUnstartedAgent`). `noSessionFiles` is included because a reported
  /// id in an empty directory lands there. Both keep the retry.
  @Test(
    "a missing file is a fault once the agent has had its prompt, and a wait before",
    arguments: [AgentStatus?.none] + AgentStatus.allCases.map { $0 },
    [
      TranscriptAbsence.noSessionFiles(directory: "/Users/x/Dev/driverr"),
      .reportedSessionMissing(sessionID: "3f8c1d20", directory: "/Users/x/Dev/driverr"),
    ])
  func aMissingFileFollowsTheAgentStatus(status: AgentStatus?, absence: TranscriptAbsence) {
    let notice = TranscriptNotice(absence: absence, agentStatus: status)
    let prompted: Bool
    switch status {
    case .working, .done: prompted = true
    case .blocked, .error, .idle, .unknown, nil: prompted = false
    }
    if prompted {
      #expect(notice.title == "The session file is missing")
      #expect(notice.symbolName == "exclamationmark.triangle")
      #expect(!notice.message.contains("Send a message below"))
    } else {
      #expect(notice.title == "No session file yet")
      #expect(notice.symbolName == "text.bubble")
      #expect(notice.message.contains("Send a message below to start the conversation"))
    }
    #expect(notice.offersRetry)
    #expect(notice.offersScreen)
    #expect(notice.message.contains("session file for /Users/x/Dev/driverr"))
    #expect(!notice.message.contains("3f8c1d20"))
    #expect(!notice.message.contains("Claude"))
  }

  /// The usual first state of a new Claude on a core, and neither sentence may name a button
  /// that is not there.
  @Test(
    "with no screen to read, a missing file names no way out",
    arguments: [AgentStatus.idle, .working],
    [
      TranscriptAbsence.noSessionFiles(directory: "/p"),
      .reportedSessionMissing(sessionID: "s", directory: "/p"),
    ])
  func aMissingFileWithNoScreen(status: AgentStatus, absence: TranscriptAbsence) {
    let notice = TranscriptNotice(absence: absence, agentStatus: status, canReadScreen: false)
    #expect(!notice.message.contains(TranscriptNotice.showScreenTitle))
    #expect(!notice.offersScreen(inSubagentChat: false, canReadScreen: false))
    #expect(notice.offersRetry)
  }

  @Test("with no screen to read, a pane that left its directory is still told why")
  func leftTheDirectoryWithNoScreen() {
    let absence = TranscriptAbsence.reportedSessionMissing(sessionID: "s", directory: "/p")
    let waiting = TranscriptNotice(absence: absence, agentStatus: .idle, canReadScreen: false)
    #expect(
      waiting.message
        == "The agent has not written its session file for /p yet. Send a message below to "
        + "start the conversation. If this pane has left the directory the agent started in, "
        + "the file will not appear here.")
    let fault = TranscriptNotice(absence: absence, agentStatus: .done, canReadScreen: false)
    #expect(
      fault.message
        == "The agent has started, but Driverr found no session file for /p. If this pane has "
        + "left the directory the agent started in, the file will not appear here.")
  }

  /// The sentences a TUI pane has always read, whole, so the core wording cannot move them.
  @Test("a pane whose screen can be read keeps its sentences")
  func aMissingFileWithAScreen() {
    let absence = TranscriptAbsence.reportedSessionMissing(sessionID: "s", directory: "/p")
    #expect(
      TranscriptNotice(absence: absence, agentStatus: .idle).message
        == "The agent has not written its session file for /p yet. Send a message below to "
        + "start the conversation. If this pane has left the directory the agent started in, "
        + "the file will not appear here, so use Show the Screen.")
    #expect(
      TranscriptNotice(absence: absence, agentStatus: .done).message
        == "The agent has started, but Driverr found no session file for /p. If this pane has "
        + "left the directory the agent started in, use Show the Screen.")
  }

  /// Every notice, not only the two that word it: all of them reach the same button.
  @Test("no notice offers a screen Driverr cannot read")
  func noNoticeOffersAnUnreadableScreen() throws {
    let notices = [
      TranscriptNotice(failure: .transcriptUnreadable(reason: "gone")),
      TranscriptNotice(absence: .paneHasNoDirectory, agentStatus: nil),
      TranscriptNotice(absence: .agentNotSupported(agent: "Cursor"), agentStatus: nil),
      try #require(TranscriptNotice(ambiguous: "/p", candidates: [])),
      try #require(
        TranscriptNotice(
          outcome: .noReadableTurns, turnCount: 0, bytesFetched: 0, agentStatus: nil)),
    ]
    for notice in notices {
      #expect(notice.offersScreen(inSubagentChat: false, canReadScreen: true))
      #expect(!notice.offersScreen(inSubagentChat: false, canReadScreen: false))
    }
  }

  @Test("an agent on an added machine says where it is, with no way out that would fail")
  func anAgentOnAnAddedMachine() {
    let notice = TranscriptNotice(
      absence: .agentOnAddedMachine(agent: "Claude", machine: "box"), agentStatus: .working)
    #expect(notice.title == "Claude is running on box")
    #expect(
      notice.message
        == "Driverr reads conversations on the computer it connected to, and this terminal is "
        + "on box.")
    #expect(!notice.offersScreen)
    #expect(!notice.offersRetry)
    #expect(!notice.offersFilePicker)
  }

  /// `true` would draw the captured screen in its place, and Driverr reads none from a core.
  @Test("an added machine is not an agent Driverr can never read")
  func anAddedMachineKeepsItsNotice() {
    let absence = TranscriptAbsence.agentOnAddedMachine(agent: "Claude", machine: "box")
    #expect(!absence.isUnreadableAgentKind)
    #expect(!TranscriptResolution.absent(absence).isUnreadableAgentKind)
  }

  @Test("a prompted agent's missing file names the way out")
  func aPromptedAgentsMissingFileNamesTheWayOut() {
    let notice = TranscriptNotice(
      absence: .reportedSessionMissing(sessionID: "s", directory: "/p"), agentStatus: .done)
    #expect(notice.message.contains("left the directory the agent started in"))
    #expect(notice.message.contains(TranscriptNotice.showScreenTitle))
  }
}

/// What a run shows under it once its question is answered.
@Suite("ToolRun.answeredQuestions")
struct AnsweredQuestionTests {
  @Test("an answered question shows its header, its question and the answer")
  func anAnsweredQuestionIsShown() {
    let run = ToolRun(calls: [
      ToolCall(name: "Read", target: "a.swift", outcome: .succeeded),
      ToolCall(
        name: "AskUserQuestion",
        outcome: .succeeded,
        questions: [
          PendingQuestion(
            question: "Which fruit do you pick?", options: ["Apple", "Banana"], header: "Fruit",
            answer: "Banana"),
          PendingQuestion(
            question: "Pick fruits", options: ["Apple", "Cherry"], allowsMultiple: true,
            answer: "Apple, Cherry"),
        ]
      ),
    ])

    #expect(
      run.answeredQuestions == [
        AnsweredQuestion(header: "Fruit", question: "Which fruit do you pick?", answer: "Banana"),
        AnsweredQuestion(header: nil, question: "Pick fruits", answer: "Apple, Cherry"),
      ]
    )
    #expect(
      run.answeredQuestions[0].accessibilityLabel
        == "Fruit. Which fruit do you pick? Answered: Banana")
  }

  @Test("a question still waiting, or with no answer recorded, shows nothing")
  func anUnansweredQuestionIsNotShown() {
    let waiting = ToolRun(calls: [
      ToolCall(
        name: "AskUserQuestion", outcome: .pending,
        questions: [PendingQuestion(question: "Which?", options: ["A", "B"])])
    ])
    #expect(waiting.answeredQuestions.isEmpty)

    let blank = ToolRun(calls: [
      ToolCall(
        name: "AskUserQuestion", outcome: .succeeded,
        questions: [PendingQuestion(question: "Which?", options: ["A"], answer: "  ")])
    ])
    #expect(blank.answeredQuestions.isEmpty)
  }

  @Test("a question with no words is spoken as its header and its answer")
  func aQuestionWithNoWordsIsSpokenWithoutIt() {
    let answered = AnsweredQuestion(header: "Fruit", question: "", answer: "Apple")
    #expect(answered.accessibilityLabel == "Fruit. Answered: Apple")
  }
}
