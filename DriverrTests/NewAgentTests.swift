import DriverrCore
import DriverrHerdr
import Foundation
import Testing

@testable import Driverr

/// A host whose agent start answers what the test says, and can be held mid-start.
///
/// `FakeControl` lists every pane it starts, so it cannot stand for a start whose pane never
/// arrives, or one that fails after its pane is open.
private actor AgentStartControl: HerdrControl {
  private var tree: SessionTree
  /// The tree the next read returns once a start has been asked for.
  private let treeAfterStart: SessionTree
  private let answer: Result<String, AppError>
  private var holdsStarts = false
  private var startGate: CheckedContinuation<Void, Never>?
  private(set) var agentStarts = 0
  private(set) var terminalStarts = 0

  init(answer: Result<String, AppError>, treeAfterStart: SessionTree = .empty) {
    tree = .empty
    self.answer = answer
    self.treeAfterStart = treeAfterStart
  }

  func holdStarts() { holdsStarts = true }
  var isHoldingAStart: Bool { startGate != nil }
  func releaseStart() {
    startGate?.resume()
    startGate = nil
  }

  nonisolated var canStartAgent: Bool { true }
  nonisolated var canStartTerminal: Bool { true }
  nonisolated var binaryPath: String { "herdr" }

  func startAgent(_ launch: AgentLaunch) async throws -> String {
    agentStarts += 1
    tree = treeAfterStart
    if holdsStarts {
      holdsStarts = false
      await withCheckedContinuation { startGate = $0 }
    }
    return try answer.get()
  }

  func startTerminal() async throws -> String {
    terminalStarts += 1
    return "core:t1"
  }

  func snapshot() async throws -> SessionTree { tree }
  nonisolated func attachCommand(for pane: Pane) -> String? { "" }
  func availability() async -> HerdrAvailability { .ready(version: "0.9.5", protocolVersion: 22) }
  func sendText(paneID: String, text: String) async throws {}
  func submitText(paneID: String, text: String) async throws {}
  func sendKeys(paneID: String, keys: [PaneKey]) async throws {}
  func readPanes(ids: [String], lines: Int) async throws -> [String: [String]] { [:] }
  func readScreen(of pane: Pane, lines: Int) async throws -> PaneScreen { .blank }
  func perform(_ action: PaneAction, on paneID: String) async throws {}
  func rename(_ target: RenameTarget, to label: String) async throws {}
}

private func oneWorkspace(paneID: String) -> SessionTree {
  SessionTree(workspaces: [
    Workspace(
      id: "w9", number: 1, label: "app",
      tabs: [
        DriverrCore.Tab(
          id: "w9:t1", workspaceID: "w9", number: 1, label: "claude",
          panes: [Pane(id: paneID, tabID: "w9:t1", workspaceID: "w9", title: "claude")])
      ])
  ])
}

/// A wait on the control's own state, which `Task.sleep` lets `.timeLimit` stop.
private func until(_ condition: () async -> Bool) async throws {
  while !(await condition()) { try await Task.sleep(for: .milliseconds(1)) }
}

private let launch = AgentLaunch(kind: .claude, directory: "~/dev/app", prompt: "fix the build")

@MainActor
@Suite("SessionModel agent start", .timeLimit(.minutes(1)))
struct SessionModelAgentStartTests {
  @Test("whether a host can start one is the control's answer")
  func canStart() {
    #expect(SessionModel(control: FakeControl(tree: .empty, canStartAgent: true)).canStartAgent)
    #expect(!SessionModel(control: FakeControl(tree: .empty)).canStartAgent)
  }

  @Test("a start answers with its pane's id once the session lists the pane")
  func started() async throws {
    let control = FakeControl(tree: .empty, canStartAgent: true)
    let model = SessionModel(control: control)
    await model.refresh()

    let id = try await model.startAgent(launch)

    #expect(model.reportedTree.pane(id: id) != nil)
    #expect(await control.agentLaunches == [launch])
  }

  @Test("a refused start throws the host's answer")
  func refused() async {
    let control = FakeControl(
      tree: .empty, canStartAgent: true, startFailure: .directoryUnavailable(path: "~/dev/app"))
    let model = SessionModel(control: control)

    await #expect(throws: AppError.directoryUnavailable(path: "~/dev/app")) {
      try await model.startAgent(launch)
    }
  }

  /// The sheet offers to open the pane, and a scene opens only what `reportedTree` lists.
  @Test("an agent that did not start is thrown once its open pane is listed")
  func didNotStart() async {
    let failure = AppError.agentDidNotStart(paneID: "w9:p1", place: "app", reason: "timeout")
    let control = AgentStartControl(
      answer: .failure(failure), treeAfterStart: oneWorkspace(paneID: "w9:p1"))
    let model = SessionModel(control: control)
    await model.refresh()

    await #expect(throws: failure) { try await model.startAgent(launch) }
    #expect(model.reportedTree.pane(id: "w9:p1") != nil)
  }

  @Test("a pane the session never lists throws a failure that says the agent started")
  func neverListed() async throws {
    let control = AgentStartControl(answer: .success("w9:p1"))
    let model = SessionModel(control: control, terminalArrivalLimit: .milliseconds(20))
    await model.refresh()

    do {
      _ = try await model.startAgent(launch)
      Issue.record("expected a failure")
    } catch AppError.herdrCommandFailed(let reason) {
      #expect(reason.contains("started"), "\(reason)")
    }
  }

  /// The wait holds one pane at a time, so a second start of either kind is refused.
  @Test("a start while an agent start is out asks the host for nothing")
  func oneAtATime() async throws {
    let control = AgentStartControl(
      answer: .success("w9:p1"), treeAfterStart: oneWorkspace(paneID: "w9:p1"))
    let model = SessionModel(control: control)
    await model.refresh()
    await control.holdStarts()
    let first = Task { try await model.startAgent(launch) }
    try await until { await control.isHoldingAStart }

    await #expect(throws: AppError.self) { try await model.startAgent(launch) }
    #expect(await model.startTerminal() == nil)
    #expect(await control.agentStarts == 1)
    #expect(await control.terminalStarts == 0)

    await control.releaseStart()
    #expect(try await first.value == "w9:p1")
  }
}

@MainActor
@Suite("New Agent model", .timeLimit(.minutes(1)))
struct NewAgentModelTests {
  /// The calls the model made, in order.
  @MainActor
  private final class Calls {
    var started: [AgentLaunch] = []
    var opened: [String] = []
  }

  private func model(
    _ calls: Calls,
    answer: @escaping @MainActor (AgentLaunch) async throws -> String = { _ in "w9:p1" }
  ) -> NewAgentModel {
    NewAgentModel(
      hostName: "box",
      recentFolders: ["~/dev/app"],
      start: { launch in
        calls.started.append(launch)
        return try await answer(launch)
      },
      open: { calls.opened.append($0) },
      runner: { nil }
    )
  }

  @Test("Start needs a folder")
  func needsAFolder() {
    let model = model(Calls())
    #expect(!model.canStart)
    model.form.directory = "~/dev/app"
    #expect(model.canStart)
  }

  @Test("a start sends the form's launch and opens the pane it answers with")
  func startsAndOpens() async {
    let calls = Calls()
    let model = model(calls)
    model.form = NewAgentForm(kind: .codex, directory: " ~/dev/app ", prompt: "hi")

    await model.startAgent()

    #expect(calls.started == [AgentLaunch(kind: .codex, directory: "~/dev/app", prompt: "hi")])
    #expect(calls.opened == ["w9:p1"])
    #expect(model.phase == .editing)
  }

  @Test("a message too long to type starts nothing")
  func tooLong() async {
    let calls = Calls()
    let model = model(calls)
    model.form = NewAgentForm(
      directory: "/srv", prompt: String(repeating: "a", count: AgentLaunch.typedLineLimit))

    #expect(!model.canStart)
    await model.startAgent()
    #expect(calls.started.isEmpty)
  }

  @Test("a failure stays on the sheet, opens nothing, and goes when the form changes")
  func failure() async {
    let calls = Calls()
    let model = model(calls) { _ in throw AppError.directoryUnavailable(path: "/nope") }
    model.form.directory = "/nope"

    await model.startAgent()

    #expect(model.phase == .failed(.directoryUnavailable(path: "/nope")))
    #expect(calls.opened.isEmpty)
    #expect(model.paneLeftOpen == nil)
    model.form.directory = "/srv"
    #expect(model.phase == .editing)
  }

  @Test("an agent that did not start offers its open pane")
  func paneLeftOpen() async throws {
    let calls = Calls()
    let model = model(calls) { _ in
      throw AppError.agentDidNotStart(paneID: "w9:p1", place: "app", reason: "timeout")
    }
    model.form.directory = "~/dev/app"
    await model.startAgent()

    let pane = try #require(model.paneLeftOpen)
    #expect(pane.id == "w9:p1")
    #expect(pane.place == "app")
    model.openPaneLeftOpen()
    #expect(calls.opened == ["w9:p1"])
  }

  @Test("Start cannot be tapped again while a start is out")
  func whileStarting() async throws {
    let calls = Calls()
    var release: CheckedContinuation<Void, Never>?
    let model = model(calls) { _ in
      await withCheckedContinuation { release = $0 }
      return "w9:p1"
    }
    model.form.directory = "~/dev/app"
    let start = Task { await model.startAgent() }
    try await until { release != nil }

    #expect(model.isStarting)
    #expect(!model.canStart)
    await model.startAgent()
    #expect(calls.started.count == 1)

    release?.resume()
    await start.value
    #expect(calls.opened == ["w9:p1"])
  }

  @Test("a picked folder fills the form")
  func pick() {
    let model = model(Calls())
    model.use(folder: "/home/uitest/dev")
    #expect(model.form.directory == "/home/uitest/dev")
  }
}

@MainActor
@Suite("Folder browser model", .timeLimit(.minutes(1)))
struct FolderBrowserModelTests {
  private let host = FakeDirectoryHost(
    home: "/home/user", folders: ["/home/user": ["dev"], "/home/user/dev": ["app"]])

  /// The commands a runner was handed, in order.
  private actor Sent {
    var commands: [String] = []
    func append(_ command: String) { commands.append(command) }
  }

  private func runner(_ sent: Sent) -> CommandRunner {
    let host = host
    return { command in
      await sent.append(command)
      return host.answer(command)
        ?? CommandResult(standardOutput: "", standardError: "", exitStatus: 127)
    }
  }

  @Test("a folder is listed through the host runner, with the command sent once as built")
  func lists() async {
    let sent = Sent()
    let model = FolderBrowserModel(path: "~/dev", hostName: "box", runner: { [self] in runner(sent) })

    await model.load()

    #expect(model.state == .loaded(DirectoryListing(path: "/home/user/dev", names: ["app"], isTruncated: false)))
    #expect(await sent.commands == [DirectoryListing.command(for: "~/dev")])
  }

  @Test("a listed folder is not read again when the screen comes back")
  func once() async {
    let sent = Sent()
    let model = FolderBrowserModel(path: "", hostName: "box", runner: { [self] in runner(sent) })
    await model.load()
    await model.load()
    #expect(await sent.commands.count == 1)
  }

  @Test("a folder that cannot be opened says so")
  func unavailable() async {
    let model = FolderBrowserModel(path: "/nope", hostName: "box", runner: { [self] in runner(Sent()) })
    await model.load()
    #expect(model.state == .failed(.directoryUnavailable(path: "/nope")))
  }

  @Test("with no link up the browser says so")
  func notConnected() async {
    let model = FolderBrowserModel(path: "", hostName: "box", runner: { nil })
    await model.load()
    #expect(model.state == .failed(.notConnected(host: "box")))
  }

  /// Pushing a sub-folder before the listing lands cancels the screen's `.task`.
  @Test("a listing cancelled by leaving the screen is asked again on return")
  func cancelled() async throws {
    let sent = Sent()
    let host = host
    // The first listing waits until it is cancelled. Any later one answers at once.
    let slow: CommandRunner = { command in
      await sent.append(command)
      if await sent.commands.count == 1 { try await Task.sleep(for: .seconds(30)) }
      return host.answer(command)
        ?? CommandResult(standardOutput: "", standardError: "", exitStatus: 127)
    }
    let model = FolderBrowserModel(path: "", hostName: "box", runner: { slow })
    let first = Task { await model.load() }
    try await until { await sent.commands.count == 1 }
    first.cancel()
    await first.value
    #expect(model.state == .loading)

    await model.load()
    #expect(model.state == .loaded(DirectoryListing(path: "/home/user", names: ["dev"], isTruncated: false)))
    #expect(await sent.commands.count == 2)
  }
}
