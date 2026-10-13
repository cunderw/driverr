import DriverrCore
import DriverrSSH
import Foundation
import Testing

@testable import Driverr

/// The key install sheet's phases, the test login, and Use This Key.
/// The command and its mapping are `swift test` (`AuthorizedKeyInstallCommandsTests`).
@MainActor
@Suite("Key install model", .serialized, .timeLimit(.minutes(1)))
struct KeyInstallModelTests {
  private let workbox = DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson")

  private struct Fixture {
    let model: KeyInstallModel
    let keys: FakeAuthorizedKeysHost
    let identities: InMemoryIdentityStore
    let hostStore: any HostStore
    let passwords: any PasswordStore
  }

  private func fixture(
    keys: FakeAuthorizedKeysHost = FakeAuthorizedKeysHost(),
    run: CommandRunner? = nil,
    connected: Bool = true,
    loginError: AppError? = nil,
    hostStore: (any HostStore)? = nil,
    passwords: (any PasswordStore)? = nil
  ) async throws -> Fixture {
    let identities = InMemoryIdentityStore()
    let hostStore = hostStore ?? InMemoryHostStore(seeded: [workbox])
    let passwords = passwords ?? InMemoryPasswordStore(seeded: [workbox.id: "hunter2"])
    let credentials = PasswordCredentials(store: passwords)
    let hosts = HostListModel(
      store: hostStore, knownHosts: InMemoryKnownHostsStore(), credentials: credentials,
      lastPanes: InMemoryLastPaneStore(), hookOffers: InMemoryHookOfferStore(),
      announcedPanes: InMemoryAnnouncedPaneStore())
    await hosts.load()
    let model = KeyInstallModel(
      hostID: workbox.id,
      hostName: workbox.displayName,
      identityStore: identities,
      hosts: hosts,
      credentials: credentials,
      runner: { connected ? run ?? keys.run : nil },
      checkLogin: { _ in loginError }
    )
    return Fixture(model: model, keys: keys, identities: identities, hostStore: hostStore, passwords: passwords)
  }

  @Test("with no keys, Generate makes one and picks it, and Install is then possible")
  func generatePicksTheNewKey() async throws {
    let f = try await fixture()
    await f.model.load()
    #expect(f.model.identities.isEmpty)
    #expect(f.model.selectedIdentity == nil)

    await f.model.generate()

    let stored = try await f.identities.identities()
    #expect(stored.count == 1)
    #expect(f.model.selectedID == stored.first?.id)
    #expect(f.model.phase == .choosing)
  }

  @Test("an install that works and a login that works offers Use This Key")
  func installThenLogin() async throws {
    let f = try await fixture()
    await f.model.generate()
    let identity = try #require(f.model.selectedIdentity)

    await f.model.install()

    #expect(f.model.phase == .loginWorked(.installed))
    #expect(await f.keys.lines == [AuthorizedKeyInstallCommands.authorizedKeysLine(for: identity)])
    #expect(f.model.isSettled)
  }

  @Test("a key already on the host is reported as such, and nothing is appended")
  func alreadyInstalled() async throws {
    let f = try await fixture()
    await f.model.generate()
    await f.model.install()
    await f.model.install()
    #expect(f.model.phase == .loginWorked(.alreadyInstalled))
    #expect(await f.keys.installCount == 1)
  }

  @Test("a login that fails after the install says so, and does not offer the switch")
  func loginRefused() async throws {
    let f = try await fixture(loginError: .authenticationFailed(host: "10.1.0.9"))
    await f.model.generate()
    await f.model.install()

    guard case .loginFailed(.installed, let message) = f.model.phase else {
      Issue.record("Expected a failed login, got \(f.model.phase)")
      return
    }
    #expect(message.contains("The host refused the key"))
    await f.model.useKey()
    #expect(try await f.hostStore.hosts().first?.authMethod == .password, "Use This Key is not offered")
  }

  @Test("an install the host refuses is a failure with the host's reason, and Try Again repeats it")
  func installFails() async throws {
    let f = try await fixture(keys: FakeAuthorizedKeysHost(failure: (74, "sh: Read-only file system")))
    await f.model.generate()
    await f.model.install()
    #expect(f.model.phase == .failed(KeyInstallError.host(.readOnlyFileSystem).message))
    #expect(f.model.isChoosing)
  }

  /// `ConnectionCoordinator.run(_:standardInput:)` throws this when the host stops
  /// answering. The sheet disables Cancel and the swipe while the model is busy, so the
  /// phase has to leave `.installing`, or the person cannot leave the sheet.
  @Test("an install the host stopped answering ends as a failure the person can leave")
  func aStalledInstallLeavesInstalling() async throws {
    let stalled = AppError.channelFailed(reason: "The host stopped answering before the command finished.")
    let f = try await fixture(run: { _ in throw stalled })
    await f.model.generate()

    await f.model.install()

    #expect(f.model.phase == .failed("The host stopped answering before the command finished."))
    #expect(!f.model.isBusy)
    #expect(f.model.isChoosing)
  }

  @Test("with no link up the sheet says to connect, and nothing is sent")
  func notConnected() async throws {
    let f = try await fixture(connected: false)
    await f.model.generate()
    await f.model.install()
    #expect(f.model.phase == .notConnected)
    #expect(await f.keys.lines == nil)
  }

  @Test("Use This Key saves the host with the key and deletes its saved password")
  func useKeySwitchesAndDeletesThePassword() async throws {
    let f = try await fixture()
    await f.model.generate()
    let identity = try #require(f.model.selectedIdentity)
    await f.model.install()

    await f.model.useKey()

    #expect(f.model.phase == .switched(passwordDeleted: true, warning: nil))
    #expect(try await f.hostStore.hosts().first?.authMethod == .identity(identity.id))
    #expect(try await f.passwords.password(for: workbox.id) == nil)
  }

  @Test("a switch that failed can be retried with Use This Key")
  func switchFailedRetries() async throws {
    let f = try await fixture()
    await f.model.generate()
    let identity = try #require(f.model.selectedIdentity)
    await f.model.install()
    try await f.hostStore.delete(workbox.id)

    await f.model.useKey()
    guard case .switchFailed = f.model.phase else {
      Issue.record("Expected a failed switch, got \(f.model.phase)")
      return
    }
    #expect(f.model.offersUseKey)

    try await f.hostStore.save(workbox)
    await f.model.useKey()
    #expect(f.model.phase == .switched(passwordDeleted: true, warning: nil))
    #expect(try await f.hostStore.hosts().first?.authMethod == .identity(identity.id))
  }

  @Test("a host that cannot be saved is not switched, and its password stays")
  func saveFailsKeepsThePassword() async throws {
    let passwords = InMemoryPasswordStore(seeded: [workbox.id: "hunter2"])
    let f = try await fixture(hostStore: RefusingHostStore(hosts: [workbox]), passwords: passwords)
    await f.model.generate()
    await f.model.install()

    await f.model.useKey()

    guard case .switchFailed = f.model.phase else {
      Issue.record("Expected a failed switch, got \(f.model.phase)")
      return
    }
    #expect(try await f.hostStore.hosts().first?.authMethod == .password)
    #expect(try await passwords.password(for: workbox.id) == "hunter2", "the password went before the host switched")
  }

  @Test("a password that cannot be deleted leaves the host switched, with a warning")
  func forgetFailsWarns() async throws {
    let f = try await fixture(passwords: UndeletablePasswordStore(hostID: workbox.id))
    await f.model.generate()
    let identity = try #require(f.model.selectedIdentity)
    await f.model.install()

    await f.model.useKey()

    guard case .switched(let deleted, let warning?) = f.model.phase else {
      Issue.record("Expected a switch with a warning, got \(f.model.phase)")
      return
    }
    #expect(!deleted)
    #expect(warning.contains("still on this device"))
    #expect(try await f.hostStore.hosts().first?.authMethod == .identity(identity.id))
  }

  @Test("a link that was up during Use This Key reconnects with the key, without asking for a password")
  func reconnectUsesTheSwitchedKey() async throws {
    let generated = SSHKeyGenerator.generateEd25519(name: "Driverr key")
    let identities = InMemoryIdentityStore()
    try await identities.add(generated.identity, privateKey: generated.privateKey)
    var switched = workbox
    switched.authMethod = .identity(generated.identity.id)
    var environment = AppEnvironment.ephemeral
    environment.identityStore = identities
    environment.hostStore = InMemoryHostStore(seeded: [switched])
    environment.passwordStore = InMemoryPasswordStore()
    environment.knownHostsStore = InMemoryKnownHostsStore(seeded: [workbox.hostname: FakeSSHTransport.defaultHostKey])
    // Built with the host as it was before the switch, as the registry's connected model is.
    let model = ConnectionModel(host: workbox, environment: environment)

    #expect(await model.needsPasswordToReconnect() == false)
    await model.reconnect()
    #expect(model.phase == .connected)
    await model.disconnect()
  }
}

private struct Refused: Error {}

/// A host store whose every save is refused.
private actor RefusingHostStore: HostStore {
  private let stored: [DriverrCore.Host]
  init(hosts: [DriverrCore.Host]) { stored = hosts }
  func hosts() async throws -> [DriverrCore.Host] { stored }
  func save(_ host: DriverrCore.Host) async throws { throw Refused() }
  func delete(_ id: UUID) async throws { throw Refused() }
}

/// A Keychain whose password cannot be deleted.
private actor UndeletablePasswordStore: PasswordStore {
  private var passwords: [UUID: String]
  init(hostID: UUID) { passwords = [hostID: "hunter2"] }
  func password(for hostID: UUID) async throws -> String? { passwords[hostID] }
  func save(_ password: String, for hostID: UUID) async throws { passwords[hostID] = password }
  func delete(for hostID: UUID) async throws { throw Refused() }
}
