import DriverrCore
import DriverrHerdr
import DriverrSSH
import Foundation
import Testing

@testable import Driverr

/// A pane on a machine the core added reads its transcript through the core's
/// `machine.exec`. `ConnectionModel` wraps each line with `LoginShell.posix`, so every
/// scripted command reaches a shell in one form. See `LoginShell`.
@MainActor
@Suite("Connection machine reader", .timeLimit(.minutes(1)))
struct ConnectionMachineReaderTests {
  @Test("a machine pane's transcript commands go to the core as one sh -c word")
  func machineReaderWrapsItsLines() async throws {
    let (lines, line) = AsyncStream.makeStream(of: String.self)
    let control = MachineRunnerControl(inner: FakeControl(), record: line)
    let transport = FakeSSHTransport()
    var environment = AppEnvironment.ephemeral
    // `FakeSSHTransport`'s key is unknown to a fresh store, and TOFU would raise a prompt
    // that nobody answers.
    environment.knownHostsStore = InMemoryKnownHostsStore(
      seeded: ["10.1.0.9": FakeSSHTransport.defaultHostKey]
    )
    environment.makeTransport = { transport }
    environment.makeHerdrControl = { _ in control }
    let model = ConnectionModel(
      host: DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "dev"),
      environment: environment
    )
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    let transcripts = try #require(model.transcripts, "the connection made no transcript cache")

    let pane = Pane(
      id: "core:box/t7",
      tabID: "core:box/tab1",
      workspaceID: "core:box/ws1",
      title: "claude",
      agent: Agent(name: "Claude", kind: "claude", status: .working),
      terminalID: "t7",
      directory: "/srv/app"
    )
    transcripts.model(for: pane).loadIfNeeded()

    // The suite's time limit bounds the wait. The first line is enough: every line goes
    // through the same runner.
    var first: String?
    for await sent in lines {
      first = sent
      break
    }

    #expect(first?.hasPrefix("sh -c '") == true, "the line reached the core raw: \(first ?? "none")")
  }
}

/// `FakeControl` that says every pane on a core machine runs its commands through a runner
/// that records each line and answers with nothing.
private struct MachineRunnerControl: HerdrControl {
  let inner: FakeControl
  let record: AsyncStream<String>.Continuation

  var binaryPath: String { inner.binaryPath }
  func snapshot() async throws -> SessionTree { try await inner.snapshot() }
  func attachCommand(for pane: Pane) -> String? { inner.attachCommand(for: pane) }
  func availability() async -> HerdrAvailability { await inner.availability() }
  func commandRunner(forPane id: String) -> CommandRunner? {
    guard CorePaneID.machine(of: id) != nil else { return nil }
    return { [record] line in
      record.yield(line)
      return CommandResult(standardOutput: "", standardError: "", exitStatus: 0)
    }
  }
  func sendText(paneID: String, text: String) async throws {
    try await inner.sendText(paneID: paneID, text: text)
  }
  func submitText(paneID: String, text: String) async throws {
    try await inner.submitText(paneID: paneID, text: text)
  }
  func sendKeys(paneID: String, keys: [PaneKey]) async throws {
    try await inner.sendKeys(paneID: paneID, keys: keys)
  }
  func readPanes(ids: [String], lines: Int) async throws -> [String: [String]] {
    try await inner.readPanes(ids: ids, lines: lines)
  }
  func readScreen(of pane: Pane, lines: Int) async throws -> PaneScreen {
    try await inner.readScreen(of: pane, lines: lines)
  }
  func perform(_ action: PaneAction, on paneID: String) async throws {
    try await inner.perform(action, on: paneID)
  }
  func rename(_ target: RenameTarget, to label: String) async throws {
    try await inner.rename(target, to: label)
  }
}
