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
///
/// `cat` and `adder` both added `core-m`, which they call `mach` and `em`. `em` is that machine
/// as a host of its own. The ids are fixed so the order is known: `cat` sorts before `adder`,
/// and each machine's own host sorts after every host that added it, so its winning is the
/// own-host rule and not the order.
@MainActor
@Suite("A machine that is also a host", .serialized, .timeLimit(.minutes(1)))
struct MachineCoverageTests {
  private let cat = DriverrCore.Host(
    id: UUID(uuidString: "11111111-0000-0000-0000-000000000001")!,
    name: "cat", hostname: "10.1.0.3", username: "carson")
  private let adder = DriverrCore.Host(
    id: UUID(uuidString: "22222222-0000-0000-0000-000000000002")!,
    name: "adder", hostname: "10.1.0.1", username: "carson")
  private let bee = DriverrCore.Host(
    id: UUID(uuidString: "33333333-0000-0000-0000-000000000003")!,
    name: "bee", hostname: "10.1.0.2", username: "carson")
  private let em = DriverrCore.Host(
    id: UUID(uuidString: "44444444-0000-0000-0000-000000000004")!,
    name: "em", hostname: "10.1.0.4", username: "carson")

  private static let beeCore = "core-b"
  private static let sharedCore = "core-m"

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

  /// A host's own idle terminal, and `core-m`'s blocked one under the name this core gave it.
  private func sharingTree(coreID: String, calling name: String) -> SessionTree {
    SessionTree(
      workspaces: [
        group("core:workspace", pane("core:t1", in: "core:workspace", status: .idle)),
        group(
          "core:\(name)/workspace",
          pane("core:\(name)/t1", in: "core:\(name)/workspace", status: .blocked),
          machine: Self.sharedCore),
      ],
      coreID: coreID
    )
  }

  private var adderSharing: SessionTree { sharingTree(coreID: "core-a", calling: "em") }
  private var catSharing: SessionTree { sharingTree(coreID: "core-c", calling: "mach") }

  /// `core-m` seen from its own core.
  private var emTree: SessionTree {
    SessionTree(
      workspaces: [group("core:workspace", pane("core:t1", in: "core:workspace", status: .blocked))],
      coreID: Self.sharedCore
    )
  }

  private func environment(
    _ tree: SessionTree,
    control: FakeControl? = nil,
    center: FakeNotificationCenter? = nil,
    announced: (any AnnouncedPaneStore)? = nil,
    lastPanes: InMemoryLastPaneStore? = nil
  ) -> AppEnvironment {
    var environment = AppEnvironment.ephemeral
    environment.knownHostsStore = InMemoryKnownHostsStore(
      seeded: [
        cat.hostname: FakeSSHTransport.defaultHostKey,
        adder.hostname: FakeSSHTransport.defaultHostKey,
        bee.hostname: FakeSSHTransport.defaultHostKey,
        em.hostname: FakeSSHTransport.defaultHostKey,
      ]
    )
    environment.makeTransport = { FakeSSHTransport() }
    let control = control ?? FakeControl(tree: tree)
    environment.makeHerdrControl = { _ in control }
    if let center { environment.notifications = center }
    if let announced { environment.announcedPanes = announced }
    if let lastPanes { environment.lastPanes = lastPanes }
    return environment
  }

  /// Connected and read, as the host list leaves a host.
  private func connect(
    _ host: DriverrCore.Host,
    tree: SessionTree,
    on registry: ConnectionRegistry,
    control: FakeControl? = nil,
    center: FakeNotificationCenter? = nil,
    announced: (any AnnouncedPaneStore)? = nil,
    lastPanes: InMemoryLastPaneStore? = nil,
    reading: Bool = true
  ) async -> ConnectionModel {
    let model = registry.model(
      for: host,
      environment: environment(
        tree, control: control, center: center, announced: announced, lastPanes: lastPanes)
    )
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    #expect(model.phase == .connected)
    if reading { await model.session?.refresh() }
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
    try await waitFor("the adder to announce the machine's pane") {
      await center.posts.count == 1
    }
    #expect(await center.posts.first?.userInfo[NotificationTapRouter.paneIDKey] == "core:bee/t1")

    let own = await connect(bee, tree: beeTree(), on: registry, center: center)
    try await waitFor("the adder to withdraw it") { await center.withdrawn.count == 1 }

    await own.disconnect()
    try await waitFor("the adder to announce it again") { await center.posts.count == 3 }
    let panes = await center.posts.compactMap { $0.userInfo[NotificationTapRouter.paneIDKey] }
    #expect(panes.filter { $0 == "core:bee/t1" }.count == 2)
  }

  private struct WaitTimedOut: Error {}

  /// The centre and the stores are actors nothing signals from. Well inside the suite's
  /// `.timeLimit`, so a failure names what never came. It records and throws, because a wait
  /// that returned at its deadline would leave what follows it to pass by chance.
  private func waitFor(
    _ what: String,
    within limit: Duration = .seconds(30),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + limit
    while !(await condition()) {
      guard clock.now < deadline else {
        Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
        throw WaitTimedOut()
      }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  /// `hostChanged()` reaches every model, and a session that has not read yet holds an empty
  /// tree. Folded in, that says every announced pane has gone: their cards come down, the
  /// record is overwritten, and the first real read announces them all again.
  @Test("another host's cores moving says nothing to a session that has not read yet")
  func aSessionWithNoReadKeepsItsAnnouncements() async throws {
    let center = FakeNotificationCenter(status: .authorized)
    let announced = InMemoryAnnouncedPaneStore()
    await announced.setAnnouncedPanes(["core:t1"], forHost: adder.id)
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    registry.isAppActive = false

    _ = await connect(
      adder, tree: adderTree, on: registry, center: center, announced: announced, reading: false)
    _ = await connect(bee, tree: beeTree(), on: registry, center: center, announced: announced)
    try await waitFor("the machine's own host to announce its pane") {
      await center.posts.count == 1
    }

    // What this guards against is a write that must not come, so it waits out several.
    for _ in 0..<25 {
      try await Task.sleep(for: .milliseconds(20))
      try #require(await announced.announcedPanes(forHost: adder.id) == ["core:t1"])
    }
    #expect(await center.withdrawn.isEmpty)
  }

  /// Keeping the record is what lets the scene come back to this pane, which is still here
  /// whoever else shows it. Read from `tree`, it would look closed and the record would go.
  @Test("the last pane stays remembered on a machine another host covers")
  func lastPaneOnACoveredMachine() async throws {
    let lastPanes = InMemoryLastPaneStore()
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    let adding = await connect(adder, tree: adderTree, on: registry, lastPanes: lastPanes)
    _ = await connect(bee, tree: beeTree(), on: registry)
    #expect(adding.session?.tree.pane(id: "core:bee/t1") == nil)

    adding.noteLastPane("core:bee/t1")

    let expected = LastPaneRecord(paneID: "core:bee/t1", witness: "bee/t1")
    try await waitFor("the last pane to be recorded") {
      await lastPanes.lastPane(forHost: adder.id) == expected
    }
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

  // MARK: - A machine two hosts added

  /// The adder's notification for `core-m`'s blocked pane.
  private var adderEm: String {
    BlockedPaneAlerts.notificationID(hostID: adder.id, paneID: "core:em/t1")
  }

  @Test(
    "a machine two hosts added shows under the first in host order, whichever connected first",
    arguments: [true, false])
  func sharedEitherOrder(catFirst: Bool) async throws {
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    let first = await connect(
      catFirst ? cat : adder, tree: catFirst ? catSharing : adderSharing, on: registry)
    let second = await connect(
      catFirst ? adder : cat, tree: catFirst ? adderSharing : catSharing, on: registry)
    let keeping = try #require((catFirst ? first : second).session)
    let other = try #require((catFirst ? second : first).session)

    #expect(keeping.tree.allPanes.map(\.id) == ["core:t1", "core:mach/t1"])
    #expect(other.tree.allPanes.map(\.id) == ["core:t1"])
    #expect(other.reportedTree.allPanes.map(\.id) == ["core:t1", "core:em/t1"])
  }

  @Test("when the host showing a shared machine drops, the next in order takes it")
  func sharedHandOver() async throws {
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    let first = await connect(cat, tree: catSharing, on: registry)
    let next = await connect(adder, tree: adderSharing, on: registry)
    let session = try #require(next.session)
    #expect(session.tree.pane(id: "core:em/t1") == nil)

    await first.disconnect()

    #expect(session.tree.allPanes.map(\.id) == ["core:t1", "core:em/t1"])
    #expect(session.blockedPanesNewestFirst.map(\.id) == ["core:em/t1"])
  }

  @Test("Needs you, the host row, the card and the switcher count a shared machine once")
  func sharedCountedOnce() async throws {
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    let keeping = await connect(cat, tree: catSharing, on: registry)
    let other = await connect(adder, tree: adderSharing, on: registry)

    #expect(try #require(keeping.session).blockedPanesNewestFirst.map(\.id) == ["core:mach/t1"])
    #expect(try #require(other.session).blockedPanesNewestFirst.isEmpty)
    #expect(registry.summary(of: [cat, adder]).needsYouCount == 1)

    let observations = registry.liveActivityObservations()
    #expect(observations.reduce(0) { $0 + $1.blockedPanes.count } == 1)
    #expect(observations.reduce(0) { $0 + $1.counts.blocked } == 1)
    // The card carries who shows it, for a background pass that has no registry.
    let shown = Dictionary(uniqueKeysWithValues: observations.map { ($0.hostID, $0.machineCoreIDs) })
    #expect(shown == [cat.id: [Self.sharedCore], adder.id: []])

    let switcher = CrossHostPanes(currentHostID: nil, hosts: registry.paneSwitcherHosts())
    #expect(switcher.sections.flatMap(\.panes).filter { $0.agent?.status == .blocked }.count == 1)
  }

  @Test("a machine's own host outranks every host that added it, whatever its place in the order")
  func ownHostOutranksTheOrder() async throws {
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    let first = await connect(cat, tree: catSharing, on: registry)
    let second = await connect(adder, tree: adderSharing, on: registry)
    let own = await connect(em, tree: emTree, on: registry)

    #expect(try #require(first.session).tree.allPanes.map(\.id) == ["core:t1"])
    #expect(try #require(second.session).tree.allPanes.map(\.id) == ["core:t1"])
    #expect(try #require(own.session).blockedPanesNewestFirst.map(\.id) == ["core:t1"])
    #expect(registry.summary(of: [cat, adder, em]).needsYouCount == 1)
  }

  /// Which host keeps the machine changes with no read of the one that loses it.
  @Test("a shared machine's notification moves to the first host in order and back")
  func sharedNotificationsFollowTheOrder() async throws {
    let center = FakeNotificationCenter(status: .authorized)
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    registry.isAppActive = false
    _ = await connect(adder, tree: adderSharing, on: registry, center: center)
    try await waitFor("the adder to announce the machine's pane") {
      await center.posts.count == 1
    }
    #expect(await center.posts.first?.userInfo[NotificationTapRouter.paneIDKey] == "core:em/t1")

    let first = await connect(cat, tree: catSharing, on: registry, center: center)
    try await waitFor("the adder to withdraw it") { await center.withdrawn == [adderEm] }

    await first.disconnect()
    try await waitFor("the adder to announce it again") {
      await center.posts.filter { $0.userInfo[NotificationTapRouter.paneIDKey] == "core:em/t1" }
        .count == 2
    }
  }

  /// A core adding a machine changes no host's core, so the registry has to compare which host
  /// reports which machine.
  @Test("a host whose core adds a shared machine later takes its notification")
  func aLaterAddTakesTheNotification() async throws {
    let center = FakeNotificationCenter(status: .authorized)
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    registry.isAppActive = false
    _ = await connect(adder, tree: adderSharing, on: registry, center: center)
    try await waitFor("the adder to announce the machine's pane") {
      await center.posts.count == 1
    }

    let catAlone = SessionTree(
      workspaces: [group("core:workspace", pane("core:t1", in: "core:workspace", status: .idle))],
      coreID: "core-c")
    let control = FakeControl(tree: catAlone)
    let first = await connect(cat, tree: catAlone, on: registry, control: control, center: center)
    #expect(try #require(first.session).tree.pane(id: "core:mach/t1") == nil)

    #expect(await center.withdrawn.isEmpty)

    await control.update(to: catSharing)
    await first.session?.refresh()
    try await waitFor("the adder to withdraw it") { await center.withdrawn == [adderEm] }
  }
}
