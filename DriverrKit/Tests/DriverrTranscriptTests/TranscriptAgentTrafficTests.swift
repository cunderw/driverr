import DriverrCore
import Foundation
import Testing

@testable import DriverrTranscript

/// What a session driving a team of agents writes about itself, and what the chat makes of
/// it. `Agent`, `TaskStop`, `SendMessage` and `ScheduleWakeup` get a per-tool reading of
/// their input, and the three that are events leave the tool run for their own line.
///
/// The fields are the ones Claude Code writes: `TaskStop` always has `task_id`,
/// `SendMessage` always has `to`, `summary` and `message`, `Agent` always has
/// `subagent_type`, `name` and `description`, and every stop resolved against the file's
/// own spawns.
@Suite("A session driving a team of agents")
struct TranscriptAgentTrafficTests {
  private func turns(_ lines: [String]) -> [TranscriptTurn] {
    TranscriptParser.page(from: lines.joined(separator: "\n")).turns
  }

  private func events(_ lines: [String]) -> [TranscriptTurn.AgentEvent] {
    turns(lines).compactMap(\.agentEvent)
  }

  private func target(_ name: String, input: String) -> String? {
    turns([Fixture.toolUse(name, input: input)]).first?.toolRun?.calls.first?.target
  }

  // MARK: - A spawn

  /// The id the team addresses the agent by, which its own `TaskStop` will name, not
  /// `subagent_type`.
  @Test("an Agent call is a line of its own, naming the agent and its brief")
  func aSpawnIsItsOwnLine() throws {
    let event = try #require(
      events([
        Fixture.toolUse(
          "Agent",
          input: #"""
            {"subagent_type":"analyst","name":"analyst-1",\#
            "description":"Plan the async pool migration","prompt":"Read the issue"}
            """#)
      ]).first)

    #expect(event.kind == .spawned)
    #expect(event.sender == "analyst-1")
    #expect(event.summary == "Plan the async pool migration")
    #expect(event.line == "Started analyst-1 · Plan the async pool migration")
  }

  /// A spawn counted as a tool call would still be one anonymous entry in a tally.
  @Test("a spawn is not a tool call")
  func aSpawnIsNotACall() {
    let page = turns([Fixture.toolUse("Agent", input: #"{"name":"p-1","description":"Plan it"}"#)])
    #expect(page.count == 1)
    #expect(page.first?.toolRun == nil)
  }

  /// `subagent_type` stands in, and `Started analyst` is still true.
  @Test("a spawn with no name falls back to its subagent type")
  func aSpawnWithNoName() throws {
    let event = try #require(
      events([
        Fixture.toolUse("Agent", input: #"{"subagent_type":"finder","description":"Survey the backlog"}"#)
      ]).first)
    #expect(event.line == "Started finder · Survey the backlog")
  }

  /// No purpose is invented.
  @Test("a spawn with no description says the agent's name and stops")
  func aSpawnWithNoDescription() throws {
    let event = try #require(
      events([Fixture.toolUse("Agent", input: #"{"subagent_type":"finder","name":"finder-10"}"#)])
        .first)
    #expect(event.summary == nil)
    #expect(event.line == "Started finder-10")
  }

  // MARK: - A stop

  /// `task_id` is only an id; the page's earlier `Agent` call turns it into a title.
  @Test("a TaskStop names what it stopped, read off this page's own spawn")
  func aStopResolvesThroughTheSpawn() throws {
    let lines = [
      Fixture.toolUse(
        "Agent",
        input: #"{"subagent_type":"analyst","name":"analyst-1","description":"Plan the pool"}"#,
        id: "toolu_a", uuid: "a1"),
      Fixture.assistant("Analyst is away.", uuid: "a2"),
      Fixture.toolUse("TaskStop", input: #"{"task_id":"analyst-1"}"#, id: "toolu_b", uuid: "a3"),
    ]
    let stopped = try #require(events(lines).last)
    #expect(stopped.kind == .stopped)
    #expect(stopped.line == "Stopped analyst-1 · Plan the pool")
  }

  /// A page is a tail, so the spawn can be off its front. The id is the honest answer.
  @Test("a TaskStop whose spawn is off the front of the page keeps the bare id")
  func aStopWithNoSpawnKeepsTheID() throws {
    let stopped = try #require(
      events([Fixture.toolUse("TaskStop", input: #"{"task_id":"verifier-3"}"#)]).first)
    #expect(stopped.summary == nil)
    #expect(stopped.line == "Stopped verifier-3")
  }

  /// The map is built in document order, so nothing reads ahead.
  @Test("a stop is never resolved by a spawn that comes after it")
  func aStopDoesNotReadAhead() throws {
    let stopped = try #require(
      events([
        Fixture.toolUse("TaskStop", input: #"{"task_id":"analyst-1"}"#, id: "t1", uuid: "b1"),
        Fixture.toolUse(
          "Agent", input: #"{"name":"analyst-1","description":"Plan the pool"}"#, id: "t2",
          uuid: "b2"),
      ]).first)
    #expect(stopped.line == "Stopped analyst-1")
  }

  // MARK: - A message out

  @Test("a SendMessage names the recipient and the summary the tool carried")
  func aMessageOut() throws {
    let event = try #require(
      events([
        Fixture.toolUse(
          "SendMessage",
          input: #"""
            {"to":"ana-8","summary":"Ask for the rest of the list",\#
            "message":"The list stopped at item 6."}
            """#)
      ]).first)
    #expect(event.kind == .sent)
    #expect(event.line == "To ana-8 · Ask for the rest of the list")
  }

  /// A message's first line is as often a heading as a sentence, so it is the fallback.
  @Test("a SendMessage with no summary falls back to the message's first line")
  func aMessageOutWithNoSummary() throws {
    let event = try #require(
      events([
        Fixture.toolUse(
          "SendMessage", input: #"{"to":"eng-2","message":"Hold the queue.\nI will say when."}"#)
      ]).first)
    #expect(event.line == "To eng-2 · Hold the queue.")
  }

  // MARK: - The order they were made in

  /// `Agent`, `Bash`, `Agent` in one record becomes event, run, event, as the terminal draws.
  @Test("agent traffic splits a run rather than being folded into it")
  func trafficSplitsARun() {
    let page = turns([
      Fixture.toolUses([
        (name: "Agent", input: #"{"name":"p-1","description":"Plan it"}"#),
        (name: "Bash", input: #"{"description":"cargo test"}"#),
        (name: "Agent", input: #"{"name":"e-1","description":"Build it"}"#),
      ])
    ])

    #expect(page.count == 3)
    #expect(page[0].agentEvent?.line == "Started p-1 · Plan it")
    #expect(page[1].toolRun?.calls.map(\.name) == ["Bash"])
    #expect(page[2].agentEvent?.line == "Started e-1 · Build it")
    // Distinct ids from one record's uuid, which a pager joins pages on.
    #expect(Set(page.map(\.id)).count == 3)
  }

  @Test("an extracted call is in no run's kinds tally")
  func extractedCallsAreNotTallied() {
    let page = turns([
      Fixture.toolUses([
        (name: "Bash", input: #"{"description":"cargo test"}"#),
        (name: "SendMessage", input: #"{"to":"eng-2","summary":"Hold the queue"}"#),
      ])
    ])
    #expect(page.compactMap(\.toolRun).flatMap(\.kinds).map(\.name) == ["Bash"])
  }

  // MARK: - The call the agent is waiting on, behind the traffic

  /// A record issuing `Bash` and `Agent` in parallel leaves the `Bash` unanswered, and the
  /// pane waiting on it must keep its row.
  @Test("a waiting call survives a spawn written after it")
  func aWaitingCallSurvivesATrailingSpawn() throws {
    let page = Transcript(
      turns: turns([
        Fixture.human("run the tests", uuid: "h"),
        Fixture.toolUses([
          (name: "Bash", input: #"{"description":"cargo test"}"#),
          (name: "Agent", input: #"{"name":"p-1","description":"Plan it"}"#),
        ]),
        Fixture.resultsScanned,
      ]),
      window: .none)

    let pending = try #require(page.pendingToolCall)
    #expect(pending.name == "Bash")
    #expect(pending.target == "cargo test")
    #expect(page.turns.last?.agentEvent?.kind == .spawned)
  }

  /// Anything said after the run means the agent was not waiting on that call.
  @Test("a call the agent went on from is not waiting")
  func aCallTheAgentWentOnFromIsNotWaiting() {
    let page = Transcript(
      turns: turns([
        Fixture.toolUse("Bash", input: #"{"description":"cargo test"}"#, id: "t1", uuid: "x1"),
        Fixture.assistant("Done, the suite is green.", uuid: "x2"),
        Fixture.resultsScanned,
      ]),
      window: .none)
    #expect(page.pendingToolCall == nil)
  }

  // MARK: - What the rest of the tools are about

  /// `reason` is for a reader and `prompt` for an agent; the general chain cannot put `prompt`
  /// first without doing so for every tool.
  @Test("a ScheduleWakeup is named by its reason, and by its prompt when it has none")
  func wakeupTargets() {
    #expect(
      target(
        "ScheduleWakeup",
        input: #"{"prompt":"/milestone 0.5","reason":"Fallback while the search runs"}"#)
        == "Fallback while the search runs")
    #expect(
      target("ScheduleWakeup", input: #"{"prompt":"/milestone 0.5"}"#)
        == "/milestone 0.5")
  }

  @Test("a file sent to the reader is named by its caption")
  func sendUserFileTargets() {
    #expect(
      target(
        "SendUserFile",
        input: ##"{"caption":"login screen, dark mode","status":"ok"}"##)
        == "login screen, dark mode")
  }

  @Test("an unknown tool reads the fields any tool might carry")
  func unknownToolTargets() {
    #expect(target("SomeNewTool", input: #"{"title":"Rebuild the index"}"#) == "Rebuild the index")
    #expect(target("SomeNewTool", input: #"{"to":"eng-1"}"#) == "eng-1")
    #expect(target("SomeNewTool", input: #"{"summary":"Held the queue"}"#) == "Held the queue")
    #expect(target("SomeNewTool", input: #"{"reason":"The queue was busy"}"#) == "The queue was busy")
    // A path still wins: it identifies a call at a glance.
    #expect(
      target("SomeNewTool", input: #"{"file_path":"/repo/a/b.swift","title":"x"}"#) == "b.swift")
  }

  /// A brief can be a paragraph.
  @Test("a long brief is cut to one line's worth")
  func longSummariesAreShortened() throws {
    let long = String(repeating: "x", count: 300)
    let event = try #require(
      events([Fixture.toolUse("Agent", input: #"{"name":"p-1","description":"\#(long)"}"#)])
        .first)
    #expect(event.summary?.count == 80)
    #expect(event.summary?.hasSuffix("…") == true)
  }
}

/// Where a spawned agent, a teammate or a background command has got to. An async `Agent`
/// call answers at once with `async_launched`; a later record ends it: a task notification
/// naming the call, a handback naming only the `agentId`, or a teammate's idle
/// notification. See `Fixture` for why no real record is copied.
@Suite("Where a spawned task has got to")
struct TranscriptTaskStateTests {
  private static let spawnAt = Fixture.timestamp
  private static let threeMinutesLater = "2026-08-24T15:07:04.988Z"
  private static let spawnDate = TranscriptParser.timestamp(spawnAt)!

  private func turns(_ lines: [String]) -> [TranscriptTurn] {
    TranscriptParser.page(from: lines.joined(separator: "\n")).turns
  }

  private func spawnTask(_ lines: [String]) -> TaskProgress? {
    turns(lines).compactMap(\.agentEvent).first { $0.kind == .spawned }?.task
  }

  private static let spawn = Fixture.toolUse(
    "Agent",
    input: #"{"subagent_type":"analyst","name":"analyst-4","description":"Plan it"}"#,
    id: "toolu_a",
    uuid: "sp1")

  /// A relayed idle notification from `sender` at `at`.
  private static func idle(from sender: String, at: String, uuid: String) -> String {
    let said = Fixture.escaped(
      "Relayed from another session:\n" + TranscriptAgentEventTests.idleBlock(from: sender))
    return Fixture.line(
      ["type": "user", "uuid": uuid, "timestamp": at],
      raw: [
        "isSidechain": "false",
        "message": "{\"role\":\"user\",\"content\":\"\(said)\"}",
      ])
  }

  // MARK: - An async spawn

  @Test("an async spawn with no notification yet is running, from its own timestamp")
  func asyncSpawnIsRunning() throws {
    let task = try #require(
      spawnTask([
        Self.spawn,
        Fixture.resultsScanned,
        Fixture.spawnResult(id: "toolu_a", status: "async_launched", agentID: "a1b2c3d4e5f6a7b8c"),
      ]))
    #expect(task.state == .running)
    #expect(task.startedAt == Self.spawnDate)
    #expect(task.elapsed(asOf: Self.spawnDate.addingTimeInterval(90)) == 90)
  }

  @Test("a notification naming the call ends it, and the elapsed time is spawn to notification")
  func notificationFinishesIt() throws {
    let task = try #require(
      spawnTask([
        Self.spawn,
        Fixture.resultsScanned,
        Fixture.spawnResult(id: "toolu_a", status: "async_launched", agentID: "a1b2c3d4e5f6a7b8c"),
        Fixture.task("toolu_a", status: "completed", at: Self.threeMinutesLater),
      ]))
    #expect(task.state == .finished)
    #expect(task.elapsed(asOf: .distantFuture) == 180)
  }

  @Test("a failed notification is a failure, and a killed or stopped one is a stop")
  func notificationStatuses() {
    func state(_ status: String) -> TaskProgress.State? {
      spawnTask([
        Self.spawn,
        Fixture.resultsScanned,
        Fixture.spawnResult(id: "toolu_a", status: "async_launched", agentID: "a1"),
        Fixture.task("toolu_a", status: status),
      ])?.state
    }
    #expect(state("failed") == .failed)
    #expect(state("killed") == .stopped)
    #expect(state("stopped") == .stopped)
  }

  /// Real notifications say the same task may notify more than once.
  @Test("the newest notification wins")
  func newestNotificationWins() {
    let task = spawnTask([
      Self.spawn,
      Fixture.resultsScanned,
      Fixture.spawnResult(id: "toolu_a", status: "async_launched", agentID: "a1"),
      Fixture.task("toolu_a", status: "failed"),
      Fixture.task("toolu_a", status: "completed", at: Self.threeMinutesLater),
    ])
    #expect(task?.state == .finished)
  }

  /// Some async spawns finish with only a handback, which names the `agentId`. The result
  /// line's third field joins the two.
  @Test("a handback naming only the agentId ends the spawn that launched that agent")
  func handbackJoinsOnAgentID() {
    let task = spawnTask([
      Self.spawn,
      Fixture.resultsScanned,
      Fixture.spawnResult(id: "toolu_a", status: "async_launched", agentID: "a1b2c3d4e5f6a7b8c"),
      Fixture.task("a1b2c3d4e5f6a7b8c", status: "completed", at: Self.threeMinutesLater),
    ])
    #expect(task?.state == .finished)
    #expect(task?.elapsed(asOf: .distantFuture) == 180)
  }

  // MARK: - A sync spawn

  @Test("a sync spawn's result ends it, timed by the duration the file states")
  func syncSpawnFinishes() {
    let finished = spawnTask([
      Self.spawn,
      Fixture.resultsScanned,
      Fixture.spawnResult(id: "toolu_a", status: "completed", agentID: "a1", durationMs: "9406"),
    ])
    #expect(finished?.state == .finished)
    #expect(finished?.elapsed(asOf: .distantFuture) == 9.406)

    let failed = spawnTask([
      Self.spawn,
      Fixture.resultsScanned,
      Fixture.result(id: "toolu_a", failed: true),
    ])
    #expect(failed?.state == .failed)
  }

  /// The parent waits on a sync spawn, so an unanswered one at the page's end is running, as
  /// `ToolCall.Outcome.pending` rules. Anything said after it means its answer fell outside
  /// the window.
  @Test("an unanswered spawn at the end of the page is running, and one the agent went on from is not")
  func unansweredSpawn() {
    #expect(spawnTask([Self.spawn, Fixture.resultsScanned])?.state == .running)
    #expect(
      spawnTask([Self.spawn, Fixture.assistant("Done.", uuid: "x2"), Fixture.resultsScanned])
        == nil)
    #expect(spawnTask([Self.spawn]) == nil, "no scan says nothing about any result")
  }

  // MARK: - A teammate

  /// Teammates get no task notification. Their idle notification, joined by name, is the only
  /// end the page carries.
  @Test("a teammate runs until it goes idle, and runs again, timed afresh, when sent a message")
  func teammateState() throws {
    let spawned = Fixture.spawnResult(id: "toolu_a", status: "teammate_spawned")
    #expect(spawnTask([Self.spawn, Fixture.resultsScanned, spawned])?.state == .running)

    let idle = try #require(
      spawnTask([
        Self.spawn,
        Self.idle(from: "analyst-4", at: Self.threeMinutesLater, uuid: "i1"),
        Fixture.resultsScanned,
        spawned,
      ]))
    #expect(idle.state == .idle)
    #expect(idle.elapsed(asOf: .distantFuture) == 180)

    // Woken two hours after the spawn: timed from the message.
    let twoHoursLater = "2026-08-24T17:04:04.988Z"
    let woken = try #require(
      spawnTask([
        Self.spawn,
        Self.idle(from: "analyst-4", at: Self.threeMinutesLater, uuid: "i1"),
        Fixture.toolUse(
          "SendMessage", input: #"{"to":"analyst-4","summary":"One more thing"}"#,
          id: "toolu_s", uuid: "s1"
        ).replacingOccurrences(of: Fixture.timestamp, with: twoHoursLater),
        Fixture.resultsScanned,
        spawned,
      ]))
    #expect(woken.state == .running)
    #expect(woken.elapsed(asOf: Self.spawnDate.addingTimeInterval(7200 + 60)) == 60)

    let stopped = spawnTask([
      Self.spawn,
      Fixture.toolUse("TaskStop", input: #"{"task_id":"analyst-4"}"#, id: "toolu_t", uuid: "t1"),
      Fixture.resultsScanned,
      spawned,
    ])
    #expect(stopped?.state == .stopped)
  }

  @Test("another teammate's idle notification does not end this one")
  func otherTeammateIdleIsIgnored() {
    let task = spawnTask([
      Self.spawn,
      Self.idle(from: "verifier-4", at: Self.threeMinutesLater, uuid: "i1"),
      Fixture.resultsScanned,
      Fixture.spawnResult(id: "toolu_a", status: "teammate_spawned"),
    ])
    #expect(task?.state == .running)
  }

  // MARK: - A background command

  private static let backgroundBash = Fixture.toolUse(
    "Bash",
    input: #"{"command":"make test","description":"Run the suite","run_in_background":true}"#,
    id: "toolu_b",
    uuid: "bg1")

  private func bashTask(_ lines: [String]) -> TaskProgress? {
    turns(lines).compactMap(\.toolRun).first?.calls.first?.task
  }

  @Test("a background command is running until its notification, then finished or stopped")
  func backgroundBash() {
    #expect(
      bashTask([Self.backgroundBash, Fixture.resultsScanned, Fixture.result(id: "toolu_b")])?.state
        == .running)
    let done = bashTask([
      Self.backgroundBash,
      Fixture.resultsScanned,
      Fixture.result(id: "toolu_b"),
      Fixture.task("toolu_b", status: "completed", at: Self.threeMinutesLater),
    ])
    #expect(done?.state == .finished)
    #expect(done?.elapsed(asOf: .distantFuture) == 180)
    #expect(
      bashTask([
        Self.backgroundBash, Fixture.resultsScanned, Fixture.result(id: "toolu_b"),
        Fixture.task("toolu_b", status: "killed"),
      ])?.state == .stopped)
  }

  /// Some background calls write the flag as the string `"true"`.
  @Test("a background flag written as a string still makes a background command")
  func backgroundFlagAsString() {
    let call = Fixture.toolUse(
      "Bash", input: #"{"command":"make","run_in_background":"true"}"#, id: "toolu_q", uuid: "q1")
    #expect(bashTask([call, Fixture.resultsScanned, Fixture.result(id: "toolu_q")])?.state == .running)
  }

  @Test("a foreground command carries no task")
  func foregroundBash() {
    let plain = Fixture.toolUse("Bash", input: #"{"command":"ls"}"#, id: "toolu_p", uuid: "p1")
    #expect(bashTask([plain, Fixture.resultsScanned, Fixture.result(id: "toolu_p")]) == nil)
  }

  // MARK: - What the line says

  @Test("the state reads as a word, and the time after it once there is one")
  func labels() {
    let start = Self.spawnDate
    #expect(
      TaskProgress(state: .running, startedAt: start).label(asOf: start.addingTimeInterval(200))
        == "Running · 3m")
    #expect(
      TaskProgress(state: .running, startedAt: start).label(asOf: start.addingTimeInterval(20))
        == "Running · 20s")
    #expect(
      TaskProgress(state: .finished, startedAt: start, endedAt: start.addingTimeInterval(161))
        .label(asOf: .distantFuture) == "Finished · 2m 41s")
    #expect(TaskProgress(state: .failed).label(asOf: start) == "Failed")
    #expect(
      TaskProgress(state: .idle, startedAt: start, endedAt: start.addingTimeInterval(300))
        .label(asOf: .distantFuture) == "Idle", "idle is a pause, and a time would read as how long")
    #expect(
      TaskProgress(state: .stopped, durationMs: 9406).label(asOf: start) == "Stopped · 9s")
  }
}

/// The two host-side programs, run through `/usr/bin/awk` over typed lines in the real
/// shapes.
@Suite("The task and launch fields on the wire")
struct TaskSelectorTests {
  private func run(_ program: String, _ lines: [String]) throws -> [String] {
    let awk = Process()
    awk.executableURL = URL(fileURLWithPath: "/usr/bin/awk")
    awk.arguments = [program]
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

  @Test("a spawn's result carries its launch; every other result stays two fields")
  func resultLines() throws {
    let lines = try run(
      TranscriptCommands.resultSelector,
      [
        Fixture.agentResult(id: "toolu_a", status: "async_launched", agentID: "a1b2c3"),
        Fixture.agentResult(id: "toolu_t", status: "teammate_spawned"),
        Fixture.agentResult(id: "toolu_s", status: "completed", agentID: "a9", durationMs: 9406),
        Fixture.toolResult(id: "toolu_r"),
        Fixture.backgroundBashResult(id: "toolu_b", taskID: "bx1"),
        Fixture.failedToolResult(id: "toolu_f"),
      ])
    #expect(
      lines == [
        "!toolu_a\t0\tasync_launched\ta1b2c3\t",
        "!toolu_t\t0\tteammate_spawned\t\t",
        "!toolu_s\t0\tcompleted\ta9\t9406",
        "!toolu_r\t0",
        "!toolu_b\t0",
        "!toolu_f\t1",
      ])
  }

  @Test("a notification, in either record kind, and a handback each make one task line")
  func taskLines() throws {
    let at = "2026-08-24T15:07:04.988Z"
    let lines = try run(
      TranscriptCommands.taskSelector,
      [
        Fixture.taskNotification(toolUseID: "toolu_b", status: "completed", at: at),
        Fixture.queuedTaskNotification(toolUseID: "toolu_a", status: "failed", at: at),
        Fixture.handback(from: "a1b2c3", at: at),
        Fixture.human("what does <tool-use-id>toolu_x</tool-use-id> mean"),
        Fixture.toolResult(id: "toolu_r"),
      ])
    #expect(
      lines == [
        "%toolu_b\tcompleted\t\(at)",
        "%toolu_a\tfailed\t\(at)",
        "%a1b2c3\tcompleted\t\(at)",
      ])
  }
}
