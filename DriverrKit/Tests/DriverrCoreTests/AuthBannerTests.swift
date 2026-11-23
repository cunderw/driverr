import Foundation
import Testing
@testable import DriverrCore

@Suite("AuthBanner")
struct AuthBannerTests {
  @Test("a Tailscale check banner yields its sign-in URL")
  func findsTheSignInURL() {
    let banner =
      "# Tailscale SSH requires an additional check.\n"
      + "# To authenticate, visit: https://login.tailscale.com/a/1a2b3c4d5e6f\n"
    #expect(
      AuthBanner.signInURL(in: banner)?.absoluteString
        == "https://login.tailscale.com/a/1a2b3c4d5e6f")
  }

  /// An ordinary sshd notice holds no link, so it must not pause the handshake deadline.
  @Test("a notice with no link yields nothing")
  func noticeHasNoURL() {
    #expect(AuthBanner.signInURL(in: "Authorized use only. Activity is logged.\n") == nil)
    #expect(AuthBanner.signInURL(in: "") == nil)
  }

  /// `NSDataDetector` reads a bare host as an `http` link, and an `http` page is not a place
  /// to send a person to sign in.
  @Test("only an https link counts")
  func onlyHTTPS() {
    #expect(AuthBanner.signInURL(in: "Contact admin.example.com for access.") == nil)
    #expect(AuthBanner.signInURL(in: "Visit http://login.example.com/a/1") == nil)
    #expect(AuthBanner.signInURL(in: "Mail ops@example.com") == nil)
    #expect(
      AuthBanner.signInURL(in: "See http://example.com or https://login.example.com/a/2")?
        .absoluteString == "https://login.example.com/a/2")
  }

  @Test("display text is trimmed and free of control characters")
  func displayTextIsCleaned() {
    #expect(AuthBanner.displayText("\n  denied by policy \u{1B}[31m\n\n") == "denied by policy [31m")
    #expect(AuthBanner.displayText("line one\nline two") == "line one\nline two")
    #expect(AuthBanner.displayText(" \n\t ") == nil)
  }

  @Test("display text is cut at the limit")
  func displayTextIsBounded() {
    let long = String(repeating: "a", count: AuthBanner.displayLimit + 50)
    let shown = AuthBanner.displayText(long)
    #expect(shown?.count == AuthBanner.displayLimit + 1)
    #expect(shown?.hasSuffix("…") == true)
  }
}
