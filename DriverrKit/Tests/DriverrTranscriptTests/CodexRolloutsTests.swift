import Foundation
import Testing

@testable import DriverrTranscript

struct CodexRolloutsTests {
  private func candidateLine(
    path: String = "/Users/x/.codex/sessions/2026/09/11/rollout-….jsonl",
    cwd: String = "/Users/x/repo",
    threadSource: String = "user",
    id: String = "01a00000-1111-7222-8333-444455556666",
    modified: String = "1789000000",
    size: String = "3000000"
  ) -> String {
    [path, cwd, threadSource, id, modified, size].joined(separator: "\t")
  }

  @Test("a well-formed listing line becomes a candidate with every field")
  func candidateParses() throws {
    let candidates = CodexRollouts.candidates(from: candidateLine())
    let candidate = try #require(candidates.first)
    #expect(candidate.path == "/Users/x/.codex/sessions/2026/09/11/rollout-….jsonl")
    #expect(candidate.cwd == "/Users/x/repo")
    #expect(candidate.threadSource == "user")
    #expect(candidate.id == "01a00000-1111-7222-8333-444455556666")
    #expect(candidate.modified == 1_789_000_000)
    #expect(candidate.sizeInBytes == 3_000_000)
    #expect(candidate.isMainThread)
  }

  @Test("a line with the wrong field count is dropped rather than guessed at")
  func malformedLineIsDropped() {
    #expect(CodexRollouts.candidates(from: "not\tenough\tfields").isEmpty)
    #expect(CodexRollouts.candidates(from: "\n\n").isEmpty)
  }

  @Test("? fields the host could not read become nil rather than 0")
  func unreadableFieldsBecomeNil() throws {
    let candidate = try #require(
      CodexRollouts.candidates(
        from: candidateLine(modified: "?", size: "?")
      ).first
    )
    #expect(candidate.modified == nil)
    #expect(candidate.sizeInBytes == nil)
  }

  @Test("subagent and guardian_review threads are not the main thread")
  func onlyUserIsMainThread() {
    for source in ["subagent", "guardian_review", "", "USER"] {
      let candidate = CodexRollouts.candidates(from: candidateLine(threadSource: source)).first
      #expect(candidate?.isMainThread == false, "\(source) should not be the main thread")
    }
  }

  @Test("main-thread candidates are filtered by thread source and exact working directory")
  func mainThreadCandidatesFilters() {
    let output = [
      candidateLine(path: "/a", cwd: "/repo", threadSource: "user"),
      candidateLine(path: "/b", cwd: "/repo", threadSource: "subagent"),
      candidateLine(path: "/c", cwd: "/other", threadSource: "user"),
      candidateLine(path: "/d", cwd: "/repo/", threadSource: "user"),
    ].joined(separator: "\n")
    let found = CodexRollouts.mainThreadCandidates(from: output, workingDirectory: "/repo")
    #expect(found.map(\.path) == ["/a", "/d"], "a trailing slash on either side must not break the match")
  }

  @Test("a directory that never matches yields nothing, not everything")
  func noMatchYieldsEmpty() {
    let output = candidateLine(cwd: "/repo", threadSource: "user")
    #expect(CodexRollouts.mainThreadCandidates(from: output, workingDirectory: "/elsewhere").isEmpty)
  }

  /// A real host's `wc -c` output is space-padded, so `candidates(from:)` must trim it or no
  /// size parses as an `Int`.
  @Test("wc -c's space-padded size is trimmed before it is parsed as an Int")
  func spacePaddedSizeIsTrimmed() throws {
    let candidate = try #require(
      CodexRollouts.candidates(from: candidateLine(modified: "  1789000000", size: " 3000000")).first
    )
    #expect(candidate.modified == 1_789_000_000)
    #expect(candidate.sizeInBytes == 3_000_000)
  }
}
