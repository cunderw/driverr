import DriverrCore
import Foundation
import Testing

@testable import DriverrTranscript

/// The context count comes off the newest assistant record whose usage says anything.
struct TranscriptContextUsageTests {
  /// An assistant record with `message.usage` and `message.model` around the given blocks.
  /// `output_tokens` is included so the test proves it is left out of the sum.
  private static func record(
    blocks: String,
    input: Int,
    cacheWrite: Int,
    cacheRead: Int,
    output: Int = 412,
    model: String = "claude-opus-5",
    uuid: String,
    sidechain: Bool = false
  ) -> String {
    Fixture.line(
      ["type": "assistant", "uuid": uuid, "timestamp": Fixture.timestamp],
      raw: [
        "isSidechain": sidechain ? "true" : "false",
        "message":
          "{\"role\":\"assistant\",\"model\":\"\(model)\",\"content\":[\(blocks)],"
          + "\"usage\":{\"input_tokens\":\(input),\"cache_creation_input_tokens\":\(cacheWrite),"
          + "\"cache_read_input_tokens\":\(cacheRead),\"output_tokens\":\(output)}}",
      ]
    )
  }

  private static func text(_ said: String) -> String {
    "{\"type\":\"text\",\"text\":\"\(Fixture.escaped(said))\"}"
  }

  private static let toolUse =
    "{\"type\":\"tool_use\",\"id\":\"toolu_9\",\"name\":\"Read\",\"input\":{\"file_path\":\"a.swift\"}}"

  @Test("the newest record wins, even one that is only a tool call and makes no turn")
  func newestRecordWins() {
    let page = TranscriptParser.page(
      from: [
        Fixture.human("go"),
        Self.record(blocks: Self.text("looking"), input: 5, cacheWrite: 1_000, cacheRead: 40_000, uuid: "a1"),
        Self.record(blocks: Self.toolUse, input: 3, cacheWrite: 1_204, cacheRead: 81_006, uuid: "a2"),
      ].joined(separator: "\n")
    )
    // The tool call joined a run; the newest turn is still the text above it.
    #expect(page.turns.last?.toolRun != nil)
    #expect(
      page.contextUsage
        == ContextUsage(inputTokens: 3, cacheCreationTokens: 1_204, cacheReadTokens: 81_006)
    )
    #expect(page.contextUsage?.totalTokens == 82_213)
  }

  @Test("a synthetic all-zero record at the end does not read as an empty context")
  func syntheticZeroesAreIgnored() {
    let page = TranscriptParser.page(
      from: [
        Self.record(blocks: Self.toolUse, input: 3, cacheWrite: 1_204, cacheRead: 81_006, uuid: "a1"),
        Self.record(
          blocks: Self.text("No response requested."), input: 0, cacheWrite: 0, cacheRead: 0,
          output: 0, model: "<synthetic>", uuid: "a2"
        ),
      ].joined(separator: "\n")
    )
    #expect(page.contextUsage?.totalTokens == 82_213)
  }

  @Test("a subagent's usage is not the pane's context")
  func subagentUsageIsIgnored() {
    let page = TranscriptParser.page(
      from: [
        Self.record(blocks: Self.text("main"), input: 1, cacheWrite: 0, cacheRead: 9_000, uuid: "a1"),
        Self.record(
          blocks: Self.text("sub"), input: 1, cacheWrite: 0, cacheRead: 500_000, uuid: "s1",
          sidechain: true
        ),
      ].joined(separator: "\n")
    )
    #expect(page.contextUsage?.totalTokens == 9_001)
  }

  @Test("a page with no usage anywhere carries none")
  func noUsageIsNil() {
    let page = TranscriptParser.page(
      from: [Fixture.human("go"), Fixture.assistant("done")].joined(separator: "\n")
    )
    #expect(page.turns.count == 2)
    #expect(page.contextUsage == nil)
  }

  @Test("an odd usage or model costs the count, never the record")
  func oddFieldsDoNotFailTheRecord() {
    for message in [
      #"{"role":"assistant","model":7,"content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":5}}"#,
      #"{"role":"assistant","content":[{"type":"text","text":"hi"}],"usage":"lots"}"#,
      #"{"role":"assistant","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":"5"}}"#,
      #"{"role":"assistant","content":[{"type":"text","text":"hi"}],"usage":null}"#,
    ] {
      let page = TranscriptParser.page(
        from: Fixture.line(
          ["type": "assistant", "uuid": "a1", "timestamp": Fixture.timestamp],
          raw: ["message": message]
        )
      )
      #expect(page.unreadableRecords == 0, "\(message)")
      #expect(page.turns.map(\.text) == ["hi"], "\(message)")
    }
    // Only `model` was wrong, so the first shape still counts.
    let page = TranscriptParser.page(
      from: Fixture.line(
        ["type": "assistant", "uuid": "a1", "timestamp": Fixture.timestamp],
        raw: [
          "message":
            #"{"role":"assistant","model":7,"content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":5}}"#
        ]
      )
    )
    #expect(page.contextUsage?.totalTokens == 5)
  }

  @Test("a Codex page carries no count")
  func codexIsNil() {
    let page = TranscriptParser.codexPage(from: CodexFixture.agentMessage("done", id: "a1"))
    #expect(page.turns.count == 1)
    #expect(page.contextUsage == nil)
  }

  @Test("the reader hands the page's count through")
  func readerPassesItThrough() async throws {
    let body =
      [
        Fixture.human("go"),
        Self.record(blocks: Self.text("done"), input: 3, cacheWrite: 1_204, cacheRead: 81_006, uuid: "a1"),
      ].joined(separator: "\n") + "\n"
    let host = FakeHost(
      responses: ["tail -c": FakeHost.output(HostFixture.read(size: 900_000, body: body))]
    )
    let transcript = try await TranscriptReader(run: host.runner).read(
      TranscriptFile(path: "\(HostFixture.projectDirectory)/s.jsonl", sizeInBytes: 900_000, age: 3),
      turns: 2
    )
    #expect(transcript.turns.count == 2)
    #expect(transcript.contextUsage?.totalTokens == 82_213)
  }
}
