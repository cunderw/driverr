import DriverrCore
import DriverrHC
import DriverrHerdr
import Foundation
import Testing

@testable import DriverrSSH

/// A viewer's output, read as it arrives, and consumed only when a test says so.
private final class ReadBack: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes = Data()
  private var ending: Result<Void, any Error>?
  private var credits = true

  var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
  var count: Int { lock.withLock { bytes.count } }
  /// How the stream ended, once it has.
  var ended: Result<Void, any Error>? { lock.withLock { ending } }

  func setCrediting(_ on: Bool) {
    lock.withLock { credits = on }
  }

  /// Everything the core has sent so far, consumed if the test is consuming.
  func start(_ output: AsyncThrowingStream<Data, any Error>, on raw: (any RawTerminalStream)?) {
    Task {
      do {
        for try await chunk in output {
          let credits = lock.withLock {
            bytes.append(chunk)
            return self.credits
          }
          if credits { raw?.consumed(chunk.count) }
        }
        lock.withLock { ending = .success(()) }
      } catch {
        lock.withLock { ending = .failure(error) }
      }
    }
  }
}

/// A real core, attached to over a real SSH exec channel, on a terminal the test started.
///
/// **Only ever a scratch core.** Everything runs with `HC_SESSION` set by `Scratch`, and each
/// test proves it is there before it sends anything. The default core on this machine is not
/// this suite's to type into or resize.
///
/// Off unless `DRIVERR_LIVE_CORE=1` and a core is installed here. Run it by hand:
///
/// ```sh
/// DRIVERR_LIVE_CORE=1 swift test --package-path DriverrKit --filter CoreAttachOverSSH
/// ```
@Suite(
  "Attaching to herdr-core over SSH",
  .enabled(
    if: ProcessInfo.processInfo.environment["DRIVERR_LIVE_CORE"] == "1"
      && CoreProbe.binary != nil
  ),
  .serialized,
  .timeLimit(.minutes(2))
)
struct CoreAttachOverSSHTests {
  private static let username = "carson"
  private static let password = UUID().uuidString
  private static let phone = TerminalSize(columns: 40, rows: 20)

  /// `ExecStreamBridge`, which is in the app target, cut down to what these tests read.
  private struct Stream: HerdrStream {
    let stream: any ExecStream
    var output: AsyncThrowingStream<Data, any Error> { stream.output }
    var end: ProcessEnd? { get async { nil } }
    func send(_ data: Data) async throws { try await stream.send(data) }
    func close() async { await stream.close() }
  }

  /// One test's scratch core, and the terminal it started on it.
  private struct Scratch {
    /// A session of its own. Its state directory is left behind, as `hc` leaves any.
    static let session = "driverr-attach-test"

    let transport: NIOSSHTransport
    let binary: String
    let name: String
    let address: String
    let control: CoreControl

    var paneID: String { CorePaneID.id(forAddress: address) }

    static func hc(
      _ arguments: String,
      binary: String,
      on transport: NIOSSHTransport
    ) async throws -> CommandResult {
      try await transport.execChannel(command: "HC_SESSION=\(session) '\(binary)' \(arguments)")
    }

    func hc(_ arguments: String) async throws -> CommandResult {
      try await Self.hc(arguments, binary: binary, on: transport)
    }

    /// The terminal's record, as `hc get` prints it.
    func record() async throws -> [String: Any] {
      let printed = try await hc("get \(address) --json")
      let data = Data(printed.standardOutput.utf8)
      return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
  }

  private func withScratchCore(
    runs line: String = "sh",
    _ body: (Scratch) async throws -> Void
  ) async throws {
    let server = try await EmbeddedSSHServer(
      username: Self.username,
      password: Self.password,
      executesRealCommands: true,
      streamsStandardOutput: true
    )
    defer { Task { await server.stop() } }
    let transport = NIOSSHTransport()
    defer { Task { await transport.disconnect() } }
    let host = DriverrCore.Host(
      name: "localhost",
      hostname: "127.0.0.1",
      port: server.port,
      username: Self.username
    )
    try await transport.connect(to: host, hostKeyValidator: AlwaysTrustValidator())
    try await transport.authenticate(.password(Self.password))

    let binary = try #require(CoreProbe.binary)
    let name = "driverr-\(UUID().uuidString.prefix(8).lowercased())"
    let started = try await Scratch.hc(
      "run --bg --keep --json --no-parent --name \(name) \(line)",
      binary: binary,
      on: transport
    )
    let record = try #require(
      try JSONSerialization.jsonObject(with: Data(started.standardOutput.utf8)) as? [String: Any]
    )
    let address = try #require(
      (record["address"] ?? (record["terminal"] as? [String: Any])?["address"]) as? String
    )
    let control = CoreControl(binaryPath: binary) { command in
      Stream(
        stream: try await transport.execStream(
          command: "HC_SESSION=\(Scratch.session) \(command)"
        )
      )
    }
    let scratch = Scratch(
      transport: transport,
      binary: binary,
      name: name,
      address: address,
      control: control
    )

    // Ends the terminal, then the core. Nothing runs after the stop, because any `hc` under
    // this session would start a new one. Kept shells would otherwise respawn on every run.
    func tearDown() async {
      _ = try? await scratch.hc("kill \(address)")
      _ = try? await scratch.hc("rm \(address)")
      _ = try? await scratch.hc("server stop")
    }

    do {
      // Before anything is sent: a name made up a moment ago can only be on the core that
      // was asked to start it, and the snapshot goes through the runner the attach uses.
      let status = try await scratch.hc("server status")
      print("scratch \(Scratch.session): \(status.standardOutput.prefix(60))")
      let tree = try await control.snapshot()
      try #require(
        tree.allPanes.contains { $0.title == name },
        "not on the scratch core; nothing was sent"
      )
      try await body(scratch)
    } catch {
      await tearDown()
      throw error
    }
    await tearDown()
  }

  private func attach(_ scratch: Scratch) async throws -> (any PaneBridge, ReadBack) {
    let attacher = try #require(scratch.control.paneAttacher(for: scratch.paneID))
    let bridge = try await attacher.open(terminalID: scratch.address, size: Self.phone)
    let readBack = ReadBack()
    readBack.start(bridge.output, on: bridge as? any RawTerminalStream)
    return (bridge, readBack)
  }

  private func waitUntil(
    _ what: String,
    within limit: Duration = .seconds(20),
    _ condition: () async throws -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + limit
    while !(try await condition()) {
      try #require(clock.now < deadline, "Never saw: \(what)")
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func size(of scratch: Scratch) async throws -> [Int] {
    let record = try await scratch.record()
    return [record["cols"] as? Int ?? -1, record["rows"] as? Int ?? -1]
  }

  @Test("a viewer paints, types, sets the size, and hands it back at CLOSE")
  func typingViewer() async throws {
    try await withScratchCore { scratch in
      let (bridge, output) = try await attach(scratch)
      try await waitUntil("the first paint") { output.text.contains("$ ") }
      // Opening is itself active, so the terminal took the phone's size with no keystroke.
      #expect(try await size(of: scratch) == [40, 20])

      try await bridge.send(text: "echo fr''om-the-viewer\r")
      try await waitUntil("the echo") { output.text.contains("from-the-viewer\r\n") }

      try await bridge.resize(to: TerminalSize(columns: 50, rows: 21))
      try await waitUntil("the resize") { try await size(of: scratch) == [50, 21] }

      await bridge.release()
      // With no typing viewer left, the core runs the terminal headless.
      try await waitUntil("the size going back") { try await size(of: scratch) != [50, 21] }
    }
  }

  /// The size event is the core's own word for what the terminal went through, so a reflow
  /// through the default on the way would be in it. Only a real core can say.
  @Test("a deferred attach holds until the measured size, which is the first resize seen")
  func deferredAttach() async throws {
    try await withScratchCore { scratch in
      let before = try await size(of: scratch)
      let measured = TerminalSize(columns: 47, rows: 19)
      #expect(before != [47, 19])

      let events = try await scratch.transport.execStream(
        command:
          "HC_SESSION=\(Scratch.session) '\(scratch.binary)' events --json"
          + " --terminal \(scratch.address)"
      )
      let heard = ReadBack()
      heard.start(events.output, on: nil)

      let attacher = try #require(scratch.control.paneAttacher(for: scratch.paneID))
      let deferred = DeferredPaneBridge { [address = scratch.address] in
        try await attacher.open(terminalID: address, size: $0)
      }
      let output = ReadBack()
      output.start(deferred.output, on: deferred)

      // Typed ahead of the size, as someone who just chose the pane does.
      try await deferred.send(text: "echo he''ld\r")
      try await Task.sleep(for: .milliseconds(300))
      #expect(try await size(of: scratch) == before, "attached before a size came")

      try await deferred.resize(to: measured)
      try await waitUntil("the held echo") { output.text.contains("held\r\n") }
      #expect(try await size(of: scratch) == [47, 19])

      // A later size is a RESIZE on the same viewer.
      try await deferred.resize(to: TerminalSize(columns: 47, rows: 22))
      try await waitUntil("the second size") { sizes(in: heard.text).count >= 2 }

      let seen = sizes(in: heard.text)
      print("size events: \(seen)")
      #expect(seen.first == [47, 19], "first resize seen: \(seen)")
      #expect(!seen.contains([80, 24]))
      await events.close()
      await deferred.release()
    }
  }

  /// The `[cols, rows]` of every `size` event in `hc events --json`'s lines.
  private func sizes(in events: String) -> [[Int]] {
    events.split(separator: "\n").compactMap { line in
      guard
        let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
        let event = message["params"] as? [String: Any],
        event["type"] as? String == "size",
        let data = event["data"] as? [String: Any],
        let columns = data["cols"] as? Int,
        let rows = data["rows"] as? Int
      else { return nil }
      return [columns, rows]
    }
  }

  /// The paint of a full-screen program skips the shell behind it, so only a second attach can
  /// bring that back. A real core, because this depends on the wording of its paint.
  @Test("attached during a full-screen program, leaving it paints the shell and its history")
  func repaintAfterAFullScreenProgram() async throws {
    try await withScratchCore(runs: "sh -c 'seq 1 300; top; exec sh'") { scratch in
      try await Task.sleep(for: .milliseconds(500))
      let (bridge, output) = try await attach(scratch)
      try await waitUntil("top's paint") { output.text.contains("\u{1b}[?1049h") }
      #expect(!output.text.contains("\r\n150\r\n"), "the paint held the shell's history")
      #expect(!output.text.contains("\u{1b}[?1049l"), "the paint would turn autowrap off")

      _ = try await scratch.hc("keys \(scratch.address) q")
      try await waitUntil("top leaving") { output.text.contains("\u{1b}[?1049l") }
      (bridge as? any RawTerminalStream)?.leftAlternateScreen()

      try await waitUntil("the shell's history") { output.text.contains("\r\n150\r\n") }
      try await bridge.send(text: "echo sti''ll-typing\r")
      try await waitUntil("the echo") { output.text.contains("still-typing\r\n") }
    }
  }

  @Test("the composer types through a 0x0 viewer without moving the size")
  func composer() async throws {
    try await withScratchCore { scratch in
      let (_, output) = try await attach(scratch)
      try await waitUntil("the first paint") { output.text.contains("$ ") }

      try await scratch.control.submitText(paneID: scratch.paneID, text: "echo com''posed")
      try await waitUntil("the submit") { output.text.contains("composed\r\n") }

      try await scratch.control.sendText(paneID: scratch.paneID, text: "echo ke''yed")
      try await scratch.control.sendKeys(paneID: scratch.paneID, keys: [.enter])
      try await waitUntil("the key") { output.text.contains("keyed\r\n") }

      #expect(try await size(of: scratch) == [40, 20])
    }
  }

  @Test("an observer sees output and never sets the size")
  func observer() async throws {
    try await withScratchCore { scratch in
      let (_, output) = try await attach(scratch)
      try await waitUntil("the first paint") { output.text.contains("$ ") }

      let attacher = try #require(scratch.control.paneAttacher(for: scratch.paneID))
      let observer = try await attacher.observe(
        terminalID: scratch.address, size: TerminalSize(columns: 30, rows: 10))
      let watched = ReadBack()
      watched.start(observer.output, on: observer as? any RawTerminalStream)

      try await scratch.control.submitText(paneID: scratch.paneID, text: "echo wat''ched")
      try await waitUntil("the observer's copy") { watched.text.contains("watched\r\n") }

      #expect(try await size(of: scratch) == [40, 20])
      await observer.release()
    }
  }

  @Test("history reaches a typing viewer at the width it asked for")
  func history() async throws {
    try await withScratchCore(runs: "sh -c 'seq 1 300; exec sh'") { scratch in
      try await Task.sleep(for: .milliseconds(300))
      let (_, output) = try await attach(scratch)
      // The screen holds 20 rows, so anything before 280 is history.
      try await waitUntil("the history") { output.text.contains("\r\n150\r\n") }
      #expect(output.text.contains("\r\n300\r\n"))
    }
  }

  /// The acceptance test's real half. It stalls for good if credit is not returned, and the
  /// stall is measured before any is.
  @Test("a burst past the starting credit stalls unconsumed, flows consumed, and spares channel 0")
  func burst() async throws {
    let window = 256 * 1024
    try await withScratchCore { scratch in
      let (bridge, output) = try await attach(scratch)
      try await waitUntil("the first paint") { output.text.contains("$ ") }

      output.setCrediting(false)
      try await bridge.send(text: "seq 1 200000; echo bu''rst-done\r")
      try await waitUntil("the window") { output.count > window - 32 * 1024 }
      try await Task.sleep(for: .milliseconds(500))
      #expect(output.count <= window + 2048, "past the credit: \(output.count)")
      #expect(!output.text.contains("burst-done"))

      // Stalled, and the shared connection still answers.
      #expect(try await scratch.control.snapshot().allPanes.contains { $0.title == scratch.name })

      (bridge as? any RawTerminalStream)?.consumed(output.count)
      output.setCrediting(true)
      try await waitUntil("the end of the burst") { output.text.contains("burst-done\r\n") }
      #expect(output.count > 1024 * 1024)
    }
  }

  /// Losing the program on a kept terminal, as `kill -9` from outside does.
  @Test("a loss closes the stream as lost, attaches are refused, then the new shell takes one")
  func lossAndRestart() async throws {
    try await withScratchCore { scratch in
      let (first, output) = try await attach(scratch)
      try await waitUntil("the first paint") { output.text.contains("$ ") }

      let pid = try #require(try await scratch.record()["pid"] as? Int)
      _ = try await scratch.transport.execChannel(command: "kill -9 \(pid)")
      try await waitUntil("the loss") { output.ended != nil }
      guard case .failure(let reason) = output.ended else {
        Issue.record("the stream finished cleanly on a loss")
        return
      }
      #expect(reason as? TerminalCloseReason == .lost)
      await first.release()

      let attacher = try #require(scratch.control.paneAttacher(for: scratch.paneID))
      var refusals = 0
      var opened: (any PaneBridge)?
      try await waitUntil("the new shell") {
        do {
          opened = try await attacher.open(terminalID: scratch.address, size: Self.phone)
          return true
        } catch {
          refusals += 1
          return false
        }
      }
      print("refused \(refusals) attaches before the new shell")

      let bridge = try #require(opened)
      let second = ReadBack()
      second.start(bridge.output, on: bridge as? any RawTerminalStream)
      try await bridge.send(text: "echo ba''ck\r")
      try await waitUntil("the new shell's echo") { second.text.contains("back\r\n") }

      // A final end says so, and finishes cleanly.
      _ = try await scratch.hc("kill \(scratch.address)")
      try await waitUntil("the end") { second.ended != nil }
      guard case .success = second.ended else {
        Issue.record("a kill did not finish the stream cleanly: \(String(describing: second.ended))")
        return
      }
    }
  }
}
