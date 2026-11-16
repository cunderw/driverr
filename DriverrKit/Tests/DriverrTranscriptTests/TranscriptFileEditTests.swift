import DriverrCore
import Foundation
import Testing

@testable import DriverrTranscript

/// An `Edit`, `MultiEdit` or `Write` call's input, read into `ToolCall.edit`. A call whose
/// input does not read keeps its plain row and loses nothing else.
///
/// `MultiEdit`'s shape (`file_path` and an `edits` array of `old_string`/`new_string`) is
/// from Claude Code's tool documentation, not from a recorded session.
@Suite("Reading a file edit off a tool call")
struct TranscriptFileEditTests {
  private func calls(_ lines: [String]) -> [ToolCall] {
    TranscriptParser.page(from: lines.joined(separator: "\n")).turns
      .compactMap(\.toolRun).flatMap(\.calls)
  }

  private func call(_ name: String, input: String) throws -> ToolCall {
    try #require(calls([Fixture.toolUse(name, input: input)]).first)
  }

  @Test("An Edit carries its old and new strings")
  func edit() throws {
    let call = try call(
      "Edit",
      input: #"{"file_path":"/src/pool.rs","old_string":"a\nb","new_string":"a\nc","replace_all":false}"#
    )
    let edit = try #require(call.edit)
    #expect(edit.filePath == "/src/pool.rs")
    #expect(edit.change == .replacements([.init(old: "a\nb", new: "a\nc")]))
    #expect(edit.diff.lines == [.context("a"), .removal("b"), .addition("c")])
    // The row's own target is unchanged.
    #expect(call.target == "pool.rs")
  }

  @Test("A MultiEdit carries every edit, in order")
  func multiEdit() throws {
    let call = try call(
      "MultiEdit",
      input: #"{"file_path":"/src/config.rs","edits":["#
        + #"{"old_string":"x","new_string":"y"},"#
        + #"{"old_string":"p","new_string":"q","replace_all":true}]}"#
    )
    #expect(
      call.edit?.change == .replacements([.init(old: "x", new: "y"), .init(old: "p", new: "q")]))
  }

  @Test("A Write carries the content")
  func write() throws {
    let call = try call("Write", input: ##"{"file_path":"/README.md","content":"# Pool\n"}"##)
    #expect(call.edit?.change == .write("# Pool\n"))
    #expect(call.edit?.diff.lines == [.addition("# Pool")])
  }

  // MARK: - Inputs that do not read

  /// One bad entry drops the whole list. A partial list would number its edits falsely.
  @Test(
    "A malformed edit gives no edit and keeps the plain row",
    arguments: [
      ("MultiEdit", #"{"file_path":"/a.rs","edits":[{"old_string":"x","new_string":"y"},{"old_string":"p"}]}"#),
      ("MultiEdit", #"{"file_path":"/a.rs","edits":"not a list"}"#),
      ("MultiEdit", #"{"file_path":"/a.rs","edits":[]}"#),
      ("MultiEdit", #"{"file_path":"/a.rs","edits":[{"old_string":1,"new_string":"y"}]}"#),
      ("Edit", #"{"file_path":"/a.rs","old_string":42,"new_string":"y"}"#),
      ("Edit", #"{"file_path":"/a.rs","new_string":"y"}"#),
      ("Edit", #"{"old_string":"x","new_string":"y"}"#),
      ("Write", #"{"file_path":"/a.rs","content":["x"]}"#),
      ("Write", #"{"file_path":"/a.rs"}"#),
    ])
  func malformedInput(name: String, input: String) throws {
    let call = try call(name, input: input)
    #expect(call.edit == nil)
    #expect(call.name == name)
  }

  @Test("A malformed edit loses nothing else in its record")
  func malformedKeepsTheMessage() {
    let page = TranscriptParser.page(
      from: [
        Fixture.human("tidy it", uuid: "h"),
        Fixture.toolUse(
          "Edit", input: #"{"file_path":"/a.rs","old_string":42,"new_string":"y"}"#, uuid: "e"),
        Fixture.assistant("Done.", uuid: "a"),
      ].joined(separator: "\n"))
    #expect(page.unreadableRecords == 0)
    #expect(page.turns.map(\.text) == ["tidy it", nil, "Done."])
    #expect(page.turns[1].toolRun?.calls.first?.target == "a.rs")
    #expect(page.turns[1].toolRun?.calls.first?.edit == nil)
  }

  /// Keyed on the tool's name: another tool may carry `file_path` and `content`.
  @Test("Another tool with the same fields gets no edit")
  func otherToolsGetNone() throws {
    let call = try call("NotebookEdit", input: #"{"file_path":"/n.ipynb","content":"x"}"#)
    #expect(call.edit == nil)
  }

  // MARK: - At the permission prompt

  @Test("A pending Edit keeps its edit, so the prompt can show the diff")
  func pendingEditKeepsItsEdit() throws {
    let page = Transcript(
      turns: TranscriptParser.page(
        from: [
          Fixture.human("fix it", uuid: "h"),
          Fixture.toolUse(
            "Edit", input: #"{"file_path":"/a.rs","old_string":"x","new_string":"y"}"#,
            id: "toolu_1", uuid: "x1"),
          Fixture.resultsScanned,
        ].joined(separator: "\n")
      ).turns,
      window: .none)
    let pending = try #require(page.pendingToolCall)
    #expect(pending.outcome == .pending)
    #expect(pending.edit?.change == .replacements([.init(old: "x", new: "y")]))
  }

  /// The other place a call is rebuilt as pending: behind this session's own agent traffic.
  @Test("A pending Edit behind a spawn keeps its edit")
  func pendingEditBehindASpawnKeepsItsEdit() throws {
    let page = Transcript(
      turns: TranscriptParser.page(
        from: [
          Fixture.human("fix it", uuid: "h"),
          Fixture.toolUses([
            (name: "Edit", input: #"{"file_path":"/a.rs","old_string":"x","new_string":"y"}"#),
            (name: "Agent", input: #"{"name":"p-1","description":"Plan it"}"#),
          ]),
          Fixture.resultsScanned,
        ].joined(separator: "\n")
      ).turns,
      window: .none)
    let pending = try #require(page.pendingToolCall)
    #expect(pending.name == "Edit")
    #expect(pending.edit?.change == .replacements([.init(old: "x", new: "y")]))
  }

  @Test("with(outcome:) changes the outcome and keeps everything else")
  func withOutcomeKeepsEverything() {
    let edit = FileEdit(filePath: "/a.rs", change: .write("x"))
    let call = ToolCall(
      name: "Write", target: "a.rs", outcome: .unknown,
      questions: [PendingQuestion(question: "q", options: ["a"])],
      task: TaskProgress(state: .running), edit: edit)
    let pending = call.with(outcome: .pending)
    #expect(pending.outcome == .pending)
    #expect(
      pending
        == ToolCall(
          name: "Write", target: "a.rs", outcome: .pending, questions: call.questions,
          task: call.task, edit: edit))
  }
}
