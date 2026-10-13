import DriverrCore
import Foundation
import Testing

@testable import DriverrTranscript

/// The round trip that fetches every candidate's opening line, asserted as a string like
/// every command here; `LiveTranscriptProbeTests` catches a well-formed wrong one.
struct TranscriptBriefCommandTests {
  private let directory = "/home/me/.claude/projects/-home-me-dev-driverr"

  @Test("the command reads the head of every candidate in one round trip")
  func shape() throws {
    let command = try #require(
      TranscriptCommands.briefCommand(directory: directory, names: ["a.jsonl", "b.jsonl"]))
    // Entered once, with relative names, as the listing does, so the directory is not on the
    // wire once per record.
    #expect(command.hasPrefix("cd \(directory) 2>/dev/null || exit 0"))
    #expect(command.contains("for f in a.jsonl b.jsonl; do [ -f \"$f\" ] || continue"))
    // The head of the file, unlike everything else this module fetches, with every bound
    // named.
    #expect(command.contains("FNR>\(TranscriptCommands.briefLines)"))
    #expect(command.contains("c>=\(TranscriptCommands.briefRecords)"))
    #expect(command.contains("length($0)<=\(TranscriptCommands.briefRecordBytes)"))
    // `FILENAME`, not a shell variable, because `awk -v` expands escapes.
    #expect(command.contains("print FILENAME \"\\t\" $0"))
    // A file that vanished since the listing has no brief; that is not a channel failure.
    #expect(command.hasSuffix("exit 0"))
  }

  /// Keeps records a person could have typed and drops tool results, injected text and the
  /// assistant's words. Raw-byte matching is safe, as in `recordSelector`, because quotes in
  /// JSON strings are escaped.
  @Test("the selector keeps user records and drops tool results and injected text")
  func selector() {
    #expect(TranscriptCommands.briefSelector.contains(#"/"type":"user"/"#))
    #expect(TranscriptCommands.briefSelector.contains(#"!/"toolUseResult":/"#))
    #expect(TranscriptCommands.briefSelector.contains(#"!/"isMeta":true/"#))
  }

  @Test("a filename is quoted like every other value that reaches a shell")
  func quoting() throws {
    let command = try #require(
      TranscriptCommands.briefCommand(directory: "/tmp/it's", names: ["a'b.jsonl"]))
    #expect(command.contains(#"'/tmp/it'\''s'"#))
    #expect(command.contains(#"'a'\''b.jsonl'"#))
  }

  @Test("no candidates is no command to run")
  func empty() {
    #expect(TranscriptCommands.briefCommand(directory: directory, names: []) == nil)
  }
}

/// Reading the briefs.
struct TranscriptBriefReaderTests {
  private let directory = "/home/me/.claude/projects/-home-me-dev-driverr"

  private func file(_ name: String, age: TimeInterval?) -> TranscriptFile {
    TranscriptFile(path: "\(directory)/\(name)", sizeInBytes: 10, age: age)
  }

  @Test("each candidate's opening line comes back under its own name")
  func briefs() async throws {
    let output = [
      "a.jsonl\t\(Fixture.clientEnvelope("<command-name>/clear</command-name>"))",
      "a.jsonl\t\(Fixture.humanWithOrigin("review the diff on the focus branch"))",
      "b.jsonl\t\(Fixture.humanWithOrigin("start on the pane-focus bug", uuid: "h2"))",
      "",
    ].joined(separator: "\n")
    let host = FakeHost(responses: ["FNR>": FakeHost.output(output)])
    let briefs = try await TranscriptReader(run: host.runner)
      .briefs(in: directory, for: [file("a.jsonl", age: 4), file("b.jsonl", age: 21)])
    #expect(briefs == [
      "a.jsonl": "review the diff on the focus branch",
      "b.jsonl": "start on the pane-focus bug",
    ])
  }

  /// A candidate with no readable opening line is absent, and the picker draws its row from
  /// the filename and mtime.
  @Test("a candidate with no readable opening line is absent rather than fatal")
  func partialAnswer() async throws {
    let output = "b.jsonl\t\(Fixture.humanWithOrigin("start on the pane-focus bug"))\n"
    let host = FakeHost(responses: ["FNR>": FakeHost.output(output)])
    let briefs = try await TranscriptReader(run: host.runner)
      .briefs(in: directory, for: [file("a.jsonl", age: 4), file("b.jsonl", age: 21)])
    #expect(briefs["a.jsonl"] == nil)
    #expect(briefs["b.jsonl"] == "start on the pane-focus bug")
  }

  @Test("a line the host mangled past recognition is dropped, not guessed at")
  func mangled() async throws {
    let host = FakeHost(responses: ["FNR>": FakeHost.output("no-tab-here\n\t\n")])
    let briefs = try await TranscriptReader(run: host.runner)
      .briefs(in: directory, for: [file("a.jsonl", age: 4)])
    #expect(briefs.isEmpty)
  }

  @Test("nothing to ask about costs no round trip")
  func nothingToAsk() async throws {
    let host = FakeHost()
    let briefs = try await TranscriptReader(run: host.runner).briefs(in: directory, for: [])
    #expect(briefs.isEmpty)
    #expect(await host.commands.isEmpty)
  }
}

/// What a pick does to a later resolve.
struct TranscriptPickResolutionTests {
  private func ambiguousHost(now: Int = 1_000_000) -> FakeHost {
    FakeHost(
      responses: [
        "date +%s": FakeHost.output(
          HostFixture.listing(
            now: now,
            directory: HostFixture.projectDirectory,
            files: [
              ("\(now - 4)", 100, "mine.jsonl"),
              ("\(now - 9)", 200, "theirs.jsonl"),
            ]
          )
        )
      ]
    )
  }

  private func pick(_ name: String) -> TranscriptPick {
    TranscriptPick(
      directory: "/home/me/dev/driverr",
      file: TranscriptFile(path: "\(HostFixture.projectDirectory)/\(name)", sizeInBytes: 0, age: nil)
    )
  }

  @Test("a picked file resolves, and credits the choice rather than claiming a match")
  func picked() async throws {
    let resolution = try await TranscriptReader(run: ambiguousHost().runner)
      .resolve(for: HostFixture.pane(), pick: pick("theirs.jsonl"))
    let source = try #require(resolution.source)
    #expect(source.file.name == "theirs.jsonl")
    #expect(source.provenance == .chosenByHand)
    // The fresh listing's age, not the one the pick was made against.
    #expect(source.file.age == 9)
  }

  /// The user picks the older of two live sessions and the other keeps writing, so the
  /// directory would rank the other file newest. A pick beats tier 2 as well as ambiguity.
  @Test("a pick outlives the directory becoming rankable again")
  func picksBeatALaterDirectoryMatch() async throws {
    let now = 1_000_000
    let host = FakeHost(
      responses: [
        "date +%s": FakeHost.output(
          HostFixture.listing(
            now: now,
            directory: HostFixture.projectDirectory,
            files: [("\(now - 2)", 100, "theirs.jsonl"), ("\(now - 400)", 200, "mine.jsonl")]
          )
        )
      ]
    )
    let reader = TranscriptReader(run: host.runner)
    // Without the pick, this resolves to the file the user rejected.
    #expect(try await reader.resolve(for: HostFixture.pane()).source?.file.name == "theirs.jsonl")
    let resolution = try await reader.resolve(for: HostFixture.pane(), pick: pick("mine.jsonl"))
    #expect(resolution.source?.file.name == "mine.jsonl")
    #expect(resolution.source?.provenance == .chosenByHand)
  }

  @Test("a pick whose file is gone falls back to the honest answer, not to the newest file")
  func pickedFileGone() async throws {
    let resolution = try await TranscriptReader(run: ambiguousHost().runner)
      .resolve(for: HostFixture.pane(), pick: pick("deleted.jsonl"))
    guard case .ambiguous(_, let candidates) = resolution else {
      Issue.record("expected the refusal back, got \(resolution)")
      return
    }
    #expect(candidates.map(\.name) == ["mine.jsonl", "theirs.jsonl"])
  }

  @Test("a pick made in another directory does not follow the pane")
  func pickedElsewhere() async throws {
    let elsewhere = TranscriptPick(
      directory: "/home/me/dev/tower",
      file: TranscriptFile(path: "\(HostFixture.projectDirectory)/mine.jsonl", sizeInBytes: 0, age: nil)
    )
    let resolution = try await TranscriptReader(run: ambiguousHost().runner)
      .resolve(for: HostFixture.pane(), pick: elsewhere)
    #expect(resolution.source == nil)
  }

  /// herdr's answer is exact and a pick is not.
  @Test("herdr reporting the session overrides a pick")
  func reportedSessionWins() async throws {
    let now = 1_000_000
    let host = FakeHost(
      responses: [
        "date +%s": FakeHost.output(
          HostFixture.listing(
            now: now,
            directory: HostFixture.projectDirectory,
            files: [("\(now - 4)", 100, "mine.jsonl"), ("\(now - 9)", 200, "theirs.jsonl")]
          )
        )
      ]
    )
    let pane = HostFixture.pane(
      agent: Agent(
        name: "Claude",
        kind: "claude",
        status: .working,
        session: AgentSession(agent: "claude", kind: "id", value: "theirs")
      )
    )
    let resolution = try await TranscriptReader(run: host.runner)
      .resolve(for: pane, pick: pick("mine.jsonl"))
    #expect(resolution.source?.file.name == "theirs.jsonl")
    #expect(resolution.source?.provenance == .reportedByHerdr(sessionID: "theirs"))
  }
}
