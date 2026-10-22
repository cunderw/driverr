import DriverrCore
import Foundation
import Testing

@testable import DriverrTranscript

/// The exact strings that run on somebody's machine. A fake host cannot catch a command
/// that is well-formed and wrong (that is `LiveTranscriptProbeTests`, opt-in), but these
/// catch a missing `--`, a lost quote, or a flag only one host OS spells.
struct TranscriptCommandsTests {
  @Test("the listing asks the host for its own clock first")
  func listingAsksForTheHostClock() {
    let command = TranscriptCommands.listCommand(projectSlug: "-Users-x-dev")
    // After the shell setup statement and before anything it prints.
    #expect(command.hasPrefix("\(TranscriptCommands.literalEmptyGlobs); date +%s; "))
  }

  @Test("the project directory is expanded on the host, not on the phone")
  func homeIsTheHostsAnswer() {
    let command = TranscriptCommands.listCommand(projectSlug: "-Users-x-dev")
    #expect(command.contains(#"d="$HOME/.claude/projects"/-Users-x-dev"#))
    #expect(command.contains(#"printf '%s\n' "$d""#))
  }

  /// GNU's `-f` is `--file-system`, so `stat -f %m` on Linux prints the mount point. Tried
  /// first, it would put `/` where every mtime belongs.
  @Test("both stat spellings are tried, GNU's first")
  func statIsPortable() throws {
    let command = TranscriptCommands.listCommand(projectSlug: "-Users-x-dev")
    let gnu = try #require(command.range(of: "stat -c %Y"))
    let bsd = try #require(command.range(of: "stat -f %m"))
    #expect(gnu.lowerBound < bsd.lowerBound)
    #expect(command.contains(#"stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null"#))
  }

  /// It runs every few seconds while a chat is open, so its cost is this string and two
  /// fields.
  @Test("the size command asks for an mtime and a size and nothing else")
  func sizeCommandIsTwoFields() {
    #expect(
      TranscriptCommands.sizeCommand(path: "/p/a1b2.jsonl") == """
        f=/p/a1b2.jsonl; \
        m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null); \
        s=$(wc -c < "$f" 2>/dev/null); \
        printf '%s\\t%s\\n' "${m:-?}" "${s:-?}"
        """)
  }

  /// It runs repeatedly, so a mount point read as an mtime would re-read the page every tick.
  @Test("the size command tries both stat spellings, GNU's first")
  func sizeCommandStatIsPortable() throws {
    let command = TranscriptCommands.sizeCommand(path: "/p/a1b2.jsonl")
    let gnu = try #require(command.range(of: "stat -c %Y"))
    let bsd = try #require(command.range(of: "stat -f %m"))
    #expect(gnu.lowerBound < bsd.lowerBound)
  }

  /// `?` rather than empty, so a missing mtime cannot collapse two tabs and shift the size.
  @Test("a file the host cannot read answers with marks rather than empty fields")
  func sizeCommandMarksMissingFields() {
    let command = TranscriptCommands.sizeCommand(path: "/p/a1b2.jsonl")
    #expect(command.contains(#""${m:-?}" "${s:-?}""#))
  }

  @Test("a path with a quote in it cannot become shell syntax")
  func sizeCommandPathsAreQuoted() {
    let command = TranscriptCommands.sizeCommand(path: "/p/it's here; rm -rf /")
    #expect(command.contains(#"f='/p/it'\''s here; rm -rf /'"#))
  }

  /// For a file herdr named before the agent wrote it. The directory is built on the host
  /// from `$HOME`, as the listing does.
  @Test("the reported-file size command names the file under the host's projects root")
  func reportedSizeCommandIsTheSizeCommand() {
    #expect(
      TranscriptCommands.reportedSizeCommand(projectSlug: "-Users-x-dev", sessionID: "a1b2")
        == """
        f="$HOME/.claude/projects"/-Users-x-dev/a1b2.jsonl; \
        m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null); \
        s=$(wc -c < "$f" 2>/dev/null); \
        printf '%s\\t%s\\n' "${m:-?}" "${s:-?}"
        """)
  }

  /// The id comes off herdr's snapshot, so it is quoted like any text reaching the shell.
  @Test("a reported session id with a quote in it cannot become shell syntax")
  func reportedSizeCommandQuotesTheID() {
    let command = TranscriptCommands.reportedSizeCommand(
      projectSlug: "-Users-x-dev", sessionID: "it's; rm -rf /")
    #expect(command.contains(#"/-Users-x-dev/'it'\''s; rm -rf /.jsonl'; "#))
  }

  @Test("a working directory with a quote in it cannot become shell syntax")
  func slugsAreQuoted() {
    let command = TranscriptCommands.listCommand(projectSlug: "-Users-x-it's here; rm -rf /")
    #expect(command.contains(#"'-Users-x-it'\''s here; rm -rf /'"#))
  }

  @Test("the continuation command reads a bounded tail of every candidate")
  func continuationIsBounded() throws {
    let command = try #require(
      TranscriptCommands.continuationCommand(directory: "/p", names: ["a.jsonl", "b.jsonl"])
    )
    #expect(command.hasPrefix("cd /p 2>/dev/null || exit 0; "))
    #expect(command.contains("for f in a.jsonl b.jsonl; do [ -f \"$f\" ] || continue"))
    #expect(command.contains("tail -c 8192 \"$f\" 2>/dev/null | awk "))
    #expect(command.hasSuffix("; exit 0"))
  }

  /// `FILENAME` is empty when `awk` reads a pipe, and `awk -v` expands escapes in a filename
  /// (see `briefCommand`), so the shell supplies the name.
  @Test("the continuation command labels each answer with the file the shell is looping on")
  func continuationLabelsItsAnswer() throws {
    let command = try #require(
      TranscriptCommands.continuationCommand(directory: "/p", names: ["a.jsonl"])
    )
    #expect(command.contains(#"printf '%s%s\t%s\n' '!' "$f" "$i""#))
    #expect(!command.contains("awk -v"))
    #expect(!command.contains("FILENAME"))
  }

  /// `match` cuts the id out, with offsets derived from the key's length rather than typed.
  @Test("the continuation selector cuts the successor's id out of the record")
  func continuationSelectorCutsTheID() throws {
    let command = try #require(
      TranscriptCommands.continuationCommand(directory: "/p", names: ["a.jsonl"])
    )
    #expect(command.contains(#"/"type":"continued-in"/"#))
    #expect(command.contains(#"match($0,/"continuedInSessionId":"[^"]*"/)"#))
    // 24 opening characters skipped and the closing quote dropped.
    #expect(TranscriptCommands.continuationKey.count == 24)
    #expect(command.contains("substr($0,RSTART+24,RLENGTH-25)"))
  }

  @Test("nothing to ask about costs no round trip")
  func continuationNeedsCandidates() {
    #expect(TranscriptCommands.continuationCommand(directory: "/p", names: []) == nil)
  }

  @Test("a read is bounded three ways")
  func readIsBounded() {
    let command = TranscriptCommands.readCommand(path: "/p/s.jsonl", bytes: 4096, records: 12)
    #expect(command.contains("tail -c 4096"))
    #expect(command.contains("tail -n 12"))
    #expect(command.contains("awk "))
  }

  @Test("a read says how big the whole file is and whether it ends mid-record")
  func readHeader() {
    let command = TranscriptCommands.readCommand(path: "/p/s.jsonl", bytes: 4096, records: 12)
    #expect(command.contains(#"s=$(wc -c < "$f" 2>/dev/null)"#))
    #expect(command.contains(#"if [ -n "$(tail -c 1 "$f" 2>/dev/null)" ]; then t=partial"#))
    #expect(command.contains(#"printf '%s\t%s\n' "${s:-?}" "$t""#))
  }

  /// The mark is printed unconditionally, so a window with no results differs from one
  /// nobody scanned. Without it every finished conversation would show a permission prompt.
  @Test("a read always says whether it looked at what became of the calls")
  func readAlwaysReportsTheScan() throws {
    let command = TranscriptCommands.readCommand(path: "/p/s.jsonl", bytes: 4096, records: 12)
    #expect(command.contains(#"printf '%s\n' '!'"#))
    let mark = try #require(command.range(of: #"printf '%s\n' '!'"#))
    let scan = try #require(command.range(of: TranscriptCommands.resultSelector))
    #expect(mark.lowerBound < scan.lowerBound, "the mark has to survive an empty scan")
  }

  /// The same bound as the records keeps result lines a fixed small share of the page, and
  /// they come last so they cannot eat the record bound. Task lines follow, bounded alike.
  @Test("the result and task lines are bounded like the records and come after them")
  func resultsAreBoundedAndLast() throws {
    let command = TranscriptCommands.readCommand(path: "/p/s.jsonl", bytes: 4096, records: 12)
    let records = try #require(command.range(of: TranscriptCommands.recordSelector))
    let results = try #require(command.range(of: TranscriptCommands.resultSelector))
    let tasks = try #require(command.range(of: TranscriptCommands.taskSelector))
    #expect(records.lowerBound < results.lowerBound)
    #expect(results.lowerBound < tasks.lowerBound)
    // One `tail -n 12` for each of the three.
    #expect(command.components(separatedBy: "tail -n 12").count == 4)
  }

  @Test("nothing beyond POSIX is asked for")
  func posixOnly() {
    let commands = [
      TranscriptCommands.listCommand(projectSlug: "-x"),
      TranscriptCommands.readCommand(path: "/p/s.jsonl", bytes: 1, records: 1),
      TranscriptCommands.codexListCommand(),
      TranscriptCommands.codexReadCommand(path: "/p/s.jsonl", bytes: 1, records: 1),
    ]
    for command in commands {
      for tool in ["jq", "python", "python3", "perl", "node", "rg", "gstat", "sed -i"] {
        #expect(!command.contains(tool), "\(tool) is not on every host")
      }
    }
  }

  // MARK: - Codex rollouts

  @Test("the Codex listing walks day directories under $HOME/.codex/sessions, newest first")
  func codexListingWalksDayDirectories() {
    let command = TranscriptCommands.codexListCommand()
    #expect(command.contains(#"d="$HOME/.codex/sessions""#))
    #expect(command.contains(#"find "$d" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | sort -r"#))
    #expect(command.contains("head -n \(CodexRollouts.maxDayDirectories)"))
    // A `while IFS= read -r` loop rather than word-splitting, because `$HOME` often has a space
    // on a Mac.
    #expect(command.contains("while IFS= read -r day"))
  }

  /// Every age is the host's subtraction against this `date`. Without it every age is `nil`,
  /// and Codex writes a rollout per day, so most `cwd`s would be unrankable. Deleting the line
  /// looks like tidying; `CodexResolverTests` asserts the consequence.
  @Test("the Codex listing reports the host's clock first, as the Claude listing does")
  func codexListingOpensWithTheClock() {
    let command = TranscriptCommands.codexListCommand()
    #expect(command.hasPrefix("\(TranscriptCommands.literalEmptyGlobs); date +%s; "))
  }

  @Test("the Codex listing tries both stat spellings, GNU's first")
  func codexListingStatIsPortable() throws {
    let command = TranscriptCommands.codexListCommand()
    let gnu = try #require(command.range(of: "stat -c %Y"))
    let bsd = try #require(command.range(of: "stat -f %m"))
    #expect(gnu.lowerBound < bsd.lowerBound)
  }

  /// Runs the `awk` header extractor on a real `session_meta` line.
  @Test("the header program pulls cwd, thread_source and id off line 1")
  func codexHeaderProgramExtractsTheThreeFields() throws {
    let line1 = CodexFixture.sessionMeta(cwd: "/Users/x/repo", threadSource: "user", id: "u-1")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/awk")
    process.arguments = [TranscriptCommands.codexHeaderProgram]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    input.fileHandleForWriting.write(Data((line1 + "\n").utf8))
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(String(decoding: data, as: UTF8.self) == "/Users/x/repo\tuser\tu-1")
  }

  /// Runs the real `codexOutcomeProgram` on a plain, a failed, and a quote-embedding
  /// `CommandExecution` line.
  @Test("the outcome program extracts id, status, exit_code and the last command element")
  func codexOutcomeProgramExtractsTheFourFields() throws {
    let plain = CodexFixture.itemCompletedCommandExecution(
      command: "git status", status: "completed", exitCode: "0", id: "exec-1"
    )
    let quoted = CodexFixture.itemCompletedCommandExecution(
      command: #"python3 -c "print(1)""#, status: "failed", exitCode: "1", id: "exec-2"
    )
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/awk")
    process.arguments = [TranscriptCommands.codexOutcomeProgram]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    input.fileHandleForWriting.write(Data(([plain, quoted].joined(separator: "\n") + "\n").utf8))
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 2)
    #expect(lines[0] == "!exec-1\tcompleted\t0\tgit status")
    #expect(lines[1] == "!exec-2\tfailed\t1\tpython3 -c \\\"print(1)\\\"")
  }

  @Test("the Codex read command has its own record selector and an outcome pass")
  func codexReadCommandHasAnOutcomePass() {
    let command = TranscriptCommands.codexReadCommand(path: "/p/a1b2.jsonl", bytes: 4096, records: 60)
    // Codex's own extractor: its join key is a command string, not a `tool_use_id`.
    #expect(!command.contains(TranscriptCommands.resultSelector))
    #expect(command.contains(TranscriptCommands.resultMark))
    #expect(command.contains(TranscriptCommands.codexRecordSelector))
    #expect(command.contains(TranscriptCommands.codexOutcomeProgram))
  }

  @Test("the Codex read command sizes and partial-checks the file before its selected tail")
  func codexReadCommandHeader() {
    let command = TranscriptCommands.codexReadCommand(path: "/p/a1b2.jsonl", bytes: 4096, records: 60)
    #expect(command.hasPrefix(#"f=/p/a1b2.jsonl; s=$(wc -c < "$f" 2>/dev/null)"#))
    #expect(command.contains(#"if [ -n "$(tail -c 1 "$f" 2>/dev/null)" ]; then t=partial; else t=complete; fi"#))
  }
}

/// The Codex read selector, mirrored by hand as `RecordSelectorTests` mirrors Claude's.
struct CodexRecordSelectorTests {
  private func keeps(_ line: String) -> Bool {
    line.contains(#""type":"UserMessage""#) || line.contains(#""type":"AgentMessage""#)
      || line.contains(#""type":"custom_tool_call""#) || line.contains(#""type":"function_call""#)
  }

  @Test("the four kept kinds are kept")
  func selectsTheFourKinds() {
    #expect(keeps(CodexFixture.userMessage("hi")))
    #expect(keeps(CodexFixture.agentMessage("hi")))
    #expect(keeps(CodexFixture.customToolCall(input: "x", callID: "call_1")))
    #expect(keeps(CodexFixture.functionCall(name: "spawn_agent", arguments: ["task_name": "t"])))
  }

  @Test("everything else in a rollout is dropped")
  func dropsEverythingElse() {
    #expect(!keeps(CodexFixture.reasoning()))
    #expect(!keeps(CodexFixture.commandExecution(["ls"])))
    #expect(!keeps(CodexFixture.fileChange(path: "a.swift")))
    #expect(!keeps(CodexFixture.mcpToolCall(tool: "search")))
    #expect(!keeps(CodexFixture.subAgentActivity("spawned")))
    #expect(!keeps(CodexFixture.hookPrompt()))
    #expect(!keeps(CodexFixture.sessionMeta()))
    #expect(!keeps(CodexFixture.bookkeeping("token_usage_record")))
  }
}

/// The selector is a line filter. An unescaped `"type":"user"` cannot occur inside JSON
/// string content, where a quote is `\"`, so a record's text can say the words and not
/// match.
struct RecordSelectorTests {
  /// A stand-in for `awk`: substring tests, as `awk` does with these patterns. It mirrors
  /// `TranscriptCommands.recordSelector` by hand and nothing checks that the two agree;
  /// `selected(_:)` below and the opt-in `LiveTranscriptProbeTests` run the real one.
  private func keeps(_ line: String) -> Bool {
    let isTurnDuration =
      line.contains(#""type":"system""#) && line.contains(#""subtype":"turn_duration""#)
    let isConversation =
      line.contains(#""type":"user""#) || line.contains(#""type":"assistant""#)
    let isToolResult = line.contains(#""toolUseResult":"#)
    let isThinking = line.contains(#""type":"thinking""#)
    let hasSomethingElse =
      line.contains(#""type":"tool_use""#) || line.contains(#""type":"text""#)
    let isQuestionAnswer = line.contains(#""toolUseResult":{"questions":"#)
    return isTurnDuration
      || (isConversation && !isToolResult && (!isThinking || hasSomethingElse))
      || isQuestionAnswer
  }

  /// The real selector through `/usr/bin/awk`, the BSD awk a macOS host runs, because the
  /// mirror above can drift unnoticed.
  private func selected(_ lines: [String]) throws -> [String] {
    let awk = Process()
    awk.executableURL = URL(fileURLWithPath: "/usr/bin/awk")
    awk.arguments = [TranscriptCommands.recordSelector]
    let input = Pipe()
    let output = Pipe()
    awk.standardInput = input
    awk.standardOutput = output
    try awk.run()
    input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    awk.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init)
  }

  /// The answers to an `AskUserQuestion` call are in its reply's `toolUseResult`, so that
  /// reply alone of all tool results travels.
  @Test("an AskUserQuestion reply crosses the wire, and no other tool result does")
  func keepsAnAskUserQuestionReply() throws {
    let answer = Fixture.askUserQuestionAnswer(
      id: "toolu_q", answers: [(question: "Which fruit do you pick?", answer: "Banana")])
    let lines = [
      Fixture.human("pick a fruit", uuid: "h1"),
      Fixture.askUserQuestion(["Which fruit do you pick?"], id: "toolu_q"),
      answer,
      Fixture.toolResult(id: "toolu_b", output: "a megabyte of output"),
      Fixture.failedToolResult(id: "toolu_c"),
    ]
    #expect(try selected(lines) == Array(lines[0...2]))
    #expect(keeps(answer))
  }

  @Test("conversation is kept and bookkeeping is not")
  func selectsConversation() {
    #expect(keeps(Fixture.human("hi")))
    #expect(keeps(Fixture.assistant("hello")))
    #expect(!keeps(Fixture.bookkeeping("mode")))
    #expect(!keeps(Fixture.bookkeeping("attachment")))
  }

  /// `away_summary` and `compact_boundary` are other `system` subtypes, and a bare
  /// `"type":"system"` clause would send them.
  @Test("the turn-duration record travels and the other system subtypes do not")
  func selectsTurnDurationAlone() {
    #expect(keeps(Fixture.turnDuration("590000")))
    #expect(!keeps(Fixture.turnDuration("590000", subtype: "away_summary")))
    #expect(!keeps(Fixture.turnDuration("590000", subtype: "compact_boundary")))
  }

  @Test("a tool result never crosses the wire")
  func dropsToolResults() {
    #expect(!keeps(Fixture.toolResult(id: "t1", output: "a megabyte of output")))
  }

  @Test("thinking is dropped, unless the record carries something real too")
  func dropsThinkingAlone() {
    #expect(!keeps(Fixture.thinking()))
    #expect(keeps(Fixture.assistantThenTool("on it", tool: "Bash")))
    #expect(keeps(Fixture.toolUse("Read")))
  }

  /// A person writing `"type":"user"` does not produce that byte sequence, because the quotes
  /// are escaped.
  @Test("a message that talks about the format does not match the format")
  func escapedQuotesDoNotMatch() {
    let talking = Fixture.assistant(#"the record carries "type":"user" at the top level"#)
    #expect(talking.contains(#"\"type\":\"user\""#))
    // Kept because it is an assistant record, not because of what it says.
    #expect(keeps(talking))
    let asHuman = Fixture.human(#"and "toolUseResult": is the key to grep for"#)
    #expect(keeps(asHuman))
  }
}

/// The one selector that reads inside a record. `"tool_use_id":"` appears only on tool
/// results and `"is_error":true` only on failed ones, checked against a large real corpus.
/// Neither can occur in written text, where quotes are escaped.
struct ResultSelectorTests {
  /// A stand-in for `awk`: the guard, the first match, and the error flag.
  private func line(_ record: String) -> String? {
    guard record.contains(#""toolUseResult":"#),
      let start = record.range(of: TranscriptCommands.resultKey)
    else { return nil }
    let identifier = record[start.upperBound...].prefix { $0 != "\"" }
    let failed = record.contains(#""is_error":true"#)
    return "\(TranscriptCommands.resultMark)\(identifier)"
      + "\(TranscriptCommands.fieldSeparator)\(failed ? "1" : "0")"
  }

  @Test("a tool result answers with its call's id and whether it failed")
  func readsTheTwoFields() {
    #expect(line(Fixture.toolResult(id: "toolu_01AbCdEfGhIjKlMnOpQrStUv")) == "!toolu_01AbCdEfGhIjKlMnOpQrStUv\t0")
    #expect(line(Fixture.failedToolResult(id: "toolu_2")) == "!toolu_2\t1")
  }

  @Test("nothing that is not a tool result answers at all")
  func answersNothingElse() {
    #expect(line(Fixture.human("hi")) == nil)
    #expect(line(Fixture.assistant("hello")) == nil)
    #expect(line(Fixture.toolUse("Read", id: "toolu_1")) == nil)
    #expect(line(Fixture.bookkeeping("attachment")) == nil)
  }

  @Test("a message that talks about the key does not carry it")
  func escapedQuotesDoNotMatch() {
    let talking = Fixture.human(#"grep for "tool_use_id":" and "is_error":true"#)
    #expect(talking.contains(#"\"tool_use_id\":\""#))
    #expect(!talking.contains(TranscriptCommands.resultKey))
    #expect(line(talking) == nil)
  }

  /// Where a line carries the key twice, the first is the block's own, because `message` is
  /// written before `toolUseResult`.
  @Test("the first occurrence is the one the result answers")
  func firstOccurrenceWins() {
    #expect(line(Fixture.toolResultQuotingAnotherID(id: "toolu_1", other: "toolu_9")) == "!toolu_1\t0")
  }
}

// MARK: - A glob that matches nothing

/// The three globbing commands, run by each login shell the exec channel can land in,
/// against a scratch home where the glob matches nothing. sh, bash and dash pass an
/// unmatched glob through and the `[ -f ]` guard skips it; zsh's default `nomatch` prints
/// `no matches found`, exits 1 and runs nothing after it.
@Suite("Empty globs")
struct EmptyGlobCommandTests {
  static let shells = ["/bin/zsh", "/bin/sh", "/bin/bash", "/bin/dash"]

  private struct Scratch {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("driverr-transcript-\(UUID().uuidString)")

    func directory(_ path: String) throws -> URL {
      let url = home.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    }

    func file(_ path: String, _ text: String) throws {
      let url = home.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: url, atomically: false, encoding: .utf8)
    }

    func remove() { try? FileManager.default.removeItem(at: home) }

    /// Runs a command as the exec channel hands it to a login shell.
    func run(_ command: String, shell: String) async throws -> CommandResult {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: shell)
      process.arguments = ["-c", command]
      process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
      let output = Pipe()
      let error = Pipe()
      process.standardOutput = output
      process.standardError = error
      // Waits on the termination handler rather than `waitUntilExit()`, so no cooperative
      // thread blocks (CLAUDE.md, "Never block a cooperative thread in a Kit test").
      let status: Int32 = try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        do { try process.run() } catch { continuation.resume(throwing: error) }
      }
      return CommandResult(
        standardOutput: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
        standardError: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
        exitStatus: Int(status)
      )
    }
  }

  @Test("an existing project directory with no session file lists as empty", arguments: shells)
  func emptyProjectDirectory(shell: String) async throws {
    let scratch = Scratch()
    defer { scratch.remove() }
    let project = try scratch.directory(".claude/projects/-Users-x-dev")
    let result = try await scratch.run(TranscriptCommands.listCommand(projectSlug: "-Users-x-dev"), shell: shell)
    #expect(result.exitStatus == 0)
    #expect(result.standardError == "")
    let listing = TranscriptReader.listing(from: result.standardOutput)
    #expect(listing.directory == project.path)
    #expect(listing.files.isEmpty)
  }

  /// Before a new session's first record, Claude Code has not created the directory.
  @Test("a project directory that does not exist yet lists as empty", arguments: shells)
  func missingProjectDirectory(shell: String) async throws {
    let scratch = Scratch()
    defer { scratch.remove() }
    _ = try scratch.directory(".claude/projects")
    let result = try await scratch.run(TranscriptCommands.listCommand(projectSlug: "-Users-x-dev"), shell: shell)
    #expect(result.exitStatus == 0)
    #expect(result.standardError == "")
    let listing = TranscriptReader.listing(from: result.standardOutput)
    #expect(listing.directory == scratch.home.appendingPathComponent(".claude/projects/-Users-x-dev").path)
    #expect(listing.files.isEmpty)
  }

  /// The newest day directory is empty and an older one holds a rollout.
  @Test("an empty Codex day directory does not hide an older rollout", arguments: shells)
  func emptyCodexDay(shell: String) async throws {
    let scratch = Scratch()
    defer { scratch.remove() }
    _ = try scratch.directory(".codex/sessions/2026/09/25")
    try scratch.file(".codex/sessions/2026/09/24/rollout-a.jsonl", "{}\n")
    let result = try await scratch.run(TranscriptCommands.codexListCommand(), shell: shell)
    #expect(result.exitStatus == 0)
    #expect(result.standardError == "")
    #expect(result.standardOutput.contains("/2026/09/24/rollout-a.jsonl\t"))
  }

  /// No `subagents` directory yet, as for a session that never spawned. The `*.meta.json`
  /// glob would trip zsh's `nomatch`.
  @Test(
    "the sub-agent link command matches nothing in an empty directory, on every shell",
    arguments: shells
  )
  func emptySubagentsDirectory(shell: String) async throws {
    let scratch = Scratch()
    defer { scratch.remove() }
    let project = try scratch.directory(".claude/projects/-Users-x-dev")
    let command = TranscriptCommands.subagentLinkCommand(
      directory: project.path, sessionID: "sess1", literal: #""toolUseId":"toolu_1""#)
    let result = try await scratch.run(command, shell: shell)
    #expect(result.exitStatus == 0)
    #expect(result.standardError == "")
    #expect(TranscriptReader.listing(from: result.standardOutput).files.isEmpty)
  }

  @Test("the sub-agent list of a session with no subagents directory is empty", arguments: shells)
  func subagentListOfNothing(shell: String) async throws {
    let scratch = Scratch()
    defer { scratch.remove() }
    let project = try scratch.directory(".claude/projects/-Users-x-dev")
    let command = TranscriptCommands.subagentListCommand(directory: project.path, sessionID: "sess1")
    let result = try await scratch.run(command, shell: shell)
    #expect(result.exitStatus == 0)
    #expect(result.standardError == "")
    #expect(TranscriptReader.subagentList(from: result.standardOutput, readAt: Date()).isEmpty)
  }

  @Test("the sub-agent list of an empty subagents directory is empty", arguments: shells)
  func subagentListOfAnEmptyDirectory(shell: String) async throws {
    let scratch = Scratch()
    defer { scratch.remove() }
    let project = try scratch.directory(".claude/projects/-Users-x-dev")
    _ = try scratch.directory(".claude/projects/-Users-x-dev/sess1/subagents")
    let command = TranscriptCommands.subagentListCommand(directory: project.path, sessionID: "sess1")
    let result = try await scratch.run(command, shell: shell)
    #expect(result.exitStatus == 0)
    #expect(result.standardError == "")
    let list = TranscriptReader.subagentList(from: result.standardOutput, readAt: Date())
    #expect(list.total == 0)
    #expect(list.summaries.isEmpty)
  }

  /// Real meta files in both shapes, one with an escaped quote in its description and one
  /// whose `.jsonl` is not written yet, read back through `subagentList(from:readAt:)`.
  @Test("the sub-agent list reads every meta file in the session", arguments: shells)
  func subagentListForReal(shell: String) async throws {
    let scratch = Scratch()
    defer { scratch.remove() }
    let project = try scratch.directory(".claude/projects/-Users-x-dev")
    let dir = ".claude/projects/-Users-x-dev/sess1/subagents"
    try scratch.file(
      "\(dir)/agent-ascout-0123456789abcdef.meta.json",
      #"{"agentType":"scout","description":"Survey the \"old\" pool","name":"scout","#
        + #""taskKind":"in_process_teammate","customAgentType":"scout-type"}"#)
    try scratch.file("\(dir)/agent-ascout-0123456789abcdef.jsonl", "{}\n")
    try scratch.file(
      "\(dir)/agent-a0000000000000004.meta.json",
      #"{"agentType":"Explore","description":"Find the callers","toolUseId":"toolu_1","finished":true}"#)
    try scratch.file("\(dir)/agent-a0000000000000004.jsonl", "{}\n{}\n")
    try scratch.file(
      "\(dir)/agent-a0000000000000005.meta.json",
      #"{"agentType":"Plan","description":"Starting up","toolUseId":"toolu_2"}"#)
    // Another session's sub-agent, which this session's list must not carry.
    try scratch.file(
      ".claude/projects/-Users-x-dev/sess2/subagents/agent-aother.meta.json",
      #"{"agentType":"Explore","toolUseId":"toolu_9"}"#)
    let command = TranscriptCommands.subagentListCommand(directory: project.path, sessionID: "sess1")
    let result = try await scratch.run(command, shell: shell)
    #expect(result.exitStatus == 0)
    #expect(result.standardError == "")
    let list = TranscriptReader.subagentList(from: result.standardOutput, readAt: Date())
    #expect(list.total == 3)
    let byID = Dictionary(uniqueKeysWithValues: list.summaries.map { ($0.id, $0) })
    #expect(Set(byID.keys) == ["ascout-0123456789abcdef", "a0000000000000004", "a0000000000000005"])
    let scout = try #require(byID["ascout-0123456789abcdef"])
    #expect(scout.name == "scout")
    #expect(scout.description == #"Survey the "old" pool"#)
    #expect(scout.agentType == "scout-type")
    #expect(scout.link == .teammate(name: "scout"))
    #expect(scout.writtenAt != nil)
    let explore = try #require(byID["a0000000000000004"])
    #expect(explore.isFinished)
    #expect(explore.link == .toolUse(id: "toolu_1"))
    let starting = try #require(byID["a0000000000000005"])
    #expect(starting.writtenAt == nil, "No .jsonl yet, so nothing was written")
    #expect(starting.spawnedAt != nil)
  }

  /// A real `agent-<id>.jsonl` beside its `.meta.json`, linked by the literal a `toolUseId`
  /// search passes, and read back through `TranscriptReader.listing(from:)`.
  @Test("the sub-agent link command finds the file whose meta carries the literal", arguments: shells)
  func linksByToolUseIDForReal(shell: String) async throws {
    let scratch = Scratch()
    defer { scratch.remove() }
    let project = try scratch.directory(".claude/projects/-Users-x-dev")
    try scratch.file(
      ".claude/projects/-Users-x-dev/sess1/subagents/agent-a0000000000000004.meta.json",
      #"{"toolUseId":"toolu_01ZyXwVuTsRqPoNmLkJiHgFe","name":"retry-fix"}"#
    )
    try scratch.file(
      ".claude/projects/-Users-x-dev/sess1/subagents/agent-a0000000000000004.jsonl",
      #"{"parentUuid":null,"isSidechain":true}"# + "\n"
    )
    let command = TranscriptCommands.subagentLinkCommand(
      directory: project.path, sessionID: "sess1",
      literal: #""toolUseId":"toolu_01ZyXwVuTsRqPoNmLkJiHgFe""#)
    let result = try await scratch.run(command, shell: shell)
    #expect(result.exitStatus == 0)
    #expect(result.standardError == "")
    let listing = TranscriptReader.listing(from: result.standardOutput)
    #expect(listing.files.map(\.name) == ["agent-a0000000000000004.jsonl"])
  }

  /// A spawn made before a `continued-in` handover can have its meta under the old session
  /// while the chat shows the new one. The meta is under `old`, the chat's file is `new`, and
  /// a decoy meta outside any `subagents` directory must not be linked.
  @Test("a tool-use id is found under another session of the same project", arguments: shells)
  func linksByToolUseIDAcrossSessions(shell: String) async throws {
    let scratch = Scratch()
    defer { scratch.remove() }
    let project = try scratch.directory(".claude/projects/-Users-x-dev")
    _ = try scratch.directory(".claude/projects/-Users-x-dev/new/subagents")
    try scratch.file(
      ".claude/projects/-Users-x-dev/new/subagents/agent-anew.meta.json",
      #"{"toolUseId":"toolu_other","name":"other"}"#)
    try scratch.file(".claude/projects/-Users-x-dev/new/subagents/agent-anew.jsonl", "{}\n")
    try scratch.file(
      ".claude/projects/-Users-x-dev/old/subagents/agent-aold.meta.json",
      #"{"toolUseId":"toolu_before_handover","name":"analyst-7"}"#)
    try scratch.file(".claude/projects/-Users-x-dev/old/subagents/agent-aold.jsonl", "{}\n")
    try scratch.file(
      ".claude/projects/-Users-x-dev/old/decoy.meta.json", #"{"toolUseId":"toolu_before_handover"}"#)
    try scratch.file(".claude/projects/-Users-x-dev/old/decoy.jsonl", "{}\n")
    let command = TranscriptCommands.subagentLinkCommand(
      directory: project.path, sessionID: nil, literal: #""toolUseId":"toolu_before_handover""#)
    let result = try await scratch.run(command, shell: shell)
    #expect(result.exitStatus == 0)
    #expect(result.standardError == "")
    let listing = TranscriptReader.listing(from: result.standardOutput)
    #expect(listing.files.map(\.path) == ["\(project.path)/old/subagents/agent-aold.jsonl"])
    #expect(FileManager.default.fileExists(atPath: try #require(listing.files.first).path))
  }

  @Test("a project-wide search of a project with no sub-agents matches nothing", arguments: shells)
  func projectWideSearchOfNothing(shell: String) async throws {
    let scratch = Scratch()
    defer { scratch.remove() }
    let project = try scratch.directory(".claude/projects/-Users-x-dev")
    try scratch.file(".claude/projects/-Users-x-dev/sess1.jsonl", "{}\n")
    let command = TranscriptCommands.subagentLinkCommand(
      directory: project.path, sessionID: nil, literal: #""toolUseId":"toolu_1""#)
    let result = try await scratch.run(command, shell: shell)
    #expect(result.exitStatus == 0)
    #expect(result.standardError == "")
    #expect(TranscriptReader.listing(from: result.standardOutput).files.isEmpty)
  }

  /// The first three loops glob nothing; the plugin's skill after them must still be listed.
  @Test("empty skill globs do not hide a plugin's skill", arguments: shells)
  func emptySkillGlobs(shell: String) async throws {
    let scratch = Scratch()
    defer { scratch.remove() }
    _ = try scratch.directory(".claude/skills")
    let cwd = try scratch.directory("project/.claude/commands")
      .deletingLastPathComponent().deletingLastPathComponent()
    let install = scratch.home.appendingPathComponent(".claude/plugins/cache/market/plug/1.0")
    try scratch.file(
      ".claude/plugins/installed_plugins.json", #"{"installPath": "\#(install.path)"}"#)
    try scratch.file(
      ".claude/plugins/cache/market/plug/1.0/skills/tidy/SKILL.md", "---\nname: tidy\n---\n")
    let result = try await scratch.run(TranscriptCommands.skillsCommand(cwd: cwd.path), shell: shell)
    #expect(result.exitStatus == 0)
    #expect(result.standardError == "")
    #expect(result.standardOutput.contains("\(TranscriptCommands.skillMark)\(TranscriptCommands.pluginSkillScope)\tplug:tidy"))
  }
}
