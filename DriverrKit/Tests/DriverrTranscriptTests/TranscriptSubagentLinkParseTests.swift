import DriverrCore
import Testing

@testable import DriverrTranscript

/// The link a spawn line opens its sub-agent's file by.
@Suite("A spawn line's link to its sub-agent's file")
struct TranscriptSubagentLinkParseTests {
  private func spawnEvents(_ lines: [String], forSubagentFile: Bool = false) -> [TranscriptTurn.AgentEvent] {
    TranscriptParser.page(from: lines.joined(separator: "\n"), forSubagentFile: forSubagentFile)
      .turns.compactMap(\.agentEvent).filter { $0.kind == .spawned }
  }

  private static func spawn(id: String, input: String) -> String {
    Fixture.toolUse("Agent", input: input, id: id, uuid: "sp-\(id)")
  }

  private static let named = #"{"subagent_type":"analyst","name":"analyst-7","description":"Plan it"}"#
  private static let unnamed = #"{"subagent_type":"analyst","description":"Plan it"}"#

  @Test("a plain spawn links by its own tool-use id")
  func plainSpawnLinksByID() {
    let events = spawnEvents([
      Self.spawn(id: "toolu_a", input: Self.named),
      Fixture.resultsScanned,
      Fixture.spawnResult(id: "toolu_a", status: "async_launched", agentID: "a1"),
    ])
    #expect(events.map(\.link) == [.toolUse(id: "toolu_a")])
  }

  /// A spawn still waiting on its answer is a running sync one, and its meta carries the id.
  @Test("an unanswered spawn links by its tool-use id")
  func unansweredSpawnLinksByID() {
    let events = spawnEvents([Self.spawn(id: "toolu_a", input: Self.named)])
    #expect(events.map(\.link) == [.toolUse(id: "toolu_a")])
  }

  /// A teammate's meta has no `toolUseId`. Its link is the name, and it has to survive
  /// `settleSpawns`, which rebuilds every teammate event.
  @Test("a teammate links by the name it was spawned under")
  func teammateLinksByName() {
    let events = spawnEvents([
      Self.spawn(id: "toolu_t", input: Self.named),
      Fixture.resultsScanned,
      Fixture.spawnResult(id: "toolu_t", status: "teammate_spawned"),
    ])
    #expect(events.map(\.link) == [.teammate(name: "analyst-7")])
    #expect(events.first?.task?.state == .running)
  }

  /// The line falls back to `subagent_type` for its text, but a meta's `name` is never a
  /// type, so the fallback must not become a link.
  @Test("a teammate with no name gets no link, never one by its subagent_type")
  func teammateWithoutNameHasNoLink() {
    let events = spawnEvents([
      Self.spawn(id: "toolu_t", input: Self.unnamed),
      Fixture.resultsScanned,
      Fixture.spawnResult(id: "toolu_t", status: "teammate_spawned"),
    ])
    #expect(events.count == 1)
    #expect(events.first?.sender == "analyst")
    #expect(events.first?.link == nil)
  }

  @Test("a spawn with an empty tool-use id gets no link")
  func emptyIDHasNoLink() {
    let events = spawnEvents([Self.spawn(id: "", input: Self.named)])
    #expect(events.count == 1)
    #expect(events.first?.link == nil)
  }

  /// The chat opens one level of sub-agent.
  @Test("a spawn inside a sub-agent's own file gets no link")
  func noLinkInsideASubagentFile() {
    let events = spawnEvents(
      [
        Fixture.subagentPrompt("Plan it"),
        Self.spawn(id: "toolu_n", input: Self.named),
      ],
      forSubagentFile: true)
    #expect(events.count == 1)
    #expect(events.first?.link == nil)
  }

  @Test("a stop and a sent message carry no link")
  func onlySpawnsLink() {
    let turns = TranscriptParser.page(
      from: [
        Fixture.toolUse("TaskStop", input: #"{"task_id":"analyst-7"}"#, id: "toolu_s", uuid: "s1"),
        Fixture.toolUse(
          "SendMessage", input: #"{"to":"analyst-7","summary":"Hi"}"#, id: "toolu_m", uuid: "m1"),
      ].joined(separator: "\n")
    ).turns
    #expect(turns.compactMap(\.agentEvent).count == 2)
    #expect(turns.compactMap(\.agentEvent).allSatisfy { $0.link == nil })
  }
}
