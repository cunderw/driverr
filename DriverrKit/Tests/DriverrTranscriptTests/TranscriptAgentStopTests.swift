import DriverrCore
import Foundation
import Testing

@testable import DriverrTranscript

/// A page that ends on Claude Code's own failed-request record carries an `AgentStop`.
struct TranscriptAgentStopTests {
  /// `resetsAt` as a real `rate_limit` record writes it: whole seconds since 1970.
  static let resetsAt: TimeInterval = 1_790_894_400

  /// A synthetic API-error record: `<synthetic>` model, all-zero usage, `isApiErrorMessage`,
  /// `error`, and on a limit `apiErrorStatus` and `quotaLimits`. `quotaLimits` is written as
  /// given, so a test can omit or break it.
  private static func apiError(
    _ text: String,
    error: String,
    status: Int? = nil,
    quotaLimits: String? = nil,
    uuid: String = "e1",
    sidechain: Bool = false,
    isApiErrorMessage: String = "true"
  ) -> String {
    var raw: [String: String] = [
      "isSidechain": sidechain ? "true" : "false",
      "isApiErrorMessage": isApiErrorMessage,
      "message":
        "{\"role\":\"assistant\",\"model\":\"<synthetic>\",\"content\":[{\"type\":\"text\","
        + "\"text\":\"\(Fixture.escaped(text))\"}],\"usage\":{\"input_tokens\":0,"
        + "\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0,\"output_tokens\":0}}",
    ]
    if let status { raw["apiErrorStatus"] = "\(status)" }
    if let quotaLimits { raw["quotaLimits"] = quotaLimits }
    return Fixture.line(
      ["type": "assistant", "uuid": uuid, "timestamp": Fixture.timestamp, "error": error],
      raw: raw
    )
  }

  /// When every fixture record was written, as the parser reads it.
  private static let at = TranscriptParser.timestamp(Fixture.timestamp)

  private static let limitText = "You've hit your session limit · resets 5:40pm (America/Chicago)"

  private static func sessionLimit(
    uuid: String = "e1",
    sidechain: Bool = false,
    quotaLimits: String? =
      "{\"status\":\"rejected\",\"resetsAt\":\(Int(resetsAt)),\"rateLimitType\":\"five_hour\","
      + "\"overageStatus\":\"rejected\",\"isUsingOverage\":false}"
  ) -> String {
    apiError(
      limitText, error: "rate_limit", status: 429, quotaLimits: quotaLimits, uuid: uuid,
      sidechain: sidechain)
  }

  private static func assistant(_ text: String, uuid: String = "a1") -> String {
    Fixture.line(
      ["type": "assistant", "uuid": uuid, "timestamp": Fixture.timestamp],
      raw: [
        "isSidechain": "false",
        "message":
          "{\"role\":\"assistant\",\"model\":\"claude-opus-5\",\"content\":[{\"type\":\"text\","
          + "\"text\":\"\(Fixture.escaped(text))\"}]}",
      ]
    )
  }

  /// A background task reporting to the agent: a `user` record whose `origin.kind` is not a
  /// person. Real limits are often followed by one, then another limit.
  private static let taskNotification = Fixture.humanWithOrigin(
    "<task-notification>done</task-notification>", kind: "task-notification", uuid: "tn1")

  private static func page(_ lines: String...) -> TranscriptParser.Page {
    TranscriptParser.page(from: lines.joined(separator: "\n"))
  }

  @Test("a limit record at the end of the page is a live stop with its reset time")
  func liveLimit() {
    let page = Self.page(Fixture.human("keep going"), Self.sessionLimit())
    #expect(
      page.agentStop
        == AgentStop(
          kind: .rateLimit, resetsAt: Date(timeIntervalSince1970: Self.resetsAt),
          message: Self.limitText, at: Self.at))
    #expect(Self.at != nil)
    #expect(page.agentStop?.isLive(at: Date(timeIntervalSince1970: Self.resetsAt - 60)) == true)
    // The notice says it once, in the phone's clock rather than the host's.
    #expect(page.turns.map(\.text) == ["keep going"])
  }

  @Test("a limit with a reset time in the past is no longer live")
  func pastReset() throws {
    let stop = try #require(Self.page(Self.sessionLimit()).agentStop)
    #expect(!stop.isLive(at: Date(timeIntervalSince1970: Self.resetsAt)))
    #expect(!stop.isLive(at: Date(timeIntervalSince1970: Self.resetsAt + 3_600)))
  }

  @Test("a limit record with no quotaLimits is a stop with no reset time")
  func noQuotaLimits() {
    let page = Self.page(Self.sessionLimit(quotaLimits: nil))
    #expect(page.agentStop == AgentStop(kind: .rateLimit, message: Self.limitText, at: Self.at))
    #expect(page.agentStop?.isLive(at: .distantFuture) == true)
  }

  @Test("a quotaLimits Driverr cannot read costs the reset time, not the record")
  func unreadableQuotaLimits() {
    let page = Self.page(Self.sessionLimit(quotaLimits: "{\"resetsAt\":\"soon\"}"))
    #expect(page.unreadableRecords == 0)
    #expect(page.agentStop == AgentStop(kind: .rateLimit, message: Self.limitText, at: Self.at))
  }

  @Test("an isApiErrorMessage that is not a bool costs the notice, not the record's turn")
  func unreadableFlag() {
    let page = Self.page(Self.apiError("odd", error: "rate_limit", isApiErrorMessage: "\"yes\""))
    #expect(page.unreadableRecords == 0)
    #expect(page.turns.last?.text == "odd")
    #expect(page.agentStop == nil)
  }

  @Test("the agent answering after the limit clears it: Claude Code's auto-continue at reset")
  func clearedByALaterReply() {
    let page = Self.page(Self.sessionLimit(), Self.assistant("Picking up where I left off."))
    #expect(page.agentStop == nil)
    // Cleared, the record is history and its turn returns.
    #expect(page.turns.map(\.text) == [Self.limitText, "Picking up where I left off."])
  }

  @Test("a page whose only turn is the stop keeps it, so the chat is not reported empty")
  func onlyTurnIsKept() {
    let page = Self.page(Self.sessionLimit())
    #expect(page.agentStop?.kind == .rateLimit)
    #expect(page.turns.map(\.text) == [Self.limitText])
  }

  @Test("the person typing after the limit clears it")
  func clearedByALaterHumanTurn() {
    let page = Self.page(Self.sessionLimit(), Fixture.human("are you back?", uuid: "u2"))
    #expect(page.agentStop == nil)
  }

  /// A notification is often followed by another limit record, so clearing on it would drop
  /// the notice, for good if the agent never retries.
  @Test("a record that makes no human turn does not clear the stop")
  func notClearedByATaskNotification() {
    let page = Self.page(Self.assistant("working"), Self.sessionLimit(), Self.taskNotification)
    #expect(page.agentStop?.kind == .rateLimit)
    #expect(page.turns.map(\.text) == ["working"])
  }

  @Test("a sub-agent's limit is not the pane's")
  func sidechainIsIgnored() {
    let page = Self.page(Self.assistant("working"), Self.sessionLimit(sidechain: true))
    #expect(page.agentStop == nil)
  }

  @Test("a sub-agent's own file never carries a stop")
  func subagentFileIsIgnored() {
    let page = TranscriptParser.page(
      from: [Fixture.subagentPrompt("look into it"), Self.sessionLimit(sidechain: true)]
        .joined(separator: "\n"),
      forSubagentFile: true
    )
    #expect(page.turns.count == 2)
    #expect(page.agentStop == nil)
  }

  @Test("a later failure replaces an earlier one, and both of their turns are hidden")
  func newestFailureWins() {
    let page = Self.page(
      Fixture.human("go"),
      Self.sessionLimit(),
      Self.apiError("Login expired · Please run /login", error: "authentication_failed", uuid: "e2")
    )
    #expect(page.agentStop?.kind == .loginExpired)
    #expect(page.agentStop?.resetsAt == nil)
    // Nothing cleared the first stop, so its turn stays hidden with the second's.
    #expect(page.turns.map(\.text) == ["go"])
  }

  /// A stopped agent writes a run of limit records.
  @Test("every turn of a run of consecutive limit records is hidden")
  func consecutiveStopsAreAllHidden() {
    let page = Self.page(
      Fixture.human("go"),
      Self.sessionLimit(uuid: "e1"),
      Self.taskNotification,
      Self.sessionLimit(uuid: "e2"),
      Self.taskNotification,
      Self.sessionLimit(uuid: "e3")
    )
    #expect(page.agentStop?.kind == .rateLimit)
    #expect(page.turns.map(\.text) == ["go"])
  }

  @Test("a stop that was cleared is history, and a later one hides only its own run")
  func clearedStopsStayVisible() {
    let page = Self.page(
      Fixture.human("go"),
      Self.sessionLimit(uuid: "e1"),
      Self.assistant("back", uuid: "a2"),
      Self.sessionLimit(uuid: "e2")
    )
    #expect(page.turns.map(\.text) == ["go", Self.limitText, "back"])
  }

  @Test(
    "each other stop kind is read off `error`, and its text travels verbatim",
    arguments: [
      ("Login expired · Please run /login", "authentication_failed", nil, AgentStop.Kind.loginExpired),
      (
        "API Error: 400 Prompt too long: 129845 tokens exceeds max context window", "unknown", 400,
        .other
      ),
      (
        "API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)",
        "server_error", nil, .serverError
      ),
      ("API Error: something new", "overloaded", 529, .other),
    ] as [(String, String, Int?, AgentStop.Kind)]
  )
  func otherKinds(text: String, error: String, status: Int?, kind: AgentStop.Kind) {
    let page = Self.page(Fixture.human("go"), Self.apiError(text, error: error, status: status))
    #expect(page.agentStop == AgentStop(kind: kind, message: text, at: Self.at))
  }

  @Test("an ordinary page carries no stop")
  func ordinaryPage() {
    #expect(Self.page(Fixture.human("go"), Self.assistant("done")).agentStop == nil)
  }

  @Test("the reader carries the stop onto the transcript, and a short page keeps it")
  func readerCarriesIt() async throws {
    let body = [Fixture.human("go"), Self.sessionLimit()].joined(separator: "\n") + "\n"
    let host = FakeHost(
      responses: ["tail -c": FakeHost.output(HostFixture.read(size: 900_000, body: body))]
    )
    let transcript = try await TranscriptReader(run: host.runner).read(
      TranscriptFile(path: "\(HostFixture.projectDirectory)/s.jsonl", sizeInBytes: 900_000, age: 3),
      turns: 2
    )
    #expect(transcript.agentStop?.kind == .rateLimit)
    #expect(transcript.stoppingShort().agentStop == transcript.agentStop)
  }
}
