import DriverrCore
import DriverrHerdr
import Foundation
import Testing

@testable import DriverrHC

@Suite("Core discovery", .timeLimit(.minutes(1)))
struct CoreDiscoveryTests {
  private func answering(_ output: String) -> CommandRunner {
    { _ in CommandResult(standardOutput: output, standardError: "", exitStatus: 0) }
  }

  private func opening(_ stream: FakeCoreStream) -> StreamRunner {
    { _ in stream }
  }

  private let neverOpens: StreamRunner = { _ in
    Issue.record("nothing was found, so nothing should run")
    throw AppError.channelFailed(reason: "unexpected")
  }

  // MARK: - Choosing a path

  @Test("herdr-core beats hc, wherever each was printed")
  func preference() {
    let output = "/usr/bin/hc\n/home/me/.local/bin/herdr-core\n"
    #expect(CoreControl.discoveredPath(in: output) == "/home/me/.local/bin/herdr-core")
  }

  @Test("hc alone is found")
  func hcAlone() {
    #expect(CoreControl.discoveredPath(in: "/home/me/.local/bin/hc\n") == "/home/me/.local/bin/hc")
  }

  @Test("a banner, an alias and a function are not paths")
  func noise() {
    let output = "Welcome to hc\nalias hc='hc --json'\nhc\n/home/me/not-hc\n"
    #expect(CoreControl.discoveredPath(in: output) == nil)
  }

  @Test("nothing printed is nothing found")
  func nothing() {
    #expect(CoreControl.discoveredPath(in: "") == nil)
  }

  // MARK: - Finding home

  @Test("home is the last line, and only if it is absolute")
  func home() {
    #expect(CoreControl.discoveredHome(in: "/home/my user") == "/home/my user")
    #expect(CoreControl.discoveredHome(in: "Welcome to the box\n/home/me") == "/home/me")
    #expect(CoreControl.discoveredHome(in: "/home/me\n") == "/home/me")
    #expect(CoreControl.discoveredHome(in: "") == nil)
    #expect(CoreControl.discoveredHome(in: "~") == nil)
    #expect(CoreControl.discoveredHome(in: "/home/me\nnot a path") == nil)
  }

  private func answering(path: String, home: CommandResult?) -> CommandRunner {
    { command in
      guard command == CoreControl.homeCommand else {
        return CommandResult(standardOutput: path, standardError: "", exitStatus: 0)
      }
      guard let home else { throw AppError.channelFailed(reason: "gone") }
      return home
    }
  }

  @Test("discovery asks for home once and hands it to the control")
  func discoveredHome() async {
    let control = await CoreControl.discovering(
      run: answering(
        path: "/usr/bin/hc\n",
        home: CommandResult(standardOutput: "/home/me", standardError: "", exitStatus: 0)),
      open: opening(FakeCoreStream())
    )
    #expect(control?.home == "/home/me")
  }

  @Test("a host that will not say where home is still has a core")
  func noHome() async {
    let control = await CoreControl.discovering(
      run: answering(path: "/usr/bin/hc\n", home: nil),
      open: opening(FakeCoreStream())
    )
    #expect(control != nil)
    #expect(control?.home == nil)
  }

  // MARK: - The probe

  @Test("the probe asks all three tiers, for both names, herdr-core first")
  func command() throws {
    let command = CoreControl.discoveryCommand
    #expect(command.contains("command -v herdr-core 2>/dev/null"))
    #expect(command.contains(#"-lc 'command -v herdr-core; command -v hc'"#))
    for directory in CLIControl.fallbackDirectories {
      #expect(command.contains("\"\(directory)/herdr-core\""))
      #expect(command.contains("\"\(directory)/hc\""))
    }
    #expect(command.contains("$HOME/.local/bin/hc"))
    let herdrCore = try #require(command.range(of: "\"/opt/homebrew/bin/herdr-core\""))
    let hc = try #require(command.range(of: "\"/opt/homebrew/bin/hc\""))
    #expect(herdrCore.lowerBound < hc.lowerBound)
  }

  @Test("the probe runs, and finds a core where a login file would hide it", .enabled(if: Self.hasSh))
  func commandRuns() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    let bin = directory.appendingPathComponent(".local/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let hc = bin.appendingPathComponent("hc")
    try Data("#!/bin/sh\n".utf8).write(to: hc)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hc.path)

    // A bare PATH and no login shell to ask, so only the third tier can answer.
    let (status, output) = try await shell(
      CoreControl.discoveryCommand,
      environment: ["HOME": directory.path, "PATH": "/usr/bin:/bin", "SHELL": "/usr/bin/true"]
    )

    #expect(status == 0)
    #expect(CoreControl.discoveredPath(in: output) == hc.path)
  }

  /// Runs on a thread of its own. Waiting for a process blocks, and a test on the cooperative
  /// pool must never block. See `EmbeddedSSHServer`.
  private func shell(
    _ command: String,
    environment: [String: String]
  ) async throws -> (status: Int32, output: String) {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
          try process.run()
          let output = pipe.fileHandleForReading.readDataToEndOfFile()
          process.waitUntilExit()
          continuation.resume(
            returning: (process.terminationStatus, String(decoding: output, as: UTF8.self))
          )
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private static let hasSh = FileManager.default.isExecutableFile(atPath: "/bin/sh")

  // MARK: - Connecting

  @Test("a host with a core comes back connected")
  func found() async {
    let stream = FakeCoreStream()
    let control = await CoreControl.discovering(
      run: answering("/home/me/.local/bin/hc\n"),
      open: opening(stream)
    )
    #expect(control?.binaryPath == "/home/me/.local/bin/hc")
    #expect(await control?.availability() == .coreReady(version: "0.1.14"))
    // The same connection discovery opened: a second would be a second `hc connect`.
    #expect(stream.closes == 0)
  }

  @Test("a host with neither runs nothing")
  func absent() async {
    let control = await CoreControl.discovering(run: answering(""), open: neverOpens)
    #expect(control == nil)
  }

  @Test("a probe that fails is nothing found, not a failed host")
  func probeFails() async {
    let control = await CoreControl.discovering(
      run: { _ in throw AppError.channelFailed(reason: "gone") },
      open: neverOpens
    )
    #expect(control == nil)
  }

  @Test("another program called hc, which exits, is not a core")
  func stranger() async {
    let stream = FakeCoreStream()
    stream.helloReply = nil
    stream.banner = Data("hc: unknown command 'connect'\n".utf8)
    stream.exitsAfterHello = true
    let control = await CoreControl.discovering(
      run: answering("/usr/bin/hc\n"),
      open: opening(stream)
    )
    #expect(control == nil)
  }

  @Test("another program called hc, which hangs, costs only the call deadline")
  func hangingStranger() async throws {
    let stream = FakeCoreStream()
    stream.helloReply = nil
    let control = await CoreControl.discovering(
      run: answering("/usr/bin/hc\n"),
      open: opening(stream),
      callDeadline: .milliseconds(50)
    )
    #expect(control == nil)
    // The close is not awaited, on purpose, so it lands after the answer.
    try await waitUntil("the stream is let go") { stream.closes == 1 }
  }

  @Test("a core this build refuses comes back, because it has something to say")
  func refused() async {
    let stream = FakeCoreStream()
    stream.helloReply = FakeCoreStream.helloReply(generation: 2)
    let control = await CoreControl.discovering(
      run: answering("/usr/bin/hc\n"),
      open: opening(stream)
    )
    #expect(
      await control?.availability()
        == .coreIncompatible(version: "0.1.14", generation: 2, missingMethods: []))
  }

  @Test("a probe that never returns gives up at the deadline, which nothing else can")
  func deadline() async {
    let clock = ContinuousClock()
    let started = clock.now
    let control = await CoreControl.discovering(
      run: { _ in
        // Ignores cancellation, as nothing under an exec channel checks it.
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        return CommandResult(standardOutput: "", standardError: "", exitStatus: 0)
      },
      open: neverOpens,
      deadline: .milliseconds(50)
    )
    #expect(control == nil)
    #expect(clock.now - started < .seconds(5))
  }
}
