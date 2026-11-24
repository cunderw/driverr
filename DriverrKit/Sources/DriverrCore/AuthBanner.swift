import Foundation

/// Reads an SSH user-auth banner (SSH_MSG_USERAUTH_BANNER), the free text a server may send
/// during authentication.
///
/// Tailscale SSH in check mode sends a banner that holds a sign-in URL, then holds the
/// request until the user signs in on the web. An ordinary sshd sends a notice, such as
/// `/etc/issue.net`, that holds no URL. The server writes the text, so Driverr reads only
/// "it holds a link" from it and never relies on the wording.
public enum AuthBanner {
  /// The most characters of a banner Driverr shows. The server writes the text, and an
  /// error message must stay readable.
  public static let displayLimit = 300

  /// The first `https` link in `text`, or `nil` when there is none.
  ///
  /// Only a link written out with `https://`: the user opens this link to sign in, so a
  /// plain `http` page or another scheme is not offered. The check reads the banner's own
  /// text, not the detected URL's scheme, because `NSDataDetector` gives a bare host name a
  /// scheme the server never wrote (measured: `https`).
  public static func signInURL(in text: String) -> URL? {
    guard
      let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    for match in detector.matches(in: text, range: range) {
      guard let written = Range(match.range, in: text),
        text[written].lowercased().hasPrefix("https://"),
        let url = match.url, url.scheme?.lowercased() == "https", url.host != nil
      else { continue }
      return url
    }
    return nil
  }

  /// The banner as Driverr shows it: trimmed, with control characters other than line
  /// breaks removed, and cut at `displayLimit`. `nil` when nothing is left.
  public static func displayText(_ text: String) -> String? {
    let printable = String(
      String.UnicodeScalarView(
        text.unicodeScalars.filter { $0 == "\n" || !CharacterSet.controlCharacters.contains($0) }
      )
    )
    let trimmed = printable.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard trimmed.count > displayLimit else { return trimmed }
    return String(trimmed.prefix(displayLimit)) + "…"
  }
}
