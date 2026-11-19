import DriverrCore
import DriverrHerdr
import Foundation
import Testing

@testable import DriverrHC

/// Issue #101 probes. Each one replays a CoreEventFeedTests test with the delay a loaded runner
/// can add at one point, and fails as that test failed on hosted CI. Delete this file with the fix.
@Suite("Core event feed flake probes (#101)", .timeLimit(.minutes(1)))
struct CoreEventFeedFlakeProbeTests {
  private let shell = #"{"address":"t1","state":"live","title":"a"}"#

  private func subscribing(_ terminals: String...) -> FakeCoreStream {
    let stream = FakeCoreStream()
    stream.replies["events.subscribe"] = .result(FakeCoreStream.subscribed(terminals, seq: 0))
    return stream
  }

  /// `documentRetried`, with the test's task late by one 50 ms tick between the first read and
  /// the reply swap. The watchdog's first tick then asks again while the reply is still
  /// the error, so the second read fails too, and the third read is the one that answers.
  @Test("probe: the retry tick lands before the reply swap")
  func documentRetriedWithLateSwap() async throws {
    let stream = subscribing(shell)
    stream.replies["doc.get"] = .error("unavailable")
    let control = CoreControl(
      binaryPath: "hc", callDeadline: .seconds(30), heartbeatTick: .milliseconds(50),
      open: { _ in stream })
    _ = try await control.snapshot()

    // A loaded runner: the test's task does not run again until the watchdog's first tick has
    // already asked again, and been refused, because the reply is still the error.
    try await waitUntil("the tick's read, still refused") { stream.calls(of: "doc.get") == 2 }

    stream.replies["doc.get"] = .result(FakeCoreStream.noDocument)
    try await waitUntil("the second read") { stream.calls(of: "doc.get") == 2 }
    for _ in 0..<30 {
      stream.emit(#"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":0}}"#)
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(stream.calls(of: "doc.get") == 2)
  }

  /// `sessionSignals`, with the status event arriving inside the pacer's gap after an earlier
  /// signal, as it does when the fixed `quiet()` sleep does not outlast subscribing's last fire.
  /// The status's change and the read's change then go out as ONE signal, and a wait for two
  /// never ends.
  @Test("probe: the status arrives inside the pacer gap of an earlier signal")
  func sessionSignalsInsideTheGap() async throws {
    let home = "/home/x"
    let path = "\(home)/.claude/sessions/101.json"
    let claude =
      #"{"address":"t1","state":"live","foreground":{"argv":["claude"],"pid":101},"#
      + #""status":{"app":"claude-code","state":"idle"}}"#
    let stream = subscribing(claude)
    stream.files = [path: .result(#"{"text":"{\"pid\":101,\"sessionId\":\"before\"}"}"#)]
    let control = CoreControl(binaryPath: "hc", home: home, open: { _ in stream })
    _ = try await control.snapshot()
    try await Task.sleep(for: CoreSignalPacer.promptGap * 2)

    let counter = ProbeCount()
    let changes = try #require(control.changes)
    let listener = Task {
      for await _ in changes { counter.add() }
    }
    defer { listener.cancel() }

    // An earlier change fires a signal at once and opens a 300 ms gap: a status whose read
    // finds the same id. On a loaded runner subscribing's own deferred fire plays this part.
    stream.event("status", on: "t1", #"{"status":{"app":"claude-code","state":"working"}}"#)
    try await waitUntil("the earlier signal") { counter.value >= 1 }
    let before = counter.value

    stream.files = [
      path: .late(#"{"text":"{\"pid\":101,\"sessionId\":\"after\"}"}"#, delay: .milliseconds(100))
    ]
    stream.event("status", on: "t1", #"{"status":{"app":"claude-code","state":"idle"}}"#)

    // The read has landed and the screen would show it: one signal carried both changes.
    try await waitUntil("the new id") {
      (try? await control.snapshot().pane(id: "core:t1")?.agent?.session?.identifier) == "after"
    }
    try await Task.sleep(for: CoreSignalPacer.promptGap * 2)
    #expect(counter.value == before + 1)
    try await waitUntil("the status's signal, then the read's", within: .seconds(1)) {
      counter.value >= before + 2
    }
  }
}

private final class ProbeCount: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func add() { lock.withLock { count += 1 } }
}
