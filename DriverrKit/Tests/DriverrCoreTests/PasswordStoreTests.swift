import Foundation
import Testing
@testable import DriverrCore

private let hostID = UUID()

@Suite("PasswordCredentials")
struct PasswordCredentialsTests {
  @Test("choosing to be prompted every time stores nothing")
  func promptEveryTimeDoesNotPersist() async throws {
    let store = InMemoryPasswordStore()
    let credentials = PasswordCredentials(store: store)

    try await credentials.remember("hunter2", for: hostID, persistence: .promptEveryTime)

    #expect(try await credentials.saved(for: hostID) == nil)
  }

  @Test("choosing to remember stores the password")
  func rememberPersists() async throws {
    let store = InMemoryPasswordStore()
    let credentials = PasswordCredentials(store: store)

    try await credentials.remember("hunter2", for: hostID, persistence: .remember)

    #expect(try await credentials.saved(for: hostID) == "hunter2")
  }

  @Test("switching a remembered host back to prompting clears what was stored")
  func downgradingClearsStoredPassword() async throws {
    let store = InMemoryPasswordStore()
    let credentials = PasswordCredentials(store: store)
    try await credentials.remember("hunter2", for: hostID, persistence: .remember)

    // Turning "remember" off must delete the stored password, not leave it on disk.
    try await credentials.remember("hunter2", for: hostID, persistence: .promptEveryTime)

    #expect(try await credentials.saved(for: hostID) == nil)
  }

  @Test("forgetting removes a stored password")
  func forgetRemoves() async throws {
    let store = InMemoryPasswordStore()
    let credentials = PasswordCredentials(store: store)
    try await credentials.remember("hunter2", for: hostID, persistence: .remember)

    try await credentials.forget(for: hostID)

    #expect(try await credentials.saved(for: hostID) == nil)
  }

  @Test("passwords are kept per host, not shared between them")
  func passwordsArePerHost() async throws {
    let store = InMemoryPasswordStore()
    let credentials = PasswordCredentials(store: store)
    let other = UUID()

    try await credentials.remember("first", for: hostID, persistence: .remember)
    try await credentials.remember("second", for: other, persistence: .remember)

    #expect(try await credentials.saved(for: hostID) == "first")
    #expect(try await credentials.saved(for: other) == "second")
  }

  @Test("the default persistence is to prompt, not to remember")
  func defaultIsPrompt() {
    // A default of .remember would persist a password the user never agreed to keep.
    #expect(PasswordPersistence.default == .promptEveryTime)
  }
}

@Suite("Auth failure error mapping")
struct AuthFailureMappingTests {
  @Test("a wrong password is a different error from an unreachable host")
  func authFailureIsDistinctFromConnectionFailure() {
    let auth = AppError.authenticationFailed(host: "workbox")
    let unreachable = AppError.connectionFailed(host: "workbox", reason: "refused")
    #expect(auth != unreachable)
    #expect(auth.errorDescription != unreachable.errorDescription)
  }

  @Test("a wrong password is a different error from a channel failure")
  func authFailureIsDistinctFromChannelFailure() {
    let auth = AppError.authenticationFailed(host: "workbox")
    let channel = AppError.channelFailed(reason: "herdr not installed")
    #expect(auth != channel)
    #expect(auth.errorDescription != channel.errorDescription)
  }

  @Test("a wrong password is a different error from a host key mismatch")
  func authFailureIsDistinctFromHostKeyMismatch() {
    #expect(AppError.authenticationFailed(host: "h") != AppError.hostKeyMismatch(host: "h"))
  }

  @Test("an auth failure is not offered as retryable, so it cannot loop on a bad password")
  func authFailureIsNotRetryable() {
    #expect(!AppError.authenticationFailed(host: "workbox").isRetryable)
  }

  @Test("the auth failure message tells the user which credential to check")
  func authFailureMessageIsActionable() {
    let message = AppError.authenticationFailed(host: "workbox").errorDescription ?? ""
    #expect(message.contains("workbox"))
    #expect(message.lowercased().contains("credential") || message.lowercased().contains("password"))
  }
}

@Suite("InMemoryPasswordStore seeding")
struct InMemoryPasswordStoreSeedingTests {
  /// `-uiTestingConnected` needs a password in the store when `AppEnvironment.ephemeral` is
  /// built, and that property is synchronous, so it cannot `await save`.
  @Test("a seeded store answers without anyone having saved")
  func seededStoreAnswers() async throws {
    let store = InMemoryPasswordStore(seeded: [hostID: "hunter2"])

    #expect(try await store.password(for: hostID) == "hunter2")
  }

  @Test("seeding leaves other hosts alone")
  func seedingIsPerHost() async throws {
    let store = InMemoryPasswordStore(seeded: [hostID: "hunter2"])

    #expect(try await store.password(for: UUID()) == nil)
  }

  @Test("a seeded password can still be deleted")
  func seededPasswordDeletes() async throws {
    let store = InMemoryPasswordStore(seeded: [hostID: "hunter2"])

    try await store.delete(for: hostID)

    #expect(try await store.password(for: hostID) == nil)
  }

  @Test("a store seeded with nothing holds no password")
  func emptySeedIsEmpty() async throws {
    let store = InMemoryPasswordStore()

    #expect(try await store.password(for: hostID) == nil)
  }
}
