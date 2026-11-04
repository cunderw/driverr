import DriverrCore
import DriverrHerdr
import DriverrTranscript
import Foundation
import Testing

@testable import DriverrHC

/// A pane on a machine the core added runs its commands there, over `machine.exec`. The
/// transcript reader is the one caller, so the last tests drive the real reader through it.
@Suite("Core machine exec", .timeLimit(.minutes(1)))
struct CoreMachineExecTests {
  private let pane = "core:box/t7"

  private func control(
    _ stream: FakeCoreStream,
    deadline: Duration = .seconds(30)
  ) -> CoreControl {
    CoreControl(binaryPath: "hc", callDeadline: deadline, open: { _ in stream })
  }

  private func runner(_ stream: FakeCoreStream, deadline: Duration = .seconds(30)) throws
    -> CommandRunner
  {
    try #require(control(stream, deadline: deadline).commandRunner(forPane: pane))
  }

  private func answering(_ reply: FakeCoreStream.Reply) -> FakeCoreStream {
    let stream = FakeCoreStream()
    stream.exec = { _, _ in reply }
    return stream
  }

  /// What a run threw, as a value, so a test can compare it.
  private func failure(of run: CommandRunner, _ line: String = "true") async -> AppError? {
    do {
      _ = try await run(line)
      return nil
    } catch {
      return error as? AppError
    }
  }

  @Test("a command runs on the pane's machine, in its shell, under the core's own timeout")
  func runsThere() async throws {
    let stream = answering(.result(FakeCoreStream.executed(stdout: "hi\n")))
    let result = try await runner(stream)("echo hi | cat")

    #expect(result == CommandResult(standardOutput: "hi\n", standardError: "", exitStatus: 0))
    let calls = try stream.params(of: "machine.exec")
    #expect(calls.count == 1)
    let params = try #require(calls.first)
    #expect(params["line"] as? String == "echo hi | cat")
    #expect(params["on"] as? String == "box")
    #expect(params["timeout"] as? Double == 20)
    #expect(params["argv"] == nil)
  }

  @Test(
    "a pane on the core's own computer, or not the core's at all, has no runner",
    arguments: ["core:t7", "w1:p2", "core:/t7", "box/t7"])
  func noRunner(id: String) {
    #expect(control(FakeCoreStream()).commandRunner(forPane: id) == nil)
  }

  @Test("a combined host asks the core for a core pane and the TUI for its own")
  func combinedRoutes() {
    let combined = CombinedControl(tui: FakeControl(), core: control(FakeCoreStream()))
    #expect(combined.commandRunner(forPane: pane) != nil)
    #expect(combined.commandRunner(forPane: "w1:p2") == nil)
  }

  @Test("the machine is the address's first part")
  func machineOfPane() {
    #expect(CorePaneID.machine(of: "core:box/t7") == "box")
    #expect(CorePaneID.machine(of: "core:t7") == nil)
    #expect(CorePaneID.machine(of: "box/t7") == nil)
  }

  @Test("an exit and its errors are passed on as the exec channel gives them")
  func exitAndErrors() async throws {
    let stream = answering(.result(FakeCoreStream.executed(stderr: "no such file\n", code: 2)))
    let result = try await runner(stream)("ls /nowhere")
    #expect(
      result == CommandResult(standardOutput: "", standardError: "no such file\n", exitStatus: 2))
  }

  @Test("a program a signal ended exits 128 and the signal, as a shell reports it")
  func signal() async throws {
    let stream = answering(.result(FakeCoreStream.executed(code: nil, signal: 9)))
    #expect(try await runner(stream)("sleep 99").exitStatus == 137)
  }

  /// Either would parse as a well-formed page that ends early.
  @Test(
    "an answer that was cut short throws rather than pass on part of the output",
    arguments: [(true, false), (false, true)])
  func cutShort(timedOut: Bool, truncated: Bool) async throws {
    let stream = answering(
      .result(
        FakeCoreStream.executed(
          stdout: "partial", code: timedOut ? nil : 0, signal: timedOut ? 9 : nil,
          timedOut: timedOut, truncated: truncated)))
    let failure = await failure(of: try runner(stream))
    guard case .herdrCommandFailed(let reason)? = failure else {
      Issue.record("expected herdrCommandFailed, got \(String(describing: failure))")
      return
    }
    #expect(reason.contains("box"))
  }

  @Test("a core that refuses throws in the core's words")
  func refused() async throws {
    let failure = await failure(of: try runner(answering(.error("machine_unknown"))))
    #expect(failure == .herdrCommandFailed(reason: "machine_unknown"))
  }

  @Test("an answer with neither an exit nor a signal is unreadable")
  func neitherExitNorSignal() async throws {
    let stream = answering(.result(FakeCoreStream.executed(code: nil, signal: nil)))
    #expect(await failure(of: try runner(stream)) == .herdrResponseUnreadable)
  }

  @Test("an answer whose output is not base64 is unreadable")
  func notBase64() async throws {
    let reply = #"{"code":0,"ms":1,"stderr":"","stdout":"not base64!","timed_out":false,"#
      + #""truncated":false}"#
    #expect(await failure(of: try runner(answering(.result(reply)))) == .herdrResponseUnreadable)
  }

  /// The connection's own deadline is 50 ms here, and the answer comes at 150.
  @Test("a command outlasts the connection's deadline, which the calls beside it keep")
  func ownDeadline() async throws {
    let stream = answering(
      .late(FakeCoreStream.executed(stdout: "slow"), delay: .milliseconds(150)))
    let result = try await runner(stream, deadline: .milliseconds(50))("sleep 0.1")
    #expect(result.standardOutput == "slow")
  }

  // MARK: - The reader over it

  private static let sessionID = "3f8c1d20-0000-4000-8000-000000000025"

  private static var host: FakeTranscriptHost {
    FakeTranscriptHost(
      sessionID: sessionID,
      turns: [
        .init(speaker: .human, text: "Tidy the logs on the box.", secondsAgo: 600),
        .init(speaker: .assistant, text: "Done, and rotated.", secondsAgo: 240),
      ]
    )
  }

  private func claudePane(machine: String = "box") -> Pane {
    Pane(
      id: "core:\(machine)/t7",
      tabID: "core:\(machine)/tab",
      workspaceID: "core:\(machine)/workspace",
      title: "claude",
      agent: Agent(
        name: "Claude",
        kind: "claude",
        status: .working,
        session: AgentSession(agent: "claude", kind: "id", value: Self.sessionID),
        machine: machine
      ),
      terminalID: "\(machine)/t7",
      directory: "/home/carson/dev/driverr"
    )
  }

  /// The machine's shell, played by the fixture host. Every line must be for `box`.
  private func machine(_ host: FakeTranscriptHost) -> FakeCoreStream {
    let stream = FakeCoreStream()
    stream.exec = { line, on in
      guard on == "box" else { return .error("machine_unknown") }
      guard let result = try? await host.run(line) else { return .error("spawn_failed") }
      return .result(
        FakeCoreStream.executed(
          stdout: result.standardOutput, stderr: result.standardError,
          code: result.exitStatus))
    }
    return stream
  }

  @Test("a Claude on an added machine opens its own transcript, read on that machine")
  func readerResolvesAndReads() async throws {
    let stream = machine(Self.host)
    let pane = claudePane()
    let run = try #require(control(stream).commandRunner(forPane: pane.id))
    let reader = TranscriptReader(run: run, machine: "box")

    let source = try #require(try await reader.resolve(for: pane).source)
    #expect(source.provenance == .reportedByHerdr(sessionID: Self.sessionID))
    #expect(source.file.name == "\(Self.sessionID).jsonl")
    let transcript = try await reader.read(source.file)
    #expect(transcript.turns.count == 2)

    let execs = try stream.params(of: "machine.exec")
    #expect(execs.count >= 2)
    #expect(execs.allSatisfy { $0["on"] as? String == "box" })
  }

  @Test("a machine that cannot answer falls back to the notice, with no error")
  func machineDoesNotAnswer() async throws {
    let reader = TranscriptReader(
      run: try runner(answering(.error("unavailable"))), machine: "box")
    let resolution = try await reader.resolve(for: claudePane())
    #expect(resolution == .absent(.agentOnAddedMachine(agent: "Claude", machine: "box")))
  }

  @Test("a reader bound to one machine refuses a pane on another, with no round trip")
  func otherMachine() async throws {
    let stream = machine(Self.host)
    let reader = TranscriptReader(run: try runner(stream), machine: "box")
    let resolution = try await reader.resolve(for: claudePane(machine: "nas"))
    #expect(resolution == .absent(.noRouteToMachine(agent: "Claude", machine: "nas")))
    #expect(try await reader.probeReportedSession(for: claudePane(machine: "nas")) == nil)
    #expect(stream.calls(of: "machine.exec") == 0)
  }
}
