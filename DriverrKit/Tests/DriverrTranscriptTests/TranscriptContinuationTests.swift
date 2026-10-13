import DriverrCore
import Foundation
import Testing

@testable import DriverrTranscript

/// Following the pointer Claude Code leaves when it continues a session. See
/// `TranscriptReader.continuation(from:reported:in:)` for why the redirect happens in
/// `resolve`, before the read.
struct TranscriptContinuationTests {
  private static let directory = HostFixture.projectDirectory

  /// The fragment only the continuation command carries. A literal, so the assertions are
  /// about the resolver's answer rather than a shared constant.
  private static let continuationKey = #""type":"continued-in""#

  /// The fragment of the read command that names one file. `f=<path>` rather than the bare
  /// name, because the continuation command names every candidate, and `FakeHost` walks an
  /// unordered dictionary, so a collision would flip between runs.
  private static func readKey(_ name: String) -> String {
    "f=\(directory)/\(name)"
  }

  /// What the host prints for a file that names a successor.
  private static func continuationLine(_ file: String, to sessionID: String) -> String {
    "\(TranscriptCommands.resultMark)\(file)\(TranscriptCommands.fieldSeparator)\(sessionID)\n"
  }

  private static func listing(_ names: [String]) -> String {
    HostFixture.listing(
      now: 1_000_000,
      directory: directory,
      files: names.enumerated().map { index, name in
        // Descending mtimes, so the reported file is not the newest and a redirect cannot be
        // mistaken for tier 2's heuristic.
        (mtime: String(999_000 - index), size: 4096, name: name)
      }
    )
  }

  private static func page(_ text: String) -> CommandResult {
    FakeHost.output(
      HostFixture.read(
        size: 4096,
        body: Fixture.assistant(text) + "\n" + Fixture.resultsScanned + "\n"
      )
    )
  }

  private static func pane(session: String) -> Pane {
    HostFixture.pane(
      agent: Agent(
        name: "Claude",
        kind: "claude",
        status: .working,
        session: AgentSession(agent: "claude", kind: "id", value: session)
      )
    )
  }

  @Test("a reported session that has been continued reads the file it was continued into")
  func followsOneHop() async throws {
    let host = FakeHost(
      responses: [
        "date +%s": FakeHost.output(Self.listing(["old.jsonl", "new.jsonl"])),
        Self.continuationKey: FakeHost.output(
          Self.continuationLine("old.jsonl", to: "new")
        ),
        Self.readKey("old.jsonl"): Self.page("the message herdr's id would have shown"),
        Self.readKey("new.jsonl"): Self.page("the newest turn, hours after the handover"),
      ]
    )
    let reader = TranscriptReader(run: host.runner)
    let source = try #require(try await reader.resolve(for: Self.pane(session: "old")).source)

    #expect(source.file.name == "new.jsonl")
    #expect(source.file.path == "\(Self.directory)/new.jsonl")
    // Still exact, and the evidence names the session on screen.
    #expect(
      source.provenance == .continuedFromHerdrSession(reportedID: "old", sessionID: "new")
    )

    let transcript = try await reader.read(source.file)
    #expect(transcript.lastAssistantMessage == "the newest turn, hours after the handover")
  }

  /// Two handovers is ordinary after a long day, and one hop would land on a dead file.
  @Test("a chain of continuations is walked to its end")
  func followsTwoHops() async throws {
    let host = FakeHost(
      responses: [
        "date +%s": FakeHost.output(Self.listing(["a.jsonl", "b.jsonl", "c.jsonl"])),
        Self.continuationKey: FakeHost.output(
          Self.continuationLine("a.jsonl", to: "b") + Self.continuationLine("b.jsonl", to: "c")
        ),
        Self.readKey("c.jsonl"): Self.page("the end of the chain"),
      ]
    )
    let reader = TranscriptReader(run: host.runner)
    let source = try #require(try await reader.resolve(for: Self.pane(session: "a")).source)
    #expect(source.file.name == "c.jsonl")
    // The end of the chain: the reported id and the one on screen are two apart.
    #expect(source.provenance == .continuedFromHerdrSession(reportedID: "a", sessionID: "c"))
  }

  /// A hop cap stops on a file as dead as the first while claiming the handover was followed,
  /// and every resolve stops in the same place. The visited set bounds the walk instead:
  /// every hop lands on a listed file and no name is taken twice.
  @Test("a chain longer than four hops is still walked to its end")
  func followsALongChain() async throws {
    let names = ["a", "b", "c", "d", "e", "f"]
    let hops = zip(names, names.dropFirst())
      .map { Self.continuationLine("\($0).jsonl", to: $1) }
      .joined()
    let host = FakeHost(
      responses: [
        "date +%s": FakeHost.output(Self.listing(names.map { "\($0).jsonl" })),
        Self.continuationKey: FakeHost.output(hops),
        Self.readKey("f.jsonl"): Self.page("five handovers later"),
      ]
    )
    let reader = TranscriptReader(run: host.runner)
    let source = try #require(try await reader.resolve(for: Self.pane(session: "a")).source)
    #expect(source.file.name == "f.jsonl")
    #expect(source.provenance == .continuedFromHerdrSession(reportedID: "a", sessionID: "f"))
  }

  /// Claude Code does not write cycles, but the files are on someone's disk and cannot be
  /// assumed well-formed. The visited set bounds the walk.
  @Test("a cycle settles on one file instead of running forever")
  func cycleTerminates() async throws {
    let host = FakeHost(
      responses: [
        "date +%s": FakeHost.output(Self.listing(["a.jsonl", "b.jsonl"])),
        Self.continuationKey: FakeHost.output(
          Self.continuationLine("a.jsonl", to: "b") + Self.continuationLine("b.jsonl", to: "a")
        ),
        Self.readKey("b.jsonl"): Self.page("where the walk stopped"),
      ]
    )
    let reader = TranscriptReader(run: host.runner)
    let source = try #require(try await reader.resolve(for: Self.pane(session: "a")).source)
    // The hop out is taken, and the hop back into a visited file refused.
    #expect(source.file.name == "b.jsonl")
  }

  /// The continuation was deleted or lives elsewhere. The reported file is stale but still
  /// this pane's own; the newest file here could be another agent's.
  @Test("a pointer at a session that is not here keeps the reported file")
  func absentContinuationKeepsTheReportedFile() async throws {
    let host = FakeHost(
      responses: [
        // Two files, so the redirect is really attempted.
        "date +%s": FakeHost.output(Self.listing(["a.jsonl", "unrelated.jsonl"])),
        Self.continuationKey: FakeHost.output(
          Self.continuationLine("a.jsonl", to: "deleted")
        ),
        Self.readKey("a.jsonl"): Self.page("stale, and still this pane's"),
      ]
    )
    let reader = TranscriptReader(run: host.runner)
    let resolution = try await reader.resolve(for: Self.pane(session: "a"))
    let source = try #require(resolution.source)
    #expect(source.file.name == "a.jsonl")
    // Nothing was followed, so nothing claims it was; and the named file is here, so it is not
    // `reportedSessionMissing`.
    #expect(source.provenance == .reportedByHerdr(sessionID: "a"))
  }

  /// A host whose `continued-in` answer changes between resolves, as when a session continues
  /// while the chat is open. `PaneTranscriptModel.refresh()` re-runs the resolver, so the
  /// handover lands on the next poll.
  private actor ContinuingHost {
    private var files: [String]
    private var continuation: String
    private let body: [String: String]

    init(files: [String], body: [String: String]) {
      self.files = files
      continuation = ""
      self.body = body
    }

    func continueInto(_ file: String, from source: String, to sessionID: String) {
      files.append(file)
      continuation = TranscriptContinuationTests.continuationLine(source, to: sessionID)
    }

    private func answer(_ command: String) -> CommandResult {
      if command.contains("date +%s") {
        return FakeHost.output(TranscriptContinuationTests.listing(files))
      }
      if command.contains(TranscriptContinuationTests.continuationKey) {
        return FakeHost.output(continuation)
      }
      for (name, text) in body
      where command.contains(TranscriptContinuationTests.readKey(name)) {
        return TranscriptContinuationTests.page(text)
      }
      return CommandResult(standardOutput: "", standardError: "", exitStatus: 0)
    }

    nonisolated var runner: CommandRunner {
      { command in await self.answer(command) }
    }
  }

  @Test("a continuation written while the chat is open is followed at the next resolve")
  func followedAtTheNextResolve() async throws {
    let host = ContinuingHost(
      files: ["live.jsonl"],
      body: [
        "live.jsonl": "what was on screen when the handover happened",
        "next.jsonl": "what was said after it",
      ]
    )
    let reader = TranscriptReader(run: host.runner)
    let before = try #require(try await reader.resolve(for: Self.pane(session: "live")).source)
    #expect(before.file.name == "live.jsonl")

    await host.continueInto("next.jsonl", from: "live.jsonl", to: "next")

    let after = try #require(try await reader.resolve(for: Self.pane(session: "live")).source)
    #expect(after.file.name == "next.jsonl")
    let transcript = try await reader.read(after.file)
    #expect(transcript.lastAssistantMessage == "what was said after it")
  }
}

/// The same handover through `FakeTranscriptHost`, which drives every screen without a
/// machine. Without it the chat, tour and UI tests could only show the uncontinued case.
@Suite("FakeTranscriptHost, continued")
struct FakeContinuedTranscriptTests {
  private static let started = "3f8c1d20-0000-4000-8000-00000000038a"
  private static let carriedOn = "3f8c1d20-0000-4000-8000-00000000038b"

  private static func pane(session: String) -> Pane {
    Pane(
      id: "w7:pM",
      tabID: "w7:t1",
      workspaceID: "w7",
      title: "wiki",
      agent: Agent(
        name: "Claude",
        kind: "claude",
        status: .working,
        session: AgentSession(agent: "claude", kind: "id", value: session)
      ),
      directory: "~/wiki/site"
    )
  }

  private var host: FakeTranscriptHost {
    FakeTranscriptHost(
      sessions: [
        .init(
          sessionID: Self.started,
          turns: [
            .init(speaker: .human, text: "Check the wiki links.", secondsAgo: 40_000),
            .init(
              speaker: .assistant,
              text: "The link check is in. One report left.",
              secondsAgo: 39_000
            ),
          ],
          continuedInto: Self.carriedOn
        ),
        .init(
          sessionID: Self.carriedOn,
          turns: [
            .init(speaker: .human, text: "Carry on.", secondsAgo: 300),
            .init(speaker: .assistant, text: "The synthesis is written.", secondsAgo: 60),
          ]
        ),
      ]
    )
  }

  @Test("the chat opens on the continuation rather than on the session herdr named")
  func readsTheContinuation() async throws {
    let reader = TranscriptReader(run: host.run)
    let source = try #require(
      try await reader.resolve(for: Self.pane(session: Self.started)).source
    )
    #expect(source.file.name == "\(Self.carriedOn).jsonl")
    #expect(
      source.provenance
        == .continuedFromHerdrSession(reportedID: Self.started, sessionID: Self.carriedOn)
    )

    let transcript = try await reader.read(source.file)
    // The old file's last word would otherwise be on screen.
    #expect(transcript.lastAssistantMessage == "The synthesis is written.")
    #expect(transcript.lastHumanMessage == "Carry on.")
  }

  /// The header's age is the continuation's, not the dead file's.
  @Test("the freshness on the header belongs to the file that is on screen")
  func freshnessFollowsTheFile() async throws {
    let reader = TranscriptReader(run: host.run)
    let source = try #require(
      try await reader.resolve(for: Self.pane(session: Self.started)).source
    )
    let age = try #require(source.file.age)
    #expect(age == 60)
  }

  /// Following a handover improves an answer the resolver already holds, so a host that
  /// cannot answer the command leaves tier 1 where it was rather than failing the chat.
  /// `PaneTranscriptModel` makes the same trade with `briefs`.
  @Test("a host that cannot answer the continuation command keeps the reported file")
  func aFailedContinuationCommandIsNotAFailedChat() async throws {
    let refusing = FakeTranscriptHost(
      sessions: [
        .init(
          sessionID: Self.started,
          turns: [.init(speaker: .assistant, text: "what herdr named", secondsAgo: 30)],
          continuedInto: Self.carriedOn
        ),
        .init(
          sessionID: Self.carriedOn,
          turns: [.init(speaker: .assistant, text: "where it went", secondsAgo: 10)]
        ),
      ],
      continuationCommandFails: true
    )
    let reader = TranscriptReader(run: refusing.run)
    let source = try #require(
      try await reader.resolve(for: Self.pane(session: Self.started)).source
    )
    #expect(source.file.name == "\(Self.started).jsonl")
    #expect(source.provenance == .reportedByHerdr(sessionID: Self.started))
    // The listing and the read never failed, so the page arrives.
    let transcript = try await reader.read(source.file)
    #expect(transcript.lastAssistantMessage == "what herdr named")
  }

  /// A fixture with no `continuedInto` must resolve exactly as before.
  @Test("a fixture that was never continued still resolves the session herdr reported")
  func uncontinuedIsUnchanged() async throws {
    let plain = FakeTranscriptHost(
      sessions: [
        .init(
          sessionID: Self.started,
          turns: [.init(speaker: .assistant, text: "still here", secondsAgo: 30)]
        ),
        .init(
          sessionID: Self.carriedOn,
          turns: [.init(speaker: .assistant, text: "somebody else's", secondsAgo: 10)]
        ),
      ]
    )
    let reader = TranscriptReader(run: plain.run)
    let source = try #require(
      try await reader.resolve(for: Self.pane(session: Self.started)).source
    )
    #expect(source.file.name == "\(Self.started).jsonl")
    #expect(source.provenance == .reportedByHerdr(sessionID: Self.started))
  }
}
