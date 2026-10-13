import DriverrCore
import Foundation

/// Asks the user whether to trust a host key they have not seen before.
///
/// Consulted only on first contact. A changed key is never a question. See
/// `TOFUHostKeyValidator`.
public protocol HostKeyPrompt: Sendable {
  /// Returns true if the user accepted the key.
  func askToTrust(_ key: SSHHostKey, for host: DriverrCore.Host) async -> Bool
}

/// Trust on first use, with a hard stop on change.
///
/// - Unknown host: show the fingerprint, ask, and store the key only if accepted.
/// - Known host, same key: trust silently. A prompt every time trains users to tap
///   Trust without reading.
/// - Known host, different key: refuse without asking. There is no override, because a
///   changed key is what an interception looks like.
///
/// For a rebuilt server the user forgets the key (`KnownHostsStore.forget`). The mismatch
/// error's Problem section has a "Forget Host Key…" button, a confirmation alert shows the
/// old fingerprint, and the next connection is first contact again.
public struct TOFUHostKeyValidator: HostKeyValidator {
  private let store: any KnownHostsStore
  private let prompt: any HostKeyPrompt

  public init(store: any KnownHostsStore, prompt: any HostKeyPrompt) {
    self.store = store
    self.prompt = prompt
  }

  public func validate(_ key: SSHHostKey, for host: DriverrCore.Host) async -> HostKeyDecision {
    guard let trusted = await store.trustedKey(for: host.hostname) else {
      guard await prompt.askToTrust(key, for: host) else { return .reject }
      await store.trust(key, for: host.hostname)
      return .trust
    }

    guard trusted == key else {
      // Never overwrite, so an attacker's key cannot become the remembered one.
      return .mismatch
    }
    return .trust
  }
}
