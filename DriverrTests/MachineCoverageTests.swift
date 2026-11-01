import DriverrCore
import DriverrHerdr
import DriverrSSH
import Foundation
import Testing

@testable import Driverr

/// A machine that a host's core added, and that is a Driverr host of its own.
///
/// `adder` is a host whose core lists `bee/t1`. `bee` is that machine, connected directly, where
/// the same terminal is `t1`. The rule is `SessionTree.hidingMachines`; these are about which
/// reader sees what, and when.
@MainActor
@Suite("A machine that is also a host", .serialized, .timeLimit(.minutes(1)))
struct MachineCoverageTests {
  private let adder = DriverrCore.Host(name: "adder", hostname: "10.1.0.1", username: "carson")
  private let bee = DriverrCore.Host(name: "bee", hostname: "10.1.0.2", username: "carson")

  private static let beeCore = "core-b"

  private func group(_ id: String, _ pane: Pane, machine: String? = nil) -> Workspace {
    Workspace(
      id: id, number: 1, label: id,
      tabs: [Tab(id: pane.tabID, workspaceID: id, number: 1, label: "a", panes: [pane])],
      machineCoreID: machine
    )
  }

  private func pane(_ id: String, in workspace: String, status: AgentStatus) -> Pane {
    Pane(
      id: id, tabID: workspace + ".tab", workspaceID: workspace, title: id,
      agent: Agent(name: "Claude", status: status),
      terminalID: CorePaneID.address(of: id))
  }

  /// `adder`'s own terminal, then the machine's, which is the one that is blocked.
  private var adderTree: SessionTree {
    SessionTree(
      workspaces: [
        group("core:workspace", pane("core:t1", in: "core:workspace", status: .idle)),
        group(
          "core:bee/workspace", pane("core:bee/t1", in: "core:bee/workspace", status: .blocked),
          machine: Self.beeCore),
      ],
      coreID: "core-a"
    )
  }

  /// The same blocked terminal, seen from its own core.
  private func beeTree(coreID: String? = MachineCoverageTests.beeCore) -> SessionTree {
    SessionTree(
      workspaces: [group("core:workspace", pane("core:t1", in: "core:workspace", status: .blocked))],
      coreID: coreID
    )
  }

  private func environment(_ tree: SessionTree, center: FakeNotificationCenter? = nil)
    -> AppEnvironment
  {
    var environment = AppEnvironment.ephemeral
    environment.knownHostsStore = InMemoryKnownHostsStore(
      seeded: [
        adder.hostname: FakeSSHTransport.defaultHostKey,
        bee.hostname: FakeSSHTransport.defaultHostKey,
      ]
    )
    environment.makeTransport = { FakeSSHTransport() }
    let control = FakeControl(tree: tree)
    environment.makeHerdrControl = { _ in control }
    if let center { environment.notifications = center }
    return environment
  }

  /// Connected and read, as the host list leaves a host.
  private func connect(
    _ host: DriverrCore.Host,
    tree: SessionTree,
    on registry: ConnectionRegistry,
    center: FakeNotificationCenter? = nil
  ) async -> ConnectionModel {
    let model = registry.model(for: host, environment: environment(tree, center: center))
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    #expect(model.phase == .connected)
    await model.session?.refresh()
    return model
  }

  @Test("the machine's terminals move under its own host, whichever connected first", arguments: [true, false])
  func eitherOrder(adderFirst: Bool) async throws {
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    let first = await connect(
      adderFirst ? adder : bee, tree: adderFirst ? adderTree : beeTree(), on: registry)
    let second = await connect(
      adderFirst ? bee : adder, tree: adderFirst ? beeTree() : adderTree, on: registry)
    let adding = try #require((adderFirst ? first : second).session)
    let own = try #require((adderFirst ? second : first).session)

    #expect(adding.tree.allPanes.map(\.id) == ["core:t1"])
    #expect(own.tree.allPanes.map(\.id) == ["core:t1"])
    #expect(adding.reportedTree.allPanes.map(\.id) == ["core:t1", "core:bee/t1"])
  }

  @Test("with the machine's own host away its terminals come back through the core that added it")
  func ownHostGoes() async throws {
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    let adding = await connect(adder, tree: adderTree, on: registry)
    let own = await connect(bee, tree: beeTree(), on: registry)
    let session = try #require(adding.session)
    #expect(session.tree.pane(id: "core:bee/t1") == nil)

    await own.disconnect()

    #expect(session.tree.pane(id: "core:bee/t1") != nil)
    #expect(session.blockedPanesNewestFirst.map(\.id) == ["core:bee/t1"])
  }

  @Test("a host with no core tree covers nothing")
  func noCoreNoCover() async throws {
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    let adding = await connect(adder, tree: adderTree, on: registry)
    _ = await connect(bee, tree: beeTree(coreID: nil), on: registry)
    #expect(adding.session?.tree.pane(id: "core:bee/t1") != nil)
  }

  @Test("a host does not cover itself")
  func notItself() async {
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    _ = await connect(adder, tree: adderTree, on: registry)
    #expect(registry.coreIDs(coveringHost: adder.id).isEmpty)
  }

  @Test("Needs you, the host row, the card and the switcher each count the pane once")
  func countedOnce() async throws {
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    let adding = await connect(adder, tree: adderTree, on: registry)
    let own = await connect(bee, tree: beeTree(), on: registry)

    #expect(try #require(adding.session).blockedPanesNewestFirst.isEmpty)
    #expect(try #require(own.session).blockedPanesNewestFirst.map(\.id) == ["core:t1"])
    #expect(registry.summary(of: [adder, bee]).needsYouCount == 1)

    let observations = registry.liveActivityObservations()
    #expect(observations.reduce(0) { $0 + $1.blockedPanes.count } == 1)
    #expect(observations.reduce(0) { $0 + $1.counts.blocked } == 1)
    #expect(Set(observations.compactMap(\.coreID)) == ["core-a", Self.beeCore])

    let switcher = CrossHostPanes(currentHostID: nil, hosts: registry.paneSwitcherHosts())
    #expect(switcher.sections.flatMap(\.panes).filter { $0.agent?.status == .blocked }.count == 1)
  }

  @Test("the switcher on either host still reaches the other")
  func switcherReachesBoth() async {
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    _ = await connect(adder, tree: adderTree, on: registry)
    _ = await connect(bee, tree: beeTree(), on: registry)

    let fromAdder = CrossHostPanes(currentHostID: adder.id, hosts: registry.paneSwitcherHosts())
    #expect(fromAdder.sections.map(\.name) == [bee.displayName])
    #expect(fromAdder.sections.first?.panes.map(\.id) == ["core:t1"])

    let fromBee = CrossHostPanes(currentHostID: bee.id, hosts: registry.paneSwitcherHosts())
    #expect(fromBee.sections.map(\.name) == [adder.displayName])
    #expect(fromBee.sections.first?.panes.map(\.id) == ["core:t1"])
  }

  /// A pane out of `tree` is still alive, and `ConnectionModel.apply` forgets the chat, screen
  /// and draft of anything `Changes` leaves out.
  @Test("a read of a covered machine forgets nothing about its panes")
  func changesStayWhole() async throws {
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    let adding = await connect(adder, tree: adderTree, on: registry)
    _ = await connect(bee, tree: beeTree(), on: registry)
    let session = try #require(adding.session)

    var seen: SessionModel.Changes?
    session.onSessionChanged = { seen = $0 }
    await session.refresh()

    #expect(try #require(seen).liveIDs == ["core:t1", "core:bee/t1"])
  }

  /// The core on the other side pushes only on change, so nothing else would tell this host.
  @Test("a notification moves to the machine's own host and back, with no read of this one")
  func notificationsFollowCoverage() async throws {
    let center = FakeNotificationCenter(status: .authorized)
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    registry.isAppActive = false
    _ = await connect(adder, tree: adderTree, on: registry, center: center)
    try await waitFor { await center.posts.count == 1 }
    #expect(await center.posts.first?.userInfo[NotificationTapRouter.paneIDKey] == "core:bee/t1")

    let own = await connect(bee, tree: beeTree(), on: registry, center: center)
    try await waitFor { await center.withdrawn.count == 1 }

    await own.disconnect()
    try await waitFor { await center.posts.count == 3 }
    let panes = await center.posts.compactMap { $0.userInfo[NotificationTapRouter.paneIDKey] }
    #expect(panes.filter { $0 == "core:bee/t1" }.count == 2)
  }

  /// The centre is an actor nothing signals from. A sleep, so `.timeLimit` can end this.
  private func waitFor(_ condition: () async -> Bool) async throws {
    while !(await condition()) { try await Task.sleep(for: .milliseconds(1)) }
  }

  /// `SessionModel.tree` has no idea this scene exists, so it has to read the whole tree.
  @Test("a scene open on a machine survives its own host connecting, and shows it once")
  func sceneStays() async throws {
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    let adding = await connect(adder, tree: adderTree, on: registry)
    let scene = TerminalSceneModel(
      host: adder, model: adding, initialTarget: .pane(id: "core:bee/t1"))
    #expect(scene.currentPane?.id == "core:bee/t1")

    _ = await connect(bee, tree: beeTree(), on: registry)

    #expect(scene.currentPane?.id == "core:bee/t1")
    #expect(scene.nearestLivePane == nil)
    #expect(scene.strip.targets.contains(.pane(id: "core:bee/t1")))

    scene.select(.pane(id: "core:t1"))
    #expect(!scene.strip.targets.contains(.pane(id: "core:bee/t1")))
  }
}
