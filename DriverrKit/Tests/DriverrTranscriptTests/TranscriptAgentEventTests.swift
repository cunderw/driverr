import DriverrCore
import Foundation
import Testing

@testable import DriverrTranscript

/// One agent talking to another, drawn as a compact line. A `<teammate-message>` is machine
/// text and must never be a person, but a team-run session is mostly this traffic, so it
/// cannot be silence either. Every fixture is typed; see `Fixture`.
@Suite("Classifying an inter-agent event")
struct TranscriptAgentEventTests {
  /// A stand-in for the paragraph the harness appends after the last closing tag. Invented
  /// text: the claim is that prose after the tag never reaches a turn.
  static let boilerplate =
    "Fixture text after the last closing tag. A parser that reads past the tag would show "
    + "this sentence: relay-footer-sentinel."

  /// A whole relayed record: preface sentence, blocks and boilerplate.
  static func relayed(_ blocks: String..., uuid: String = "tm1") -> String {
    Fixture.clientEnvelope(
      "Relayed from another session:\n"
        + blocks.joined(separator: "\n\n")
        + "\n\n" + boilerplate,
      uuid: uuid
    )
  }

  /// The JSON shape, most relayed records and every idle notification.
  static func idleBlock(
    from sender: String,
    summary: String? = nil,
    result: String = ""
  ) -> String {
    var fields = [
      "\"type\":\"idle_notification\"",
      "\"from\":\"\(sender)\"",
      "\"timestamp\":\"2026-09-06T09:41:12.004Z\"",
      "\"idleReason\":\"available\"",
    ]
    if let summary { fields.append("\"summary\":\"\(summary)\"") }
    fields.append("\"result\":\"\(result)\"")
    return "<teammate-message teammate_id=\"\(sender)\" color=\"blue\">\n"
      + "{\(fields.joined(separator: ","))}\n"
      + "</teammate-message>"
  }

  /// The markdown shape: the summary is a tag attribute and the body is markdown.
  static func messageBlock(from sender: String, summary: String? = nil, body: String) -> String {
    let attribute = summary.map { " summary=\"\($0)\"" } ?? ""
    return "<teammate-message teammate_id=\"\(sender)\" color=\"purple\"\(attribute)>\n"
      + body + "\n</teammate-message>"
  }

  private func events(in text: String) -> [TranscriptTurn.AgentEvent] {
    TranscriptParser.page(from: text).turns.compactMap(\.agentEvent)
  }

  @Test("an idle notification becomes one agent event, sender and summary read off the JSON")
  func idleNotification() {
    let page = TranscriptParser.page(
      from: Self.relayed(
        Self.idleBlock(
          from: "eng-6",
          summary: "Fixes ready for another look",
          result: "All four review items are fixed."
        )
      )
    )

    #expect(page.turns.count == 1)
    let event = page.turns.first?.agentEvent
    #expect(event?.sender == "eng-6")
    #expect(event?.summary == "Fixes ready for another look")
    #expect(event?.body == "All four review items are fixed.")
    #expect(event?.kind == .idle)
    // Never a person.
    #expect(page.turns.contains(where: \.isHuman) == false)
  }

  @Test("a teammate's markdown message becomes one agent event, summary off the tag")
  func markdownMessage() {
    let page = TranscriptParser.page(
      from: Self.relayed(
        Self.messageBlock(
          from: "ver-6",
          summary: "Review done: two small fixes",
          body: "## Findings\n\nBoth are in the parser."
        )
      )
    )

    #expect(page.turns.count == 1)
    let event = page.turns.first?.agentEvent
    #expect(event?.sender == "ver-6")
    #expect(event?.summary == "Review done: two small fixes")
    #expect(event?.body == "## Findings\n\nBoth are in the parser.")
    // A teammate spoke, so it is not idle.
    #expect(event?.kind == .message)
  }

  /// About half of real records carry no summary, and the two kinds must not borrow each
  /// other's words.
  @Test("with no summary the line falls back to what the kind actually says")
  func noSummaryFallsBack() {
    let idle = events(in: Self.relayed(Self.idleBlock(from: "finder-6")))
    #expect(idle.first?.summary == nil)
    #expect(idle.first?.line == "finder-6: went idle")

    let message = events(
      in: Self.relayed(Self.messageBlock(from: "qa-6", body: "Looks right on both."))
    )
    #expect(message.first?.summary == nil)
    #expect(message.first?.line == "qa-6: sent a message")
  }

  /// Two blocks in one record are usually a closing message and the idle that followed. Taking
  /// the first would lose the second.
  @Test("a record carrying two blocks becomes two turns with distinct ids")
  func twoBlocksBecomeTwoTurns() {
    let page = TranscriptParser.page(
      from: Self.relayed(
        Self.messageBlock(from: "eng-6", summary: "Merged and closed", body: "The change is in."),
        Self.idleBlock(from: "eng-6")
      )
    )

    #expect(page.turns.count == 2)
    #expect(page.turns.compactMap(\.agentEvent).map(\.kind) == [.message, .idle])
    #expect(page.turns.compactMap(\.agentEvent).map(\.line) == [
      "eng-6: Merged and closed", "eng-6: went idle",
    ])
    // The pager joins pages by turn id, so a repeated id would merge the pair.
    #expect(Set(page.turns.map(\.id)).count == 2)
  }

  /// A summary is an XML attribute, so an apostrophe arrives as `&apos;`.
  @Test("entities in a summary attribute are decoded")
  func entitiesAreDecoded() {
    let page = TranscriptParser.page(
      from: Self.relayed(
        Self.messageBlock(
          from: "ver-6",
          summary: "the verifier&apos;s two finds &amp; one nit &lt;here&gt;",
          body: "Details follow."
        )
      )
    )

    #expect(page.turns.first?.agentEvent?.summary == "the verifier's two finds & one nit <here>")
  }

  /// `&amp;` is decoded last, so a literal `&lt;` survives.
  @Test("a doubly-escaped entity survives one decode, not two")
  func doubleEscapeIsNotDecodedTwice() {
    #expect(TranscriptParser.entityDecoded("&amp;lt;") == "&lt;")
  }

  /// The paragraph after the closing tag is the harness warning the agent, not the teammate
  /// speaking, and must not reach the screen.
  @Test("the harness boilerplate is in no turn, anywhere")
  func boilerplateIsStripped() {
    let page = TranscriptParser.page(
      from: Self.relayed(
        Self.idleBlock(from: "eng-6", result: "Done."),
        uuid: "tm-boiler"
      )
    )

    for event in page.turns.compactMap(\.agentEvent) {
      #expect(event.body.contains("relay-footer-sentinel") == false)
      #expect(event.line.contains("relay-footer-sentinel") == false)
      #expect(event.body == "Done.")
    }
  }

  /// The preface is Claude Code's own and sits ahead of the tag.
  @Test("the preface sentence is in no turn either")
  func prefaceIsNotCarried() {
    let page = TranscriptParser.page(
      from: Self.relayed(Self.messageBlock(from: "eng-6", body: "The tests pass."))
    )

    #expect(page.turns.first?.agentEvent?.body == "The tests pass.")
  }

  /// The scan runs only on text the envelope check accepts, so a quoted tag cannot swallow a
  /// person's message.
  @Test("a person quoting the tag mid-message still gets a human turn")
  func quotingTheTagIsStillAPerson() {
    let page = TranscriptParser.page(
      from: Fixture.human("the log said <teammate-message teammate_id=\"x\">hi</teammate-message>")
    )

    #expect(page.turns.count == 1)
    #expect(page.turns.first?.isHuman == true)
    #expect(page.turns.first?.agentEvent == nil)
  }

  /// Nothing is emitted, so the record falls through to `isHumanAuthored` and is dropped. A
  /// truncated block's body would be whatever the tail held, boilerplate included.
  @Test("an envelope with no closing tag yields no turn rather than a guessed one")
  func truncatedEnvelopeYieldsNothing() {
    let page = TranscriptParser.page(
      from: Fixture.clientEnvelope(
        "Relayed from another session:\n"
          + "<teammate-message teammate_id=\"eng-6\" color=\"blue\">\n"
          + "{\"type\":\"idle_notification\",\"from\":\"eng-6\""
      )
    )

    #expect(page.turns.isEmpty)
    #expect(page.records == 1)
  }

  /// Summaries contain `>`, so the first `>` would cut the tag in half.
  @Test("a summary containing an angle bracket does not end the tag")
  func angleBracketInSummary() {
    let page = TranscriptParser.page(
      from: Self.relayed(
        Self.messageBlock(from: "eng-6", summary: "moved a -> b", body: "Body only.")
      )
    )

    #expect(page.turns.first?.agentEvent?.summary == "moved a -> b")
    #expect(page.turns.first?.agentEvent?.body == "Body only.")
  }

  /// A teammate event is something that happened, so it closes the run.
  @Test("an agent event closes an open tool run in place")
  func closesAnOpenRun() {
    let page = TranscriptParser.page(
      from: [
        Fixture.toolUse("Read", id: "toolu_1", uuid: "tu1"),
        Self.relayed(Self.idleBlock(from: "eng-6"), uuid: "tm2"),
        Fixture.assistant("carrying on", uuid: "a1"),
      ].joined(separator: "\n")
    )

    #expect(page.turns.count == 3)
    #expect(page.turns.first?.toolRun?.count == 1)
    #expect(page.turns.dropFirst().first?.agentEvent?.kind == .idle)
    #expect(page.turns.last?.isAssistant == true)
  }

  /// The fake host writes the whole real envelope, so UI fixtures go through this
  /// classification.
  @Test("the fake host's teammate turns parse back into agent events")
  func fakeHostRoundTrips() async throws {
    let host = FakeTranscriptHost(
      sessionID: "s1",
      turns: [
        .init(speaker: .human, text: "kick it off", secondsAgo: 300),
        .init(
          speaker: .teammate([
            .init(
              sender: "eng-6",
              summary: "the verifier's two finds",
              body: "## Fixes\n\nBoth applied.",
              shape: .message
            ),
            .init(sender: "eng-6", shape: .idleNotification),
          ]),
          secondsAgo: 120
        ),
      ]
    )
    let pane = Pane(
      id: "w1:p2",
      tabID: "w1:t1",
      workspaceID: "w1",
      title: "needs a decision",
      agent: Agent(
        name: "Claude",
        kind: "claude",
        status: .blocked,
        session: AgentSession(agent: "claude", kind: "id", value: "s1")
      ),
      directory: "~/dev/driverr"
    )
    let reader = TranscriptReader(run: host.run)
    let source = try #require(try await reader.resolve(for: pane).source)
    let transcript = try await reader.read(source.file)

    let events = transcript.turns.compactMap(\.agentEvent)
    #expect(events.count == 2)
    #expect(events.first?.summary == "the verifier's two finds")
    #expect(events.first?.body == "## Fixes\n\nBoth applied.")
    #expect(events.last?.kind == .idle)
    #expect(events.last?.line == "eng-6: went idle")
    for event in events {
      #expect(event.body.contains("relay-footer-sentinel") == false)
    }
  }
}
