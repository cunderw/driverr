import Testing

@testable import Driverr

/// `groupedFingerprint` and the `ssh-keygen -lf` hint the trust prompt derives from a
/// key's algorithm — the pure pieces behind `HostKeyPromptView`, testable without a
/// screen. See `HostConnectUITests` for proof the screen itself renders the grouped form.
@Suite("Trust prompt fingerprint formatting")
struct HostKeyPromptTests {
  /// A fingerprint SwiftUI hyphenated as `SHA256:hLL4CH+U7JJVluVbfl7jqkak7JsStOl-` /
  /// `DtcupBsqmB5I`, a `-` that is not in the key. Space-joined 4-character blocks give the
  /// layout engine a legal break every four characters.
  private static let previouslyWrappingFingerprint =
    "SHA256:hLL4CH+U7JJVluVbfl7jqkak7JsStOlDtcupBsqmB5I"

  @Test("the grouped fingerprint contains no hyphen the fingerprint did not have")
  func neverHyphenates() {
    let grouped = groupedFingerprint(Self.previouslyWrappingFingerprint)
    #expect(!grouped.contains("-"))
  }

  @Test("grouping is reversible — removing the spaces gives back the original fingerprint")
  func roundTrips() {
    let grouped = groupedFingerprint(Self.previouslyWrappingFingerprint)
    let ungrouped = grouped.replacingOccurrences(of: " ", with: "")
    #expect(ungrouped == Self.previouslyWrappingFingerprint)
  }

  @Test("the SHA256: prefix is left alone, only the base64 half is grouped")
  func prefixUntouched() {
    let grouped = groupedFingerprint(Self.previouslyWrappingFingerprint)
    #expect(grouped.hasPrefix("SHA256:hLL4 "))
  }

  @Test("every block is at most 4 characters, so no run is ever long enough to hyphenate")
  func blocksAreShort() {
    let grouped = groupedFingerprint(Self.previouslyWrappingFingerprint)
    let base64Part = grouped.dropFirst("SHA256:".count)
    for block in base64Part.split(separator: " ") {
      #expect(block.count <= 4)
    }
  }

  @Test("a string with no colon is returned unchanged rather than crashing")
  func noColonIsPassedThrough() {
    #expect(groupedFingerprint("not-a-fingerprint") == "not-a-fingerprint")
  }

  @Test("the ssh-keygen hint names the ed25519 host key file")
  func hintNamesEd25519() {
    #expect(
      HostKeyPromptView.hostKeyFile(for: "ssh-ed25519") == "/etc/ssh/ssh_host_ed25519_key.pub"
    )
  }

  @Test("the ssh-keygen hint names the rsa host key file for any rsa signature scheme")
  func hintNamesRSAForEverySignatureScheme() {
    for algorithm in ["ssh-rsa", "rsa-sha2-256", "rsa-sha2-512"] {
      #expect(HostKeyPromptView.hostKeyFile(for: algorithm) == "/etc/ssh/ssh_host_rsa_key.pub")
    }
  }

  @Test("the ssh-keygen hint names the ecdsa host key file for every curve")
  func hintNamesECDSA() {
    #expect(
      HostKeyPromptView.hostKeyFile(for: "ecdsa-sha2-nistp256")
        == "/etc/ssh/ssh_host_ecdsa_key.pub"
    )
  }
}
