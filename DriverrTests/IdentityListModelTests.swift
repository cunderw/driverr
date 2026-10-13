import DriverrCore
import Foundation
import Testing

@testable import Driverr

/// `IdentityListModel`'s own logic, the delete confirmation's host lookup and the generated-key
/// naming, with in-memory stores. The view is `KeyManagementUITests`.
@MainActor
@Suite("IdentityListModel")
struct IdentityListModelTests {
  private func makeIdentity(name: String = "a key") -> SSHIdentity {
    SSHIdentity(name: name, publicKeyBlob: Data("blob".utf8))
  }

  @Test("a key used by no host reports an empty list")
  func noHostsUseIt() async {
    let identity = makeIdentity()
    let identityStore = InMemoryIdentityStore()
    try? await identityStore.add(identity, privateKey: SSHPrivateKey(rawRepresentation: Data(repeating: 0, count: 32)))
    let hostStore = InMemoryHostStore(seeded: [
      DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson")
    ])
    let model = IdentityListModel(store: identityStore, hostStore: hostStore)

    let names = await model.hostNames(usingKey: identity)

    #expect(names.isEmpty)
  }

  @Test("hosts pointed at this key are named, in the order the store returns them")
  func namesHostsUsingIt() async {
    let identity = makeIdentity()
    let identityStore = InMemoryIdentityStore()
    let hostStore = InMemoryHostStore(seeded: [
      DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson", authMethod: .identity(identity.id)),
      DriverrCore.Host(name: "edge-01", hostname: "10.1.0.99", username: "root", authMethod: .password),
      DriverrCore.Host(name: "gpu-box", hostname: "10.1.0.5", username: "carson", authMethod: .identity(identity.id)),
    ])
    let model = IdentityListModel(store: identityStore, hostStore: hostStore)

    let names = await model.hostNames(usingKey: identity)

    #expect(names == ["workbox", "gpu-box"])
  }

  @Test("a host pointed at a different key is not named")
  func doesNotNameHostsUsingAnotherKey() async {
    let identity = makeIdentity()
    let otherIdentity = makeIdentity(name: "a different key")
    let identityStore = InMemoryIdentityStore()
    let hostStore = InMemoryHostStore(seeded: [
      DriverrCore.Host(
        name: "workbox",
        hostname: "10.1.0.9",
        username: "carson",
        authMethod: .identity(otherIdentity.id)
      )
    ])
    let model = IdentityListModel(store: identityStore, hostStore: hostStore)

    let names = await model.hostNames(usingKey: identity)

    #expect(names.isEmpty)
  }

  @Test("an unnamed host is reported by its user@host fallback")
  func unnamedHostFallsBackToUserAtHost() async {
    let identity = makeIdentity()
    let identityStore = InMemoryIdentityStore()
    let hostStore = InMemoryHostStore(seeded: [
      DriverrCore.Host(name: "", hostname: "10.1.0.9", username: "carson", authMethod: .identity(identity.id))
    ])
    let model = IdentityListModel(store: identityStore, hostStore: hostStore)

    let names = await model.hostNames(usingKey: identity)

    #expect(names == ["carson@10.1.0.9"])
  }

  /// The view shows `errorMessage` once the import sheet has dismissed; this proves it is set.
  @Test("a PEM that cannot be parsed sets an error and adds no key")
  func badPEMSetsAnError() async {
    let identityStore = InMemoryIdentityStore()
    let model = IdentityListModel(store: identityStore, hostStore: InMemoryHostStore(seeded: []))
    await model.load()

    await model.importKey(pem: "definitely not an OpenSSH private key")

    #expect(model.errorMessage != nil)
    #expect(model.identities.isEmpty)

    model.dismissError()
    #expect(model.errorMessage == nil)
  }

  @Test("the default key name reads 'Driverr key · d MMM y', fixed regardless of language")
  func defaultKeyNameFormat() {
    // Noon local time. `defaultKeyName` pins the locale but not the time zone, so a key's date
    // matches the generator's calendar. Noon keeps this test off the edges of a day.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 12))!

    #expect(IdentityListModel.defaultKeyName(date: date) == "Driverr key · 27 Aug 2026")
  }
}
