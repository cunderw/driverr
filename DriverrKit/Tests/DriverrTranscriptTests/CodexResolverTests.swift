import DriverrCore
import Foundation
import Testing

@testable import DriverrTranscript

/// Which rollout is a Codex pane's, and which reader it gets. The Claude counterpart is
/// `TranscriptResolverTests`. Shared ranking, liveness and picker rules are asserted once,
/// on the Claude side.
@Suite("Codex resolver")
struct CodexResolverTests {
  /// One rollout line, as `codexListCommand` prints it.
  private static func rollout(
    path: String = "/home/me/.codex/sessions/2026/09/11/rollout-2026-09-11T16-43-31-01a0.jsonl",
    cwd: String = "/home/me/dev/driverr",
    threadSource: String = "user",
    id: String = "01a0",
    mtime: String = "1000000000",
    size: Int = 4096
  ) -> String {
    [path, cwd, threadSource, id, mtime, String(size)].joined(separator: "\t")
  }

  private static func listing(now: Int = 1_000_000_000, _ rollouts: [String]) -> String {
    ([String(now)] + rollouts).joined(separator: "\n") + "\n"
  }

  private static func pane(
    agent: Agent = Agent(name: "Codex", kind: "codex", status: .working),
    directory: String? = "/home/me/dev/driverr"
  ) -> Pane {
    Pane(
      id: "w1:p1", tabID: "w1:t1", workspaceID: "w1", title: "tower",
      agent: agent, directory: directory
    )
  }

  /// A build that sent both panes to one reader would still resolve both, off the wrong file,
  /// into a page that parses.
  @Test("a Codex pane is listed out of the rollout root, a Claude pane out of the projects root")
  func eachAgentAsksItsOwnQuestion() async throws {
    let codexHost = FakeHost(responses: [CodexRollouts.root: FakeHost.output(Self.listing([Self.rollout()]))])
    _ = try await TranscriptReader(run: codexHost.runner).resolve(for: Self.pane())
    let codexAsked = await codexHost.commands
    #expect(codexAsked.count == 1)
    #expect(codexAsked.first?.contains(CodexRollouts.root) == true)
    #expect(codexAsked.first?.contains(ClaudeProjects.root) == false)

    let claudeHost = FakeHost(
      responses: [
        "date +%s": FakeHost.output(
          HostFixture.listing(
            now: 1_000_000_000,
            directory: HostFixture.projectDirectory,
            files: [(mtime: "999999990", size: 10, name: "a1b2.jsonl")]
          ))
      ])
    _ = try await TranscriptReader(run: claudeHost.runner)
      .resolve(for: HostFixture.pane())
    let claudeAsked = await claudeHost.commands
    #expect(claudeAsked.first?.contains(ClaudeProjects.root) == true)
    #expect(claudeAsked.first?.contains(CodexRollouts.root) == false)
  }

  /// Tier 2: the rollout whose own `cwd` is this pane's, newest first.
  @Test("a rollout filed under this pane's cwd resolves, and carries the Codex reader with it")
  func matchesByWorkingDirectory() async throws {
    let host = FakeHost(
      responses: [
        CodexRollouts.root: FakeHost.output(
          Self.listing([
            Self.rollout(path: "/r/old.jsonl", id: "old", mtime: "999990000"),
            Self.rollout(path: "/r/new.jsonl", id: "new", mtime: "999999990"),
          ]))
      ])

    let resolution = try await TranscriptReader(run: host.runner).resolve(for: Self.pane())

    let source = try #require(resolution.source)
    #expect(source.file.path == "/r/new.jsonl")
    #expect(source.provenance == .matchedByDirectory)
    #expect(source.directory == "/home/me/dev/driverr")
    // The agent rides on the file, choosing the read command and parser. Wrong here, a rollout
    // would parse with Claude's parser into an empty page with no error.
    #expect(source.file.agent == .codex)
    // The host's subtraction from the clock `date +%s` printed first.
    #expect(source.file.age == 10)
  }

  /// Unrankable is reported, not resolved. Codex writes a rollout per day, so without the
  /// clock in `codexListCommand` every busy `cwd` would look like this.
  @Test("rollouts whose ages the host could not report are reported, not ranked")
  func unrankableRolloutsAreReported() async throws {
    let host = FakeHost(
      responses: [
        CodexRollouts.root: FakeHost.output(
          Self.listing([
            Self.rollout(path: "/r/a.jsonl", id: "a", mtime: "?"),
            Self.rollout(path: "/r/b.jsonl", id: "b", mtime: "?"),
          ]))
      ])

    let resolution = try await TranscriptReader(run: host.runner).resolve(for: Self.pane())

    guard case .ambiguous(let directory, let candidates) = resolution else {
      Issue.record("Expected an unrankable listing to be reported, got \(resolution)")
      return
    }
    #expect(directory == "/home/me/dev/driverr")
    #expect(candidates.count == 2)
    #expect(candidates.allSatisfy { $0.age == nil })
  }

  /// `briefCommand` `cd`s into one directory and parses `ClaudeRecord`s, but Codex
  /// candidates are filed by day under `~/.codex/sessions`, so it could only answer `[:]`.
  /// Asserted on the commands sent, because running it and discarding the answer also
  /// returns `[:]` and costs a round trip.
  @Test("an ambiguous Codex directory does not ask the host for briefs")
  func codexAmbiguityAsksForNoBriefs() async throws {
    let host = FakeHost(
      responses: [
        CodexRollouts.root: FakeHost.output(
          Self.listing([
            Self.rollout(path: "/r/a.jsonl", id: "a", mtime: "?"),
            Self.rollout(path: "/r/b.jsonl", id: "b", mtime: "?"),
          ]))
      ])
    let reader = TranscriptReader(run: host.runner)

    let resolution = try await reader.resolve(for: Self.pane())
    guard case .ambiguous(let directory, let candidates) = resolution else {
      Issue.record("Expected an ambiguous Codex directory to set this up, got \(resolution)")
      return
    }

    let found = try await reader.briefs(in: directory, for: candidates)

    #expect(found.isEmpty)
    let asked = await host.commands
    #expect(
      !asked.contains { $0.contains("FNR>") },
      "the brief command went to the host for a Codex directory it cannot answer for"
    )
    // The listing and nothing else.
    #expect(asked.count == 1)
  }

  /// The guard above is aimed at the agent, not the picker.
  @Test("an ambiguous Claude directory still asks for briefs")
  func claudeAmbiguityStillAsksForBriefs() async throws {
    let host = FakeHost(
      responses: [
        "date +%s": FakeHost.output(
          HostFixture.listing(
            now: 1_000_000_000,
            directory: HostFixture.projectDirectory,
            files: [
              (mtime: "999999999", size: 10, name: "a.jsonl"),
              (mtime: "999999999", size: 10, name: "b.jsonl"),
            ]
          ))
      ])
    let reader = TranscriptReader(run: host.runner)

    let resolution = try await reader.resolve(for: HostFixture.pane())
    guard case .ambiguous(let directory, let candidates) = resolution else {
      Issue.record("Expected two live Claude files to be ambiguous, got \(resolution)")
      return
    }

    _ = try await reader.briefs(in: directory, for: candidates)

    #expect(await host.commands.contains { $0.contains("FNR>") })
  }

  @Test("a rollout under a different cwd is not this pane's")
  func anotherDirectoryIsNotThisPanes() async throws {
    let host = FakeHost(
      responses: [
        CodexRollouts.root: FakeHost.output(
          Self.listing([Self.rollout(cwd: "/home/me/dev/somewhere-else", mtime: "999999999")]))
      ])

    let resolution = try await TranscriptReader(run: host.runner).resolve(for: Self.pane())

    #expect(resolution == .absent(.noSessionFiles(directory: "/home/me/dev/driverr")))
  }

  /// A `subagent` rollout is a collaborator Codex spawned and a `guardian_review` is its
  /// safety reviewer. Both sit in the same day directory with this pane's `cwd`, and neither
  /// is the pane's conversation. See `CodexRollouts`.
  @Test("a subagent or guardian-review rollout is never a pane's transcript")
  func onlyTheMainThreadIsAPanesOwn() async throws {
    for source in ["subagent", "guardian_review"] {
      let host = FakeHost(
        responses: [
          CodexRollouts.root: FakeHost.output(
            Self.listing([Self.rollout(threadSource: source, mtime: "999999999")]))
        ])

      let resolution = try await TranscriptReader(run: host.runner).resolve(for: Self.pane())

      #expect(
        resolution == .absent(.noSessionFiles(directory: "/home/me/dev/driverr")),
        "a \(source) thread was drawn as the pane's own conversation"
      )
    }
  }

  /// Tier 1 matches the header's `id`, which for Codex is not the filename.
  @Test("a reported session id is matched against the rollout's own id field")
  func reportedSessionMatchesTheHeaderField() async throws {
    let host = FakeHost(
      responses: [
        CodexRollouts.root: FakeHost.output(
          Self.listing([
            Self.rollout(path: "/r/newer.jsonl", id: "newer", mtime: "999999999"),
            Self.rollout(path: "/r/wanted.jsonl", id: "wanted-id", mtime: "999000000"),
          ]))
      ])
    let pane = Self.pane(
      agent: Agent(
        name: "Codex", kind: "codex", status: .working,
        session: AgentSession(agent: "codex", kind: "id", value: "wanted-id", source: "herdr:codex")
      ))

    let resolution = try await TranscriptReader(run: host.runner).resolve(for: pane)

    let source = try #require(resolution.source)
    // The older file, because herdr named it; falling back to the newest would draw whichever
    // rollout was running.
    #expect(source.file.path == "/r/wanted.jsonl")
    #expect(source.provenance == .reportedByHerdr(sessionID: "wanted-id"))
    #expect(source.file.agent == .codex)
  }

  /// `TranscriptAbsence.reportedSessionMissing`'s rule, which must hold on both arms.
  @Test("a reported session with no rollout behind it is named rather than guessed past")
  func reportedSessionMissingIsNotGuessedPast() async throws {
    let host = FakeHost(
      responses: [
        CodexRollouts.root: FakeHost.output(
          Self.listing([Self.rollout(path: "/r/other.jsonl", id: "other", mtime: "999999999")]))
      ])
    let pane = Self.pane(
      agent: Agent(
        name: "Codex", kind: "codex", status: .working,
        session: AgentSession(agent: "codex", kind: "id", value: "gone", source: "herdr:codex")
      ))

    let resolution = try await TranscriptReader(run: host.runner).resolve(for: pane)

    #expect(
      resolution
        == .absent(.reportedSessionMissing(sessionID: "gone", directory: "/home/me/dev/driverr")))
  }

  /// Same as Claude: a working Codex has had its prompt, so a missing rollout is a fault; an
  /// idle one keeps the wait. Neither names Claude.
  @Test("a Codex reported session with no rollout is a fault while working, a wait while idle")
  func aMissingRolloutFollowsTheAgentStatus() async throws {
    let host = FakeHost(
      responses: [
        CodexRollouts.root: FakeHost.output(
          Self.listing([Self.rollout(path: "/r/other.jsonl", id: "other", mtime: "999999999")]))
      ])
    let pane = Self.pane(
      agent: Agent(
        name: "Codex", kind: "codex", status: .working,
        session: AgentSession(agent: "codex", kind: "id", value: "gone", source: "herdr:codex")
      ))

    let resolution = try await TranscriptReader(run: host.runner).resolve(for: pane)
    guard case .absent(let absence) = resolution else {
      Issue.record("expected an absence, got \(resolution)")
      return
    }

    let working = TranscriptNotice(absence: absence, agentStatus: .working)
    let idle = TranscriptNotice(absence: absence, agentStatus: .idle)
    #expect(working.symbolName == "exclamationmark.triangle")
    #expect(working.title == "The session file is missing")
    #expect(idle.symbolName == "text.bubble")
    #expect(idle.title == "No session file yet")
    #expect(!working.message.contains("Claude"))
    #expect(!idle.message.contains("Claude"))
  }

  /// herdr can name an agent without slugging it. The name fallback is matched against each
  /// reader, or `"Codex CLI"` would read as `agentNotSupported`.
  @Test("an agent herdr named without slugging is matched on the name, for either reader")
  func theNameFallbackCoversBothReaders() async throws {
    let host = FakeHost(
      responses: [CodexRollouts.root: FakeHost.output(Self.listing([Self.rollout()]))])
    let pane = Self.pane(agent: Agent(name: "Codex CLI", kind: nil, status: .working))

    let resolution = try await TranscriptReader(run: host.runner).resolve(for: pane)

    #expect(resolution.source?.file.agent == .codex)
  }

  /// Codex's listing walks up to thirty day directories, and `cwd` is the only thing
  /// narrowing a root holding every project.
  @Test("a Codex pane with no directory is not worth a round trip")
  func noDirectoryCostsNothing() async throws {
    let host = FakeHost()

    let resolution = try await TranscriptReader(run: host.runner)
      .resolve(for: Self.pane(directory: nil))

    #expect(resolution == .absent(.paneHasNoDirectory))
    #expect(await host.commands.isEmpty)
  }

  /// The failure this prevents is silent.
  @Test("a Codex file is read with the Codex command and parsed with the Codex parser")
  func theReadFollowsTheFile() async throws {
    let records = [
      #"{"timestamp":"2026-09-11T16:43:31.997Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"u1","content":[{"type":"text","text":"sync the schema"}]}}}"#,
      #"{"timestamp":"2026-09-11T16:43:41.997Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"a1","content":[{"type":"Text","text":"Done."}]}}}"#,
    ].joined(separator: "\n") + "\n"
    let host = FakeHost(
      responses: [
        CodexRollouts.root: FakeHost.output(Self.listing([Self.rollout(path: "/r/one.jsonl")])),
        "tail -c": FakeHost.output("\(records.utf8.count)\tcomplete\n" + records),
      ])
    let reader = TranscriptReader(run: host.runner)

    let source = try #require(try await reader.resolve(for: Self.pane()).source)
    let transcript = try await reader.read(source.file, turns: 6)

    #expect(transcript.turns.compactMap(\.text) == ["sync the schema", "Done."])
    let read = try #require(await host.commands.last)
    // Claude's selector keeps no lines of a rollout, which arrives as zero turns, not an error.
    #expect(read.contains(TranscriptCommands.codexRecordSelector))
    #expect(!read.contains(TranscriptCommands.recordSelector))
  }
}
