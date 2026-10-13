import DriverrCore
import Foundation
import Testing

@testable import DriverrTranscript

/// The commands in `TranscriptCommands` against this machine's `~/.claude/projects`.
///
/// Off unless `DRIVERR_LIVE_TRANSCRIPT=1`, because it needs real Claude Code session files.
/// Run it by hand:
///
/// ```sh
/// DRIVERR_LIVE_TRANSCRIPT=1 swift test --package-path DriverrKit --filter LiveTranscriptProbe
/// ```
///
/// A fake host answers whatever the test wrote, so a well-formed but wrong command passes
/// every unit test: `stat -f %m` returns a mount point on Linux, and an `awk` pattern that
/// matches nothing returns an empty page. It also prints the measured byte cost.
///
/// Read-only (`date`, `stat`, `wc`, `tail`, `awk`), and it asserts only on shapes, so no
/// conversation content is printed or compared.
@Suite(
  "LiveTranscriptProbe",
  .enabled(if: ProcessInfo.processInfo.environment["DRIVERR_LIVE_TRANSCRIPT"] == "1")
)
struct LiveTranscriptProbeTests {
  /// Runs a command as an SSH exec channel does: non-interactive `/bin/sh`, separate streams,
  /// no terminal, no rc file.
  private static let localRunner: CommandRunner = { command in
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
          try process.run()
          // Read before waiting: an undrained pipe deadlocks the child, and a page is far more than
          // 64 KB.
          let outData = out.fileHandleForReading.readDataToEndOfFile()
          let errData = err.fileHandleForReading.readDataToEndOfFile()
          process.waitUntilExit()
          continuation.resume(
            returning: CommandResult(
              standardOutput: String(decoding: outData, as: UTF8.self),
              standardError: String(decoding: errData, as: UTF8.self),
              exitStatus: Int(process.terminationStatus)
            )
          )
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// A working directory on this machine that has Claude sessions behind it.
  private static func probeDirectory() -> String? {
    let projects = "\(NSHomeDirectory())/.claude/projects"
    guard let slugs = try? FileManager.default.contentsOfDirectory(atPath: projects) else {
      return nil
    }
    // The slug is not invertible (a dash could have been a dash, slash or dot), so read `cwd`
    // from a session file, which also checks the derivation.
    for slug in slugs.sorted() {
      let directory = "\(projects)/\(slug)"
      guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
        continue
      }
      for file in files where file.hasSuffix(".jsonl") {
        guard let handle = FileHandle(forReadingAtPath: "\(directory)/\(file)"),
          let head = try? handle.read(upToCount: 64 * 1024)
        else { continue }
        try? handle.close()
        for line in String(decoding: head, as: UTF8.self).split(separator: "\n") {
          guard let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cwd = object["cwd"] as? String, !cwd.isEmpty
          else { continue }
          if ClaudeProjects.slug(forWorkingDirectory: cwd) == slug { return cwd }
        }
      }
    }
    return nil
  }

  /// Checked against every project directory on this machine.
  @Test("a session file's own cwd derives the directory it is filed under")
  func derivationHolds() throws {
    let projects = "\(NSHomeDirectory())/.claude/projects"
    let slugs = try #require(try? FileManager.default.contentsOfDirectory(atPath: projects))
    var checked = 0
    for slug in slugs {
      guard let files = try? FileManager.default.contentsOfDirectory(atPath: "\(projects)/\(slug)"),
        let file = files.first(where: { $0.hasSuffix(".jsonl") }),
        let handle = FileHandle(forReadingAtPath: "\(projects)/\(slug)/\(file)"),
        let head = try? handle.read(upToCount: 64 * 1024)
      else { continue }
      try? handle.close()
      for line in String(decoding: head, as: UTF8.self).split(separator: "\n") {
        guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cwd = object["cwd"] as? String, !cwd.isEmpty
        else { continue }
        #expect(
          ClaudeProjects.slug(forWorkingDirectory: cwd) == slug,
          "\(cwd) does not derive \(slug)"
        )
        checked += 1
        break
      }
    }
    #expect(checked > 0, "no project directory on this machine had a cwd to check against")
    print("[live] derivation checked against \(checked) project directories")
  }

  /// The real `stat` spelling, `wc` and the host clock, which a fake cannot get wrong.
  @Test("the listing comes back with real ages and real sizes")
  func listingIsReal() async throws {
    let directory = try #require(Self.probeDirectory(), "no Claude sessions on this machine")
    let slug = ClaudeProjects.slug(forWorkingDirectory: directory)
    let result = try await Self.localRunner(TranscriptCommands.listCommand(projectSlug: slug))
    #expect(result.exitStatus == 0)
    #expect(result.standardError.isEmpty, "the listing wrote to stderr: \(result.standardError)")

    let listing = TranscriptReader.listing(from: result.standardOutput)
    #expect(listing.directory.hasSuffix(slug))
    #expect(!listing.files.isEmpty)
    // A mount point where an epoch belongs comes back as `nil`.
    #expect(
      listing.files.allSatisfy { $0.age != nil },
      "no usable mtime — check which stat spelling this host has"
    )
    #expect(listing.files.allSatisfy { $0.sizeInBytes > 0 })
    #expect(listing.files.allSatisfy { $0.path.hasPrefix("/") })
    print("[live] \(listing.files.count) session files in \(slug)")
  }

  /// If this drifts by an order of magnitude, `TranscriptCommands.readCommand`'s documented
  /// cost and the pager's copy are wrong.
  @Test("a first page costs what the design says it costs")
  func firstPageCost() async throws {
    let directory = try #require(Self.probeDirectory(), "no Claude sessions on this machine")
    let reader = TranscriptReader(run: Self.localRunner)
    let pane = Pane(
      id: "probe",
      tabID: "t",
      workspaceID: "w",
      title: "probe",
      agent: Agent(name: "Claude", kind: "claude", status: .idle),
      directory: directory
    )

    let resolution = try await reader.resolve(for: pane)
    guard let source = resolution.source else {
      // Ambiguity is legitimate here; this machine runs several agents at once.
      print("[live] \(directory) did not resolve to one file: \(resolution)")
      return
    }

    let transcript = try await reader.read(source.file)
    print(
      """
      [live] \(source.file.name)
             file \(source.file.sizeInBytes) B, age \(source.file.age.map { Int($0) } ?? -1) s
             fetched \(transcript.window.bytesFetched) B \
      of \(transcript.window.bytesRead) B read
             \(transcript.turns.count) turns, \(transcript.window.records) records, \
      outcome \(transcript.outcome)
      """
    )

    // What crossed the wire is a fraction of what was read.
    if transcript.window.bytesRead > 64 * 1024 {
      #expect(transcript.window.bytesFetched < transcript.window.bytesRead)
    }
    // A byte tail starts mid-record, so at most one record is unreadable.
    #expect(transcript.window.unreadableRecords <= 1)
    #expect(transcript.window.fileSizeInBytes == source.file.sizeInBytes)

    // Every assistant record carries `message.usage`, and whole lines are sent.
    print("[live] context \(transcript.contextUsage.map(\.breakdown) ?? "none")")
    if transcript.turns.contains(where: \.isAssistant) {
      #expect(transcript.contextUsage.map { $0.totalTokens > 0 } == true)
    }
  }

  // MARK: - Codex rollouts

  /// `TranscriptCommands.codexListCommand()` against this machine's `~/.codex/sessions`, and a
  /// full read of the newest `user`-thread rollout.
  @Test("Codex: the listing walks real day directories and a main-thread file reads")
  func codexListingAndReadAreReal() async throws {
    let start = Date()
    let listing = try await Self.localRunner(TranscriptCommands.codexListCommand())
    let elapsed = Date().timeIntervalSince(start)
    #expect(listing.exitStatus == 0)
    #expect(listing.standardError.isEmpty, "the Codex listing wrote to stderr: \(listing.standardError)")

    let all = CodexRollouts.candidates(from: listing.standardOutput)
    guard !all.isEmpty else {
      print("[live] no Codex rollouts on this machine")
      return
    }
    #expect(all.allSatisfy { $0.path.hasPrefix("/") })
    print("[live] \(all.count) Codex rollouts across day directories, listed in \(elapsed)s")

    let mainThread = all.filter(\.isMainThread)
    guard let newest = mainThread.max(by: { ($0.modified ?? 0) < ($1.modified ?? 0) }) else {
      print("[live] no user-thread Codex rollout on this machine")
      return
    }

    let read = try await Self.localRunner(
      TranscriptCommands.codexReadCommand(path: newest.path, bytes: 8 * 1024 * 1024, records: 4000)
    )
    #expect(read.exitStatus == 0)
    guard let newline = read.standardOutput.firstIndex(of: "\n") else {
      Issue.record("Codex read produced no header line for \(newest.path)")
      return
    }
    let header = read.standardOutput[read.standardOutput.startIndex..<newline]
    let body = String(read.standardOutput[read.standardOutput.index(after: newline)...])
    let page = TranscriptParser.codexPage(from: body)
    // Codex's usage is in records its selector does not send, so there is no count.
    #expect(page.contextUsage == nil)

    print(
      """
      [live] \(newest.path)
             id \(newest.id), thread_source \(newest.threadSource), cwd \(newest.cwd)
             header \(header)
             \(page.turns.count) turns, \(page.records) records, \
      \(page.unreadableRecords) unreadable
             human \(page.turns.filter(\.isHuman).count), assistant \(page.turns.filter(\.isAssistant).count), \
      tool runs \(page.turns.compactMap(\.toolRun).count)
      """
    )

    // At most one unreadable record, as for Claude.
    #expect(page.unreadableRecords <= 1)

    // The outcome join against a real rollout, because a wrong `awk` program passes every test
    // that never runs it. One page is a small sample, so this checks only that some pairing
    // happened.
    let calls = page.turns.compactMap(\.toolRun).flatMap(\.calls)
    let succeeded = calls.filter { $0.outcome == .succeeded }.count
    let failed = calls.filter { $0.outcome == .failed }.count
    let pending = calls.filter { $0.outcome == .pending }.count
    let unknown = calls.filter { $0.outcome == .unknown }.count
    print(
      "[live] outcomes: \(succeeded) succeeded, \(failed) failed, \(pending) pending, "
        + "\(unknown) unknown, of \(calls.count) calls"
    )
    if calls.contains(where: { $0.name == "exec" }) {
      #expect(
        succeeded + failed + pending > 0,
        "an exec call is in this page but none of them ever joined to an outcome"
      )
    } else {
      print("[live] no exec call in this page's window")
    }
  }
}
