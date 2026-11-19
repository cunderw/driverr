import DriverrCore
import DriverrHerdr
import Foundation
import Testing

@testable import DriverrHC

/// A core starts an agent as a labelled shell the desktop app adopts, and types the agent's
/// command into it. Measured on #97 with a sandboxed app: a terminal with a new `herdr.space`
/// joins the window as a new space named after its folder, whether the window was open then
/// or opened later. `herdr-app do space.new` needs an open window, so it is not used.
@Suite("Core agent launch", .timeLimit(.minutes(1)))
struct CoreAgentLaunchTests {
  private let launch = AgentLaunch(kind: .claude, directory: "~/my app", prompt: "fix it")

  private func control(_ stream: FakeCoreStream) -> CoreControl {
    CoreControl(binaryPath: "hc", home: "/home/me", open: { _ in stream })
  }

  /// A core where the folder is `folder`, or is not there when `nil`.
  private func core(folder: String? = "/srv/my app") -> FakeCoreStream {
    let stream = FakeCoreStream()
    stream.exec = { _, _ in
      guard let folder else {
        return .result(FakeCoreStream.executed(stderr: "cd: no such file\n", code: 2))
      }
      return .result(FakeCoreStream.executed(stdout: "\ndriverr-agent-folder\n\(folder)\n"))
    }
    stream.replies["terminal.run"] = .result(#"{"address":"t9"}"#)
    stream.replies["terminal.attach"] = .result(FakeCoreStream.attached(channel: 3, pasteGap: 1))
    return stream
  }

  /// What was typed through the viewer, in writes.
  private func typed(on stream: FakeCoreStream) async throws -> [String] {
    try await waitUntil("the CLOSE") { stream.streamFrames.last?.kind == .close }
    let frames = stream.streamFrames
    #expect(frames.dropLast().allSatisfy { $0.kind == .data && $0.channel == 3 })
    return frames.dropLast().map { String(decoding: $0.payload, as: UTF8.self) }
  }

  @Test("a core can start an agent")
  func canStart() {
    #expect(control(FakeCoreStream()).canStartAgent)
  }

  @Test("the folder is resolved on the core's machine, a labelled shell opens there, and the agent is typed into it")
  func commandsSent() async throws {
    let stream = core()
    let id = try await control(stream).startAgent(launch)

    #expect(id == "core:t9")
    #expect(stream.methods == ["machine.exec", "terminal.run", "terminal.attach"])

    let exec = try #require(try stream.params(of: "machine.exec").first)
    #expect(exec["line"] as? String == AgentLaunch.resolveCommand(for: "~/my app"))
    #expect(exec["on"] == nil, "the core's own machine, which is the SSH host")

    let run = try #require(try stream.params(of: "terminal.run").first)
    #expect(run["argv"] as? [String] == [], "the machine's login shell")
    #expect(run["cwd"] as? String == "/srv/my app")
    #expect(run["keep"] as? Bool == true)
    #expect(run["on"] == nil)
    let labels = try #require(run["labels"] as? [String: String])
    #expect(Set(labels.keys) == ["herdr.space", "herdr.seen"])
    #expect(labels["herdr.seen"] == "0")
    let space = try #require(labels["herdr.space"])
    // The app's own form, as `herdr-app ls` showed one: `sp` and 32 hex digits.
    #expect(space.count == 34 && space.hasPrefix("sp"))
    #expect(space.dropFirst(2).allSatisfy { $0.isHexDigit && !$0.isUppercase })

    let attach = try #require(try stream.params(of: "terminal.attach").first)
    #expect(attach["terminal"] as? String == "t9")
    #expect(try await typed(on: stream) == ["claude -- 'fix it'", "\r"])
  }

  @Test("each start is a new space")
  func newSpaceEachTime() async throws {
    let stream = core()
    let control = control(stream)
    _ = try await control.startAgent(launch)
    _ = try await control.startAgent(launch)
    let spaces = try stream.params(of: "terminal.run").compactMap {
      ($0["labels"] as? [String: String])?["herdr.space"]
    }
    #expect(spaces.count == 2)
    #expect(Set(spaces).count == 2)
  }

  /// A missing `cwd` is `spawn_failed` on a core, so this is also what keeps that message off
  /// the screen.
  @Test("a folder that is not there opens nothing")
  func badFolder() async {
    let stream = core(folder: nil)
    await #expect(throws: AppError.directoryUnavailable(path: "~/my app")) {
      try await control(stream).startAgent(launch)
    }
    #expect(stream.methods == ["machine.exec"])
  }

  @Test("a shell the core refuses to start opens nothing, and says so in the core's words")
  func spawnRefused() async {
    let stream = core()
    stream.replies["terminal.run"] = .error("spawn_failed")
    await #expect(throws: AppError.herdrCommandFailed(reason: "spawn_failed")) {
      try await control(stream).startAgent(launch)
    }
    #expect(stream.calls(of: "terminal.attach") == 0)
  }

  @Test("a shell that opened and could not be typed into stays open, and is named")
  func halfFailure() async {
    let stream = core()
    stream.replies["terminal.attach"] = .error("not_found")
    await #expect(
      throws: AppError.agentDidNotStart(
        paneID: "core:t9", place: "my app",
        reason: AppError.herdrCommandFailed(reason: "not_found").localizedDescription)
    ) {
      try await control(stream).startAgent(launch)
    }
    #expect(stream.calls(of: "terminal.kill") == 0, "the shell stays")
  }

  @Test("a message too long to type is refused before the core is asked anything")
  func tooLong() async {
    let stream = core()
    let long = AgentLaunch(kind: .codex, directory: "/srv", prompt: String(repeating: "x", count: 2000))
    await #expect(throws: AppError.agentPromptTooLong) { try await control(stream).startAgent(long) }
    #expect(stream.calls(of: "machine.exec") == 0)
    #expect(stream.calls(of: "terminal.run") == 0)
  }
}
