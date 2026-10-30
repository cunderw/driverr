import DriverrCore
import Foundation
import Testing

@testable import DriverrHerdr

/// One side of a combined host: answers from a script and records what reached it.
private actor Side: HerdrControl {
  nonisolated let binaryPath: String
  private let tree: SessionTree
  private let snapshotFailure: AppError?
  private let answer: HerdrAvailability
  private(set) var calls: [String] = []

  init(
    binaryPath: String,
    tree: SessionTree = .empty,
    snapshotFailure: AppError? = nil,
    answer: HerdrAvailability = .notInstalled
  ) {
    self.binaryPath = binaryPath
    self.tree = tree
    self.snapshotFailure = snapshotFailure
    self.answer = answer
  }

  func snapshot() async throws -> SessionTree {
    if let snapshotFailure { throw snapshotFailure }
    return tree
  }

  func availability() async -> HerdrAvailability { answer }
  nonisolated func attachCommand(for pane: Pane) -> String { "\(binaryPath) attach" }

  func sendText(paneID: String, text: String) async throws { calls.append("sendText \(paneID)") }
  func submitText(paneID: String, text: String) async throws {
    calls.append("submitText \(paneID)")
  }
  func sendKeys(paneID: String, keys: [PaneKey]) async throws {
    calls.append("sendKeys \(paneID)")
  }
  func readPanes(ids: [String], lines: Int) async throws -> [String: [String]] {
    calls.append("readPanes \(ids.joined(separator: ","))")
    return Dictionary(uniqueKeysWithValues: ids.map { ($0, ["from \(binaryPath)"]) })
  }
  func readScreen(of pane: Pane, lines: Int) async throws -> PaneScreen {
    calls.append("readScreen \(pane.id)")
    return PaneScreen.sanitised("", lines: lines)
  }
  func perform(_ action: PaneAction, on paneID: String) async throws {
    calls.append("perform \(paneID)")
  }
  func rename(_ target: RenameTarget, to label: String) async throws {
    calls.append("rename \(target.id)")
  }
}

private let tuiFailure = AppError.herdrCommandFailed(reason: "no session")
private let coreFailure = AppError.channelFailed(reason: "core went away")

private func pane(_ id: String, in workspace: String) -> Pane {
  Pane(id: id, tabID: "\(workspace).tab", workspaceID: workspace, title: id)
}

private func tree(_ workspace: String, panes: [String], focused: String? = nil) -> SessionTree {
  SessionTree(
    workspaces: [
      Workspace(
        id: workspace,
        number: 1,
        label: workspace,
        tabs: [
          Tab(
            id: "\(workspace).tab",
            workspaceID: workspace,
            number: 1,
            label: "Tab",
            panes: panes.map { pane($0, in: workspace) }
          )
        ]
      )
    ],
    focusedPaneID: focused
  )
}

private let tuiTree = tree("w1", panes: ["w1:p1"], focused: "w1:p1")
private let coreTree = tree("core:workspace", panes: ["core:t1"])

@Suite("Combined control")
struct CombinedControlTests {
  private func control(
    tui: Side = Side(binaryPath: "herdr"),
    core: Side = Side(binaryPath: "hc")
  ) -> CombinedControl {
    CombinedControl(tui: tui, core: core)
  }

  // MARK: - Which control serves a host

  @Test("both found is combined, and one found is that one")
  func joining() {
    let tui = Side(binaryPath: "herdr")
    let core = Side(binaryPath: "hc")
    #expect(CombinedControl.joining(tui: tui, core: core) is CombinedControl)
    #expect(CombinedControl.joining(tui: tui, core: nil)?.binaryPath == "herdr")
    #expect(CombinedControl.joining(tui: nil, core: core)?.binaryPath == "hc")
    #expect(CombinedControl.joining(tui: nil, core: nil) == nil)
  }

  // MARK: - The tree

  @Test("a host with both shows both, TUI first, with the TUI's focus")
  func merged() async throws {
    let combined = control(
      tui: Side(binaryPath: "herdr", tree: tuiTree),
      core: Side(binaryPath: "hc", tree: coreTree)
    )
    let tree = try await combined.snapshot()
    #expect(tree.allPanes.map(\.id) == ["w1:p1", "core:t1"])
    #expect(tree.workspaces.map(\.id) == ["w1", "core:workspace"])
    #expect(tree.focusedPaneID == "w1:p1")
  }

  @Test("the core failing returns the TUI's tree")
  func coreFails() async throws {
    let combined = control(
      tui: Side(binaryPath: "herdr", tree: tuiTree),
      core: Side(binaryPath: "hc", snapshotFailure: coreFailure)
    )
    #expect(try await combined.snapshot() == tuiTree)
  }

  @Test("a TUI with no session running gives way to the core's tree")
  func tuiHasNothing() async throws {
    let combined = control(
      tui: Side(
        binaryPath: "herdr",
        snapshotFailure: tuiFailure,
        answer: .serverNotRunning(version: "0.9.1")
      ),
      core: Side(binaryPath: "hc", tree: coreTree)
    )
    #expect(try await combined.snapshot() == coreTree)
  }

  /// A failed poll must stay a failure. Passed over, it clears `SessionModel.lastFailure`, and
  /// `ConnectionModel.apply` forgets every TUI pane's transcript, screen, draft and surface.
  @Test(
    "a TUI that failed a poll stays a failure, even with a core to show",
    arguments: [
      HerdrAvailability.ready(version: "0.9.1", protocolVersion: 22),
      HerdrAvailability.tooOld(version: "0.7.0", protocolVersion: 16),
      HerdrAvailability.statusUnreadable(version: "0.9.1"),
      // Also what `CLIControl.availability` answers when its status command fails to run.
      HerdrAvailability.notInstalled,
    ]
  )
  func tuiPollFails(answer: HerdrAvailability) async {
    let combined = control(
      tui: Side(binaryPath: "herdr", snapshotFailure: tuiFailure, answer: answer),
      core: Side(binaryPath: "hc", tree: coreTree)
    )
    await #expect(throws: tuiFailure) { try await combined.snapshot() }
  }

  @Test("both failing throws the TUI's error")
  func bothFail() async {
    let combined = control(
      tui: Side(binaryPath: "herdr", snapshotFailure: tuiFailure),
      core: Side(binaryPath: "hc", snapshotFailure: coreFailure)
    )
    await #expect(throws: tuiFailure) { try await combined.snapshot() }
  }

  // MARK: - Availability

  @Test("ready and ready is combined")
  func bothReady() async {
    let combined = control(
      tui: Side(
        binaryPath: "herdr", answer: .ready(version: "0.9.1", protocolVersion: 22)),
      core: Side(binaryPath: "hc", answer: .coreReady(version: "0.1.14"))
    )
    #expect(
      await combined.availability() == .combined(herdrVersion: "0.9.1", coreVersion: "0.1.14"))
  }

  @Test("a TUI with no session and a ready core is ready, because there is something to show")
  func coreOnlyAnswers() async {
    let combined = control(
      tui: Side(binaryPath: "herdr", answer: .serverNotRunning(version: "0.9.1")),
      core: Side(binaryPath: "hc", answer: .coreReady(version: "0.1.14"))
    )
    #expect(await combined.availability() == .coreReady(version: "0.1.14"))
  }

  @Test("a core this build refuses does not disturb a working TUI")
  func coreIncompatible() async {
    let ready = HerdrAvailability.ready(version: "0.9.1", protocolVersion: 22)
    let combined = control(
      tui: Side(binaryPath: "herdr", answer: ready),
      core: Side(
        binaryPath: "hc",
        answer: .coreIncompatible(version: "9", generation: 2, missingMethods: [])
      )
    )
    #expect(await combined.availability() == ready)
  }

  @Test("neither ready is the TUI's answer, which has the next step")
  func neitherReady() async {
    let combined = control(
      tui: Side(binaryPath: "herdr", answer: .serverNotRunning(version: "0.9.1")),
      core: Side(binaryPath: "hc", answer: .notInstalled)
    )
    #expect(await combined.availability() == .serverNotRunning(version: "0.9.1"))
  }

  // MARK: - Routing

  @Test("every pane call goes to the side the id belongs to")
  func routing() async throws {
    let tui = Side(binaryPath: "herdr")
    let core = Side(binaryPath: "hc")
    let combined = control(tui: tui, core: core)

    for id in ["w1:p1", "core:t1"] {
      try await combined.sendText(paneID: id, text: "x")
      try await combined.submitText(paneID: id, text: "x")
      try await combined.sendKeys(paneID: id, keys: [.enter])
      _ = try await combined.readScreen(of: pane(id, in: "w"), lines: 5)
      try await combined.perform(.close, on: id)
    }

    let verbs = ["sendText", "submitText", "sendKeys", "readScreen", "perform"]
    #expect(await tui.calls == verbs.map { "\($0) w1:p1" })
    #expect(await core.calls == verbs.map { "\($0) core:t1" })
  }

  @Test("the attach command is the owning side's")
  func attachCommand() {
    let combined = control()
    #expect(combined.attachCommand(for: pane("w1:p1", in: "w")) == "herdr attach")
    #expect(combined.attachCommand(for: pane("core:t1", in: "w")) == "hc attach")
  }

  @Test("a rename goes by the workspace or tab id")
  func renameRouting() async throws {
    let tui = Side(binaryPath: "herdr")
    let core = Side(binaryPath: "hc")
    let combined = control(tui: tui, core: core)

    try await combined.rename(.workspace(id: "w1"), to: "x")
    try await combined.rename(.tab(id: "core:tab"), to: "x")

    #expect(await tui.calls == ["rename w1"])
    #expect(await core.calls == ["rename core:tab"])
  }

  @Test("a read splits by side, and every pane comes back")
  func readPanes() async throws {
    let tui = Side(binaryPath: "herdr")
    let core = Side(binaryPath: "hc")
    let combined = control(tui: tui, core: core)

    let panes = try await combined.readPanes(ids: ["w1:p1", "core:t1", "w1:p2"], lines: 3)

    #expect(await tui.calls == ["readPanes w1:p1,w1:p2"])
    #expect(await core.calls == ["readPanes core:t1"])
    #expect(panes["core:t1"] == ["from hc"])
    #expect(panes["w1:p2"] == ["from herdr"])
  }

  // MARK: - Set-up

  @Test("the binary is the TUI's, which the bridge runs")
  func binaryPath() {
    #expect(control().binaryPath == "herdr")
  }

  @Test("a socket path reaches the TUI side, and only the TUI has one")
  func socketPath() throws {
    let cli = CLIControl(run: { _ in CommandResult(standardOutput: "", standardError: "", exitStatus: 0) })
    let combined = CombinedControl(tui: cli, core: Side(binaryPath: "hc"))
    let bound = try #require(combined.bound(toSocketPath: "/run/x.sock") as? CombinedControl)
    let command = bound.attachCommand(
      for: Pane(id: "w1:p1", tabID: "t", workspaceID: "w", title: "x", terminalID: "term")
    )
    #expect(command.hasPrefix("export HERDR_SOCKET_PATH=/run/x.sock;"))
  }

  @Test("the default binding is no binding")
  func defaultBinding() {
    let side = Side(binaryPath: "hc")
    #expect(side.bound(toSocketPath: "/run/x.sock").binaryPath == "hc")
  }

  @Test("a CLIControl keeps the path it is bound to, and a nil leaves it alone")
  func cliBinding() throws {
    let cli = CLIControl(
      herdrSocketPath: "/run/old.sock",
      run: { _ in CommandResult(standardOutput: "", standardError: "", exitStatus: 0) }
    )
    let bound = try #require(cli.bound(toSocketPath: "/run/new.sock") as? CLIControl)
    #expect(bound.herdrSocketPath == "/run/new.sock")
    let unchanged = try #require(cli.bound(toSocketPath: nil) as? CLIControl)
    #expect(unchanged.herdrSocketPath == "/run/old.sock")
  }

  // MARK: - The prefix

  @Test("a core id is the prefix and the address, machine included")
  func corePaneID() {
    #expect(CorePaneID.id(forAddress: "10.1.0.254/t1") == "core:10.1.0.254/t1")
    #expect(CorePaneID.isCore("core:t1"))
    #expect(!CorePaneID.isCore("w1:p1"))
  }
}
