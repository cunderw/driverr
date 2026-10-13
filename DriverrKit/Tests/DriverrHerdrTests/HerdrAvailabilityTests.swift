import DriverrCore
import Foundation
import Testing

@testable import DriverrHerdr

private func host(
  _ answer: @escaping @Sendable (String) throws -> CommandResult
) -> CommandRunner {
  { command in try answer(command) }
}

private func output(_ text: String, exitStatus: Int = 0, stderr: String = "") -> CommandResult {
  CommandResult(standardOutput: text, standardError: stderr, exitStatus: exitStatus)
}

/// A healthy `herdr status server` from herdr 0.7.5, socket path removed. `protocol` and
/// `compatible` are the names herdr printed through 0.9.0, and Driverr still accepts them.
private let runningStatus = """
  status: running
  version: 0.7.5
  protocol: 17
  compatible: yes
  """

/// herdr 0.9.1's output, socket path replaced. herdr renamed `protocol` to
/// `private_protocol` and `compatible` to `private_protocol_compatible`, and added
/// `endpoint_compatible`. Reading only `protocol` reported every 0.9.1 host as having no
/// session.
private let running091Status = """
  status: running
  version: 0.9.1
  endpoint_compatible: yes
  private_protocol: 22
  private_protocol_compatible: yes
  socket: /Users/example/.config/herdr/herdr.sock
  """

@Suite("herdr availability")
struct HerdrAvailabilityTests {
  @Test("a running, compatible herdr is ready")
  func ready() async {
    let control = CLIControl(run: host { _ in output(runningStatus) })
    #expect(await control.availability() == .ready(version: "0.7.5", protocolVersion: 17))
  }

  @Test("herdr 0.9.1's renamed protocol field is still read")
  func ready091() async {
    // `private_protocol` is herdr's `PROTOCOL_VERSION`, the number `api snapshot` reports, so
    // `HerdrProtocol.minimum` still compares the right thing.
    let control = CLIControl(run: host { _ in output(running091Status) })
    #expect(await control.availability() == .ready(version: "0.9.1", protocolVersion: 22))
  }

  @Test("herdr installed with no server is not the same as herdr missing")
  func serverNotRunning() async {
    // Start a session versus install herdr: different next actions.
    let control = CLIControl(run: host { _ in output("status: not running\nversion: 0.7.5") })
    #expect(await control.availability() == .serverNotRunning(version: "0.7.5"))
  }

  @Test("exit 127 is herdr missing")
  func notInstalled() async {
    let control = CLIControl(
      run: host { _ in output("", exitStatus: 127, stderr: "sh: herdr: command not found") }
    )
    #expect(await control.availability() == .notInstalled)
  }

  @Test("a shell that says command not found is missing at any exit status")
  func notInstalledByMessage() async {
    let control = CLIControl(
      run: host { _ in output("", exitStatus: 1, stderr: "herdr: command not found") }
    )
    #expect(await control.availability() == .notInstalled)
  }

  @Test("a protocol newer than this build was written against is still ready")
  func newerProtocolIsReady() async {
    // herdr adds fields and the wire types ignore unknown ones, so newer is expected to work.
    // Refusing it would break every herdr release on its first day.
    let future = "status: running\nversion: 0.9.0\nprotocol: 22\ncompatible: yes"
    let control = CLIControl(run: host { _ in output(future) })
    #expect(await control.availability() == .ready(version: "0.9.0", protocolVersion: 22))
  }

  @Test("the protocol actually shipping today is ready")
  func currentProtocolIsReady() async {
    // herdr 0.8.0.
    let current = "status: running\nversion: 0.8.0\nprotocol: 19\ncompatible: yes"
    let control = CLIControl(run: host { _ in output(current) })
    #expect(await control.availability() == .ready(version: "0.8.0", protocolVersion: 19))
  }

  @Test("a protocol below the floor is reported as too old")
  func belowFloorIsTooOld() async {
    // An update problem, pointing at herdr.
    let ancient = "status: running\nversion: 0.5.0\nprotocol: \(HerdrProtocol.minimum - 1)\ncompatible: yes"
    let control = CLIControl(run: host { _ in output(ancient) })
    #expect(
      await control.availability()
        == .tooOld(version: "0.5.0", protocolVersion: HerdrProtocol.minimum - 1)
    )
  }

  @Test("exactly the floor is ready")
  func floorIsReady() async {
    let atFloor = "status: running\nversion: 0.7.5\nprotocol: \(HerdrProtocol.minimum)\ncompatible: yes"
    let control = CLIControl(run: host { _ in output(atFloor) })
    #expect(
      await control.availability()
        == .ready(version: "0.7.5", protocolVersion: HerdrProtocol.minimum)
    )
  }

  @Test("a transport that throws is reported as missing rather than crashing")
  func transportFailure() async {
    let control = CLIControl(run: host { _ in throw AppError.disconnected(reason: "gone") })
    #expect(await control.availability() == .notInstalled)
  }

  @Test("status output in an unrecognised shape does not claim readiness")
  func unparseableStatus() async {
    // Claiming ready and then failing on the first snapshot is worse. See
    // `statusKeyMissingOnASuccessfulRunIsUnreadable` for why this is not `.serverNotRunning`.
    let control = CLIControl(run: host { _ in output("herdr is fine, thanks") })
    #expect(await control.availability() == .statusUnreadable(version: nil))
    #expect(!(await control.availability().isReady))
  }

  // MARK: - A running server Driverr cannot read is not a stopped server

  @Test("a running server with an unreadable status is not reported as stopped")
  func statusUnreadableIsNotServerNotRunning() async {
    // `status: running` says something is listening, so the honest answer is that Driverr
    // cannot read it. `.serverNotRunning` would send the user to start a running session.
    let unknown = "status: running\nversion: 1.4.0\nsome_future_protocol: 40"
    let control = CLIControl(run: host { _ in output(unknown) })
    #expect(await control.availability() == .statusUnreadable(version: "1.4.0"))
  }

  @Test("an unreadable status with no version still reports the server as running")
  func statusUnreadableWithoutAVersion() async {
    let control = CLIControl(run: host { _ in output("status: running\nsomething: else") })
    #expect(await control.availability() == .statusUnreadable(version: nil))
  }

  @Test("a successful herdr that prints no status key at all is unreadable, not stopped")
  func statusKeyMissingOnASuccessfulRunIsUnreadable() async {
    // herdr always prints a `status` key, `status: not running` included, even for an
    // unreachable socket (exit 0). A successful run with no `status` key is a shape this build
    // does not know, not a stopped server.
    let renamed = "server_state: running\nversion: 1.4.0\nprivate_protocol: 22"
    let control = CLIControl(run: host { _ in output(renamed) })
    #expect(await control.availability() == .statusUnreadable(version: "1.4.0"))
  }

  @Test("a stopped server still lands on serverNotRunning")
  func stoppedServerIsStillServerNotRunning() async {
    // herdr 0.9.1's stopped output, socket path replaced. It keeps the `status` key.
    let stopped = """
      status: not running
      socket: /Users/example/.config/herdr/herdr.sock
      """
    let control = CLIControl(run: host { _ in output(stopped) })
    #expect(await control.availability() == .serverNotRunning(version: nil))
  }

  @Test("a herdr that ran and failed is not reported as running")
  func nonZeroExitWithNoStatusIsNotRunning() async {
    // herdr 0.9.1 with `HERDR_SOCKET_PATH` at a non-socket exits 1 with only stderr.
    // `.statusUnreadable` says a server is up, so the exit status separates the two cases.
    let control = CLIControl(
      run: host { _ in
        output(
          "",
          exitStatus: 1,
          stderr: #"Error: Os { code: 38, kind: Uncategorized, message: "Socket operation on non-socket" }"#
        )
      }
    )
    #expect(await control.availability() == .serverNotRunning(version: nil))
  }

  @Test("the unreadable-status message blames Driverr and never offers a shell")
  func statusUnreadableMessage() {
    for availability in [
      HerdrAvailability.statusUnreadable(version: "1.4.0"),
      HerdrAvailability.statusUnreadable(version: nil),
    ] {
      let message = availability.message
      #expect(message.contains("running"), "a server is up and the message has to say so")
      #expect(message.contains("Update Driverr"), "this build is the thing that is behind")
      // One assertion per wrong claim.
      #expect(!message.contains("no session"))
      #expect(!message.contains("Open Shell"))
      #expect(!message.contains("Update herdr"))
      #expect(!availability.isReady)
    }
    #expect(HerdrAvailability.statusUnreadable(version: "1.4.0").message.contains("herdr 1.4.0"))
  }

  @Test("neither compatibility flag herdr 0.9.1 prints changes the verdict")
  func compatibilityFlagsAreNotHonoured() async {
    // Both flags compare herdr's own CLI binary with its server, not Driverr, which speaks
    // neither protocol directly. Refusing on them would refuse a working host.
    let unhappy = """
      status: running
      version: 0.9.1
      endpoint_compatible: no
      private_protocol: 22
      private_protocol_compatible: no
      """
    let control = CLIControl(run: host { _ in output(unhappy) })
    #expect(await control.availability() == .ready(version: "0.9.1", protocolVersion: 22))
  }

  @Test("the new protocol key wins where a host somehow prints both")
  func privateProtocolIsPreferred() {
    let fields = ["private_protocol": "22", "protocol": "19"]
    #expect(CLIControl.protocolVersion(in: fields) == 22)
    #expect(CLIControl.protocolVersion(in: ["protocol": "19"]) == 19)
    #expect(CLIControl.protocolVersion(in: ["private_protocol": "nonsense"]) == nil)
    #expect(CLIControl.protocolVersion(in: [:]) == nil)
  }

  @Test("every outcome says something a person can act on")
  func messagesAreActionable() {
    let outcomes: [HerdrAvailability] = [
      .ready(version: "0.7.5", protocolVersion: 17),
      .serverNotRunning(version: "0.7.5"),
      .serverNotRunning(version: nil),
      .notInstalled,
      .tooOld(version: "0.5.0", protocolVersion: 3),
      .statusUnreadable(version: "1.4.0"),
      .statusUnreadable(version: nil),
    ]
    for outcome in outcomes {
      #expect(!outcome.message.isEmpty, "\(outcome)")
    }
    #expect(HerdrAvailability.notInstalled.message.contains("PATH"))

    // The remaining update case is herdr being too old, so it must point at herdr.
    let tooOld = HerdrAvailability.tooOld(version: "0.5.0", protocolVersion: 3).message
    #expect(tooOld.contains("Update herdr"))
    #expect(!tooOld.contains("Update Driverr"))
    #expect(HerdrAvailability.ready(version: "0.7.5", protocolVersion: 17).isReady)
    #expect(!HerdrAvailability.serverNotRunning(version: nil).isReady)
  }

  @Test("the not-found message names where Driverr actually looked")
  func notInstalledMessageIsHonest() {
    // An SSH exec channel runs a non-login shell, so the login PATH is not what was searched.
    let message = HerdrAvailability.notInstalled.message
    #expect(!message.contains("login shell's PATH"))
    #expect(message.contains("non-login"))
    #expect(message.contains("login shell"), "a login shell is genuinely asked now")

    // Read from the command's own list so the prose cannot drift from the code.
    for path in CLIControl.fallbackPaths {
      let directory = String(path.dropLast("/herdr".count))
        .replacingOccurrences(of: "$HOME", with: "~")
      #expect(message.contains(directory), "\(directory) is probed but not named")
    }
    #expect(
      message.contains("/opt/homebrew/bin"), "the Homebrew prefix /opt/homebrew/bin is not named")
  }

  // MARK: - A next step, not just a diagnosis

  @Test("the ready line names the version and says nothing about the protocol")
  func readyLineDropsTheProtocolNumber() {
    // The protocol number is a build detail with no next action.
    let message = HerdrAvailability.ready(version: "0.8.0", protocolVersion: 19).message
    #expect(message == "herdr 0.8.0")
    #expect(!message.localizedCaseInsensitiveContains("protocol"))
  }

  @Test("a stopped server names the next step")
  func serverNotRunningNamesTheNextStep() {
    for message in [
      HerdrAvailability.serverNotRunning(version: "0.7.5").message,
      HerdrAvailability.serverNotRunning(version: nil).message,
    ] {
      #expect(message.hasSuffix("Open Shell and run `herdr` to start a session."))
    }
  }

  @Test("the not-found message leads with what to do")
  func notInstalledMessageLeadsWithAnAction() {
    #expect(HerdrAvailability.notInstalled.message.contains("Install herdr"))
  }

  @Test("`key: value` lines are parsed, and the first value for a key wins")
  func statusParsing() {
    let fields = CLIControl.statusFields("status: running\nsocket: /a/b:c\nstatus: nonsense\n")
    #expect(fields["status"] == "running")
    // A path with a colon keeps everything after the first separator.
    #expect(fields["socket"] == "/a/b:c")
  }
}

@Suite("herdr discovery")
struct HerdrDiscoveryTests {
  @Test("the discovered path is what later commands run")
  func usesDiscoveredPath() async throws {
    // An SSH exec channel's non-login shell need not have Homebrew on PATH.
    let commands = CommandLog()
    let control = try #require(
      await CLIControl.discovering(run: { command in
        await commands.record(command)
        return output("/opt/homebrew/bin/herdr\n")
      })
    )

    #expect(control.binaryPath == "/opt/homebrew/bin/herdr")
    let first = await commands.all.first
    #expect(first?.contains("command -v herdr") == true)
    #expect(first?.contains(".local/bin/herdr") == true, "the fallback has to be probed too")
  }

  @Test("herdr on PATH is preferred, and is what the control is bound to")
  func foundOnPath() async throws {
    // The cheap probe stays first, so the login shell's profile is not paid for when PATH
    // answers.
    let control = try #require(
      await CLIControl.discovering(run: { _ in output("/usr/bin/herdr\n") })
    )
    #expect(control.binaryPath == "/usr/bin/herdr")
    #expect(CLIControl.discoveryCommand.hasPrefix("herdr_path=$(command -v herdr"))
  }

  @Test("Homebrew's Apple Silicon prefix is probed, and binds when it answers")
  func homebrewPrefixIsProbed() async throws {
    // The literal path, so the test fails if `fallbackPaths` loses the entry.
    #expect(CLIControl.discoveryCommand.contains("/opt/homebrew/bin/herdr"))
    let control = try #require(
      await CLIControl.discovering(run: { _ in output("/opt/homebrew/bin/herdr\n") })
    )
    #expect(control.binaryPath == "/opt/homebrew/bin/herdr")
  }

  @Test("Intel Homebrew and herdr's own installer default are probed too")
  func otherFallbacksAreProbed() async throws {
    #expect(CLIControl.discoveryCommand.contains("/usr/local/bin/herdr"))
    // Unexpanded: only the remote shell knows the remote home.
    #expect(CLIControl.discoveryCommand.contains("$HOME/.local/bin/herdr"))

    for path in ["/usr/local/bin/herdr", "/home/carson/.local/bin/herdr"] {
      let control = try #require(await CLIControl.discovering(run: { _ in output(path + "\n") }))
      #expect(control.binaryPath == path)
    }
  }

  @Test("the login shell is asked, so a custom prefix needs no hardcoding")
  func loginShellIsProbed() async {
    // mise, asdf or a custom prefix can only be found on the login shell's PATH, hence `-l`.
    let command = CLIControl.discoveryCommand
    #expect(command.contains(#""${SHELL:-/bin/sh}" -lc 'command -v herdr'"#))
  }

  @Test("nothing found is nothing returned")
  func notFound() async {
    #expect(await CLIControl.discovering(run: { _ in output("", exitStatus: 1) }) == nil)
    #expect(await CLIControl.discovering(run: { _ in output("   \n") }) == nil)
  }

  @Test("banner text before the answer does not become the binary path")
  func bannerNoiseIsSkipped() async throws {
    // Profiles print things; taking the first line would bind herdr to a MOTD.
    let noisy = """
      Welcome to ExampleOS 1.0

       * Documentation:  https://example.com/docs
      Last login: Mon Jan  1 00:00:00 2024 from 192.0.2.4
      /opt/homebrew/bin/herdr
      """
    let control = try #require(await CLIControl.discovering(run: { _ in output(noisy) }))
    #expect(control.binaryPath == "/opt/homebrew/bin/herdr")
  }

  @Test("an absolute path in the banner that is not herdr is not the answer")
  func absolutePathsInBannerAreSkipped() async throws {
    // An absolute path to herdr, not any absolute path.
    let noisy = """
      /etc/motd: read the wiki
      /usr/share/fortune/wisdom
      /opt/custom/mise/installs/herdr/0.8.0/bin/herdr
      """
    let control = try #require(await CLIControl.discovering(run: { _ in output(noisy) }))
    #expect(control.binaryPath == "/opt/custom/mise/installs/herdr/0.8.0/bin/herdr")
  }

  @Test("banner text with no path in it finds nothing")
  func bannerWithoutAnAnswer() async {
    #expect(
      await CLIControl.discovering(run: { _ in output("herdr: aliased to hd\nnot found\n") })
        == nil
    )
  }

  @Test("a path that was printed counts even when the script exits non-zero")
  func exitStatusIsNotTheAnswer() async throws {
    // The status reflects only the last probe, so a printed path counts regardless.
    let control = try #require(
      await CLIControl.discovering(run: { _ in output("/opt/homebrew/bin/herdr\n", exitStatus: 1) })
    )
    #expect(control.binaryPath == "/opt/homebrew/bin/herdr")
  }

  @Test("the first usable path is taken, in case several locations answer")
  func firstUsablePathWins() async throws {
    let control = try #require(
      await CLIControl.discovering(run: { _ in
        output("/usr/bin/herdr\n/home/carson/.local/bin/herdr\n")
      })
    )
    #expect(control.binaryPath == "/usr/bin/herdr")
  }

  @Test("a transport that throws finds nothing rather than crashing")
  func transportFailure() async {
    #expect(await CLIControl.discovering(run: { _ in throw AppError.cancelled }) == nil)
  }
}

private actor CommandLog {
  private(set) var all: [String] = []
  func record(_ command: String) { all.append(command) }
}
