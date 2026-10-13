import DriverrCore
import Foundation

/// Where Codex CLI keeps a rollout, and how to pick a pane's own thread out of them.
///
/// Rollouts are `~/.codex/sessions/<yyyy>/<mm>/<dd>/rollout-<timestamp>-<uuid>.jsonl`.
/// Line 1 is always a `session_meta` record whose `payload.id` is the filename's uuid.
///
/// `thread_source` is `user` (the pane's thread), `subagent` or `guardian_review` (Codex's
/// safety reviewer, in its own file). Only `user` is read; the others are skipped.
///
/// On a `user` thread `session_id == id == filename uuid`; on the others only `id`
/// matches. herdr reports the thread id as `agent_session`, so the listing prints `id`,
/// which is what the reported-session rule can match.
///
/// Raw-byte matching on line 1 is safe for `TranscriptCommands.recordSelector`'s reason:
/// each key pattern occurs once on line 1, and a quote inside a JSON string is escaped, so
/// no transcript text can forge one.
enum CodexRollouts {
  /// Where the day directories live, as a shell fragment the host expands. `$HOME`, for
  /// `ClaudeProjects.root`'s reason.
  static let root = "\"$HOME/.codex/sessions\""

  static let fileExtension = "jsonl"

  /// The `thread_source` of a pane's own conversation.
  static let mainThreadSource = "user"

  /// How many day directories the listing walks, newest first. Bounded so months of
  /// rollouts do not turn a listing into a tree walk.
  static let maxDayDirectories = 30

  /// One rollout's line-1 header plus mtime and size, as `codexListCommand()` prints it.
  struct Candidate {
    let path: String
    let cwd: String
    let threadSource: String
    /// The filename's uuid, from `payload.id`. See this file's header for why not
    /// `session_id`.
    let id: String
    /// `nil` when the host printed `?` for the mtime.
    let modified: TimeInterval?
    let sizeInBytes: Int?

    var isMainThread: Bool { threadSource == mainThreadSource }
  }

  /// `path<TAB>cwd<TAB>threadSource<TAB>id<TAB>mtime<TAB>size` lines in, one candidate per
  /// line out. A malformed line is dropped, not guessed at.
  static func candidates(from output: String) -> [Candidate] {
    output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
      let fields = line.split(
        separator: TranscriptCommands.fieldSeparator,
        maxSplits: 5,
        omittingEmptySubsequences: false
      )
      guard fields.count == 6 else { return nil }
      let path = trimmed(String(fields[0]))
      guard !path.isEmpty else { return nil }
      return Candidate(
        path: path,
        cwd: trimmed(String(fields[1])),
        threadSource: trimmed(String(fields[2])),
        id: trimmed(String(fields[3])),
        modified: epoch(trimmed(String(fields[4]))),
        sizeInBytes: Int(trimmed(String(fields[5])))
      )
    }
  }

  /// Main-thread candidates whose `cwd` equals the working directory exactly. Codex records
  /// the literal path, so there is no slug. Trailing slashes are stripped from both sides.
  static func mainThreadCandidates(
    from output: String, workingDirectory: String
  ) -> [Candidate] {
    let wanted = withoutTrailingSlash(workingDirectory)
    return candidates(from: output).filter {
      $0.isMainThread && withoutTrailingSlash($0.cwd) == wanted
    }
  }

  /// This pane's rollouts, newest first, each with an age.
  ///
  /// Line 1 is the host's `date +%s`. It is peeled here, not in `candidates(from:)`, because
  /// tests hand that function a bare body and it would eat a candidate. The age arithmetic
  /// matches `TranscriptReader.listing(from:)`: host clock minus host mtime, clamped at zero,
  /// and `nil` when unknown so the file sorts last.
  static func listing(from output: String, workingDirectory: String) -> [TranscriptFile] {
    var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let now = lines.first.flatMap { epoch(trimmed($0)) }
    if !lines.isEmpty { lines.removeFirst() }

    let body = lines.joined(separator: "\n")
    let mine = mainThreadCandidates(from: body, workingDirectory: workingDirectory)
    return TranscriptFile.newestFirst(
      mine.map { candidate in
        let age: TimeInterval? = {
          guard let now, let modified = candidate.modified, modified > 0 else { return nil }
          return max(0, now - modified)
        }()
        return TranscriptFile(
          path: candidate.path,
          sizeInBytes: candidate.sizeInBytes ?? 0,
          age: age,
          agent: .codex
        )
      }
    )
  }

  /// The rollout whose header `id` equals the reported session. Codex puts the uuid in the
  /// middle of the filename, so this matches the header field, not the name.
  static func candidate(
    withID id: String, from output: String, workingDirectory: String
  ) -> Candidate? {
    var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if !lines.isEmpty { lines.removeFirst() }
    return mainThreadCandidates(
      from: lines.joined(separator: "\n"), workingDirectory: workingDirectory
    ).first { $0.id == id }
  }

  private static func withoutTrailingSlash(_ path: String) -> String {
    var path = path
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }

  /// An epoch second, or nothing. A `stat -f` mount point read as an mtime would otherwise
  /// make a rollout look decades old.
  private static func epoch(_ field: String) -> TimeInterval? {
    guard !field.isEmpty, field.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    return TimeInterval(field)
  }
}

private func trimmed(_ value: String) -> String {
  value.trimmingCharacters(in: .whitespacesAndNewlines)
}
