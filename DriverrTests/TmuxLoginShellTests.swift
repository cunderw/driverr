import DriverrCore
import DriverrSSH
import Foundation
import Testing

@testable import Driverr
@testable import DriverrTmux

/// The app joins `TmuxControl` to the SSH transport through `posixRunner`, so every tmux
/// command reaches the host as one `sh -c` word that a fish login shell hands to `sh`
/// unchanged. The mode guard's `if-shell` line carries quotes, `#{…}` and `\;`, which is
/// what a raw line through fish would mangle (#128). See `LoginShell`.
@Suite("tmux through the login shell", .timeLimit(.minutes(1)))
struct TmuxLoginShellTests {
  private struct Trusting: HostKeyValidator {
    func validate(_ key: SSHHostKey, for host: DriverrCore.Host) async -> HostKeyDecision { .trust }
  }

  /// The fake answers only the commands seeded here, and a command it does not know exits
  /// 127, which `TmuxControl` reports as tmux missing. So each call succeeds only if it
  /// arrived wrapped.
  @Test("the guarded send reaches the host as one sh -c word")
  func guardedSendIsWrapped() async throws {
    let binary = "\(shellQuoted("/usr/bin/tmux")) -u"
    let send = try #require(
      TmuxCommands.input(binary: binary, pane: "%3", text: "it's #{x};", submit: true))
    #expect(send.contains("if-shell -F -t '%3' '#{pane_in_mode}' 'copy-mode -q -t %3'"))
    let keys = try #require(TmuxCommands.keys(binary: binary, pane: "%3", keys: [.down, .enter]))
    let ok = CommandResult(standardOutput: "", standardError: "", exitStatus: 0)
    let transport = FakeSSHTransport(responses: [
      LoginShell.posix(TmuxControl.discoveryCommand): CommandResult(
        standardOutput: "/usr/bin/tmux\n", standardError: "", exitStatus: 0),
      LoginShell.posix(send): ok,
      LoginShell.posix(keys): ok,
    ])
    try await transport.connect(
      to: DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "dev"),
      hostKeyValidator: Trusting())
    try await transport.authenticate(.password("hunter2"))

    let control = try #require(
      await TmuxControl.discovering(transport: transport, resizesWindow: { true }),
      "discovery did not arrive wrapped")
    try await control.submitText(paneID: "tmux:%3", text: "it's #{x};")
    try await control.sendKeys(paneID: "tmux:%3", keys: [.down, .enter])
  }
}
