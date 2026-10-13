import DriverrCore
import Foundation
import Testing
@testable import DriverrSSH

private let workbox = DriverrCore.Host(
  name: "workbox",
  hostname: "10.1.0.9",
  port: 22,
  username: "carson"
)

private func key(_ seed: String) -> SSHHostKey {
  SSHHostKey(algorithm: "ssh-ed25519", blob: Data(seed.utf8))
}

/// Records whether it was asked: once for a new host, never for a changed one.
private actor RecordingPrompt: HostKeyPrompt {
  private let answer: Bool
  private(set) var askedFor: [String] = []

  init(accepting: Bool) {
    answer = accepting
  }

  func askToTrust(_ key: SSHHostKey, for host: DriverrCore.Host) async -> Bool {
    askedFor.append(host.hostname)
    return answer
  }

  var timesAsked: Int { askedFor.count }
}

@Suite("TOFUHostKeyValidator")
struct TOFUHostKeyValidatorTests {
  @Test("a new host asks the user, and trusting it stores the key")
  func firstContactAsksAndStores() async {
    let store = InMemoryKnownHostsStore()
    let prompt = RecordingPrompt(accepting: true)
    let validator = TOFUHostKeyValidator(store: store, prompt: prompt)

    let decision = await validator.validate(key("alpha"), for: workbox)

    #expect(decision == .trust)
    #expect(await prompt.timesAsked == 1)
    #expect(await store.trustedKey(for: workbox.hostname) == key("alpha"))
  }

  @Test("declining a new host rejects it and stores nothing")
  func decliningStoresNothing() async {
    let store = InMemoryKnownHostsStore()
    let prompt = RecordingPrompt(accepting: false)
    let validator = TOFUHostKeyValidator(store: store, prompt: prompt)

    let decision = await validator.validate(key("alpha"), for: workbox)

    #expect(decision == .reject)
    // Storing a declined key would silently trust it on the next attempt.
    #expect(await store.trustedKey(for: workbox.hostname) == nil)
  }

  @Test("a host whose key matches is trusted without asking again")
  func matchingKeyDoesNotPrompt() async {
    let store = InMemoryKnownHostsStore()
    await store.trust(key("alpha"), for: workbox.hostname)
    let prompt = RecordingPrompt(accepting: false)
    let validator = TOFUHostKeyValidator(store: store, prompt: prompt)

    let decision = await validator.validate(key("alpha"), for: workbox)

    #expect(decision == .trust)
    #expect(await prompt.timesAsked == 0, "A known, unchanged host must not prompt")
  }

  @Test("a changed key is a mismatch, not a rejection")
  func changedKeyIsMismatch() async {
    let store = InMemoryKnownHostsStore()
    await store.trust(key("alpha"), for: workbox.hostname)
    let prompt = RecordingPrompt(accepting: true)
    let validator = TOFUHostKeyValidator(store: store, prompt: prompt)

    let decision = await validator.validate(key("beta"), for: workbox)

    // Distinct from `.reject`, so the transport raises the hard-stop `hostKeyMismatch`.
    #expect(decision == .mismatch)
  }

  @Test("a changed key never asks the user, even one who would say yes")
  func mismatchNeverPrompts() async {
    let store = InMemoryKnownHostsStore()
    await store.trust(key("alpha"), for: workbox.hostname)
    // This prompt accepts everything. Consulting it would let a user click through a
    // man-in-the-middle.
    let prompt = RecordingPrompt(accepting: true)
    let validator = TOFUHostKeyValidator(store: store, prompt: prompt)

    _ = await validator.validate(key("beta"), for: workbox)

    #expect(await prompt.timesAsked == 0, "A mismatch must never be a question")
  }

  @Test("a mismatch leaves the originally trusted key in place")
  func mismatchDoesNotOverwrite() async {
    let store = InMemoryKnownHostsStore()
    await store.trust(key("alpha"), for: workbox.hostname)
    let validator = TOFUHostKeyValidator(
      store: store,
      prompt: RecordingPrompt(accepting: true)
    )

    _ = await validator.validate(key("beta"), for: workbox)

    // Overwriting would make the attacker's key the trusted one.
    #expect(await store.trustedKey(for: workbox.hostname) == key("alpha"))
  }

  @Test("hosts are tracked separately, so trusting one does not trust another")
  func hostsAreIndependent() async {
    let store = InMemoryKnownHostsStore()
    let prompt = RecordingPrompt(accepting: true)
    let validator = TOFUHostKeyValidator(store: store, prompt: prompt)
    let other = DriverrCore.Host(name: "other", hostname: "10.1.0.10", username: "carson")

    _ = await validator.validate(key("alpha"), for: workbox)
    _ = await validator.validate(key("beta"), for: other)

    #expect(await store.trustedKey(for: workbox.hostname) == key("alpha"))
    #expect(await store.trustedKey(for: other.hostname) == key("beta"))
    #expect(await prompt.timesAsked == 2)
  }

  @Test("forgetting a host makes the next connection ask again")
  func forgettingReprompts() async {
    let store = InMemoryKnownHostsStore()
    await store.trust(key("alpha"), for: workbox.hostname)
    await store.forget(workbox.hostname)
    let prompt = RecordingPrompt(accepting: true)
    let validator = TOFUHostKeyValidator(store: store, prompt: prompt)

    // The sanctioned way back after a legitimate rebuild.
    let decision = await validator.validate(key("beta"), for: workbox)

    #expect(decision == .trust)
    #expect(await prompt.timesAsked == 1)
  }

  /// Its next connection must neither ask nor refuse.
  @Test("deleting a host that shares its hostname leaves the other host trusted")
  func sharedDeleteKeepsTheOtherTrusted() async {
    let asRoot = DriverrCore.Host(
      name: "workbox (root)", hostname: workbox.hostname, port: 2222, username: "root")
    let store = InMemoryKnownHostsStore()
    await store.trust(key("alpha"), for: workbox.hostname)

    await store.forget(workbox, unlessUsedBy: [asRoot])

    let prompt = RecordingPrompt(accepting: false)
    let validator = TOFUHostKeyValidator(store: store, prompt: prompt)
    let decision = await validator.validate(key("alpha"), for: asRoot)

    #expect(decision == .trust)
    #expect(await prompt.timesAsked == 0, "the other host was asked about a key it had")
  }
}

@Suite("TOFU against a real server")
struct TOFUIntegrationTests {
  @Test("a mismatched host key refuses the connection with hostKeyMismatch")
  func mismatchRefusesRealConnection() async throws {
    let server = try await EmbeddedSSHServer(username: "carson", password: "hunter2")
    defer { Task { await server.stop() } }
    let host = DriverrCore.Host(
      name: "embedded",
      hostname: "127.0.0.1",
      port: server.port,
      username: "carson"
    )

    // Trust some other key first, so the server's real key looks like a change.
    let store = InMemoryKnownHostsStore()
    await store.trust(key("not-the-servers-key"), for: host.hostname)
    let validator = TOFUHostKeyValidator(
      store: store,
      prompt: RecordingPrompt(accepting: true)
    )

    let transport = NIOSSHTransport()
    await #expect(throws: AppError.hostKeyMismatch(host: "127.0.0.1")) {
      try await transport.connect(to: host, hostKeyValidator: validator)
    }
  }

  @Test("a first connection that is trusted stores the server's real key")
  func firstContactStoresRealKey() async throws {
    let server = try await EmbeddedSSHServer(username: "carson", password: "hunter2")
    defer { Task { await server.stop() } }
    let host = DriverrCore.Host(
      name: "embedded",
      hostname: "127.0.0.1",
      port: server.port,
      username: "carson"
    )

    let store = InMemoryKnownHostsStore()
    let validator = TOFUHostKeyValidator(
      store: store,
      prompt: RecordingPrompt(accepting: true)
    )

    let transport = NIOSSHTransport()
    try await transport.connect(to: host, hostKeyValidator: validator)

    let stored = await store.trustedKey(for: host.hostname)
    #expect(stored?.algorithm == "ssh-ed25519")
    // Reconnecting with the stored key must be a silent match.
    #expect(await validator.validate(stored!, for: host) == .trust)
    await transport.disconnect()
  }
}
