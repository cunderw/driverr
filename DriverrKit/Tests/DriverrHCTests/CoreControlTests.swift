import DriverrCore
import DriverrHerdr
import Foundation
import Testing

@testable import DriverrHC

/// Hands out one scripted stream per `hc connect`, and counts them.
private final class CoreHost: @unchecked Sendable {
  private let lock = NSLock()
  private var streams: [FakeCoreStream]
  private var commands: [String] = []

  init(_ streams: FakeCoreStream...) {
    self.streams = streams
  }

  var opened: [String] { lock.withLock { commands } }

  func open(_ command: String) async throws -> any HerdrStream {
    try lock.withLock {
      commands.append(command)
      guard !streams.isEmpty else { throw AppError.channelFailed(reason: "no stream") }
      return streams.removeFirst()
    }
  }
}

@Suite("Core control", .timeLimit(.minutes(1)))
struct CoreControlTests {
  private func control(_ host: CoreHost, deadline: Duration = .seconds(30)) -> CoreControl {
    CoreControl(
      binaryPath: "/home/my user/.local/bin/herdr-core",
      callDeadline: deadline,
      open: { try await host.open($0) }
    )
  }

  private func listing(_ terminals: String) -> FakeCoreStream {
    let stream = FakeCoreStream()
    stream.replies = ["terminal.list": .result(#"{"terminals":[\#(terminals)]}"#)]
    return stream
  }

  private let terminal = #"{"address":"t1","cwd":"/srv","title":"a"}"#

  @Test("a snapshot opens the connection by quoted path and lists terminals")
  func snapshot() async throws {
    let stream = listing(terminal)
    let host = CoreHost(stream)
    let tree = try await control(host).snapshot()
    #expect(tree.allPanes.map(\.id) == ["core:t1"])
    #expect(host.opened == ["'/home/my user/.local/bin/herdr-core' connect"])
    #expect(stream.methods == ["terminal.list"])
  }

  @Test("snapshots share one connection")
  func oneConnection() async throws {
    let host = CoreHost(listing(terminal))
    let control = control(host)
    _ = try await control.snapshot()
    _ = try await control.snapshot()
    #expect(host.opened.count == 1)
  }

  @Test("concurrent first calls share one opening")
  func oneOpening() async throws {
    let host = CoreHost(listing(terminal))
    let control = control(host)
    async let first = control.snapshot()
    async let second = control.snapshot()
    _ = try await (first, second)
    #expect(host.opened.count == 1)
  }

  @Test("after the stream dies, the next snapshot reopens")
  func reopen() async throws {
    let dying = listing(terminal)
    let replacement = listing(#"{"address":"t2","cwd":"/srv","title":"b"}"#)
    let host = CoreHost(dying, replacement)
    let control = control(host)
    _ = try await control.snapshot()

    dying.finish()
    // The reader sees the end on its own schedule, and a snapshot in the gap fails. That is
    // the contract: reopened by the next one after the death is noticed.
    var tree: SessionTree?
    while tree == nil {
      tree = try? await control.snapshot()
      await Task.yield()
    }
    #expect(tree?.allPanes.map(\.id) == ["core:t2"])
    #expect(host.opened.count == 2)
  }

  @Test("availability reads the same connection the snapshot uses")
  func availability() async throws {
    let host = CoreHost(listing(terminal))
    let control = control(host)
    #expect(await control.availability() == .coreReady(version: "0.1.14"))
    _ = try await control.snapshot()
    #expect(host.opened.count == 1)
  }

  @Test("a refused core reports why, and is not asked again on every poll")
  func refusal() async {
    let stream = FakeCoreStream()
    stream.helloReply = FakeCoreStream.helloReply(generation: 2)
    let host = CoreHost(stream)
    let control = control(host)

    let expected = HerdrAvailability.coreIncompatible(
      version: "0.1.14", generation: 2, missingMethods: [])
    #expect(await control.availability() == expected)

    await #expect(throws: AppError.herdrCommandFailed(reason: expected.message)) {
      try await control.snapshot()
    }
    #expect(host.opened.count == 1)
  }

  @Test("no core and a dead core are both not installed")
  func notCore() async {
    let stream = FakeCoreStream()
    stream.helloReply = nil
    let host = CoreHost(stream)
    let control = control(host, deadline: .milliseconds(50))
    #expect(await control.availability() == .notInstalled)
    await #expect(throws: AppError.herdrCommandFailed(reason: "herdr-core is not answering.")) {
      try await control.snapshot()
    }
  }

  @Test("a failed exec is not a crash")
  func openFails() async {
    let host = CoreHost()
    #expect(await control(host).availability() == .notInstalled)
  }

  @Test("attaching names the terminal's address, quoted, machine prefix included")
  func attachCommand() {
    let pane = Pane(
      id: "core:10.1.0.254/t1", tabID: "x", workspaceID: "y", title: "z",
      terminalID: "10.1.0.254/t1")
    #expect(
      control(CoreHost()).attachCommand(for: pane)
        == "'/home/my user/.local/bin/herdr-core' attach 10.1.0.254/t1"
    )
  }

  @Test("everything that writes refuses instead of reporting success")
  func writesRefuse() async {
    let control = control(CoreHost())
    let pane = Pane(id: "core:t1", tabID: "x", workspaceID: "y", title: "z", terminalID: "t1")
    let refused = AppError.herdrCommandFailed(
      reason: "Driverr can't do this on a herdr-core terminal yet.")

    await #expect(throws: refused) { try await control.sendText(paneID: pane.id, text: "x") }
    await #expect(throws: refused) { try await control.submitText(paneID: pane.id, text: "x") }
    await #expect(throws: refused) { try await control.sendKeys(paneID: pane.id, keys: [.enter]) }
    await #expect(throws: refused) { _ = try await control.readScreen(of: pane, lines: 5) }
    await #expect(throws: refused) { try await control.perform(.close, on: pane.id) }
    await #expect(throws: refused) {
      try await control.rename(.tab(id: CoreSnapshotMapper.tabID), to: "x")
    }
  }

  @Test("a read maps every pane to empty, as a pane that could not be read")
  func readPanes() async throws {
    let panes = try await control(CoreHost()).readPanes(ids: ["core:t1", "core:t2"], lines: 5)
    #expect(panes == ["core:t1": [], "core:t2": []])
  }

  @Test("a socket path changes nothing: a core is not a herdr session")
  func socketPath() {
    let control = control(CoreHost())
    #expect(control.bound(toSocketPath: "/run/x.sock").binaryPath == control.binaryPath)
  }
}
