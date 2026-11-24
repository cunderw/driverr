import SwiftUI

/// The page a host asked the user to sign in on, while it holds the connection. Tailscale
/// SSH's check mode does this. The connect finishes by itself once the sign-in is done.
///
/// The host gets a line of its own, cut from the front, so the end of the name, which
/// holds the registrable domain, always shows. A long name such as
/// `login.tailscale.com.aaaa….evil.example` cannot then pass for a trusted one. The server
/// writes the URL.
///
/// Shown by the host screen's connect and by a pane scene's reconnect. Each passes its own
/// identifiers, because XCUITest sees through a push: shared ones would let a test of one
/// screen pass on the row the other screen drew. Identifiers on the host, the URL and the
/// button, never the stack.
struct SignInRow: View {
  struct Identifiers {
    let host: String
    let url: String
    let open: String

    /// The host screen's connect.
    static let connect = Identifiers(
      host: "connect.signInHost", url: "connect.signInURL", open: "connect.signInOpen")
    /// A pane scene's reconnect.
    static let terminal = Identifiers(
      host: "terminal.signIn.host", url: "terminal.signIn.url", open: "terminal.signIn.open")
  }

  let url: URL
  let identifiers: Identifiers

  @Environment(\.openURL) private var openURL

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Sign in to continue")
        if let host = url.host() {
          Text(host)
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.head)
            .accessibilityIdentifier(identifiers.host)
        }
        Text(url.absoluteString)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .truncationMode(.middle)
          .accessibilityIdentifier(identifiers.url)
      }
      Spacer(minLength: 0)
      // The label, not the tint: accent text on the tinted fill measured 2.61:1 in light.
      Button {
        openURL(url)
      } label: {
        BorderedButtonLabel("Open")
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier(identifiers.open)
    }
  }
}
