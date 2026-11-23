import DriverrCore
import DriverrSSH
import Foundation
import Testing

@testable import Driverr

/// A host that takes no credential, and one that holds the connect while the user signs in
/// on the web (#171). Tailscale SSH does both. The protocol side is proven against a real
/// server in `DriverrKit` (`TailscaleSSHTests`); this is what `ConnectionModel` makes of it.
@MainActor
@Suite("Sign-in connect", .timeLimit(.minutes(1)))
struct SignInConnectTests {
  private let tailnet = DriverrCore.Host(
    name: "tailnet", hostname: "100.64.0.1", username: "carson", authMethod: .none)

  private static let checkBanner =
    "# Tailscale SSH requires an additional check.\n"
    + "# To authenticate, visit: https://login.tailscale.com/a/1a2b3c4d5e6f\n"

  private func environment(_ transport: FakeSSHTransport) -> AppEnvironment {
    var environment = AppEnvironment.ephemeral
    environment.knownHostsStore = InMemoryKnownHostsStore(
      seeded: [tailnet.hostname: FakeSSHTransport.defaultHostKey]
    )
    environment.makeTransport = { transport }
    return environment
  }

  @Test("a host with no credential connects without a password and offers none")
  func noCredentialConnects() async {
    let transport = FakeSSHTransport()
    let model = ConnectionModel(host: tailnet, environment: environment(transport))

    await model.connect(password: nil, persistence: .promptEveryTime)

    #expect(model.phase == .connected)
    #expect(await model.needsPasswordToReconnect() == false)
    let attempts = await transport.authenticationAttempts.map(\.debugDescription)
    #expect(attempts == ["SSHAuthMethod.none"])
  }

  /// The URL is the only thing that tells the user why the connect is waiting, and Cancel
  /// must still end it.
  @Test("a sign-in URL shows while the host holds the connect, and Cancel clears it")
  func signInURLShowsUntilCancel() async {
    let transport = FakeSSHTransport(
      authenticationBanner: Self.checkBanner,
      authenticationHold: .seconds(600)
    )
    let model = ConnectionModel(host: tailnet, environment: environment(transport))

    let attempt = Task { await model.connect(password: nil, persistence: .promptEveryTime) }
    await waitUntil("the sign-in URL is shown") { model.signInURL != nil }

    #expect(model.signInURL?.absoluteString == "https://login.tailscale.com/a/1a2b3c4d5e6f")
    #expect(model.phase == .connecting)

    await model.cancelConnect()
    await attempt.value
    #expect(model.signInURL == nil)
    #expect(model.phase == .idle)
  }

  /// Disconnect retires the attempt, and a retired attempt never clears its own URL.
  @Test("a disconnect during a held sign-in clears the URL")
  func disconnectClearsTheURL() async {
    let transport = FakeSSHTransport(
      authenticationBanner: Self.checkBanner,
      authenticationHold: .seconds(600)
    )
    let model = ConnectionModel(host: tailnet, environment: environment(transport))

    let attempt = Task { await model.connect(password: nil, persistence: .promptEveryTime) }
    await waitUntil("the sign-in URL is shown") { model.signInURL != nil }

    await model.disconnect()
    await attempt.value
    #expect(model.signInURL == nil)
    #expect(model.phase == .idle)
  }

  /// Tailscale denies a user with a banner and a close. The banner is the reason.
  @Test("a close after a banner fails with the banner's text and shows no URL")
  func denialBannerIsTheFailure() async {
    let transport = FakeSSHTransport(
      acceptsCredentials: false,
      authenticationBanner: "\nTailscale SSH: tailnet policy does not permit you here.\n",
      refusalClosesTheConnection: true
    )
    let model = ConnectionModel(host: tailnet, environment: environment(transport))

    await model.connect(password: nil, persistence: .promptEveryTime)

    #expect(
      model.phase
        == .failed(
          .authenticationRefused(
            host: "100.64.0.1",
            message: "Tailscale SSH: tailnet policy does not permit you here.")))
    #expect(model.signInURL == nil)
  }
}

extension SignInConnectTests {
  /// The fake's ordinary refusal matches `NIOSSHTransport`'s: a banner before a real failure
  /// message is not quoted.
  @Test("an ordinary refusal after a notice banner keeps the ordinary error")
  func ordinaryRefusalIgnoresTheBanner() async {
    let transport = FakeSSHTransport(
      acceptsCredentials: false,
      authenticationBanner: "Authorized use only.\n"
    )
    let model = ConnectionModel(host: tailnet, environment: environment(transport))

    await model.connect(password: nil, persistence: .promptEveryTime)

    #expect(model.phase == .failed(.authenticationFailed(host: "100.64.0.1")))
  }
}
