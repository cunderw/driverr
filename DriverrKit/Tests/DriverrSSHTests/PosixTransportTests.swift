import DriverrCore
import Foundation
import Testing

@testable import DriverrSSH

/// `posixRunner` and `posixOpen` are the joins the app uses for every command it writes.
/// Each must hand the transport the `sh -c` form, not the bare script.
@Suite("SSHTransport scripted forms")
struct PosixTransportTests {
  private struct Trusting: HostKeyValidator {
    func validate(_ key: SSHHostKey, for host: DriverrCore.Host) async -> HostKeyDecision { .trust }
  }

  private func connected() async throws -> FakeSSHTransport {
    let transport = FakeSSHTransport()
    try await transport.connect(
      to: DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson"),
      hostKeyValidator: Trusting())
    try await transport.authenticate(.password("hunter2"))
    return transport
  }

  @Test("the runner sends the script as one sh -c word")
  func runnerWraps() async throws {
    let transport = try await connected()
    let answer = CommandResult(standardOutput: "herdr 0.8.2\n", standardError: "", exitStatus: 0)
    // Only the wrapped command is answered. The bare script gets "command not found".
    await transport.stub(command: "sh -c 'herdr --version'", result: answer)

    let result = try await transport.posixRunner("herdr --version")

    #expect(result == answer)
  }

  @Test("the stream opens the script as one sh -c word, with a quote kept literal")
  func openWraps() async throws {
    let transport = try await connected()

    _ = try await transport.posixOpen(#"herdr pane read 'a\'b'"#)

    #expect(await transport.streamedCommands == [#"sh -c 'herdr pane read '\''a'\\''\''b'\'''"#])
  }
}
