import DriverrCore
import Foundation
import Testing

@testable import DriverrHerdr

/// Records what was asked of the host and answers with whatever the test wants. This is
/// why `CommandRunner` is a closure rather than an SSH type.
private final class FakeHost: @unchecked Sendable {
  private let lock = NSLock()
  private var _commands: [String] = []
  var commands: [String] { lock.withLock { _commands } }
  var lastCommand: String? { commands.last }

  private let answer: @Sendable (String) throws -> CommandResult

  init(answer: @escaping @Sendable (String) throws -> CommandResult) {
    self.answer = answer
  }

  convenience init(standardOutput: String, exitStatus: Int = 0, standardError: String = "") {
    self.init { _ in
      CommandResult(
        standardOutput: standardOutput,
        standardError: standardError,
        exitStatus: exitStatus
      )
    }
  }

  var runner: CommandRunner {
    { [self] command in
      lock.withLock { _commands.append(command) }
      return try answer(command)
    }
  }
}

@Suite("CLIControl")
struct CLIControlTests {
  @Test("a snapshot is fetched and mapped")
  func fetchesSnapshot() async throws {
    let host = FakeHost(standardOutput: Fixture.snapshot())
    let control = CLIControl(run: host.runner)

    let tree = try await control.snapshot()

    #expect(tree.workspaces.count == 2)
    #expect(tree.pane(id: "w1:p1")?.agent?.name == "Claude")
    #expect(host.lastCommand == "herdr api snapshot")
  }

  @Test("the configured binary path is what gets run")
  func usesBinaryPath() async throws {
    let host = FakeHost(standardOutput: Fixture.snapshot())
    let control = CLIControl(binaryPath: "/usr/local/bin/herdr", run: host.runner)

    _ = try await control.snapshot()

    #expect(host.lastCommand == "/usr/local/bin/herdr api snapshot")
  }

  @Test("a path with a space is quoted, because home directories have spaces")
  func quotesAwkwardPaths() async throws {
    let host = FakeHost(standardOutput: Fixture.snapshot())
    let control = CLIControl(binaryPath: "/Users/a b/.local/bin/herdr", run: host.runner)

    _ = try await control.snapshot()

    #expect(host.lastCommand == "'/Users/a b/.local/bin/herdr' api snapshot")
  }

  @Test("exit 127 is herdr missing, not a generic failure")
  func missingBinary() async {
    // The user's next action is different, so it must not render like any other failure.
    let host = FakeHost(
      standardOutput: "",
      exitStatus: 127,
      standardError: "sh: herdr: command not found"
    )
    let control = CLIControl(run: host.runner)

    await #expect(throws: AppError.herdrNotInstalled) {
      _ = try await control.snapshot()
    }
  }

  @Test("a shell that says command not found is herdr missing even at another status")
  func missingBinaryByMessage() async {
    let host = FakeHost(standardOutput: "", exitStatus: 1, standardError: "herdr: command not found")
    let control = CLIControl(run: host.runner)

    await #expect(throws: AppError.herdrNotInstalled) {
      _ = try await control.snapshot()
    }
  }

  @Test("any other non-zero exit carries what herdr said")
  func otherFailureKeepsTheMessage() async {
    let host = FakeHost(
      standardOutput: "",
      exitStatus: 2,
      standardError: "no herdr server is running\n"
    )
    let control = CLIControl(run: host.runner)

    await #expect(throws: AppError.herdrCommandFailed(reason: "no herdr server is running")) {
      _ = try await control.snapshot()
    }
  }

  @Test("a non-zero exit with nothing on stderr still says something useful")
  func silentFailure() async throws {
    let host = FakeHost(standardOutput: "", exitStatus: 3)
    let control = CLIControl(run: host.runner)

    await #expect(throws: AppError.herdrCommandFailed(reason: "herdr exited with 3.")) {
      _ = try await control.snapshot()
    }
  }

  @Test("herdr's own error envelope is reported as herdr's message")
  func herdrErrorEnvelope() async {
    // Exit 0 with an error body: herdr said no. "Malformed response" would blame the wrong
    // component.
    let host = FakeHost(
      standardOutput: #"{"id":"1","error":{"code":"not_found","message":"no such pane"}}"#
    )
    let control = CLIControl(run: host.runner)

    await #expect(throws: AppError.herdrCommandFailed(reason: "no such pane")) {
      _ = try await control.snapshot()
    }
  }

  @Test("output that is not herdr's at all is an unreadable response")
  func garbageOutput() async {
    let host = FakeHost(standardOutput: "Welcome to ExampleOS 1.0\nlast login: today\n")
    let control = CLIControl(run: host.runner)

    await #expect(throws: AppError.herdrResponseUnreadable) {
      _ = try await control.snapshot()
    }
  }

  @Test("an AppError from the transport passes through unchanged")
  func transportErrorSurvives() async {
    // Relabelling a dropped connection as a herdr problem sends the user to the wrong place.
    let host = FakeHost { _ in throw AppError.disconnected(reason: "The connection dropped.") }
    let control = CLIControl(run: host.runner)

    await #expect(throws: AppError.disconnected(reason: "The connection dropped.")) {
      _ = try await control.snapshot()
    }
  }

  @Test("a transport error that is not an AppError still becomes one")
  func unknownTransportError() async {
    struct Mystery: Error {}
    let host = FakeHost { _ in throw Mystery() }
    let control = CLIControl(run: host.runner)

    await #expect(throws: AppError.channelFailed(reason: "Could not run herdr on this host.")) {
      _ = try await control.snapshot()
    }
  }

  @Test("text is sent to the named pane")
  func sendsText() async throws {
    let host = FakeHost(standardOutput: "")
    let control = CLIControl(run: host.runner)

    try await control.sendText(paneID: "w1:p2", text: "yes")

    #expect(host.lastCommand == "herdr pane send-text 'w1:p2' yes")
  }

  @Test("text a person typed is quoted, whatever they typed")
  func quotesTypedText() async throws {
    // The one command built from free text, so the one place a stray quote or `$(…)` could
    // reach the far side's shell.
    let host = FakeHost(standardOutput: "")
    let control = CLIControl(run: host.runner)

    try await control.sendText(paneID: "p", text: "it's $(rm -rf /) & done\n")

    #expect(host.lastCommand == #"herdr pane send-text p 'it'\''s $(rm -rf /) & done"# + "\n'")
  }

  @Test("an empty argument stays an argument")
  func emptyTextIsStillAnArgument() async throws {
    // Unquoted, an empty string is no argument and shifts every value after it.
    let host = FakeHost(standardOutput: "")
    let control = CLIControl(run: host.runner)

    try await control.sendText(paneID: "p", text: "")

    #expect(host.lastCommand == "herdr pane send-text p ''")
  }

  // MARK: - Submitting a reply

  /// `send-text "yes\n"` sends LF, which Claude Code reads as a line break. `pane run "yes"`
  /// appends CR, which submits. See `HerdrControl.submitText`.
  @Test("a reply is submitted with pane run, which is the verb that appends a CR")
  func submitsWithPaneRun() async throws {
    let host = FakeHost(standardOutput: "")
    let control = CLIControl(run: host.runner)

    try await control.submitText(paneID: "w1:p2", text: "yes, go ahead")

    #expect(host.lastCommand == "herdr pane run 'w1:p2' 'yes, go ahead'")
  }

  /// `pane run "q\n"` sends `LF CR`, a stray blank line ahead of the submit.
  @Test("a trailing newline is trimmed rather than sent ahead of the submit")
  func trimsTrailingNewlines() async throws {
    let host = FakeHost(standardOutput: "")
    let control = CLIControl(run: host.runner)

    try await control.submitText(paneID: "p", text: "yes\n\n  ")

    #expect(host.lastCommand == "herdr pane run p yes")
  }

  /// An interior LF is a line break the person meant, and the final CR still submits.
  @Test("an interior newline survives, because that is a line break somebody typed")
  func keepsInteriorNewlines() async throws {
    let host = FakeHost(standardOutput: "")
    let control = CLIControl(run: host.runner)

    try await control.submitText(paneID: "p", text: "first\nsecond\n")

    #expect(host.lastCommand == "herdr pane run p 'first\nsecond'")
  }

  @Test("a submitted reply is quoted exactly as a typed one is")
  func quotesSubmittedText() async throws {
    let host = FakeHost(standardOutput: "")
    let control = CLIControl(run: host.runner)

    try await control.submitText(paneID: "p", text: "it's $(rm -rf /) & done")

    #expect(host.lastCommand == #"herdr pane run p 'it'\''s $(rm -rf /) & done'"#)
  }

  @Test("keys go over as herdr's own key names")
  func sendsKeys() async throws {
    let host = FakeHost(standardOutput: "")
    let control = CLIControl(run: host.runner)

    try await control.sendKeys(paneID: "w1:p2", keys: [.esc])

    #expect(host.lastCommand == "herdr pane send-keys 'w1:p2' esc")
  }

  /// Two printable keys in one `pane send-keys` reach Claude Code's picker as one burst and
  /// both are dropped. Separate calls all land, so each key is its own call in one exec.
  @Test("several keys go over one herdr call per key, in one exec")
  func sendsOneCallPerKey() async throws {
    let host = FakeHost(standardOutput: "")
    let control = CLIControl(run: host.runner)

    try await control.sendKeys(paneID: "w1:p2", keys: [.yes, .no, .right, .interrupt])

    #expect(host.commands.count == 1)
    #expect(
      host.lastCommand
        == "herdr pane send-keys 'w1:p2' y && herdr pane send-keys 'w1:p2' n"
        + " && herdr pane send-keys 'w1:p2' right && herdr pane send-keys 'w1:p2' 'ctrl+c'"
    )
  }

  @Test("sending no keys runs nothing at all")
  func noKeysIsNoCommand() async throws {
    // `send-keys` with no keys is a usage error, which would surface as herdr refusing.
    let host = FakeHost(standardOutput: "")
    let control = CLIControl(run: host.runner)

    try await control.sendKeys(paneID: "p", keys: [])

    #expect(host.commands.isEmpty)
  }

  @Test("a refused steering command reports what herdr said")
  func steeringFailureIsSpecific() async {
    let host = FakeHost(standardOutput: "", exitStatus: 1, standardError: "no such pane: p9")
    let control = CLIControl(run: host.runner)

    await #expect(throws: AppError.herdrCommandFailed(reason: "no such pane: p9")) {
      try await control.sendText(paneID: "p9", text: "hi")
    }
  }

  @Test(
    "every pane action maps to the herdr command it claims to",
    arguments: [
      (PaneAction.split(.right), "pane split 'w1:p2' --direction right"),
      (PaneAction.split(.down), "pane split 'w1:p2' --direction down"),
      (PaneAction.rename("build logs"), "pane rename 'w1:p2' 'build logs'"),
      (PaneAction.close, "pane close 'w1:p2'"),
    ]
  )
  func paneActionCommands(action: PaneAction, expected: String) async throws {
    // A wrong command does something real to somebody's session.
    let host = FakeHost(standardOutput: "")
    let control = CLIControl(run: host.runner)

    try await control.perform(action, on: "w1:p2")

    #expect(host.lastCommand == "herdr \(expected)")
  }

  @Test("a rename with an awkward label is still one argument")
  func quotesRenameLabel() async throws {
    let host = FakeHost(standardOutput: "")
    let control = CLIControl(run: host.runner)

    try await control.perform(.rename("it's #2; done"), on: "p")

    #expect(host.lastCommand == #"herdr pane rename p 'it'\''s #2; done'"#)
  }

  @Test(
    "a workspace and a tab each map to the herdr command they claim to",
    arguments: [
      (RenameTarget.workspace(id: "w1"), "workspace rename w1 'build logs'"),
      (RenameTarget.tab(id: "w1:t2"), "tab rename 'w1:t2' 'build logs'"),
    ]
  )
  func renameCommands(target: RenameTarget, expected: String) async throws {
    // Checked against the herdr CLI. A wrong one renames somebody else's workspace.
    let host = FakeHost(standardOutput: "")
    let control = CLIControl(run: host.runner)

    try await control.rename(target, to: "build logs")

    #expect(host.lastCommand == "herdr \(expected)")
  }

  @Test(
    "a container rename with an awkward label is still one argument",
    arguments: [
      (RenameTarget.workspace(id: "w1"), "workspace"),
      (RenameTarget.tab(id: "t1"), "tab"),
    ]
  )
  func quotesContainerRenameLabel(target: RenameTarget, subcommand: String) async throws {
    // `LABEL` is variadic, so an unquoted label would be cut at its first space.
    let host = FakeHost(standardOutput: "")
    let control = CLIControl(run: host.runner)

    try await control.rename(target, to: "it's #2; done")

    #expect(
      host.lastCommand == #"herdr \#(subcommand) rename \#(target.id) 'it'\''s #2; done'"#
    )
  }

  @Test("a refused container rename reports what herdr said")
  func renameFailure() async {
    let host = FakeHost(standardOutput: "", exitStatus: 1, standardError: "no such workspace: w9")
    let control = CLIControl(run: host.runner)

    await #expect(throws: AppError.herdrCommandFailed(reason: "no such workspace: w9")) {
      try await control.rename(.workspace(id: "w9"), to: "anything")
    }
  }

  @Test("a container rename carries the host's socket path like every other command")
  func renameExportsTheSocketPath() async throws {
    let host = FakeHost(standardOutput: "")
    let control = CLIControl(herdrSocketPath: "/tmp/h.sock", run: host.runner)

    try await control.rename(.tab(id: "w1:t1"), to: "tests")

    #expect(
      host.lastCommand
        == "export HERDR_SOCKET_PATH=/tmp/h.sock; herdr tab rename 'w1:t1' tests"
    )
  }

  @Test("a refused pane action reports what herdr said")
  func paneActionFailure() async {
    let host = FakeHost(standardOutput: "", exitStatus: 1, standardError: "pane is the last one")
    let control = CLIControl(run: host.runner)

    await #expect(throws: AppError.herdrCommandFailed(reason: "pane is the last one")) {
      try await control.perform(.close, on: "p")
    }
  }

  @Test("attaching goes by terminal id, which every pane has")
  func attachesByTerminalID() {
    // `agent attach <pane>` answers `agent_not_found` for a pane with no agent, and most panes
    // have none. Asserted exactly, because a wrong command fails on the far side with herdr's
    // error.
    let control = CLIControl(run: { _ in CommandResult(standardOutput: "", standardError: "", exitStatus: 0) })
    let shell = Pane(
      id: "w7:p6",
      tabID: "w7:t1",
      workspaceID: "w7",
      title: "zsh",
      terminalID: "term_w7p6",
      directory: "~"
    )
    let agentPane = Pane(
      id: "w1:p2",
      tabID: "w1:t1",
      workspaceID: "w1",
      title: "needs a decision",
      agent: Agent(name: "Claude", status: .blocked),
      terminalID: "term_w1p2"
    )

    // A shell pane and an agent pane produce the same kind of command.
    #expect(control.attachCommand(for: shell) == "herdr terminal attach term_w7p6")
    #expect(control.attachCommand(for: agentPane) == "herdr terminal attach term_w1p2")
    // No `--takeover`: attaching must not evict whoever is on the pane at a desk.
    #expect(!control.attachCommand(for: shell).contains("--takeover"))
  }

  @Test("a pane with no terminal id falls back to the old command")
  func attachFallsBackToThePaneID() {
    // `terminal_id` is optional below protocol 19, and Driverr's floor is 17.
    let control = CLIControl(run: { _ in CommandResult(standardOutput: "", standardError: "", exitStatus: 0) })
    let pane = Pane(id: "w1:p2", tabID: "w1:t1", workspaceID: "w1", title: "old herdr")

    #expect(control.attachCommand(for: pane) == "herdr agent attach 'w1:p2'")
  }

  @Test("an awkward terminal id cannot break out of its argument")
  func quotesTheTerminalID() {
    let control = CLIControl(
      binaryPath: "/opt/homebrew/bin/herdr",
      run: { _ in CommandResult(standardOutput: "", standardError: "", exitStatus: 0) }
    )
    let pane = Pane(
      id: "p",
      tabID: "t",
      workspaceID: "w",
      title: "odd",
      terminalID: "term; rm -rf /"
    )

    // The id comes off the wire and is typed into a shell on the far side. The whole string is
    // asserted, so the bare binary path is visible too.
    #expect(
      control.attachCommand(for: pane)
        == #"/opt/homebrew/bin/herdr terminal attach 'term; rm -rf /'"#
    )
  }

  @Test("a missing binary is not worth retrying; a failed command is")
  func retryability() {
    #expect(!AppError.herdrNotInstalled.isRetryable)
    #expect(!AppError.herdrResponseUnreadable.isRetryable)
    #expect(AppError.herdrCommandFailed(reason: "transient").isRetryable)
  }

  // MARK: - Reading panes in a batch

  /// Asserted exactly: the command is typed into a shell on the far side and nothing else
  /// checks its shape.
  @Test("a batch of reads is one command, one `pane read` per id")
  func readsPanesInOneCommand() async throws {
    let host = FakeHost(standardOutput: "")
    let control = CLIControl(run: host.runner)

    _ = try await control.readPanes(ids: ["w1:p1", "w1:p2"], lines: 6)

    #expect(host.commands.count == 1)
    #expect(
      host.lastCommand == """
        printf '\\n%s\\n' '__DRIVERR_PANE__ w1:p1'; \
        herdr pane read 'w1:p1' --source visible --lines 6 --format text; \
        printf '\\n%s\\n' '__DRIVERR_PANE__ w1:p2'; \
        herdr pane read 'w1:p2' --source visible --lines 6 --format text
        """
    )
  }

  @Test("each pane's lines come back under its own id")
  func mapsEachPanesLines() async throws {
    let host = FakeHost(
      standardOutput: """

        __DRIVERR_PANE__ w1:p1
        $ swift test
        Test Suite 'All tests' passed

        __DRIVERR_PANE__ w1:p2
        Shall I apply the patch? (y/n)

        """
    )
    let control = CLIControl(run: host.runner)

    let panes = try await control.readPanes(ids: ["w1:p1", "w1:p2"], lines: 6)

    #expect(panes["w1:p1"] == ["$ swift test", "Test Suite 'All tests' passed"])
    #expect(panes["w1:p2"] == ["Shall I apply the patch? (y/n)"])
  }

  @Test("a pane that fails to read is empty, and the rest of the batch survives")
  func aFailingPaneDoesNotFailTheBatch() async throws {
    // herdr 0.8.0 writes its error envelope to stdout and exits 1, so it sits where the pane's
    // content should be. 0.8.2 writes to stderr (see `anEmptyBatchThatComplainedThrows`).
    // Driverr's protocol floor still admits 0.8.0.
    let host = FakeHost(
      standardOutput: """

        __DRIVERR_PANE__ w1:p1
        {"error":{"code":"pane_not_found","message":"pane w1:p1 not found"},"id":"cli:pane:read"}

        __DRIVERR_PANE__ w1:p2
        still here

        """,
      exitStatus: 1
    )
    let control = CLIControl(run: host.runner)

    let panes = try await control.readPanes(ids: ["w1:p1", "w1:p2"], lines: 6)

    #expect(panes["w1:p1"] == [])
    #expect(panes["w1:p2"] == ["still here"])
  }

  @Test("every id asked for comes back, even one herdr said nothing about at all")
  func everyIDIsAnswered() async throws {
    // An empty stdout and stderr is a session showing nothing, not a failure.
    let host = FakeHost(standardOutput: "")
    let control = CLIControl(run: host.runner)

    let panes = try await control.readPanes(ids: ["w1:p1", "w1:p2"], lines: 6)

    #expect(panes == ["w1:p1": [], "w1:p2": []])
  }

  @Test("a batch of nothing runs nothing at all")
  func noIDsIsNoCommand() async throws {
    // `pane read` with no id is a usage error; see `sendKeys`.
    let host = FakeHost(standardOutput: "")
    let control = CLIControl(run: host.runner)

    let panes = try await control.readPanes(ids: [], lines: 6)

    #expect(panes.isEmpty)
    #expect(host.commands.isEmpty)
  }

  @Test("blank rows at the end of a chunk are not part of the picture")
  func trimsPadding() async throws {
    // At least the blank line the next boundary's `printf` opens with lands in this chunk.
    let host = FakeHost(
      standardOutput:
        "\n__DRIVERR_PANE__ p\n$ make   \nbuilding…\n      \n   \n\n\n"
    )
    let control = CLIControl(run: host.runner)

    let panes = try await control.readPanes(ids: ["p"], lines: 6)

    #expect(panes["p"] == ["$ make", "building…"])
  }

  @Test("a pane id with a space in it cannot break out of its argument")
  func quotesPaneIDsInABatch() async throws {
    let host = FakeHost(standardOutput: "")
    let control = CLIControl(binaryPath: "/opt/homebrew/bin/herdr", run: host.runner)

    _ = try await control.readPanes(ids: ["w1:p1; rm -rf /"], lines: 3)

    #expect(
      host.lastCommand == """
        printf '\\n%s\\n' '__DRIVERR_PANE__ w1:p1; rm -rf /'; \
        /opt/homebrew/bin/herdr pane read 'w1:p1; rm -rf /' --source visible \
        --lines 3 --format text
        """
    )
  }

  @Test("a batch that answers nothing at all and complains is a refusal, not a quiet session")
  func anEmptyBatchThatComplainedThrows() async {
    // herdr 0.8.2 puts its envelope on stderr, so a refused batch arrives as an empty stdout,
    // which looks like panes showing nothing. Empty output plus a complaint is a refusal.
    let envelope =
      #"{"error":{"code":"pane_not_found","message":"pane w1:p1 not found"},"id":"cli:pane:read"}"#
    let host = FakeHost(standardOutput: "", exitStatus: 1, standardError: envelope)
    let control = CLIControl(run: host.runner)

    await #expect(throws: AppError.herdrCommandFailed(reason: envelope)) {
      _ = try await control.readPanes(ids: ["w1:p1", "w1:p2"], lines: 6)
    }
  }

  @Test("one pane's refusal is not the batch's, however loudly herdr complained")
  func oneRefusedPaneDoesNotThrow() async throws {
    // One pane closed a moment ago must not throw away the rest; stderr is noisy then.
    let host = FakeHost(
      standardOutput: "\n__DRIVERR_PANE__ w1:p2\nstill here\n",
      exitStatus: 1,
      standardError:
        #"{"error":{"code":"pane_not_found","message":"pane w1:p1 not found"},"id":"cli:pane:read"}"#
    )
    let control = CLIControl(run: host.runner)

    let panes = try await control.readPanes(ids: ["w1:p1", "w1:p2"], lines: 6)

    #expect(panes["w1:p1"] == [])
    #expect(panes["w1:p2"] == ["still here"])
  }

  @Test("a transport that fails takes the whole batch with it")
  func aBrokenChannelStillThrows() async {
    // A failed read is an empty thumbnail, but a channel that never opened asked nothing.
    let host = FakeHost { _ in throw AppError.channelFailed(reason: "the link went away") }
    let control = CLIControl(run: host.runner)

    await #expect(throws: AppError.channelFailed(reason: "the link went away")) {
      _ = try await control.readPanes(ids: ["p"], lines: 6)
    }
  }

  // MARK: - The single-pane screen read

  private func pane(_ id: String = "w1:p1", viewportRows: Int? = 58) -> Pane {
    Pane(
      id: id,
      tabID: "w1:t1",
      workspaceID: "w1",
      title: "worker",
      agent: Agent(name: "Claude", status: .working),
      terminalID: "term_\(id)",
      viewportRows: viewportRows
    )
  }

  /// None of these flags fails loudly when wrong: `agent read` refuses a working pane,
  /// `--format text` drops the styling that marks the agent's message, and `--source recent`
  /// reads the wrong buffer.
  @Test("one pane is read as the visible screen, in ansi, bounded to its viewport")
  func readsOnePaneScreen() async throws {
    let host = FakeHost(standardOutput: "hello")
    let control = CLIControl(run: host.runner)

    _ = try await control.readScreen(of: pane(), lines: 9)

    #expect(host.commands.count == 1)
    #expect(
      host.lastCommand == "herdr pane read 'w1:p1' --source visible --lines 9 --format ansi"
    )
  }

  /// Over-asking made herdr scroll the pane to capture, about 420 ms against 30 ms, for
  /// identical bytes.
  @Test("a request for more rows than the pane has is bounded to what it has")
  func boundsTheRequestToTheViewport() async throws {
    let host = FakeHost(standardOutput: "hello")
    let control = CLIControl(run: host.runner)

    _ = try await control.readScreen(of: pane(viewportRows: 58), lines: 1000)

    #expect(host.lastCommand?.contains("--lines 58") == true)
    #expect(host.lastCommand?.contains("--lines 1000") == false)
  }

  /// The visible screen is the viewport, so asking for all of it cannot exceed it.
  @Test("a pane that reported no viewport is asked for no line count at all")
  func noViewportMeansNoLineCount() async throws {
    let host = FakeHost(standardOutput: "hello")
    let control = CLIControl(run: host.runner)

    _ = try await control.readScreen(of: pane(viewportRows: nil), lines: 9)

    #expect(host.lastCommand == "herdr pane read 'w1:p1' --source visible --format ansi")
    #expect(host.lastCommand?.contains("--lines") == false)
  }

  @Test("the tail the caller asked for is what comes back, however much herdr sent")
  func takesTheTail() async throws {
    let host = FakeHost(standardOutput: "one\ntwo\nthree\nfour")
    let control = CLIControl(run: host.runner)

    let screen = try await control.readScreen(of: pane(), lines: 2)

    #expect(screen.lines.map(\.text) == ["three", "four"])
  }

  @Test("the styling survives as a style, and no escape reaches the value")
  func mapsStylingToTheValue() async throws {
    let host = FakeHost(
      standardOutput: "\u{1B}[0m\u{1B}[38;5;15m⏺ \u{1B}[0mthe suite is green"
    )
    let control = CLIControl(run: host.runner)

    let screen = try await control.readScreen(of: pane(), lines: 9)

    #expect(screen.text == "⏺ the suite is green")
    #expect(screen.agentMessage == 0..<1)
    #expect(screen.lines[0].spans.first?.style.foreground == .brightWhite)
  }

  /// Both sides have an empty stdout; only the exit status and stderr tell them apart. This
  /// is why the screen read is separate from the batch.
  @Test("a refusal and a genuinely blank screen are different answers")
  func refusalIsNotABlankScreen() async throws {
    let refusing = FakeHost(
      standardOutput: "",
      exitStatus: 1,
      standardError: """
        {"error":{"code":"agent_not_idle","message":"cannot read 100 lines while wJ:pV is \
        working: its alternate-screen history can only be captured by scrolling while idle. \
        Wait and retry, or use --source visible"}}
        """
    )
    await #expect(throws: AppError.self) {
      _ = try await CLIControl(run: refusing.runner).readScreen(of: pane(), lines: 9)
    }

    let quiet = FakeHost(standardOutput: "", exitStatus: 0)
    let screen = try await CLIControl(run: quiet.runner).readScreen(of: pane(), lines: 9)

    #expect(screen.isEmpty)
    #expect(screen == .blank)
  }

  /// `agent_not_idle`'s sentence says what to do; its JSON says nothing.
  @Test("a refusal is reported as what herdr said, not as raw JSON")
  func refusalCarriesHerdrsMessage() async {
    let host = FakeHost(
      standardOutput: "",
      exitStatus: 1,
      standardError: #"{"error":{"code":"pane_not_found","message":"pane w9:p9 not found"}}"#
    )

    await #expect(throws: AppError.herdrCommandFailed(reason: "pane w9:p9 not found")) {
      _ = try await CLIControl(run: host.runner).readScreen(of: pane(), lines: 9)
    }
  }

  /// On herdr 0.8.0 the envelope is on stdout and would be drawn as the pane's content.
  @Test("an older herdr's envelope on stdout is read as the refusal it is")
  func refusalOnStandardOutput() async {
    let host = FakeHost(
      standardOutput: #"{"error":{"code":"pane_not_found","message":"pane w9:p9 not found"}}"#,
      exitStatus: 1
    )

    await #expect(throws: AppError.herdrCommandFailed(reason: "pane w9:p9 not found")) {
      _ = try await CLIControl(run: host.runner).readScreen(of: pane(), lines: 9)
    }
  }

  @Test("a missing herdr is still its own failure, not a refused screen read")
  func missingBinaryOnScreenRead() async {
    let host = FakeHost(
      standardOutput: "",
      exitStatus: 127,
      standardError: "sh: herdr: command not found"
    )

    await #expect(throws: AppError.herdrNotInstalled) {
      _ = try await CLIControl(run: host.runner).readScreen(of: pane(), lines: 9)
    }
  }

  @Test("a channel that could not be opened is not a blank screen either")
  func brokenChannelOnScreenRead() async {
    let host = FakeHost { _ in throw AppError.channelFailed(reason: "the link went away") }

    await #expect(throws: AppError.channelFailed(reason: "the link went away")) {
      _ = try await CLIControl(run: host.runner).readScreen(of: pane(), lines: 9)
    }
  }

  /// Asserted here so a change to the single read cannot take the batch's `--source` with it.
  @Test("the batch read is untouched by the single-pane read existing")
  func batchIsUnchanged() async throws {
    let host = FakeHost(standardOutput: "")
    let control = CLIControl(run: host.runner)

    _ = try await control.readPanes(ids: ["w1:p1"], lines: 6)

    #expect(
      host.lastCommand == """
        printf '\\n%s\\n' '__DRIVERR_PANE__ w1:p1'; \
        herdr pane read 'w1:p1' --source visible --lines 6 --format text
        """
    )
  }

  // MARK: - HERDR_SOCKET_PATH

  /// Every command must carry `Host.herdrSocketPath`, or the stored value has no effect.
  @Suite("HERDR_SOCKET_PATH")
  struct SocketPathTests {
    private func pane(_ id: String = "w1:p1", viewportRows: Int? = 58) -> Pane {
      Pane(
        id: id,
        tabID: "w1:t1",
        workspaceID: "w1",
        title: "worker",
        agent: Agent(name: "Claude", status: .working),
        terminalID: "term_\(id)",
        viewportRows: viewportRows
      )
    }

    @Test("a snapshot carries the socket path")
    func snapshotCarriesIt() async throws {
      let host = FakeHost(standardOutput: Fixture.snapshot())
      let control = CLIControl(herdrSocketPath: "/run/herdr.sock", run: host.runner)

      _ = try await control.snapshot()

      #expect(host.lastCommand == "export HERDR_SOCKET_PATH=/run/herdr.sock; herdr api snapshot")
    }

    @Test("sendText carries the socket path")
    func sendTextCarriesIt() async throws {
      let host = FakeHost(standardOutput: "")
      let control = CLIControl(herdrSocketPath: "/run/herdr.sock", run: host.runner)

      try await control.sendText(paneID: "w1:p1", text: "hi")

      #expect(
        host.lastCommand
          == "export HERDR_SOCKET_PATH=/run/herdr.sock; herdr pane send-text 'w1:p1' hi"
      )
    }

    @Test("submitText carries the socket path — it is the path a reply is delivered on")
    func submitTextCarriesIt() async throws {
      let host = FakeHost(standardOutput: "")
      let control = CLIControl(herdrSocketPath: "/run/herdr.sock", run: host.runner)

      try await control.submitText(paneID: "w1:p2", text: "yes, go ahead")

      #expect(
        host.lastCommand
          == "export HERDR_SOCKET_PATH=/run/herdr.sock; herdr pane run 'w1:p2' 'yes, go ahead'"
      )
    }

    @Test("sendKeys carries the socket path")
    func sendKeysCarriesIt() async throws {
      let host = FakeHost(standardOutput: "")
      let control = CLIControl(herdrSocketPath: "/run/herdr.sock", run: host.runner)

      try await control.sendKeys(paneID: "w1:p1", keys: [.esc])

      #expect(
        host.lastCommand
          == "export HERDR_SOCKET_PATH=/run/herdr.sock; herdr pane send-keys 'w1:p1' esc"
      )
    }

    /// Exported once, ahead of the chain, so it reaches every call.
    @Test("a chain of keys carries the socket path to every call")
    func sendKeysChainCarriesIt() async throws {
      let host = FakeHost(standardOutput: "")
      let control = CLIControl(herdrSocketPath: "/run/herdr.sock", run: host.runner)

      try await control.sendKeys(paneID: "w1:p1", keys: [.yes, .no])

      #expect(
        host.lastCommand
          == "export HERDR_SOCKET_PATH=/run/herdr.sock; herdr pane send-keys 'w1:p1' y"
          + " && herdr pane send-keys 'w1:p1' n"
      )
    }

    @Test("perform carries the socket path")
    func performCarriesIt() async throws {
      let host = FakeHost(standardOutput: "")
      let control = CLIControl(herdrSocketPath: "/run/herdr.sock", run: host.runner)

      try await control.perform(.close, on: "w1:p1")

      #expect(
        host.lastCommand
          == "export HERDR_SOCKET_PATH=/run/herdr.sock; herdr pane close 'w1:p1'"
      )
    }

    @Test("the batch pane read carries the socket path once, for the whole request")
    func readPanesCarriesIt() async throws {
      let host = FakeHost(standardOutput: "")
      let control = CLIControl(herdrSocketPath: "/run/herdr.sock", run: host.runner)

      _ = try await control.readPanes(ids: ["w1:p1"], lines: 6)

      #expect(
        host.lastCommand == """
          export HERDR_SOCKET_PATH=/run/herdr.sock; \
          printf '\\n%s\\n' '__DRIVERR_PANE__ w1:p1'; \
          herdr pane read 'w1:p1' --source visible --lines 6 --format text
          """
      )
    }

    @Test("the single-pane screen read carries the socket path")
    func readScreenCarriesIt() async throws {
      let host = FakeHost(standardOutput: "")
      let control = CLIControl(herdrSocketPath: "/run/herdr.sock", run: host.runner)

      _ = try await control.readScreen(of: pane(), lines: 9)

      #expect(
        host.lastCommand == """
          export HERDR_SOCKET_PATH=/run/herdr.sock; \
          herdr pane read 'w1:p1' --source visible --lines 9 --format ansi
          """
      )
    }

    @Test("attachCommand carries the socket path, even though it is never run here")
    func attachCommandCarriesIt() {
      let control = CLIControl(herdrSocketPath: "/run/herdr.sock", run: { _ in
        CommandResult(standardOutput: "", standardError: "", exitStatus: 0)
      })

      #expect(
        control.attachCommand(for: pane())
          == "export HERDR_SOCKET_PATH=/run/herdr.sock; herdr terminal attach 'term_w1:p1'"
      )
    }

    @Test("a value with a space is quoted like every other path here")
    func quotesAnAwkwardSocketPath() async throws {
      let host = FakeHost(standardOutput: Fixture.snapshot())
      let control = CLIControl(herdrSocketPath: "/Users/a b/herdr.sock", run: host.runner)

      _ = try await control.snapshot()

      #expect(
        host.lastCommand
          == "export HERDR_SOCKET_PATH='/Users/a b/herdr.sock'; herdr api snapshot"
      )
    }

    @Test("no socket path leaves every command exactly as it was")
    func nilLeavesCommandsUnchanged() async throws {
      let host = FakeHost(standardOutput: Fixture.snapshot())
      let control = CLIControl(run: host.runner)

      _ = try await control.snapshot()

      #expect(host.lastCommand == "herdr api snapshot")
    }
  }
}
