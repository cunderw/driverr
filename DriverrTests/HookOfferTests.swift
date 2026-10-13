import DriverrCore
import DriverrSSH
import Foundation
import Testing

@testable import Driverr

/// When a connection offers the agent hooks, what the sheet's model records,
/// and the persisted store. The policy and the install itself are `swift test`
/// (`HookOfferStoreTests`, `HookInstallerTests`); this is the wiring around them.
@MainActor
@Suite("Hook offer", .serialized, .timeLimit(.minutes(1)))
struct HookOfferTests {
  private let workbox = DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson")
  private let claude = AgentIntegration.claudeCode
  private let settings = #"{"env": {"EXAMPLE_API_KEY": "sk-test-NOT-A-REAL-KEY"}}"# + "\n"

  /// `.ephemeral`, with the key trusted and the hook commands answered by `host`.
  private func environment(host: FakeHookHost, store: any HookOfferStore) -> AppEnvironment {
    var environment = AppEnvironment.ephemeral
    environment.knownHostsStore = InMemoryKnownHostsStore(
      seeded: [workbox.hostname: FakeSSHTransport.defaultHostKey])
    environment.hookOffers = store
    environment.makeHookRunners = { _ in host.runners }
    return environment
  }

  private func connected(
    host: FakeHookHost,
    store: any HookOfferStore = InMemoryHookOfferStore()
  ) async -> (ConnectionRegistry, ConnectionModel) {
    let registry = ConnectionRegistry()
    let model = registry.model(for: workbox, environment: environment(host: host, store: store))
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    #expect(model.phase == .connected)
    return (registry, model)
  }

  @Test("a host without the hooks is offered them, and the root is told once nothing else is up")
  func offersAHostWithoutTheHooks() async {
    let (registry, model) = await connected(host: FakeHookHost(integration: claude, text: settings))
    #expect(registry.pendingHookOffer(isRootPresenting: false) == nil, "nothing is offered before the check")

    await model.offerHooksIfNeeded()

    #expect(registry.pendingHookOffer(isRootPresenting: false)?.model === model)
    #expect(registry.pendingHookOffer(isRootPresenting: false)?.integration == claude)
    #expect(
      registry.pendingHookOffer(isRootPresenting: true) == nil,
      "an offer raised over another root presentation is a presentation from inside one")

    model.clearHookOffer()
    #expect(registry.pendingHookOffer(isRootPresenting: false) == nil)
  }

  @Test("no offer for a host that has the hooks, has no ~/.claude, or declined")
  func noOffer() async throws {
    let installed = try #require(try claude.installing(into: settings))
    let (_, hasHooks) = await connected(host: FakeHookHost(integration: claude, text: installed))
    await hasHooks.offerHooksIfNeeded()
    #expect(hasHooks.pendingHookOffer == nil)

    let (_, neverRan) = await connected(
      host: FakeHookHost(integration: claude, text: nil, hasConfigDirectory: false))
    await neverRan.offerHooksIfNeeded()
    #expect(neverRan.pendingHookOffer == nil)

    let declined = InMemoryHookOfferStore(
      seeded: [.init(hostID: workbox.id, agent: claude.agent): .declined])
    let (_, said) = await connected(host: FakeHookHost(integration: claude, text: settings), store: declined)
    await said.offerHooksIfNeeded()
    #expect(said.pendingHookOffer == nil)
  }

  /// It asks once. A swipe is not a decline, so the next version is still offered, but this
  /// one is not offered again.
  @Test("an offer swiped away is recorded as asked, is not offered again, and is not a decline")
  func swipeCountsAsAsked() async {
    let store = InMemoryHookOfferStore()
    let (registry, model) = await connected(host: FakeHookHost(integration: claude, text: settings), store: store)
    await model.offerHooksIfNeeded()
    #expect(model.pendingHookOffer == claude)

    await model.hookOfferDismissed(claude)
    #expect(registry.pendingHookOffer(isRootPresenting: false) == nil)
    #expect(await store.state(forHost: workbox.id, agent: claude.agent) == .offered(version: claude.version))

    await model.offerHooksIfNeeded()
    #expect(model.pendingHookOffer == nil, "a swiped offer came back on the next connect")
  }

  @Test("dismissing after Not Now or Install keeps the answer")
  func dismissKeepsTheAnswer() async {
    let declined = InMemoryHookOfferStore(seeded: [.init(hostID: workbox.id, agent: claude.agent): .declined])
    let (_, a) = await connected(host: FakeHookHost(integration: claude, text: settings), store: declined)
    await a.hookOfferDismissed(claude)
    #expect(await declined.state(forHost: workbox.id, agent: claude.agent) == .declined)

    let installed = InMemoryHookOfferStore(
      seeded: [.init(hostID: workbox.id, agent: claude.agent): .installed(version: claude.version)])
    let (_, b) = await connected(host: FakeHookHost(integration: claude, text: settings), store: installed)
    await b.hookOfferDismissed(claude)
    #expect(await installed.state(forHost: workbox.id, agent: claude.agent) == .installed(version: claude.version))
  }

  @Test("a host that installed an earlier hook set is offered the update")
  func offersTheUpdate() async {
    let store = InMemoryHookOfferStore(
      seeded: [.init(hostID: workbox.id, agent: claude.agent): .installed(version: claude.version - 1)])
    let (_, model) = await connected(host: FakeHookHost(integration: claude, text: settings), store: store)
    await model.offerHooksIfNeeded()
    #expect(model.pendingHookOffer == claude)
  }

  @Test("a disconnected host is not checked")
  func notConnected() async {
    let registry = ConnectionRegistry()
    let host = FakeHookHost(integration: claude, text: settings)
    let model = registry.model(for: workbox, environment: environment(host: host, store: InMemoryHookOfferStore()))
    await model.offerHooksIfNeeded()
    #expect(model.pendingHookOffer == nil)
    #expect(model.hookRunners() == nil)
  }

  @Test("Install writes the hooks and records the version; Not Now records a decline")
  func sheetRecordsTheAnswer() async throws {
    let host = FakeHookHost(integration: claude, text: settings)
    let store = InMemoryHookOfferStore()
    let sheet = HookInstallModel(
      hostID: workbox.id, hostName: "workbox", integration: claude, store: store, runners: { host.runners })

    await sheet.check()
    #expect(sheet.phase == .checked(.absent))
    #expect(sheet.canInstall)

    await sheet.install()
    #expect(sheet.phase == .finished(.installed))
    #expect(await store.state(forHost: workbox.id, agent: claude.agent) == .installed(version: claude.version))
    let text = await host.text
    #expect(try claude.status(in: text) == .installed)

    await sheet.check()
    #expect(sheet.phase == .checked(.installed), "the menu on an installed host says so")
    #expect(!sheet.canInstall)

    await sheet.decline()
    #expect(await store.state(forHost: workbox.id, agent: claude.agent) == .declined)
  }

  @Test("a file that changed under the install is reported, and Try Again reads it again")
  func changedSinceReadIsRetryable() async {
    let host = FakeHookHost(integration: claude, text: settings, changeBeforeWrite: settings + "\n")
    let sheet = HookInstallModel(
      hostID: workbox.id, hostName: "workbox", integration: claude, store: InMemoryHookOfferStore(),
      runners: { host.runners })

    await sheet.install()
    #expect(
      sheet.phase
        == .failed(message: "~/.claude/settings.json changed after Driverr read it. Nothing was written.", isRetryable: true))
    await sheet.install()
    #expect(sheet.phase == .finished(.installed))
  }

  /// `ConnectionCoordinator.run(_:standardInput:)` throws this when the host stops
  /// answering. The sheet disables Cancel, Not Now and the swipe only while the phase is
  /// `.installing`, so the phase has to leave it, or the person cannot leave the sheet.
  @Test("a write the host stopped answering ends the install as a failure the person can leave")
  func aStalledWriteLeavesInstalling() async {
    let host = FakeHookHost(integration: claude, text: settings)
    let stalled = AppError.channelFailed(reason: "The host stopped answering before the command finished.")
    let sheet = HookInstallModel(
      hostID: workbox.id, hostName: "workbox", integration: claude, store: InMemoryHookOfferStore(),
      runners: { HookInstallRunners(run: host.run, write: { _, _ in throw stalled }) })

    await sheet.install()

    #expect(
      sheet.phase
        == .failed(message: "The host stopped answering before the command finished.", isRetryable: false))
    #expect(!sheet.isBusy)
    #expect(await host.writeCount == 0)
  }

  @Test("no link reads as not connected rather than as a failure")
  func noLink() async {
    let sheet = HookInstallModel(
      hostID: workbox.id, hostName: "workbox", integration: claude, store: InMemoryHookOfferStore(),
      runners: { nil })
    await sheet.check()
    #expect(sheet.phase == .notConnected)
  }

  @Test("deleting a host forgets its hook offer record")
  func deleteForgetsTheRecord() async {
    let store = InMemoryHookOfferStore(seeded: [.init(hostID: workbox.id, agent: claude.agent): .declined])
    let list = HostListModel(
      store: InMemoryHostStore(seeded: [workbox]),
      knownHosts: InMemoryKnownHostsStore(),
      credentials: PasswordCredentials(store: InMemoryPasswordStore()),
      lastPanes: InMemoryLastPaneStore(),
      hookOffers: store,
      announcedPanes: InMemoryAnnouncedPaneStore()
    )
    await list.load()
    await list.delete(workbox)
    #expect(await store.state(forHost: workbox.id, agent: claude.agent) == nil)
  }

  @Test("the persisted store survives into another store over the same defaults, and nil removes")
  func userDefaultsStore() async {
    let suite = "driverr.tests.hookoffer.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let other = UUID()

    await UserDefaultsHookOfferStore(suiteName: suite).setState(.declined, forHost: workbox.id, agent: claude.agent)
    let reopened = UserDefaultsHookOfferStore(suiteName: suite)
    #expect(await reopened.state(forHost: workbox.id, agent: claude.agent) == .declined)
    #expect(await reopened.state(forHost: other, agent: claude.agent) == nil)
    #expect(await reopened.state(forHost: workbox.id, agent: "codex") == nil)

    await reopened.setState(.installed(version: 3), forHost: workbox.id, agent: claude.agent)
    #expect(await reopened.state(forHost: workbox.id, agent: claude.agent) == .installed(version: 3))
    await reopened.setState(nil, forHost: workbox.id, agent: claude.agent)
    #expect(await reopened.state(forHost: workbox.id, agent: claude.agent) == nil)
  }
}
