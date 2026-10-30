import DriverrCore
import Foundation
import Testing

@testable import DriverrTranscript

/// A host that answers whatever the test wrote down. `CommandRunner` is a closure so these
/// run with no network, `herdr` or `~/.claude`.
actor FakeHost {
  private var responses: [String: CommandResult]
  private var fallback: CommandResult
  private(set) var commands: [String] = []

  init(
    responses: [String: CommandResult] = [:],
    fallback: CommandResult = CommandResult(standardOutput: "", standardError: "", exitStatus: 0)
  ) {
    self.responses = responses
    self.fallback = fallback
  }

  /// Matched on a substring, because the byte count grows as the reader climbs its ladder.
  func answer(_ command: String) -> CommandResult {
    commands.append(command)
    for (fragment, result) in responses where command.contains(fragment) {
      return result
    }
    return fallback
  }

  nonisolated var runner: CommandRunner {
    { command in await self.answer(command) }
  }

  static func output(_ text: String) -> CommandResult {
    CommandResult(standardOutput: text, standardError: "", exitStatus: 0)
  }
}

/// Listing lines, as the host writes them.
enum HostFixture {
  static func listing(now: Int, directory: String, files: [(mtime: String, size: Int, name: String)])
    -> String
  {
    ([String(now), directory] + files.map { "\($0.mtime)\t\($0.size)\t\($0.name)" })
      .joined(separator: "\n") + "\n"
  }

  static func read(size: Int, endsMidRecord: Bool = false, body: String) -> String {
    "\(size)\t\(endsMidRecord ? "partial" : "complete")\n" + body
  }

  static let projectDirectory = "/home/me/.claude/projects/-home-me-dev-driverr"

  static func pane(
    agent: Agent? = Agent(name: "Claude", kind: "claude", status: .working),
    directory: String? = "/home/me/dev/driverr"
  ) -> Pane {
    Pane(
      id: "w1:p1",
      tabID: "w1:t1",
      workspaceID: "w1",
      title: "driverr",
      agent: agent,
      directory: directory
    )
  }
}

struct TranscriptResolverTests {
  @Test("a shell pane has no transcript, and that is not a failure")
  func shellPane() async throws {
    let host = FakeHost()
    let resolution = try await TranscriptReader(run: host.runner)
      .resolve(for: HostFixture.pane(agent: nil))
    #expect(resolution == .absent(.paneHasNoAgent))
    // A shell cannot have a Claude session, so no round trip is spent.
    #expect(await host.commands.isEmpty)
  }

  /// A pane running an agent with no reader, in a directory Claude also worked in, must not
  /// draw a Claude session. Any unreadable agent will do; `CodexResolverTests`
  /// covers the agents with readers.
  @Test("an agent this build cannot read is named, not guessed at")
  func unsupportedAgent() async throws {
    let host = FakeHost()
    let resolution = try await TranscriptReader(run: host.runner)
      .resolve(for: HostFixture.pane(agent: Agent(name: "Gemini", kind: "gemini", status: .idle)))
    #expect(resolution == .absent(.agentNotSupported(agent: "Gemini")))
    #expect(await host.commands.isEmpty)
  }

  /// What a core gives an agent whose files are not on this host. The token has to stop the
  /// name match, or `Claude` on another machine would read this host's sessions.
  @Test("the unknown token reads nothing, whatever the agent is called")
  func unknownToken() async throws {
    let host = FakeHost()
    let resolution = try await TranscriptReader(run: host.runner)
      .resolve(for: HostFixture.pane(agent: Agent(name: "Claude", kind: "unknown", status: .idle)))
    #expect(resolution == .absent(.agentNotSupported(agent: "Claude")))
    #expect(await host.commands.isEmpty)
  }

  @Test("an agent herdr named without slugging is matched on the name")
  func agentWithoutASlug() async throws {
    let host = FakeHost(
      responses: [
        "date +%s": FakeHost.output(
          HostFixture.listing(
            now: 1_000_000,
            directory: HostFixture.projectDirectory,
            files: [("999995", 400, "a.jsonl")]
          )
        )
      ]
    )
    let resolution = try await TranscriptReader(run: host.runner)
      .resolve(for: HostFixture.pane(agent: Agent(name: "Claude Code", status: .idle)))
    #expect(resolution.source != nil)
  }

  @Test("a pane with no working directory has nothing to derive from")
  func noDirectory() async throws {
    let host = FakeHost()
    let resolution = try await TranscriptReader(run: host.runner)
      .resolve(for: HostFixture.pane(directory: nil))
    #expect(resolution == .absent(.paneHasNoDirectory))
  }

  @Test("an empty project directory is 'no transcript here'")
  func noSessionFiles() async throws {
    let host = FakeHost(
      responses: [
        "date +%s": FakeHost.output(
          HostFixture.listing(now: 1_000_000, directory: HostFixture.projectDirectory, files: [])
        )
      ]
    )
    let resolution = try await TranscriptReader(run: host.runner).resolve(for: HostFixture.pane())
    #expect(resolution == .absent(.noSessionFiles(directory: "/home/me/dev/driverr")))
  }

  /// herdr reports a new session before its first record, so the directory may hold no file
  /// or not exist. Both list the same (see `EmptyGlobCommandTests`) and both are waiting.
  @Test("a reported session in a directory with no session file yet is waiting, not missing")
  func reportedSessionNotWrittenYet() async throws {
    let host = FakeHost(
      responses: [
        "date +%s": FakeHost.output(
          HostFixture.listing(now: 1_000_000, directory: HostFixture.projectDirectory, files: [])
        )
      ]
    )
    let pane = HostFixture.pane(
      agent: Agent(
        name: "Claude",
        kind: "claude",
        status: .working,
        session: AgentSession(agent: "claude", kind: "id", value: "new-session")
      )
    )
    let resolution = try await TranscriptReader(run: host.runner).resolve(for: pane)
    #expect(resolution == .absent(.noSessionFiles(directory: "/home/me/dev/driverr")))
  }

  @Test("herdr's own session id wins, with no heuristic in sight")
  func tierOne() async throws {
    let host = FakeHost(
      responses: [
        "date +%s": FakeHost.output(
          HostFixture.listing(
            now: 1_000_000,
            directory: HostFixture.projectDirectory,
            files: [
              ("999_999".replacingOccurrences(of: "_", with: ""), 100, "newer.jsonl"),
              ("999000", 4096, "wanted.jsonl"),
            ]
          )
        )
      ]
    )
    let pane = HostFixture.pane(
      agent: Agent(
        name: "Claude",
        kind: "claude",
        status: .working,
        session: AgentSession(agent: "claude", kind: "id", value: "wanted", source: "herdr:claude")
      )
    )
    let resolution = try await TranscriptReader(run: host.runner).resolve(for: pane)
    let source = try #require(resolution.source)
    // The older file, because herdr named it; a heuristic would take the newer.
    #expect(source.file.name == "wanted.jsonl")
    #expect(source.file.path == "\(HostFixture.projectDirectory)/wanted.jsonl")
    #expect(source.provenance == .reportedByHerdr(sessionID: "wanted"))
  }

  /// A session id not in this directory means the directory is not this session's.
  @Test("a reported session that is not here does not fall back to the newest")
  func reportedSessionMissing() async throws {
    let host = FakeHost(
      responses: [
        "date +%s": FakeHost.output(
          HostFixture.listing(
            now: 1_000_000,
            directory: HostFixture.projectDirectory,
            files: [("999999", 100, "someone-else.jsonl")]
          )
        )
      ]
    )
    let pane = HostFixture.pane(
      agent: Agent(
        name: "Claude",
        kind: "claude",
        status: .working,
        session: AgentSession(agent: "claude", kind: "id", value: "gone")
      )
    )
    let resolution = try await TranscriptReader(run: host.runner).resolve(for: pane)
    #expect(
      resolution
        == .absent(.reportedSessionMissing(sessionID: "gone", directory: "/home/me/dev/driverr"))
    )
  }

  /// What a herdr-core terminal's pane carries. See `CoreSessionFiles`.
  private func corePane(session: String) -> Pane {
    HostFixture.pane(
      agent: Agent(
        name: "Claude",
        kind: "claude",
        status: .working,
        session: AgentSession(
          agent: "claude", kind: "id", value: session, source: "claude:sessions")
      )
    )
  }

  @Test("two Claude sessions writing in one folder each open their own file")
  func twoSessionsOneFolder() async throws {
    let host = FakeHost(
      responses: [
        "date +%s": FakeHost.output(
          HostFixture.listing(
            now: 1_000_000,
            directory: HostFixture.projectDirectory,
            files: [("999999", 100, "first.jsonl"), ("999998", 200, "second.jsonl")]
          )
        )
      ]
    )
    let reader = TranscriptReader(run: host.runner)
    for name in ["first", "second"] {
      let source = try await reader.resolve(for: corePane(session: name)).source
      #expect(source?.file.name == "\(name).jsonl")
      #expect(source?.provenance == .reportedByHerdr(sessionID: name))
    }
  }

  /// A new session is named before its file exists, and three of five live records measured
  /// on a real core had no transcript yet. The newest file is another conversation.
  @Test("a record whose transcript is not written yet stays missing, among live files")
  func recordWithNoTranscript() async throws {
    let host = FakeHost(
      responses: [
        "date +%s": FakeHost.output(
          HostFixture.listing(
            now: 1_000_000,
            directory: HostFixture.projectDirectory,
            files: [("999999", 100, "someone-else.jsonl")]
          )
        )
      ]
    )
    let resolution = try await TranscriptReader(run: host.runner)
      .resolve(for: corePane(session: "not-written"))
    #expect(
      resolution
        == .absent(
          .reportedSessionMissing(sessionID: "not-written", directory: "/home/me/dev/driverr"))
    )
  }

  /// The reader lists the SSH host's files, so anything past this reads the wrong machine.
  @Test("an agent on an added machine is refused before any file is listed")
  func addedMachine() async throws {
    let host = FakeHost()
    let pane = HostFixture.pane(
      agent: Agent(name: "Claude", kind: "unknown", status: .working, machine: "box"))
    let resolution = try await TranscriptReader(run: host.runner).resolve(for: pane)
    #expect(resolution == .absent(.agentOnAddedMachine(agent: "Claude", machine: "box")))
    #expect(await host.commands.isEmpty)
  }

  @Test("a session reference of a kind this build does not understand falls back to the directory")
  func unknownSessionKind() async throws {
    let host = FakeHost(
      responses: [
        "date +%s": FakeHost.output(
          HostFixture.listing(
            now: 1_000_000,
            directory: HostFixture.projectDirectory,
            files: [("999999", 100, "only.jsonl")]
          )
        )
      ]
    )
    let pane = HostFixture.pane(
      agent: Agent(
        name: "Claude",
        kind: "claude",
        status: .working,
        session: AgentSession(agent: "claude", kind: "path", value: "/somewhere/else")
      )
    )
    let resolution = try await TranscriptReader(run: host.runner).resolve(for: pane)
    #expect(resolution.source?.provenance == .matchedByDirectory)
  }

  @Test("the newest file wins, and names its evidence")
  func tierTwo() async throws {
    let host = FakeHost(
      responses: [
        "date +%s": FakeHost.output(
          HostFixture.listing(
            now: 1_000_000,
            directory: HostFixture.projectDirectory,
            files: [
              ("900000", 10, "ancient.jsonl"),
              ("999_988".replacingOccurrences(of: "_", with: ""), 4096, "live.jsonl"),
              ("990000", 20, "old.jsonl"),
            ]
          )
        )
      ]
    )
    let resolution = try await TranscriptReader(run: host.runner).resolve(for: HostFixture.pane())
    let source = try #require(resolution.source)
    #expect(source.file.name == "live.jsonl")
    #expect(source.provenance == .matchedByDirectory)
    // The two halves of a tier-2 header's evidence.
    #expect(source.directory == "/home/me/dev/driverr")
    #expect(source.file.age == 12)
    #expect(source.file.sizeInBytes == 4096)
  }

  @Test("sixteen old files and one live one is not ambiguous")
  func onlyOneLive() async throws {
    let old = (0..<16).map { (mtime: "\(900_000 + $0)", size: 10, name: "old\($0).jsonl") }
    let host = FakeHost(
      responses: [
        "date +%s": FakeHost.output(
          HostFixture.listing(
            now: 1_000_000,
            directory: HostFixture.projectDirectory,
            files: old + [("999990", 4096, "live.jsonl")]
          )
        )
      ]
    )
    let resolution = try await TranscriptReader(run: host.runner).resolve(for: HostFixture.pane())
    #expect(resolution.source?.file.name == "live.jsonl")
  }

  /// The heuristic's one failure mode, made detectable rather than silent.
  @Test("two sessions written in the last minute is reported, never picked between")
  func ambiguous() async throws {
    let host = FakeHost(
      responses: [
        "date +%s": FakeHost.output(
          HostFixture.listing(
            now: 1_000_000,
            directory: HostFixture.projectDirectory,
            files: [
              ("999990", 100, "mine.jsonl"),
              ("999995", 200, "theirs.jsonl"),
              ("900000", 300, "ancient.jsonl"),
            ]
          )
        )
      ]
    )
    let resolution = try await TranscriptReader(run: host.runner).resolve(for: HostFixture.pane())
    guard case .ambiguous(let directory, let candidates) = resolution else {
      Issue.record("expected ambiguity, got \(resolution)")
      return
    }
    #expect(directory == "/home/me/dev/driverr")
    // Every file, newest first; the screen counts live ones by the resolver's rule.
    #expect(candidates.map(\.name) == ["theirs.jsonl", "mine.jsonl", "ancient.jsonl"])
    #expect(candidates.filter(\.isLive).count == 2)
  }

  @Test("an age the host could not report makes a directory unrankable, not resolvable")
  func unreadableMtimes() async throws {
    let host = FakeHost(
      responses: [
        "date +%s": FakeHost.output(
          HostFixture.listing(
            now: 1_000_000,
            directory: HostFixture.projectDirectory,
            files: [("?", 100, "one.jsonl"), ("?", 200, "two.jsonl")]
          )
        )
      ]
    )
    let resolution = try await TranscriptReader(run: host.runner).resolve(for: HostFixture.pane())
    guard case .ambiguous(_, let candidates) = resolution else {
      Issue.record("expected ambiguity, got \(resolution)")
      return
    }
    #expect(candidates.allSatisfy { $0.age == nil })
    #expect(candidates.allSatisfy { !$0.isLive })
  }

  @Test("one file whose age is unknown still resolves — there is nothing to confuse it with")
  func singleUnreadableMtime() async throws {
    let host = FakeHost(
      responses: [
        "date +%s": FakeHost.output(
          HostFixture.listing(
            now: 1_000_000,
            directory: HostFixture.projectDirectory,
            files: [("?", 100, "only.jsonl")]
          )
        )
      ]
    )
    let resolution = try await TranscriptReader(run: host.runner).resolve(for: HostFixture.pane())
    #expect(resolution.source?.file.name == "only.jsonl")
    #expect(resolution.source?.file.age == nil)
  }

  /// `TimeInterval("…")` accepts `inf` and `nan`, which would make an unrankable directory
  /// rankable.
  @Test("only a plain run of digits is an mtime")
  func epochIsStrict() {
    #expect(TranscriptReader.epoch("1787780603") == 1_787_780_603)
    for rubbish in ["?", "", "/", "/mnt/data2", "inf", "nan", "1e9", "-5", " 12", "12.5"] {
      #expect(TranscriptReader.epoch(rubbish) == nil, "\(rubbish) was read as an mtime")
    }
  }

  /// A mount point read as an epoch would be a very old file resolved with confidence.
  @Test("a mount path where an mtime should be is read as no mtime at all")
  func mountPointInsteadOfMtime() async throws {
    // `/mnt/data2`, not `/`, because a bare slash fails any check. GNU `stat -f %m` prints this
    // for sessions off the root filesystem.
    let host = FakeHost(
      responses: [
        "date +%s": FakeHost.output(
          HostFixture.listing(
            now: 1_000_000,
            directory: HostFixture.projectDirectory,
            files: [("/mnt/data2", 100, "one.jsonl")]
          )
        )
      ]
    )
    let resolution = try await TranscriptReader(run: host.runner).resolve(for: HostFixture.pane())
    #expect(resolution.source?.file.age == nil)
  }

  @Test("a file written the same second the listing ran is not in the future")
  func clockSkewWithinTheHost() async throws {
    let host = FakeHost(
      responses: [
        "date +%s": FakeHost.output(
          HostFixture.listing(
            now: 1_000_000,
            directory: HostFixture.projectDirectory,
            files: [("1000001", 100, "only.jsonl")]
          )
        )
      ]
    )
    let resolution = try await TranscriptReader(run: host.runner).resolve(for: HostFixture.pane())
    #expect(resolution.source?.file.age == 0)
  }

  /// The age stays a host-side subtraction, so a phone clock that disagrees cannot make a
  /// live session stale. The device adds only when it asked, so the header can advance.
  @Test("a resolved source records when the device asked, so its age can advance")
  func resolvedSourceRecordsWhenItWasRead() async throws {
    let host = FakeHost(
      responses: [
        "date +%s": FakeHost.output(
          HostFixture.listing(
            now: 1_000_000,
            directory: HostFixture.projectDirectory,
            files: [("999988", 400, "only.jsonl")]
          )
        )
      ]
    )
    let askedAt = Date(timeIntervalSince1970: 1_800_000_000)

    let resolution = try await TranscriptReader(run: host.runner, now: { askedAt })
      .resolve(for: HostFixture.pane())

    #expect(resolution.source?.readAt == askedAt)
    // 1_000_000 - 999_988 on the host's clock.
    #expect(resolution.source?.file.age == 12)
    #expect(resolution.source?.modifiedAt == askedAt.addingTimeInterval(-12))
  }
}

/// The growth check. It runs every few seconds, so its parse is as strict as the listing's;
/// a lenient one re-reads the whole page repeatedly.
struct TranscriptProbeTests {
  private func file() -> TranscriptFile {
    TranscriptFile(path: "\(HostFixture.projectDirectory)/s.jsonl", sizeInBytes: 4096, age: 3)
  }

  @Test("a probe reads the host's two fields back")
  func readsBothFields() async throws {
    let host = FakeHost(fallback: FakeHost.output("1787780591\t541536\n"))

    let stamp = try await TranscriptReader(run: host.runner).probe(file())

    #expect(stamp == TranscriptStamp(modified: 1_787_780_591, sizeInBytes: 541_536))
    let commands = await host.commands
    #expect(commands == [TranscriptCommands.sizeCommand(path: file().path)])
  }

  /// A file that has gone is an answer, read off the marks rather than an exit status.
  @Test("a file the host cannot stat answers with nothing rather than throwing")
  func missingFileIsNil() async throws {
    let host = FakeHost(fallback: FakeHost.output("?\t?\n"))

    #expect(try await TranscriptReader(run: host.runner).probe(file()) == nil)
  }

  /// `stat -f %m` on Linux prints a mount point; without the digit check every tick compares
  /// nonsense silently.
  @Test("a mount point where an mtime belongs is refused")
  func aPathIsNotAnMtime() async throws {
    let host = FakeHost(fallback: FakeHost.output("/mnt/data2\t541536\n"))

    #expect(try await TranscriptReader(run: host.runner).probe(file()) == nil)
  }

  /// `Int("-1")` succeeds, and a negative size would re-read the page every tick.
  @Test("a size that is not digits is refused")
  func aSignedSizeIsNotASize() async throws {
    let host = FakeHost(fallback: FakeHost.output("1787780591\t-1\n"))

    #expect(try await TranscriptReader(run: host.runner).probe(file()) == nil)
  }

  /// A refused command is a channel failure, not a missing file, so it throws rather than
  /// answering nil.
  @Test("a host that refuses the command throws rather than answering nothing")
  func aRefusalThrows() async {
    let host = FakeHost(
      fallback: CommandResult(standardOutput: "", standardError: "boom", exitStatus: 1))

    await #expect(throws: AppError.self) {
      try await TranscriptReader(run: host.runner).probe(file())
    }
  }

  private func reporting(_ id: String, kind: String = "claude") -> Pane {
    HostFixture.pane(
      agent: Agent(
        name: "Claude",
        kind: kind,
        status: .idle,
        session: AgentSession(agent: kind, kind: "id", value: id, source: "herdr:\(kind)")))
  }

  /// The file herdr named before the agent wrote it is probed by name, with no listing.
  @Test("a reported session's file is probed by name, in one command")
  func probesTheReportedFileByName() async throws {
    let host = FakeHost(fallback: FakeHost.output("1787780591\t812\n"))

    let stamp = try await TranscriptReader(run: host.runner)
      .probeReportedSession(for: reporting("new"))

    #expect(stamp == TranscriptStamp(modified: 1_787_780_591, sizeInBytes: 812))
    let commands = await host.commands
    #expect(
      commands == [
        TranscriptCommands.reportedSizeCommand(projectSlug: "-home-me-dev-driverr", sessionID: "new")
      ])
  }

  @Test("a reported session with no file yet answers nothing")
  func aReportedFileNotWrittenYetIsNil() async throws {
    let host = FakeHost(fallback: FakeHost.output("?\t?\n"))

    #expect(
      try await TranscriptReader(run: host.runner).probeReportedSession(for: reporting("new"))
        == nil)
  }

  /// A Codex rollout is named after its start time, so no path can be built from the id.
  @Test("a pane with nothing to name by id sends no command")
  func nothingToNameSendsNothing() async throws {
    let host = FakeHost(fallback: FakeHost.output("1787780591\t812\n"))
    let reader = TranscriptReader(run: host.runner)

    #expect(try await reader.probeReportedSession(for: reporting("new", kind: "codex")) == nil)
    #expect(try await reader.probeReportedSession(for: HostFixture.pane()) == nil)
    #expect(try await reader.probeReportedSession(for: HostFixture.pane(directory: nil)) == nil)
    let commands = await host.commands
    #expect(commands.isEmpty)
  }

  /// The re-resolve would never match, so the directory would be re-listed every tick. A `/`
  /// names another directory, and the listing trims whitespace from names.
  @Test(
    "an id resolve could never match is not probed", arguments: ["../other/new", " new", "new\n"])
  func anUnmatchableIDSendsNothing(id: String) async throws {
    let host = FakeHost(fallback: FakeHost.output("1787780591\t812\n"))

    #expect(
      try await TranscriptReader(run: host.runner).probeReportedSession(for: reporting(id)) == nil)
    let commands = await host.commands
    #expect(commands.isEmpty)
  }
}

struct TranscriptReadTests {
  private func file(size: Int = 4096) -> TranscriptFile {
    TranscriptFile(path: "\(HostFixture.projectDirectory)/s.jsonl", sizeInBytes: size, age: 3)
  }

  @Test("a page of turns, and the bill for it")
  func page() async throws {
    let body = [
      Fixture.human("go"),
      Fixture.toolUse("Read", id: "t1", uuid: "x1"),
      Fixture.assistant("done"),
    ].joined(separator: "\n") + "\n"
    let host = FakeHost(
      responses: ["tail -c": FakeHost.output(HostFixture.read(size: 900_000, body: body))]
    )
    let transcript = try await TranscriptReader(run: host.runner).read(file(), turns: 3)
    #expect(transcript.outcome == .parsed)
    #expect(transcript.turns.count == 3)
    #expect(transcript.lastAssistantMessage == "done")
    #expect(transcript.lastHumanMessage == "go")
    #expect(transcript.window.bytesFetched == body.utf8.count)
    #expect(transcript.window.fileSizeInBytes == 900_000)
    #expect(transcript.window.records == 3)
    #expect(transcript.window.reachesStartOfFile == false)
  }

  @Test("a file that ends mid-record shows what parsed and names the tail")
  func endsMidRecord() async throws {
    let body = Fixture.assistant("this much parsed") + "\n" + #"{"type":"assistant","uuid":"#
    let host = FakeHost(
      responses: [
        "tail -c": FakeHost.output(HostFixture.read(size: 4096, endsMidRecord: true, body: body))
      ]
    )
    let transcript = try await TranscriptReader(run: host.runner).read(file(), turns: 1)
    #expect(transcript.outcome == .endsMidRecord)
    #expect(transcript.turns.map(\.text) == ["this much parsed"])
    #expect(transcript.window.unreadableRecords == 1)
  }

  @Test("a file with nothing conversational in it says so rather than showing an empty chat")
  func parsesToNothing() async throws {
    let body = [Fixture.bookkeeping(), Fixture.bookkeeping("mode")].joined(separator: "\n") + "\n"
    let host = FakeHost(
      responses: ["tail -c": FakeHost.output(HostFixture.read(size: 200, body: body))]
    )
    let transcript = try await TranscriptReader(run: host.runner).read(file(size: 200), turns: 6)
    #expect(transcript.outcome == .noReadableTurns)
    #expect(transcript.turns.isEmpty)
    #expect(transcript.window.records == 2)
  }

  @Test("nothing at all in the file is 'no readable turns', not a crash")
  func emptyFile() async throws {
    let host = FakeHost(
      responses: ["tail -c": FakeHost.output(HostFixture.read(size: 0, body: ""))]
    )
    let transcript = try await TranscriptReader(run: host.runner).read(file(size: 0))
    #expect(transcript.outcome == .noReadableTurns)
    #expect(transcript.window.reachesStartOfFile)
  }

  @Test("a file that has gone is an error, not an empty conversation")
  func missingFile() async throws {
    let host = FakeHost(
      responses: ["tail -c": FakeHost.output("?\tcomplete\n")]
    )
    await #expect(throws: AppError.self) {
      _ = try await TranscriptReader(run: host.runner).read(file())
    }
  }

  @Test("a host that could not run the command at all is an error")
  func hostRefused() async throws {
    let host = FakeHost(
      fallback: CommandResult(standardOutput: "", standardError: "sh: tail: not found", exitStatus: 127)
    )
    await #expect(throws: AppError.transcriptUnreadable(reason: "sh: tail: not found")) {
      _ = try await TranscriptReader(run: host.runner).read(file())
    }
  }

  /// A page can be large in bytes and nearly empty in turns, because forty tool calls are one
  /// turn.
  @Test("too few turns grows the window, and stops the moment there are enough")
  func growsUntilEnough() async throws {
    let host = GrowingHost()
    let transcript = try await TranscriptReader(run: host.runner).read(file(size: 10_000_000), turns: 3)
    #expect(transcript.turns.count >= 3)
    #expect(await host.commands.count == 2)
  }

  @Test("reaching the start of the file stops the ladder rather than climbing it")
  func stopsAtTheStartOfTheFile() async throws {
    let body = Fixture.assistant("all there is") + "\n"
    let host = FakeHost(
      responses: ["tail -c": FakeHost.output(HostFixture.read(size: 80, body: body))]
    )
    let transcript = try await TranscriptReader(run: host.runner).read(file(size: 80), turns: 20)
    #expect(transcript.turns.count == 1)
    #expect(transcript.window.reachesStartOfFile)
    #expect(await host.commands.count == 1)
  }

  @Test("the whole file read, but records cut off the top, is not the start of the file")
  func recordBoundHidesTheStart() async throws {
    // Every record the bound allowed came back, so there may be more above.
    let body = (0..<60).map { Fixture.assistant("m\($0)", uuid: "a\($0)") }
      .joined(separator: "\n") + "\n"
    let host = FakeHost(
      responses: ["tail -c": FakeHost.output(HostFixture.read(size: 10, body: body))]
    )
    let transcript = try await TranscriptReader(run: host.runner).read(file(size: 10), turns: 6)
    #expect(transcript.window.reachesStartOfFile == false)
  }

  @Test("the ladder is sized from the turns asked for")
  func ladderScalesWithTheAsk() {
    #expect(TranscriptReader.ladder(forTurns: 6).first?.records == 60)
    #expect(TranscriptReader.ladder(forTurns: 40).first?.records == 240)
    let ladder = TranscriptReader.ladder(forTurns: 6)
    #expect(ladder.count == 6)
    #expect(ladder.map(\.records) == [60, 240, 960, 3840, 15360, 61440])
    // The last two rungs are a reserve, climbed only while the rung before bought turns.
    #expect(TranscriptReader.baseRungs == 4)
    // Bytes are read on the host and free; records cross the wire. The byte window is generous
    // so the record bound does the work.
    #expect(ladder.allSatisfy { $0.bytes == $0.records * 4096 })
  }

  /// The four base rungs top out at 15.7 MB for a six-turn ask, and a dense file hits that
  /// short of the ask. The reserve serves a page still gaining turns, and the flag says when
  /// the climb ended short. The fixture must exceed the top rung's window (251 MB for six
  /// turns, 503 MB for twenty), or the file reaches its own front, which is a different case.
  @Test("a rung that keeps gaining turns is allowed two more")
  func climbsPastTheBaseRungsWhileGaining() async throws {
    let host = DenseHost(turnsPerRung: [1, 2, 3, 4, 5, 6], fileSizeInBytes: 600_000_000)
    let transcript = try await TranscriptReader(run: host.runner)
      .read(file(size: 600_000_000), turns: 20)
    #expect(await host.commands.count == 6)
    #expect(transcript.turns.count == 6)
    #expect(transcript.window.reachesStartOfFile == false)
    #expect(transcript.window.stoppedShort)
  }

  @Test("a rung that bought nothing ends the climb rather than spending the reserve")
  func stopsClimbingWhenARungGainsNothing() async throws {
    let host = DenseHost(turnsPerRung: [2, 2, 2, 2, 2, 2], fileSizeInBytes: 300_000_000)
    let transcript = try await TranscriptReader(run: host.runner)
      .read(file(size: 300_000_000), turns: 20)
    // The fourth rung bought nothing, so the reserve would be two wasted round trips.
    #expect(await host.commands.count == 4)
    #expect(transcript.turns.count == 2)
    #expect(transcript.window.stoppedShort)
  }

  @Test("a page that got the turns it was asked for did not stop short")
  func enoughTurnsIsNotStoppingShort() async throws {
    let host = DenseHost(turnsPerRung: [1, 4, 9, 9, 9, 9], fileSizeInBytes: 20_000_000)
    let transcript = try await TranscriptReader(run: host.runner)
      .read(file(size: 20_000_000), turns: 3)
    #expect(transcript.turns.count >= 3)
    #expect(transcript.window.stoppedShort == false)
  }

  @Test("a short page that reached the start of the file did not stop short")
  func theStartOfTheFileIsNotStoppingShort() async throws {
    let body = Fixture.assistant("all there is") + "\n"
    let host = FakeHost(
      responses: ["tail -c": FakeHost.output(HostFixture.read(size: 80, body: body))]
    )
    let transcript = try await TranscriptReader(run: host.runner).read(file(size: 80), turns: 20)
    #expect(transcript.window.reachesStartOfFile)
    #expect(transcript.window.stoppedShort == false)
  }
}

/// A file so dense that the byte window never reaches its front. Each rung answers with
/// the test's turn count, and the header size sits above the top rung.
actor DenseHost {
  private let turnsPerRung: [Int]
  private let fileSizeInBytes: Int
  private(set) var commands: [String] = []

  init(turnsPerRung: [Int], fileSizeInBytes: Int) {
    self.turnsPerRung = turnsPerRung
    self.fileSizeInBytes = fileSizeInBytes
  }

  func answer(_ command: String) -> CommandResult {
    commands.append(command)
    let turns = turnsPerRung[min(commands.count - 1, turnsPerRung.count - 1)]
    let body = (0..<turns).map { Fixture.assistant("m\($0)", uuid: "a\($0)") }
      .joined(separator: "\n") + "\n"
    return FakeHost.output(HostFixture.read(size: fileSizeInBytes, body: body))
  }

  nonisolated var runner: CommandRunner {
    { command in await self.answer(command) }
  }
}

/// `TranscriptReader.subagentFile` against a raw `FakeHost`: the command it sends and its
/// reuse of `listing(from:)`.
struct TranscriptSubagentLinkTests {
  private let directory = "/home/me/.claude/projects/-home-me-dev-driverr"
  private let sessionID = "3f8c1d20-0000-4000-8000-000000000002"

  @Test("a spawn's tool-use id links to its own sub-agent file")
  func linksByToolUseID() async throws {
    let host = FakeHost(
      responses: [
        "grep -rlF": FakeHost.output(
          HostFixture.listing(
            now: 1_000_000,
            directory: "\(directory)/\(sessionID)/subagents",
            files: [("999000", 4096, "agent-a1.jsonl")]
          )
        )
      ]
    )
    let file = try await TranscriptReader(run: host.runner).subagentFile(
      toolUseID: "toolu_abc", directory: directory, sessionID: sessionID
    )
    #expect(file?.name == "agent-a1.jsonl")
    #expect(file?.isSubagentFile == true)
    let sent = try #require(await host.commands.first)
    #expect(sent.contains(#""toolUseId":"toolu_abc""#))
  }

  /// The id is unique, and a spawn made before a `continued-in` handover can have its meta
  /// under the old session.
  @Test("a tool-use id is searched for project-wide and found under another session")
  func toolUseIDIsProjectWide() async throws {
    let host = FakeHost(
      responses: [
        "grep -rlF": FakeHost.output(
          HostFixture.listing(
            now: 1_000_000,
            directory: directory,
            files: [("999000", 4096, "old-session/subagents/agent-aold.jsonl")]
          )
        )
      ]
    )
    let file = try await TranscriptReader(run: host.runner).subagentFile(
      toolUseID: "toolu_before_handover", directory: directory, sessionID: sessionID
    )
    #expect(file?.path == "\(directory)/old-session/subagents/agent-aold.jsonl")
    #expect(file?.isSubagentFile == true)
    let sent = try #require(await host.commands.first)
    #expect(sent.contains("grep -rlF"))
    #expect(sent.contains("--include='*.meta.json'"))
    #expect(!sent.contains("\(sessionID)/subagents"))
  }

  /// A name is unique only within one session.
  @Test("a teammate is searched for under its own session only")
  func teammateIsSessionScoped() async throws {
    let host = FakeHost(
      responses: [
        "grep -lF": FakeHost.output(
          HostFixture.listing(
            now: 1_000_000, directory: "\(directory)/\(sessionID)/subagents",
            files: [("999000", 4096, "agent-aver.jsonl")]
          )
        )
      ]
    )
    _ = try await TranscriptReader(run: host.runner).subagentFile(
      teammateName: "ver-7", directory: directory, sessionID: sessionID
    )
    let sent = try #require(await host.commands.first)
    #expect(sent.contains("\(directory)/\(sessionID)/subagents"))
    #expect(!sent.contains("grep -r"))
  }

  @Test("a teammate with no tool-use id links by name")
  func linksByName() async throws {
    let host = FakeHost(
      responses: [
        "grep -lF": FakeHost.output(
          HostFixture.listing(
            now: 1_000_000, directory: "\(directory)/\(sessionID)/subagents",
            files: [("999000", 4096, "agent-aver.jsonl")]
          )
        )
      ]
    )
    let file = try await TranscriptReader(run: host.runner).subagentFile(
      teammateName: "ver-7", directory: directory, sessionID: sessionID
    )
    #expect(file?.name == "agent-aver.jsonl")
    let sent = try #require(await host.commands.first)
    #expect(sent.contains(#""name":"ver-7""#))
  }

  /// `newestFirst` ranks; this proves the host's two ages reach it.
  @Test("of two files linked by the same name, the newest wins")
  func newestNameWins() async throws {
    let host = FakeHost(
      responses: [
        "grep -lF": FakeHost.output(
          HostFixture.listing(
            now: 1_000_000, directory: "\(directory)/\(sessionID)/subagents",
            files: [
              ("500000", 10, "agent-old.jsonl"),
              ("999900", 4096, "agent-new.jsonl"),
            ]
          )
        )
      ]
    )
    let file = try await TranscriptReader(run: host.runner).subagentFile(
      teammateName: "ver-7", directory: directory, sessionID: sessionID
    )
    #expect(file?.name == "agent-new.jsonl")
  }

  @Test("no match in the directory is a clear absence, not a crash")
  func noMatchIsNotFound() async throws {
    let host = FakeHost(
      responses: [
        "grep -rlF": FakeHost.output(
          HostFixture.listing(now: 1_000_000, directory: "\(directory)/\(sessionID)/subagents", files: [])
        )
      ]
    )
    let file = try await TranscriptReader(run: host.runner).subagentFile(
      toolUseID: "toolu_absent", directory: directory, sessionID: sessionID
    )
    #expect(file == nil)
  }

  @Test("neither a tool-use id nor a name sends no command at all")
  func neitherArgumentSendsNothing() async throws {
    let host = FakeHost()
    let file = try await TranscriptReader(run: host.runner).subagentFile(
      directory: directory, sessionID: sessionID
    )
    #expect(file == nil)
    #expect(await host.commands.isEmpty)
  }

  /// `grep -F -e` reads each line of the pattern as its own pattern, so a name like
  /// `"nobody\n318"` would match either fragment. No command is sent.
  @Test("a name or id carrying a newline is refused, not searched for")
  func aNewlineInTheLiteralIsRefused() async throws {
    let host = FakeHost(
      responses: [
        "grep -lF": FakeHost.output(
          HostFixture.listing(
            now: 1_000_000, directory: "\(directory)/\(sessionID)/subagents",
            files: [("999000", 4096, "agent-wrong.jsonl")]
          )
        )
      ]
    )
    let byName = try await TranscriptReader(run: host.runner).subagentFile(
      teammateName: "nobody\n318", directory: directory, sessionID: sessionID
    )
    let byID = try await TranscriptReader(run: host.runner).subagentFile(
      toolUseID: "toolu\nabc", directory: directory, sessionID: sessionID
    )
    let byQuote = try await TranscriptReader(run: host.runner).subagentFile(
      teammateName: #"rev"318"#, directory: directory, sessionID: sessionID
    )
    #expect(byName == nil)
    #expect(byID == nil)
    #expect(byQuote == nil)
    #expect(await host.commands.isEmpty)
  }
}

/// First answer one turn, second four: the growth path.
actor GrowingHost {
  private(set) var commands: [String] = []

  func answer(_ command: String) -> CommandResult {
    commands.append(command)
    let body: String
    if commands.count == 1 {
      body = Fixture.assistant("only one", uuid: "a0") + "\n"
    } else {
      body = (0..<4).map { Fixture.assistant("m\($0)", uuid: "a\($0)") }
        .joined(separator: "\n") + "\n"
    }
    return FakeHost.output(HostFixture.read(size: 10_000_000, body: body))
  }

  nonisolated var runner: CommandRunner {
    { command in await self.answer(command) }
  }
}
