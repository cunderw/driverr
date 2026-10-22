import DriverrCore
import Testing

@testable import DriverrTranscript

/// A `TaskStop` that names a teammate by its agent id, not by its name.
///
/// **Both shapes are live.** Claude Code as of 2026-10-13 wrote `task_id` as the name the
/// teammate was spawned under (`"scout"`), and its spawn answer's `agent_id` was
/// `name@team`. As of 2026-10-22 `task_id` is the answer's `agentId`
/// (`"a" + name + "-" + 16 hex`), so a stop keyed on the name matches nothing: the spawn
/// line never says `Stopped`, and the stop line shows the bare id. The lines below are
/// trimmed from a real session of that version, with the prompts and names replaced.
@Suite("A teammate stopped by its agent id")
struct TranscriptTeammateStopByAgentIDTests {
  private static let agentID = "aanalyst-7-0123456789abcdef"

  private static let lines = [
    Fixture.toolUse(
      "Agent",
      input: #"{"subagent_type":"analyst","name":"analyst-7","description":"Plan the pool","prompt":"Read the issue"}"#,
      id: "toolu_s", uuid: "s1"),
    Fixture.assistant("The analyst is working.", uuid: "s2"),
    Fixture.toolUse("TaskStop", input: #"{"task_id":"\#(agentID)"}"#, id: "toolu_x", uuid: "s3"),
    Fixture.resultsScanned,
    Fixture.spawnResult(id: "toolu_s", status: "teammate_spawned", agentID: agentID),
    Fixture.result(id: "toolu_x"),
  ]

  private func events() -> [TranscriptTurn.AgentEvent] {
    TranscriptParser.page(from: Self.lines.joined(separator: "\n")).turns.compactMap(\.agentEvent)
  }

  @Test("the spawn line reads stopped")
  func spawnLineReadsStopped() throws {
    let spawn = try #require(events().first { $0.kind == .spawned })
    #expect(spawn.task?.state == .stopped)
  }

  @Test("the stop line names the teammate and its brief, not the agent id")
  func stopLineNamesTheTeammate() throws {
    let stop = try #require(events().first { $0.kind == .stopped })
    #expect(stop.summary == "Plan the pool")
    #expect(stop.line == "Stopped analyst-7 · Plan the pool")
  }
}
