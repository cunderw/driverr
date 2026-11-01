import DriverrCore
import DriverrHerdr
import Foundation
import Testing

@testable import DriverrHC

/// Hands out one scripted stream per `hc connect`.
private final class Streams: @unchecked Sendable {
  private let lock = NSLock()
  private var left: [FakeCoreStream]
  private var openedCount = 0

  init(_ streams: FakeCoreStream...) {
    left = streams
  }

  var opened: Int { lock.withLock { openedCount } }

  func open() throws -> any HerdrStream {
    try lock.withLock {
      openedCount += 1
      guard !left.isEmpty else { throw AppError.channelFailed(reason: "no stream") }
      return left.removeFirst()
    }
  }
}

/// Counts signals, so a wait on one fails at a deadline and not at the suite's time limit.
private final class SignalCount: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int { lock.withLock { count } }

  func add() {
    lock.withLock { count += 1 }
  }

  /// Counts what `changes` says, until cancelled.
  func listen(to changes: AsyncStream<Void>) -> Task<Void, Never> {
    Task {
      for await _ in changes { add() }
    }
  }
}

/// The subscription through `CoreControl`, because what matters is the tree it leaves.
///
/// A wait here is on the tree, or on a count that only rises. Nothing asserts that a signal has
/// not come, because that would be a sleep. `CoreSignalPacerTests` holds the rate.
@Suite("Core event feed", .timeLimit(.minutes(1)))
struct CoreEventFeedTests {
  private let shell = #"{"address":"t1","state":"live","title":"a"}"#
  private let blocked = #"{"records":{},"reported":true,"status":{"app":"x","state":"blocked"}}"#

  private func subscribing(_ terminals: String..., seq: Int = 0) -> FakeCoreStream {
    let stream = FakeCoreStream()
    stream.replies["events.subscribe"] = .result(
      FakeCoreStream.subscribed(terminals, seq: seq))
    return stream
  }

  private func control(
    _ streams: Streams,
    deadline: Duration = .seconds(30),
    heartbeatTick: Duration = .seconds(60)
  ) -> CoreControl {
    CoreControl(
      binaryPath: "hc", callDeadline: deadline, heartbeatTick: heartbeatTick,
      open: { _ in try streams.open() })
  }

  private func control(_ stream: FakeCoreStream) -> CoreControl {
    control(Streams(stream))
  }

  private func status(_ tree: SessionTree) -> AgentStatus? {
    tree.pane(id: "core:t1")?.agent?.status
  }

  @Test("once subscribed, nothing is asked of the core per read, and an event still lands")
  func noPolling() async throws {
    let stream = subscribing(shell)
    let control = control(stream)
    _ = try await control.snapshot()

    stream.event("status", on: "t1", blocked)
    try await tree(of: control) { status($0) == .blocked }
    for _ in 0..<5 { _ = try await control.snapshot() }

    #expect(!stream.methods.contains("terminal.list"))
    #expect(stream.calls(of: "events.subscribe") == 1)
    #expect(stream.calls(of: "doc.get") == 1)
    #expect(stream.calls(of: "machine.list") == 1)
  }

  @Test("subscribing reads the document and the machines only after the subscribe")
  func subscribeBeforeReading() async throws {
    let stream = subscribing(shell)
    _ = try await control(stream).snapshot()
    #expect(stream.methods.first == "events.subscribe")
    #expect(Set(stream.methods) == ["events.subscribe", "doc.get", "machine.list"])
    #expect(stream.methods.count == 3)
  }

  // MARK: - Which core a machine is

  private let onMachine = #"{"address":"box/t1","state":"live"}"#

  @Test("the first tree already says which core it came through and which core a machine is")
  func firstTreeKnowsItsMachines() async throws {
    let stream = subscribing(shell, onMachine)
    stream.replies["machine.list"] = .result(FakeCoreStream.machines("box", id: "5b37"))
    let tree = try await control(stream).snapshot()
    #expect(tree.coreID == "f47b")
    #expect(tree.workspaces.first { $0.id == "core:box/workspace" }?.machineCoreID == "5b37")
  }

  @Test("a machine that turns up later reads the machines again and lands in the tree")
  func machineArrivesLater() async throws {
    let stream = subscribing(shell)
    let control = control(stream)
    _ = try await control.snapshot()

    stream.replies["machine.list"] = .result(FakeCoreStream.machines("box", id: "5b37"))
    stream.event("created", on: "box/t1", onMachine)
    try await tree(of: control) {
      $0.workspaces.first { $0.id == "core:box/workspace" }?.machineCoreID == "5b37"
    }
    #expect(stream.calls(of: "machine.list") == 2)
  }

  @Test("a rename keeps the id, and the old name's group goes")
  func machineRenamed() async throws {
    let stream = subscribing(shell, onMachine)
    stream.replies["machine.list"] = .result(FakeCoreStream.machines("box", id: "5b37"))
    let control = control(stream)
    _ = try await control.snapshot()

    stream.replies["machine.list"] = .result(FakeCoreStream.machines("cee", id: "5b37"))
    stream.event("removed", on: "box/t1")
    stream.event("created", on: "cee/t1", #"{"address":"cee/t1","state":"live"}"#)
    try await tree(of: control) {
      $0.workspaces.filter { $0.machineCoreID == "5b37" }.map(\.id) == ["core:cee/workspace"]
    }
  }

  @Test("missed reads the machines again")
  func missedReadsMachines() async throws {
    let stream = subscribing(shell)
    _ = try await control(stream).snapshot()
    stream.emit(#"{"jsonrpc":"2.0","method":"missed","params":{"seq":57,"terminals":[]}}"#)
    try await waitUntil("the machines") { stream.calls(of: "machine.list") == 2 }
  }

  @Test("the machines read again on a new connection, and last until they answer")
  func machinesAcrossReconnect() async throws {
    let dying = subscribing(shell, onMachine)
    dying.replies["machine.list"] = .result(FakeCoreStream.machines("box", id: "5b37"))
    let replacement = subscribing(shell, onMachine)
    replacement.replies["machine.list"] = .error("unavailable")
    let control = control(Streams(dying, replacement))
    _ = try await control.snapshot()

    dying.finish()
    try await waitUntil("the reader sees the end") { dying.closes == 1 }
    try await waitUntil("the new subscription") {
      (try? await control.snapshot()) != nil && replacement.calls(of: "machine.list") == 1
    }
    let tree = try await control.snapshot()
    #expect(tree.workspaces.first { $0.id == "core:box/workspace" }?.machineCoreID == "5b37")
  }

  @Test("a machine list with no answer is asked again by the next tick")
  func machinesRetried() async throws {
    let stream = subscribing(shell, onMachine)
    stream.replies["machine.list"] = .error("unavailable")
    let control = control(Streams(stream), heartbeatTick: .milliseconds(20))
    _ = try await control.snapshot()

    stream.replies["machine.list"] = .result(FakeCoreStream.machines("box", id: "5b37"))
    try await tree(of: control) {
      $0.workspaces.first { $0.id == "core:box/workspace" }?.machineCoreID == "5b37"
    }
  }

  @Test("a machine list this build cannot read is not asked again")
  func unreadableMachinesNotRetried() async throws {
    let stream = subscribing(shell)
    stream.replies["machine.list"] = .result(#"{"machines":5}"#)
    let control = control(Streams(stream), heartbeatTick: .milliseconds(20))
    _ = try await control.snapshot()

    try await quiet()
    #expect(stream.calls(of: "machine.list") == 1)
  }

  @Test("a change is signalled, and a burst of them lands as one read of the latest")
  func signal() async throws {
    let stream = subscribing(shell)
    let control = control(stream)
    _ = try await control.snapshot()
    var changes = try #require(control.changes).makeAsyncIterator()

    stream.event("title", on: "t1", #"{"title":"b"}"#)
    stream.event("status", on: "t1", blocked)
    _ = await changes.next()
    try await tree(of: control) {
      status($0) == .blocked && $0.pane(id: "core:t1")?.title == "b"
    }
  }

  /// An `AsyncStream` ends with the task reading it, and a session cancels that on every pause.
  @Test("a listener that was cancelled can be followed by another")
  func secondListener() async throws {
    let stream = subscribing(shell)
    let control = control(stream)
    _ = try await control.snapshot()

    let first = Task {
      for await _ in try #require(control.changes) {}
    }
    first.cancel()
    _ = await first.result

    var changes = try #require(control.changes).makeAsyncIterator()
    stream.event("status", on: "t1", blocked)
    #expect(await changes.next() != nil)
  }

  @Test("a new listener ends the last")
  func oneListener() async throws {
    let control = control(subscribing(shell))
    var first = try #require(control.changes).makeAsyncIterator()
    _ = control.changes
    #expect(await first.next() == nil)
  }

  @Test("the whole line is applied however DATA cut it")
  func lineAcrossFrames() async throws {
    let stream = subscribing(shell)
    let control = control(stream)
    _ = try await control.snapshot()

    let line = Data(
      (#"{"method":"event","params":{"data":{"title":"b"},"seq":1,"terminal":"t1","#
        + #""type":"title"}}"# + "\n").utf8)
    let middle = line.count / 2
    let channel = FakeCoreStream.eventChannel
    stream.write(CoreFrame(channel: channel, kind: .data, payload: line[..<middle]).encoded)
    stream.write(CoreFrame(channel: channel, kind: .data, payload: line[middle...]).encoded)

    try await tree(of: control) { $0.pane(id: "core:t1")?.title == "b" }
    try await waitUntil("the credit") { stream.creditReturned() == line.count }
  }

  @Test("every byte comes back as credit, a type this build cannot read among them")
  func credit() async throws {
    let stream = subscribing(shell)
    let control = control(stream)
    _ = try await control.snapshot()

    var sent = 0
    for line in [
      #"{"method":"heartbeat","params":{"seq":0}}"#,
      #"{"method":"event","params":{"data":{"sky":"clear"},"seq":1,"type":"weather"}}"#,
      #"{"method":"event","params":{"data":{"title":"b"},"seq":2,"terminal":"t1","type":"title"}}"#,
    ] {
      stream.emit(line)
      sent += line.utf8.count + 1
    }

    try await tree(of: control) { $0.pane(id: "core:t1")?.title == "b" }
    try await waitUntil("the credit") { stream.creditReturned() == sent }
  }

  @Test("a read that never answers holds up no event, and no other read")
  func silentDocument() async throws {
    let stream = subscribing(shell)
    let control = control(Streams(stream), deadline: .seconds(20))
    _ = try await control.snapshot()

    stream.replies["doc.get"] = .silent
    stream.event("doc", #"{"name":"herdr-app","version":8}"#)
    try await waitUntil("the read") { stream.calls(of: "doc.get") == 2 }
    stream.event("status", on: "t1", blocked)
    try await tree(of: control) { status($0) == .blocked }
  }

  @Test("missed replaces the tree without what finished, and reads the document again")
  func missed() async throws {
    let stream = subscribing(shell)
    let control = control(stream)
    _ = try await control.snapshot()

    let terminals = [
      #"{"address":"t2","state":"live"}"#,
      #"{"address":"t3","state":"finished"}"#,
    ]
    stream.emit(
      #"{"jsonrpc":"2.0","method":"missed","params":{"seq":57,"#
        + #""terminals":[\#(terminals.joined(separator: ","))]}}"#)
    try await tree(of: control) { $0.allPanes.map(\.id) == ["core:t2"] }
    try await waitUntil("the document") { stream.calls(of: "doc.get") == 2 }

    // Queued behind it, so already in it.
    stream.event("removed", on: "t2", seq: 57)
    stream.event("created", on: "t4", #"{"address":"t4","state":"live"}"#, seq: 58)
    try await tree(of: control) { $0.allPanes.map(\.id) == ["core:t2", "core:t4"] }
  }

  /// Every viewer on the link would go with it, for one line nobody could read.
  @Test("a line that is not JSON ends the subscription, and leaves the connection and its viewers")
  func brokenLine() async throws {
    let stream = subscribing(shell)
    stream.replies["terminal.attach"] = .result(FakeCoreStream.attached(channel: 3))
    let streams = Streams(stream)
    let control = control(streams)
    _ = try await control.snapshot()
    let viewer = try await control.observe(
      terminalID: "t1", size: TerminalSize(columns: 80, rows: 24))

    stream.replies["events.subscribe"] = .result(
      FakeCoreStream.subscribed([#"{"address":"t2","state":"live"}"#], seq: 9))
    stream.emit("this is not json")
    try await waitUntil("the CLOSE") {
      stream.streamFrames.contains {
        $0.channel == FakeCoreStream.eventChannel && $0.kind == .close
      }
    }

    try await tree(of: control) { $0.allPanes.map(\.id) == ["core:t2"] }
    #expect(stream.closes == 0)
    #expect(streams.opened == 1)
    stream.writeMessage("still here", onChannel: 3)
    var output = viewer.output.makeAsyncIterator()
    #expect(try await output.next() == Data("still here".utf8))
  }

  /// The poll retried in 3 s. Without this a core that was busy for one read leaves the rows
  /// in the wrong order until the app's document next changes.
  @Test("a document read that got no answer is asked again, and stops once it has one")
  func documentRetried() async throws {
    let stream = subscribing(shell)
    stream.replies["doc.get"] = .error("unavailable")
    let control = control(Streams(stream), heartbeatTick: .milliseconds(50))
    _ = try await control.snapshot()

    stream.replies["doc.get"] = .result(FakeCoreStream.noDocument)
    try await waitUntil("the second read") { stream.calls(of: "doc.get") == 2 }
    for _ in 0..<30 {
      stream.emit(#"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":0}}"#)
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(stream.calls(of: "doc.get") == 2)
  }

  /// The app's format is private, so a value this build cannot read stays that way until a
  /// `doc` event says it changed.
  @Test("a document that answered and cannot be read is not asked for again")
  func unreadableDocumentNotRetried() async throws {
    let stream = subscribing(shell)
    stream.replies["doc.get"] = .result(#"{"value":5,"version":8}"#)
    let control = control(Streams(stream), heartbeatTick: .milliseconds(50))
    _ = try await control.snapshot()

    for _ in 0..<30 {
      stream.emit(#"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":0}}"#)
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(stream.calls(of: "doc.get") == 1)
  }

  /// Waits out what subscribing signalled, so the next signal can only be the next change's.
  private func quiet() async throws {
    try await Task.sleep(for: CoreSignalPacer.promptGap * 2)
  }

  /// A `doc` event says only that the document moved. The read is what there is to draw.
  @Test("a document read reaches the screen by its own signal")
  func documentSignals() async throws {
    let spaces = #"""
      {"address":"t1","state":"live","labels":{"herdr.space":"a"}},
      {"address":"t2","state":"live","labels":{"herdr.space":"b"}}
      """#
    let stream = subscribing(spaces)
    let control = control(stream)
    _ = try await control.snapshot()
    try await quiet()
    let signals = SignalCount()
    let listener = signals.listen(to: try #require(control.changes))
    defer { listener.cancel() }

    stream.replies["doc.get"] = .result(
      #"{"value":{"spaces":[{"id":"b","name":"Bee","tabs":[]}]},"version":8}"#)
    stream.event("doc", #"{"name":"herdr-app","version":8}"#)

    try await waitUntil("the signal") { signals.value >= 1 }
    #expect(try await control.snapshot().workspaces.map(\.id) == ["core:b", "core:a"])
  }

  /// `/clear`'s status has been signalled by the time the read lands, and the new id is what a
  /// chat needs to hear.
  @Test("a session id that moved reaches the screen by its own signal")
  func sessionSignals() async throws {
    let home = "/home/x"
    let path = "\(home)/.claude/sessions/101.json"
    let claude =
      #"{"address":"t1","state":"live","foreground":{"argv":["claude"],"pid":101},"#
      + #""status":{"app":"claude-code","state":"idle"}}"#
    let record = { (id: String) in
      FakeCoreStream.Reply.result(
        #"{"text":"{\"pid\":101,\"sessionId\":\"\#(id)\"}"}"#)
    }
    let stream = subscribing(claude)
    stream.files = [path: record("before")]
    let control = CoreControl(binaryPath: "hc", home: home, open: { _ in stream })
    _ = try await control.snapshot()
    try await quiet()
    let signals = SignalCount()
    let listener = signals.listen(to: try #require(control.changes))
    defer { listener.cancel() }

    stream.files = [path: .late(#"{"text":"{\"pid\":101,\"sessionId\":\"after\"}"}"#, delay: .milliseconds(100))]
    stream.event("status", on: "t1", #"{"status":{"app":"claude-code","state":"idle"}}"#)

    try await waitUntil("the status's signal, then the read's") { signals.value >= 2 }
    #expect(
      try await control.snapshot().pane(id: "core:t1")?.agent?.session?.identifier == "after")
  }

  @Test("a connection that dies signals, and the read that follows subscribes on a new one")
  func reconnect() async throws {
    let dying = subscribing(shell, seq: 500)
    let replacement = subscribing(#"{"address":"t2","state":"live"}"#, seq: 3)
    let streams = Streams(dying, replacement)
    let control = control(streams)
    _ = try await control.snapshot()
    var changes = try #require(control.changes).makeAsyncIterator()

    dying.finish()
    _ = await changes.next()
    try await tree(of: control) { $0.allPanes.map(\.id) == ["core:t2"] }
    #expect(streams.opened == 2)

    // The new process counts from its own start, far below where the old one had got.
    replacement.event("status", on: "t2", blocked, seq: 4)
    try await tree(of: control) { $0.pane(id: "core:t2")?.agent?.status == .blocked }
    #expect(replacement.methods.first == "events.subscribe")
    #expect(replacement.calls(of: "doc.get") == 1)
  }

  @Test("the document and the sessions survive a reconnect until they are read again")
  func keptAcrossReconnect() async throws {
    let spaces = #"""
      {"address":"t1","state":"live","labels":{"herdr.space":"a"}},
      {"address":"t2","state":"live","labels":{"herdr.space":"b"}}
      """#
    let dying = subscribing(spaces)
    dying.replies["doc.get"] = .result(
      #"{"value":{"spaces":[{"id":"b","name":"Bee","tabs":[]},{"id":"a","name":"Ay","tabs":[]}]},"#
        + #""version":7}"#)
    let replacement = subscribing(spaces)
    replacement.replies["doc.get"] = .error("unavailable")
    let control = control(Streams(dying, replacement))
    #expect(try await control.snapshot().workspaces.map(\.id) == ["core:b", "core:a"])

    dying.finish()
    try await waitUntil("the reader sees the end") { dying.closes == 1 }
    try await waitUntil("the new subscription") {
      (try? await control.snapshot()) != nil && replacement.calls(of: "doc.get") == 1
    }
    #expect(try await control.snapshot().workspaces.map(\.id) == ["core:b", "core:a"])
  }

  @Test("a CLOSE on the channel ends the subscription and not the connection")
  func closedChannel() async throws {
    let stream = subscribing(shell)
    let streams = Streams(stream)
    let control = control(streams)
    _ = try await control.snapshot()

    stream.replies["events.subscribe"] = .result(
      FakeCoreStream.subscribed([#"{"address":"t2","state":"live"}"#], seq: 9))
    stream.write(
      CoreFrame(channel: FakeCoreStream.eventChannel, kind: .close, payload: Data()).encoded)

    try await tree(of: control) { $0.allPanes.map(\.id) == ["core:t2"] }
    #expect(streams.opened == 1)
    #expect(stream.calls(of: "events.subscribe") == 2)
  }

  @Test("a failed subscribe is the read's failure, and the next read tries again")
  func refused() async throws {
    let stream = subscribing(shell)
    stream.replies["events.subscribe"] = .error("not now")
    let control = control(stream)
    await #expect(throws: AppError.herdrCommandFailed(reason: "not now")) {
      try await control.snapshot()
    }

    stream.replies["events.subscribe"] = .result(FakeCoreStream.subscribed([shell]))
    #expect(try await control.snapshot().allPanes.map(\.id) == ["core:t1"])
    #expect(stream.calls(of: "events.subscribe") == 2)
  }

  @Test("nine silent ticks close the connection and signal")
  func heartbeatLost() async throws {
    let stream = subscribing(shell)
    let control = control(Streams(stream), heartbeatTick: .milliseconds(5))
    _ = try await control.snapshot()
    var changes = try #require(control.changes).makeAsyncIterator()

    try await waitUntil("the close") { stream.closes == 1 }
    _ = await changes.next()
    await #expect(throws: AppError.self) { try await control.snapshot() }
  }

  /// A sleep is never short, so this cannot fail on a slow machine. Asserts the floor only.
  @Test("it takes all nine silent ticks")
  func nineTicks() async throws {
    let tick = Duration.milliseconds(100)
    let stream = subscribing(shell)
    let started = ContinuousClock.now
    let control = control(Streams(stream), heartbeatTick: tick)
    _ = try await control.snapshot()

    try await waitUntil("the close") { stream.closes == 1 }
    #expect(ContinuousClock.now - started >= tick * 9)
  }

  /// A tick is long enough that heartbeats sent every twentieth of one are never late, however
  /// loaded the machine.
  @Test("a heartbeat is what keeps it open")
  func heartbeatKeepsItOpen() async throws {
    let stream = subscribing(shell)
    let control = control(Streams(stream), heartbeatTick: .milliseconds(200))
    _ = try await control.snapshot()

    let beats = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < beats {
      stream.emit(#"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":0}}"#)
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(stream.closes == 0)

    try await waitUntil("the close") { stream.closes == 1 }
  }

  @Test("a viewer on the same connection hears it close")
  func viewerHearsTheClose() async throws {
    let stream = subscribing(shell)
    stream.replies["terminal.attach"] = .result(FakeCoreStream.attached(channel: 3))
    let control = control(Streams(stream), heartbeatTick: .milliseconds(5))
    _ = try await control.snapshot()
    let viewer = try await control.observe(
      terminalID: "t1", size: TerminalSize(columns: 80, rows: 24))

    await #expect(throws: TerminalCloseReason.streamEnded) {
      for try await _ in viewer.output {}
    }
  }
}
