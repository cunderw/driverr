import Foundation
import Testing

@testable import DriverrCore

/// The markdown parse hoisted out of the turn body. These count calls to `parse`, because a
/// render that is correct and re-parses the page every poll passes every other suite.
@Suite("Parsing a page's turns once")
struct TranscriptRenderTests {
  private final class Counter {
    private(set) var texts: [String] = []
    var count: Int { texts.count }

    func parse(_ text: String) -> [TranscriptMarkdown.Block] {
      texts.append(text)
      return TranscriptMarkdown.blocks(from: text)
    }
  }

  private func assistant(_ id: String, _ text: String) -> TranscriptTurn {
    TranscriptTurn(id: id, speech: .assistant(text))
  }

  @Test("A page is parsed once per assistant turn")
  func firstPass() {
    let counter = Counter()
    let render = TranscriptRender.rendering(
      [assistant("a", "One."), assistant("b", "Two.")], parse: counter.parse)

    #expect(counter.count == 2)
    #expect(render["a"]?.blocks == [.paragraph("One.")])
    #expect(render["b"]?.blocks == [.paragraph("Two.")])
  }

  @Test("Rebuilding an unchanged page parses nothing")
  func unchangedTurnsAreReused() {
    let first = TranscriptRender.rendering([assistant("a", "One."), assistant("b", "Two.")])
    let counter = Counter()

    var render = first
    for _ in 0..<5 {
      render = TranscriptRender.rendering(
        [assistant("a", "One."), assistant("b", "Two.")],
        reusing: render, parse: counter.parse)
    }

    #expect(counter.count == 0)
    #expect(render["b"]?.blocks == [.paragraph("Two.")])
  }

  /// The streaming newest turn keeps its id and grows, so reuse is keyed on text, not id.
  @Test("A turn whose text grew parses exactly once more")
  func agrownTurnReparses() {
    let first = TranscriptRender.rendering([assistant("a", "One."), assistant("b", "Two.")])
    let counter = Counter()

    let render = TranscriptRender.rendering(
      [assistant("a", "One."), assistant("b", "Two. And more.")],
      reusing: first, parse: counter.parse)

    #expect(counter.texts == ["Two. And more."])
    #expect(render["b"]?.blocks == [.paragraph("Two. And more.")])
    #expect(render["a"]?.blocks == [.paragraph("One.")])
  }

  @Test("A turn that arrived parses only itself")
  func aNewTurnParsesOnlyItself() {
    let first = TranscriptRender.rendering([assistant("a", "One."), assistant("b", "Two.")])
    let counter = Counter()

    let render = TranscriptRender.rendering(
      [assistant("a", "One."), assistant("b", "Two."), assistant("c", "Three.")],
      reusing: first, parse: counter.parse)

    #expect(counter.texts == ["Three."])
    #expect(render.turns.count == 3)
  }

  /// Rebuilt rather than merged, so turns paged out do not accumulate.
  @Test("A turn that has left the page leaves the map")
  func droppedTurnsLeaveTheMap() {
    let first = TranscriptRender.rendering([assistant("a", "One."), assistant("b", "Two.")])

    let render = TranscriptRender.rendering([assistant("b", "Two.")], reusing: first)

    #expect(render["a"] == nil)
    #expect(render["b"] != nil)
    #expect(render.turns.count == 1)
  }

  @Test("Nothing a person said, no command and no tool run is parsed")
  func onlyTheAgentsProseIsParsed() {
    let counter = Counter()
    let render = TranscriptRender.rendering(
      [
        TranscriptTurn(id: "h", speech: .human("**not** markdown here")),
        TranscriptTurn(id: "c", speech: .assistant("/run-tests"), isCommand: true),
        TranscriptTurn(id: "t", speech: .tools(ToolRun(calls: []))),
        assistant("a", "One."),
      ], parse: counter.parse)

    #expect(counter.texts == ["One."])
    #expect(render.turns.keys.sorted() == ["a"])
  }

  /// An agent event's body is long and rarely opened, so it is parsed when its row opens.
  @Test("An agent event is not parsed with the page")
  func agentEventsAreNotParsed() {
    let counter = Counter()
    let render = TranscriptRender.rendering(
      [
        TranscriptTurn(
          id: "e",
          speech: .agentEvent(
            TranscriptTurn.AgentEvent(
              sender: "eng-6",
              summary: "Fixes ready",
              body: "## Findings\n\nBoth applied.",
              kind: .message
            )
          )
        ),
        assistant("a", "One."),
      ], parse: counter.parse)

    #expect(counter.texts == ["One."])
    #expect(render["e"] == nil)
    #expect(render.turns.keys.sorted() == ["a"])
  }

  @Test("An inline string is parsed for drawing and for measuring")
  func inlinesAreHeld() {
    let render = TranscriptRender.rendering(
      [assistant("a", "## Heading\n\nA **bold** word.\n\n- an `item`")])
    let turn = render["a"]

    #expect(turn?.plain("A **bold** word.") == "A bold word.")
    #expect(turn?.plain("an `item`") == "an item")
    #expect(turn?.plain("Heading") == "Heading")
    #expect(turn.map { String($0.inline("A **bold** word.").characters) } == "A bold word.")
  }

  /// Used for a preview, or a block this render was not built from.
  @Test("An inline string the render never saw is parsed on the spot")
  func anUnheldInlineFallsBack() {
    let render = TranscriptRender.rendering([assistant("a", "One.")])

    #expect(render["a"]?.plain("A **bold** word.") == "A bold word.")
  }
}
