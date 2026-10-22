import DriverrCore
import Foundation
import Testing

/// The chat's sub-agent list: its order, its links, and where each row's state comes from.
@Suite("Sub-agent list")
struct SubagentListTests {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)

  private static func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

  private static let teammate = SubagentSummary(
    id: "averifier-0123", name: "verifier-7", description: "Review the loader",
    agentType: "verifier", spawnedAt: ago(1000), writtenAt: ago(600))
  private static let plain = SubagentSummary(
    id: "a0004", description: "Find the callers", agentType: "Explore", toolUseID: "toolu_1",
    spawnedAt: ago(3000), writtenAt: ago(2900))
  private static let finished = SubagentSummary(
    id: "a0005", description: "Judge the candidates", agentType: "Explore", toolUseID: "toolu_2",
    isFinished: true, spawnedAt: ago(7200), writtenAt: ago(7000))
  private static let live = SubagentSummary(
    id: "a0006", description: "Read the diff", agentType: "Explore", toolUseID: "toolu_3",
    spawnedAt: ago(100), writtenAt: ago(5))

  private static func spawn(
    _ link: SubagentLink, _ state: TaskProgress.State, id: String, agentID: String? = nil
  ) -> TranscriptTurn {
    TranscriptTurn(
      id: id,
      speech: .agentEvent(
        .init(
          sender: "x", summary: nil, body: "", kind: .spawned,
          task: TaskProgress(state: state, startedAt: ago(1000)), link: link, agentID: agentID)))
  }

  /// A teammate stopped and spawned again under the same name: a meta and a file per spawn.
  private static let firstSpawn = SubagentSummary(
    id: "averifier-7-first", name: "verifier-7", agentType: "verifier", spawnedAt: ago(2000),
    writtenAt: ago(1500))
  private static let secondSpawn = SubagentSummary(
    id: "averifier-7-second", name: "verifier-7", agentType: "verifier", spawnedAt: ago(900),
    writtenAt: ago(5))

  @Test("a respawned teammate's rows each take their own spawn line, joined by agent id")
  func aRespawnJoinsByAgentID() {
    let rows = SubagentList(total: 2, summaries: [Self.firstSpawn, Self.secondSpawn]).rows(
      merging: [
        Self.spawn(.teammate(name: "verifier-7"), .stopped, id: "t1", agentID: "averifier-7-first"),
        Self.spawn(.teammate(name: "verifier-7"), .running, id: "t2", agentID: "averifier-7-second"),
      ],
      asOf: Self.now)
    #expect(rows.map(\.id) == ["averifier-7-second", "averifier-7-first"])
    #expect(rows.map(\.state) == [.running, .stopped])
    #expect(rows.map(\.summary.link) == [.agent(id: "averifier-7-second"), .agent(id: "averifier-7-first")])
  }

  /// An older Claude Code wrote a teammate's answer id as `name@team`, which names no file.
  @Test("without agent ids, a respawned name pairs its newest spawn line with its newest row")
  func aRespawnPairsByName() {
    let rows = SubagentList(total: 2, summaries: [Self.firstSpawn, Self.secondSpawn]).rows(
      merging: [
        Self.spawn(.teammate(name: "verifier-7"), .stopped, id: "t1", agentID: "verifier-7@team"),
        Self.spawn(.teammate(name: "verifier-7"), .running, id: "t2", agentID: "verifier-7@team"),
      ],
      asOf: Self.now)
    #expect(rows.map(\.state) == [.running, .stopped])
  }

  @Test("a row left over after its name's spawn lines takes nothing from the page")
  func aRowWithNoSpawnLineLeft() {
    let rows = SubagentList(total: 2, summaries: [Self.firstSpawn, Self.secondSpawn]).rows(
      merging: [Self.spawn(.teammate(name: "verifier-7"), .running, id: "t2")], asOf: Self.now)
    #expect(rows.first?.state == .running)
    #expect(rows.last?.task == nil)
    #expect(rows.last?.state == nil, "written 25m ago, so not running, and not the page's")
  }

  @Test("newest spawned first, whatever order the host printed")
  func newestSpawnedFirst() {
    let list = SubagentList(total: 4, summaries: [Self.finished, Self.live, Self.plain, Self.teammate])
    #expect(list.summaries.map(\.id) == ["a0006", "averifier-0123", "a0004", "a0005"])
  }

  @Test("the total is never below the rows the host printed")
  func totalCoversTheRows() {
    #expect(SubagentList(total: 0, summaries: [Self.plain]).total == 1)
    #expect(SubagentList(total: 243, summaries: [Self.plain]).total == 243)
    #expect(SubagentList.empty.isEmpty)
  }

  @Test("a plain spawn links by its tool-use id, a teammate by its name")
  func links() {
    #expect(Self.plain.pageLink == .toolUse(id: "toolu_1"))
    #expect(Self.teammate.pageLink == .teammate(name: "verifier-7"))
    #expect(SubagentSummary(id: "a1").pageLink == nil)
    // A row opens its own file, whatever the page would link by.
    #expect(Self.plain.link == .agent(id: "a0004"))
    #expect(Self.teammate.link == .agent(id: "averifier-0123"))
  }

  @Test("the title is the name, else the type, else the description")
  func titles() {
    #expect(Self.teammate.title == "verifier-7")
    #expect(Self.plain.title == "Explore")
    #expect(SubagentSummary(id: "a1", description: "Only a brief").title == "Only a brief")
    #expect(SubagentSummary(id: "a1").title == "a1")
  }

  @Test("a spawn line on the page wins, joined by link")
  func thePageWins() {
    let list = SubagentList(total: 2, summaries: [Self.teammate, Self.finished])
    let rows = list.rows(
      merging: [
        Self.spawn(.teammate(name: "verifier-7"), .idle, id: "t1"),
        // The meta says finished, the page says it failed. The page is read later and says
        // more.
        Self.spawn(.toolUse(id: "toolu_2"), .failed, id: "t2"),
      ],
      asOf: Self.now)
    #expect(rows.map(\.state) == [.idle, .failed])
    #expect(rows[0].statusLine(asOf: Self.now) == "Idle")
  }

  @Test("a later spawn line under the same link wins")
  func theLaterSpawnWins() {
    let rows = SubagentList(total: 1, summaries: [Self.teammate]).rows(
      merging: [
        Self.spawn(.teammate(name: "verifier-7"), .stopped, id: "t1"),
        Self.spawn(.teammate(name: "verifier-7"), .running, id: "t2"),
      ],
      asOf: Self.now)
    #expect(rows.first?.state == .running)
  }

  @Test("with nothing on the page, the meta's finished and then the file's age decide")
  func offThePage() {
    let list = SubagentList(total: 3, summaries: [Self.finished, Self.live, Self.plain])
    let rows = list.rows(merging: [], asOf: Self.now)
    let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    #expect(byID["a0005"]?.state == .finished)
    #expect(byID["a0005"]?.statusLine(asOf: Self.now) == "Finished · 1h ago")
    #expect(byID["a0006"]?.state == .running)
    #expect(byID["a0006"]?.statusLine(asOf: Self.now) == "Running")
    // Quiet for 48 minutes: idle or done, and the row does not guess which.
    #expect(byID["a0004"]?.state == nil)
    #expect(byID["a0004"]?.statusLine(asOf: Self.now) == "Written 48m ago")
  }

  @Test("a file written inside the live window reads running, and one minute out does not")
  func theLiveWindow() {
    let edge = SubagentSummary(id: "a", toolUseID: "t", writtenAt: Self.ago(SubagentList.liveWindow))
    let inside = SubagentSummary(id: "b", toolUseID: "u", writtenAt: Self.ago(SubagentList.liveWindow - 1))
    let rows = SubagentList(total: 2, summaries: [edge, inside]).rows(merging: [], asOf: Self.now)
    #expect(rows.first { $0.id == "a" }?.state == nil)
    #expect(rows.first { $0.id == "b" }?.state == .running)
  }

  @Test("a sub-agent with no file yet reads as starting")
  func noFileYet() {
    let rows = SubagentList(total: 1, summaries: [SubagentSummary(id: "a", toolUseID: "t")])
      .rows(merging: [], asOf: Self.now)
    #expect(rows.first?.statusLine(asOf: Self.now) == "Starting")
  }

  @Test("a spawn line from the page brings its own label, with its time")
  func thePagesLabel() {
    let rows = SubagentList(total: 1, summaries: [Self.plain]).rows(
      merging: [Self.spawn(.toolUse(id: "toolu_1"), .running, id: "t1")], asOf: Self.now)
    #expect(rows.first?.statusLine(asOf: Self.now) == "Running · 16m")
  }

  @Test("the header counts every sub-agent and the running ones")
  func header() {
    #expect(TranscriptChatCopy.subagentCount(total: 3, running: 1) == "3 sub-agents · 1 running")
    #expect(TranscriptChatCopy.subagentCount(total: 1, running: 0) == "1 sub-agent")
    #expect(TranscriptChatCopy.subagentCount(total: 2, running: 2) == "2 sub-agents · 2 running")
    #expect(TranscriptChatCopy.subagentListCapped(shown: 50, of: 243) == "The newest 50 of 243")
  }

  @Test("a row reads as one statement")
  func accessibility() {
    let row = SubagentRow(summary: Self.plain, task: nil, state: nil)
    #expect(row.accessibilityLabel(asOf: Self.now) == "Explore, Find the callers, Written 48m ago")
  }
}
