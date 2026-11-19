import DriverrCore
import Foundation
import Testing

@testable import DriverrHerdr

@Suite("CombinedControl agent launch")
struct CombinedControlAgentLaunchTests {
  private let launch = AgentLaunch(kind: .codex, directory: "~/app", prompt: "hi")
  private let tmuxPrefix = "tmux:"
  private let tree = SessionTree.empty

  private func launches(_ control: FakeControl) async -> [AgentLaunch] {
    await control.agentLaunches
  }

  @Test("the TUI starts it when it can, before a core and tmux")
  func tuiFirst() async throws {
    let tui = FakeControl(tree: tree, canStartAgent: true)
    let core = FakeControl(tree: tree, canStartAgent: true)
    let tmux = FakeControl(tree: tree, canStartAgent: true)
    let combined = CombinedControl(
      tui: tui,
      sides: [
        .init(prefix: CorePaneID.prefix, control: core), .init(prefix: tmuxPrefix, control: tmux),
      ])

    #expect(combined.canStartAgent)
    _ = try await combined.startAgent(launch)

    #expect(await launches(tui) == [launch])
    #expect(await launches(core).isEmpty)
    #expect(await launches(tmux).isEmpty)
  }

  @Test("with no TUI that can, the core starts it, and with no core, tmux")
  func thenCoreThenTmux() async throws {
    let tui = FakeControl(tree: tree)
    let core = FakeControl(tree: tree, canStartAgent: true)
    let tmux = FakeControl(tree: tree, canStartAgent: true)
    _ = try await CombinedControl(
      tui: tui,
      sides: [
        .init(prefix: CorePaneID.prefix, control: core), .init(prefix: tmuxPrefix, control: tmux),
      ]
    ).startAgent(launch)
    #expect(await launches(core) == [launch])
    #expect(await launches(tmux).isEmpty)

    let onlyTmux = FakeControl(tree: tree, canStartAgent: true)
    _ = try await CombinedControl(
      primary: FakeControl(tree: tree), sides: [.init(prefix: tmuxPrefix, control: onlyTmux)]
    ).startAgent(launch)
    #expect(await launches(onlyTmux) == [launch])
  }

  /// A TUI with no session would refuse `workspace create`, and the core beside it is up.
  @Test("a TUI whose last poll found no session gives way to the core")
  func tuiWithNoSession() async throws {
    let tui = FakeControl(
      tree: .empty, failure: .herdrCommandFailed(reason: "no server"),
      availability: .serverNotRunning(version: "0.9.5"), canStartAgent: true)
    let core = FakeControl(tree: tree, canStartAgent: true)
    let combined = CombinedControl(tui: tui, core: core)
    _ = try await combined.snapshot()

    _ = try await combined.startAgent(launch)

    #expect(await launches(tui).isEmpty)
    #expect(await launches(core) == [launch])
  }

  @Test("a TUI with no session and nothing else that can is still asked, for herdr's own error")
  func tuiWithNoSessionAlone() async throws {
    let tui = FakeControl(
      tree: .empty, failure: .herdrCommandFailed(reason: "no server"),
      availability: .serverNotRunning(version: "0.9.5"), canStartAgent: true)
    let core = FakeControl(tree: tree)
    let combined = CombinedControl(tui: tui, core: core)
    _ = try await combined.snapshot()

    #expect(combined.canStartAgent)
    _ = try await combined.startAgent(launch)

    #expect(await launches(tui) == [launch])
  }

  @Test("an agent and a terminal are started by different sides: the TUI starts no terminal")
  func separateFromStarter() {
    let combined = CombinedControl(
      tui: FakeControl(tree: tree, canStartAgent: true), core: FakeControl(tree: tree))
    #expect(combined.canStartAgent)
    #expect(!combined.canStartTerminal)
  }

  @Test("with nothing that can, it cannot, and a start says so")
  func nobody() async {
    let combined = CombinedControl(tui: FakeControl(tree: tree), core: FakeControl(tree: tree))
    #expect(!combined.canStartAgent)
    await #expect(throws: AppError.self) { try await combined.startAgent(launch) }
  }

  @Test("the chosen side's failure is the answer, and no other side is tried")
  func failureStays() async {
    let failure = AppError.agentDidNotStart(paneID: "w2:p1", place: "app", reason: "no")
    let tui = FakeControl(tree: tree, canStartAgent: true, startFailure: failure)
    let core = FakeControl(tree: tree, canStartAgent: true)
    await #expect(throws: failure) {
      try await CombinedControl(tui: tui, core: core).startAgent(launch)
    }
    #expect(await launches(core).isEmpty, "a second side would open a second pane")
  }
}
