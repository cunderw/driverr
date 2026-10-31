import Foundation
import Testing

@testable import DriverrHC

/// schema/README.md's table, one row at a time, with no stream behind it.
@Suite("Core event state")
struct CoreEventStateTests {
  private typealias Effect = CoreEventState.Effect

  private func decoded(_ line: String) throws -> CoreEventLine {
    try JSONDecoder().decode(CoreEventLine.self, from: Data(line.utf8))
  }

  private func event(
    _ type: String,
    on terminal: String? = "t1",
    _ data: String = "{}",
    machine: String? = nil,
    seq: Int = 11
  ) throws -> CoreEventLine {
    let address = terminal.map { #""terminal":"\#($0)","# } ?? ""
    let machine = machine.map { #""machine":"\#($0)","# } ?? ""
    return try decoded(
      #"{"jsonrpc":"2.0","method":"event","params":{\#(address)\#(machine)"#
        + #""data":\#(data),"seq":\#(seq),"type":"\#(type)"}}"#)
  }

  private func record(_ address: String, state: String = "live", rest: String = "") -> String {
    #"{"address":"\#(address)","state":"\#(state)"\#(rest)}"#
  }

  private func state(_ terminals: String..., seq: Int = 10) throws -> CoreEventState {
    let list = terminals.joined(separator: ",")
    return CoreEventState(
      try JSONDecoder().decode(
        CoreEventSnapshot.self,
        from: Data(#"{"seq":\#(seq),"terminals":[\#(list)]}"#.utf8)))
  }

  private var claude: String {
    record(
      "t1",
      rest: #","title":"a","rows":24,"labels":{"a":"b"},"#
        + #""foreground":{"pid":7,"cwd":"/a","argv":["claude"]},"#
        + #""status":{"app":"claude-code","state":"working"}"#)
  }

  private func addresses(_ state: CoreEventState) -> [String] {
    state.terminals.map(\.address)
  }

  @Test("finished terminals are in a subscribe reply and stay out")
  func finishedInReply() throws {
    let state = try state(record("t1"), record("t2", state: "finished"), record("t3"))
    #expect(addresses(state) == ["t1", "t3"])
  }

  @Test("created adds the whole record, and reads its session")
  func created() throws {
    var state = try state(record("t1"))
    let effect = state.apply(
      try event("created", on: "t2", record("t2", rest: #","title":"new""#)))
    #expect(addresses(state) == ["t1", "t2"])
    #expect(state.terminals[1].title == "new")
    #expect(effect == Effect(signal: .prompt, sessionReads: ["t2"]))
  }

  /// A machine's line coming back says `created` of what is already held.
  @Test("created again replaces, in place")
  func createdAgain() throws {
    var state = try state(record("box/t1", rest: #","title":"old""#), record("t2"))
    _ = state.apply(
      try event("created", on: "box/t1", record("box/t1", rest: #","title":"new""#)))
    #expect(addresses(state) == ["box/t1", "t2"])
    #expect(state.terminals[0].title == "new")
  }

  @Test("created of what finished meanwhile takes it away")
  func createdFinished() throws {
    var state = try state(record("box/t1"), record("t2"))
    let effect = state.apply(
      try event("created", on: "box/t1", record("box/t1", state: "finished")))
    #expect(addresses(state) == ["t2"])
    #expect(effect == Effect(signal: .prompt, sessionReads: ["box/t1"]))

    #expect(
      state.apply(try event("created", on: "t9", record("t9", state: "finished"), seq: 12))
        == Effect())
    #expect(addresses(state) == ["t2"])
  }

  @Test("restarted replaces the record")
  func restarted() throws {
    var state = try state(claude)
    let effect = state.apply(
      try event("restarted", record("t1", rest: #","foreground":{"pid":8}"#)))
    #expect(state.terminals[0].foreground?.pid == 8)
    #expect(state.terminals[0].status == nil)
    #expect(effect == Effect(signal: .prompt, sessionReads: ["t1"]))
  }

  @Test("lost stays live and drops its foreground, and a status stays")
  func lost() throws {
    var state = try state(claude)
    let effect = state.apply(
      try event("lost", #"{"reason":"signaled","exit_code":null,"signal":9,"finished_ms":null}"#))
    #expect(addresses(state) == ["t1"])
    #expect(state.terminals[0].foreground == nil)
    #expect(state.terminals[0].status?.state == "working")
    #expect(effect == Effect(signal: .prompt))
  }

  /// The session read is how its remembered id goes. `CoreSessionFilesTests.leaves`.
  @Test("finished and removed both drop it, and the second is nothing")
  func finished() throws {
    var state = try state(claude, record("t2"))
    let effect = state.apply(
      try event("finished", #"{"reason":"exited","exit_code":0,"signal":null,"finished_ms":5}"#))
    #expect(addresses(state) == ["t2"])
    #expect(effect == Effect(signal: .prompt, sessionReads: ["t1"]))
    #expect(state.apply(try event("removed", seq: 12)) == Effect())

    #expect(
      state.apply(try event("removed", on: "t2", seq: 13))
        == Effect(signal: .prompt, sessionReads: ["t2"]))
    #expect(state.terminals.isEmpty)
  }

  @Test("a status replaces the last, and reads the session")
  func status() throws {
    var state = try state(claude)
    let effect = state.apply(
      try event(
        "status",
        #"{"records":{},"reported":true,"status":{"app":"claude-code","kind":"question","#
          + #""msg":"which?","state":"blocked"}}"#))
    #expect(state.terminals[0].status?.state == "blocked")
    #expect(state.terminals[0].status?.kind == "question")
    #expect(effect == Effect(signal: .prompt, sessionReads: ["t1"]))
  }

  @Test("a null status clears")
  func statusCleared() throws {
    var state = try state(claude)
    _ = state.apply(try event("status", #"{"records":{},"reported":true,"status":null}"#))
    #expect(state.terminals[0].status == nil)
  }

  @Test("title and size apply, and only ask for a paced signal")
  func paced() throws {
    var state = try state(claude)
    #expect(
      state.apply(try event("title", #"{"title":"b"}"#, seq: 11)) == Effect(signal: .paced))
    #expect(
      state.apply(try event("size", #"{"cols":80,"rows":50}"#, seq: 12)) == Effect(signal: .paced))
    #expect(state.terminals[0].title == "b")
    #expect(state.terminals[0].rows == 50)
  }

  @Test("labels replace all of them")
  func labels() throws {
    var state = try state(claude)
    let effect = state.apply(try event("labels", #"{"labels":{"c":"d"}}"#))
    #expect(state.terminals[0].labels == ["c": "d"])
    #expect(effect == Effect(signal: .prompt))
  }

  @Test("a new pid reads the session")
  func foregroundPID() throws {
    var state = try state(claude)
    let effect = state.apply(
      try event("foreground", #"{"pid":8,"cwd":"/a","argv":["sleep"],"name":"sleep"}"#))
    #expect(state.terminals[0].foreground?.pid == 8)
    #expect(state.terminals[0].foreground?.argv == ["sleep"])
    #expect(effect == Effect(signal: .prompt, sessionReads: ["t1"]))
  }

  @Test("a new folder under one pid is prompt, and reads nothing")
  func foregroundFolder() throws {
    var state = try state(claude)
    #expect(
      state.apply(try event("foreground", #"{"pid":7,"cwd":"/b","argv":["claude"]}"#))
        == Effect(signal: .prompt))
    #expect(state.terminals[0].foreground?.cwd == "/b")
  }

  @Test("the same pid and folder under another name is only paced")
  func foregroundName() throws {
    var state = try state(claude)
    #expect(
      state.apply(try event("foreground", #"{"pid":7,"cwd":"/a","argv":["other"]}"#))
        == Effect(signal: .paced))
    #expect(state.terminals[0].foreground?.argv == ["other"])
  }

  @Test("a null foreground drops it")
  func foregroundGone() throws {
    var state = try state(claude)
    _ = state.apply(try event("foreground", "null"))
    #expect(state.terminals[0].foreground == nil)
  }

  @Test("turn and keep draw nothing and ask for nothing")
  func nothingDrawn() throws {
    var state = try state(claude)
    #expect(state.apply(try event("turn", #"{"turn":2,"state":"idle"}"#, seq: 11)) == Effect())
    #expect(state.apply(try event("keep", #"{"keep":true}"#, seq: 12)) == Effect())
    #expect(state.seq == 12)
  }

  @Test("a type this build has not met is skipped, and still counts")
  func unknownType() throws {
    var state = try state(claude)
    #expect(state.apply(try event("weather", #"{"sky":"clear"}"#, seq: 11)) == Effect())
    #expect(state.seq == 11)
    #expect(state.apply(try event("title", #"{"title":"b"}"#, seq: 11)) == Effect())
  }

  @Test("a method this build has not met is skipped")
  func unknownMethod() throws {
    var state = try state(claude)
    #expect(state.apply(try decoded(#"{"method":"news","params":{"seq":99}}"#)) == Effect())
    #expect(state.seq == 10)
  }

  @Test("a heartbeat changes nothing")
  func heartbeat() throws {
    var state = try state(claude)
    #expect(state.apply(try decoded(#"{"method":"heartbeat","params":{"seq":10}}"#)) == Effect())
    #expect(state.seq == 10)
  }

  @Test("an event at or below the snapshot's seq is already in it", arguments: [9, 10])
  func stale(seq: Int) throws {
    var state = try state(claude)
    #expect(state.apply(try event("removed", seq: seq)) == Effect())
    #expect(addresses(state) == ["t1"])
    #expect(state.seq == 10)
  }

  @Test("an event for a terminal not held is passed over")
  func unheld() throws {
    var state = try state(claude)
    #expect(
      state.apply(try event("status", on: "t9", #"{"status":{"state":"blocked"}}"#)) == Effect())
  }

  @Test("missed replaces everything, filters what finished, and reads what events cannot carry")
  func missed() throws {
    var state = try state(claude, seq: 10)
    let line = try decoded(
      #"{"jsonrpc":"2.0","method":"missed","params":{"seq":57,"terminals":["#
        + record("t2") + "," + record("t3", state: "finished") + "," + record("t4") + "]}}")
    let effect = state.apply(line)

    #expect(addresses(state) == ["t2", "t4"])
    #expect(state.seq == 57)
    #expect(effect == Effect(signal: .prompt, sessionReads: ["t2", "t4"], readsDocument: true))
    // What was queued behind it is dropped by its seq.
    #expect(state.apply(try event("removed", on: "t2", seq: 57)) == Effect())
    #expect(addresses(state) == ["t2", "t4"])
  }

  @Test("this core's app document reads again, with no signal until it has")
  func document() throws {
    var state = try state(claude)
    #expect(
      state.apply(try event("doc", on: nil, #"{"name":"herdr-app","version":2}"#))
        == Effect(readsDocument: true))
  }

  @Test(
    "another document, or another machine's, reads nothing",
    arguments: [("something-else", nil), ("herdr-app", "box")] as [(String, String?)])
  func otherDocument(name: String, machine: String?) throws {
    var state = try state(claude)
    #expect(
      state.apply(
        try event("doc", on: nil, #"{"name":"\#(name)","version":2}"#, machine: machine))
        == Effect())
  }

  @Test("a known type with unreadable data is a broken line, not a skipped one")
  func unreadable() {
    #expect(throws: (any Error).self) { try event("status", "[1,2]") }
  }
}

@Suite("Core signal pacing")
struct CoreSignalPacerTests {
  private let start = ContinuousClock.now

  @Test("the first change after a quiet spell goes at once, whichever kind", arguments: [
    CoreChangeUrgency.prompt, .paced,
  ])
  func quiet(urgency: CoreChangeUrgency) {
    var pacer = CoreSignalPacer()
    #expect(pacer.noted(urgency, at: start) == start)
  }

  @Test("no change asks for nothing")
  func none() {
    var pacer = CoreSignalPacer()
    #expect(pacer.noted(.none, at: start) == nil)
  }

  @Test("prompt changes go at most every 300 ms, and a burst is one")
  func prompt() {
    var pacer = CoreSignalPacer()
    pacer.fired(at: start)
    let due = start + CoreSignalPacer.promptGap
    #expect(pacer.noted(.prompt, at: start + .milliseconds(10)) == due)
    #expect(pacer.noted(.prompt, at: start + .milliseconds(200)) == due)
  }

  @Test("paced changes go at most every 3 s, however fast they come")
  func paced() {
    var pacer = CoreSignalPacer()
    pacer.fired(at: start)
    let due = start + CoreSignalPacer.pacedGap
    for tick in 1...29 {
      #expect(pacer.noted(.paced, at: start + .milliseconds(100 * tick)) == due)
    }
    pacer.fired(at: due)
    #expect(pacer.noted(.paced, at: due + .milliseconds(100)) == due + CoreSignalPacer.pacedGap)
  }

  @Test("a prompt change does not wait for a paced one")
  func promptOverPaced() {
    var pacer = CoreSignalPacer()
    pacer.fired(at: start)
    _ = pacer.noted(.paced, at: start + .milliseconds(10))
    #expect(
      pacer.noted(.prompt, at: start + .milliseconds(20)) == start + CoreSignalPacer.promptGap)
  }

  @Test("a paced change joins a prompt one already due")
  func pacedJoinsPrompt() {
    var pacer = CoreSignalPacer()
    pacer.fired(at: start)
    let due = start + CoreSignalPacer.promptGap
    _ = pacer.noted(.prompt, at: start + .milliseconds(10))
    #expect(pacer.noted(.paced, at: start + .milliseconds(20)) == due)
  }
}

@Suite("Core line assembly")
struct CoreLineAssemblerTests {
  private func text(_ lines: [Data]) -> [String] {
    lines.map { String(decoding: $0, as: UTF8.self) }
  }

  @Test("a line that spans DATA frames comes out whole, and once")
  func spans() throws {
    var assembler = CoreLineAssembler()
    #expect(try assembler.append(Data("ab".utf8)).isEmpty)
    #expect(try assembler.append(Data("cd".utf8)).isEmpty)
    #expect(text(try assembler.append(Data("e\nf".utf8))) == ["abcde"])
    #expect(text(try assembler.append(Data("\n".utf8))) == ["f"])
  }

  @Test("a frame can hold many lines and start another")
  func many() throws {
    var assembler = CoreLineAssembler()
    #expect(text(try assembler.append(Data("a\nb\nc".utf8))) == ["a", "b"])
    #expect(text(try assembler.append(Data("\n".utf8))) == ["c"])
  }

  @Test("a line longer than any frame could be is refused")
  func tooLong() throws {
    var assembler = CoreLineAssembler()
    _ = try assembler.append(Data(count: CoreFrame.maximumPayload))
    #expect(throws: CoreLineAssembler.TooLong.self) {
      try assembler.append(Data(count: 1))
    }
  }
}
