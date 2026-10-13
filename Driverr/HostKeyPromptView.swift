import DriverrCore
import DriverrSSH
import SwiftUI

/// The first-contact trust prompt.
///
/// Shows the fingerprint in the `SHA256:…` form `ssh-keygen -lf` prints. Only an unknown
/// host reaches it: `TOFUHostKeyValidator` refuses a changed key outright, so no screen
/// offers to accept one.
struct HostKeyPromptView: View {
  let hostname: String
  let key: SSHHostKey
  /// Whether this sheet has room to be a form sheet. See `AddHostView.isRegularWidth`.
  var isRegularWidth = false
  let onDecision: (Bool) -> Void

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        // First, so the fingerprint is above the fold at every text size.
        Section {
          Text(groupedFingerprint(key.fingerprint))
            // `.body`, because this is the text compared character by character.
            .font(.body.monospaced())
            .textSelection(.enabled)
            // Spelled out, so VoiceOver can be used to check it by ear.
            .speechSpellsOutCharacters()
            .accessibilityIdentifier("hostkey.fingerprint")
        } header: {
          Text("Fingerprint")
        } footer: {
          // A footer, directly under the fingerprint, set the same way as the `ssh-keygen`
          // note below. Footer text is smaller, but the fingerprint itself stays `.body`.
          Text(
            """
            Driverr has no trusted key for \(hostname). Check that this fingerprint matches \
            the one on the server.
            """
          )
        }

        Section {
          Text(key.algorithm)
            .font(.footnote.monospaced())
        } header: {
          Text("Algorithm")
        } footer: {
          // Monospace, not backticks: `Text` renders Markdown only for a literal string, and
          // this one interpolates, so backticks would show as characters.
          VStack(alignment: .leading, spacing: 4) {
            Text("On the server, run this to see the same fingerprint:")
            Text("ssh-keygen -lf \(Self.hostKeyFile(for: key.algorithm))")
              .font(.footnote.monospaced())
              .textSelection(.enabled)
          }
        }
      }
      // Fits the sheet to the list on iPad. See `FittedSheetHeight`.
      .fittedSheetHeight(isEnabled: isRegularWidth)
      .navigationTitle("Unknown Host")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            onDecision(false)
            dismiss()
          }
          .tint(Color.primary)
          .accessibilityIdentifier("hostkey.cancel")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Trust") {
            onDecision(true)
            dismiss()
          }
          // Toolbar text takes `Color.primary`. See CLAUDE.md, "Style".
          .tint(Color.primary)
          .accessibilityIdentifier("hostkey.trust")
        }
      }
      .interactiveDismissDisabled()
    }
  }

  /// The host key file `ssh-keygen -lf` would read, guessed from the key's algorithm.
  ///
  /// OpenSSH's default files follow this naming, but a server can keep keys anywhere.
  /// `nonisolated` so `HostKeyPromptTests` can call it from a non-`@MainActor` suite.
  nonisolated static func hostKeyFile(for algorithm: String) -> String {
    let kind: String
    switch algorithm {
    case "ssh-ed25519": kind = "ed25519"
    case "ssh-rsa", "rsa-sha2-256", "rsa-sha2-512": kind = "rsa"
    case "ssh-dss": kind = "dsa"
    default:
      kind = algorithm.hasPrefix("ecdsa-sha2-") ? "ecdsa" : algorithm
    }
    return "/etc/ssh/ssh_host_\(kind)_key.pub"
  }
}

/// Groups a `SHA256:…` fingerprint's base64 half into 4-character blocks joined by
/// spaces, leaving the `SHA256:` prefix untouched.
///
/// SwiftUI hyphenates a word it must break, and a 43-character base64 run then shows a hyphen
/// that is not in the fingerprint. Spaces give it a legal break. `KeyManagementView` uses
/// it too.
func groupedFingerprint(_ fingerprint: String) -> String {
  guard let colonIndex = fingerprint.firstIndex(of: ":") else { return fingerprint }
  let prefix = fingerprint[...colonIndex]
  let base64 = fingerprint[fingerprint.index(after: colonIndex)...]
  // `String.Index` is not `Strideable`, so the blocks are walked by hand.
  var blocks: [Substring] = []
  var start = base64.startIndex
  while start < base64.endIndex {
    let end = base64.index(start, offsetBy: 4, limitedBy: base64.endIndex) ?? base64.endIndex
    blocks.append(base64[start..<end])
    start = end
  }
  return "\(prefix)\(blocks.joined(separator: " "))"
}

/// Bridges the validator's `async` question to a SwiftUI sheet.
///
/// `TOFUHostKeyValidator` waits on a background task. The continuation lets a tap resume
/// the handshake without the transport knowing about UI.
@MainActor
@Observable
final class InteractiveHostKeyPrompt: HostKeyPrompt {
  struct Request: Identifiable {
    let id = UUID()
    let hostname: String
    let key: SSHHostKey
  }

  private(set) var pending: Request?
  private var continuation: CheckedContinuation<Bool, Never>?

  nonisolated init() {}

  func askToTrust(_ key: SSHHostKey, for host: DriverrCore.Host) async -> Bool {
    await withCheckedContinuation { continuation in
      Task { @MainActor in
        self.continuation = continuation
        self.pending = Request(hostname: host.hostname, key: key)
      }
    }
  }

  func answer(_ trusted: Bool) {
    pending = nil
    continuation?.resume(returning: trusted)
    continuation = nil
  }
}
