import DriverrCore
import Foundation
import Testing

@testable import DriverrTranscript

/// `TranscriptReader.subagentList(from:readAt:)` on answers shaped like a host's, and the
/// fake host's answer read back through the real reader. The meta lines are trimmed from real
/// files of Claude Code as of 2026-10-22, with names and briefs replaced.
@Suite("Sub-agent list reader")
struct SubagentListReaderTests {
  private static let readAt = Date(timeIntervalSince1970: 1_900_000_000)

  private static let teammateMeta =
    #"{"agentType":"exec-subagents","description":"Fix TaskStop and add a list","#
    + #""name":"exec-subagents","spawnDepth":0,"requestShape":"background","#
    + #""model":"opus[1m]","taskKind":"in_process_teammate","teamName":"session-4e568fe3","#
    + #""customAgentType":"executor","spawnedAgentType":"executor","permissionMode":"auto"}"#
  private static let plainMeta =
    #"{"agentType":"Explore","launchedWithDefaults":true,"description":"Judge a candidate","#
    + #""toolUseId":"toolu_01KyouBhuktvfGFRdr28FgXe","spawnDepth":1,"finished":true}"#

  /// BSD `wc` pads both counts with spaces, as a Mac host prints them.
  private static let answer = [
    "1792649108",
    "/Users/me/.claude/projects/-Users-me-dev/sess1/subagents",
    "#       3",
    "1792649074\t1792649106\t  528259\tagent-aexec-subagents-4e3d51c1e2190d37.jsonl\t\(teammateMeta)",
    "1792640000\t1792641000\t   1200\tagent-a0000000000000004.jsonl\t\(plainMeta)",
    // A meta that does not decode is dropped and still counted.
    "1792630000\t1792630000\t     10\tagent-abroken.jsonl\t{\"agentType\":",
  ].joined(separator: "\n") + "\n"

  @Test("each meta line maps to a summary, the teammate's type from spawnedAgentType")
  func mapsEachLine() throws {
    let list = TranscriptReader.subagentList(from: Self.answer, readAt: Self.readAt)
    #expect(list.total == 3)
    #expect(list.summaries.map(\.id) == ["aexec-subagents-4e3d51c1e2190d37", "a0000000000000004"])
    let teammate = try #require(list.summaries.first)
    #expect(teammate.name == "exec-subagents")
    #expect(teammate.agentType == "executor")
    #expect(teammate.toolUseID == nil)
    #expect(teammate.link == .teammate(name: "exec-subagents"))
    #expect(!teammate.isFinished)
    let plain = try #require(list.summaries.last)
    #expect(plain.name == nil)
    #expect(plain.agentType == "Explore")
    #expect(plain.link == .toolUse(id: "toolu_01KyouBhuktvfGFRdr28FgXe"))
    #expect(plain.isFinished)
  }

  @Test("ages are the host's subtraction, placed on the reader's clock")
  func agesAreTheHosts() throws {
    let list = TranscriptReader.subagentList(from: Self.answer, readAt: Self.readAt)
    let teammate = try #require(list.summaries.first)
    #expect(teammate.spawnedAt == Self.readAt.addingTimeInterval(-34))
    #expect(teammate.writtenAt == Self.readAt.addingTimeInterval(-2))
  }

  @Test("an mtime that is not an epoch gives no date, not a wrong one")
  func unknownMtime() throws {
    let answer = "1792649108\n/d\n#1\n?\t?\t?\tagent-a1.jsonl\t\(Self.plainMeta)\n"
    let list = TranscriptReader.subagentList(from: answer, readAt: Self.readAt)
    let only = try #require(list.summaries.first)
    #expect(only.spawnedAt == nil)
    #expect(only.writtenAt == nil)
  }

  @Test("a teammate whose agentType is not its name keeps it")
  func aTypeThatIsNotTheName() throws {
    let meta = #"{"agentType":"asset-research","name":"research-1","taskKind":"in_process_teammate"}"#
    let answer = "1\n/d\n#1\n1\t1\t1\tagent-aresearch-1-00.jsonl\t\(meta)\n"
    let only = try #require(TranscriptReader.subagentList(from: answer, readAt: Self.readAt).summaries.first)
    #expect(only.agentType == "asset-research")
  }

  @Test("a directory with no meta files is an empty list")
  func noMetaFiles() {
    #expect(TranscriptReader.subagentList(from: "1792649108\n/d\n#       0\n", readAt: Self.readAt).isEmpty)
    #expect(TranscriptReader.subagentList(from: "1792649108\n/d\n", readAt: Self.readAt).isEmpty)
  }

  @Test("the command names the session's own subagents directory, quoted, capped")
  func command() {
    let command = TranscriptCommands.subagentListCommand(
      directory: "/home/me/.claude/projects/-home-me-dev", sessionID: "sess-1")
    #expect(command.hasPrefix("\(TranscriptCommands.literalEmptyGlobs); date +%s; "))
    #expect(command.contains("d=/home/me/.claude/projects/-home-me-dev/sess-1/subagents;"))
    #expect(
      TranscriptCommands.subagentListCommand(directory: "/home/a b", sessionID: "s")
        .contains("d='/home/a b/s/subagents';"))
    #expect(command.contains("\(TranscriptCommands.subagentListSelector) 2>/dev/null | head -n 50"))
    // The `.jsonl` is measured, never read.
    #expect(!command.contains("cat "))
    #expect(!command.contains("tail "))
  }

  @Test("the fake host's sub-agents come back through the real reader")
  func fakeHostRoundTrip() async throws {
    let host = FakeTranscriptHost(sessionID: "sess1", turns: []).serving([
      .init(
        agentID: "averifier7", name: "verifier-7", isTeammate: true, secondsAgo: 10,
        prompt: "Review", description: "Review the loader", agentType: "verifier",
        spawnedSecondsAgo: 900),
      .init(
        agentID: "aexplore1", toolUseID: "toolu_9", secondsAgo: 7000, prompt: "Find",
        description: "Find the callers", agentType: "Explore", isFinished: true,
        spawnedSecondsAgo: 7200),
    ])
    let reader = TranscriptReader(run: host.run)
    let list = try await reader.subagentList(directory: host.directory, sessionID: "sess1")
    #expect(list.total == 2)
    #expect(list.summaries.map(\.title) == ["verifier-7", "Explore"])
    #expect(list.summaries.first?.agentType == "verifier")
    #expect(list.summaries.first?.link == .teammate(name: "verifier-7"))
    #expect(list.summaries.last?.link == .toolUse(id: "toolu_9"))
    #expect(list.summaries.last?.isFinished == true)
  }

  @Test("a fake host with no sub-agents lists none")
  func fakeHostWithNone() async throws {
    let host = FakeTranscriptHost(sessionID: "sess1", turns: [])
    let list = try await TranscriptReader(run: host.run)
      .subagentList(directory: host.directory, sessionID: "sess1")
    #expect(list.isEmpty)
  }
}
