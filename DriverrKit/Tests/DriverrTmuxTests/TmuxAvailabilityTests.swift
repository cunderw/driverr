import DriverrCore
import Testing

@testable import DriverrTmux

@Suite("TmuxAvailability")
struct TmuxAvailabilityTests {
  @Test(
    "the version in tmux -V's output",
    arguments: [
      ("tmux 3.7c\n", 3, 7), ("tmux 3.2\n", 3, 2), ("tmux 3.4-rc\n", 3, 4),
      ("tmux next-3.5\n", 3, 5), ("tmux 2.7\n", 2, 7), ("tmux 10.12a", 10, 12),
    ])
  func parses(output: String, major: Int, minor: Int) throws {
    let version = try #require(TmuxVersion.parse(output))
    #expect(version.major == major)
    #expect(version.minor == minor)
  }

  @Test("master is newer than any number")
  func master() throws {
    let version = try #require(TmuxVersion.parse("tmux master\n"))
    #expect(version >= TmuxVersion.minimum)
    #expect(version > TmuxVersion(major: 99, minor: 99, text: "99.99"))
  }

  @Test(
    "output that names no version is not guessed at",
    arguments: ["", "tmux", "tmux openbsd-7.4", "tmux 3", "3.7c", "screen 3.7", "tmux a.b", "usage: tmux"]
  )
  func unreadable(output: String) {
    #expect(TmuxVersion.parse(output) == nil)
  }

  @Test("the floor is 3.2, inclusive")
  func floor() {
    func availability(_ out: String) -> TmuxAvailability {
      .from(CommandResult(standardOutput: out, standardError: "", exitStatus: 0))
    }
    #expect(availability("tmux 3.2\n") == .ready(version: "3.2"))
    #expect(availability("tmux 3.1c\n") == .tooOld(version: "3.1c"))
    #expect(availability("tmux 2.7\n") == .tooOld(version: "2.7"))
    #expect(availability("tmux 3.7c\n") == .ready(version: "3.7c"))
    #expect(availability("tmux 4.0\n") == .ready(version: "4.0"))
    #expect(availability("hello\n") == .unreadable)
  }

  @Test("a missing tmux is not installed, whichever way the shell says so")
  func missing() {
    let by127 = CommandResult(standardOutput: "", standardError: "", exitStatus: 127)
    let byMessage = CommandResult(
      standardOutput: "", standardError: "sh: tmux: command not found", exitStatus: 1)
    #expect(TmuxAvailability.from(by127) == .notInstalled)
    #expect(TmuxAvailability.from(byMessage) == .notInstalled)
  }

  @Test("a failing -V is unreadable, not installed")
  func failingVersion() {
    let result = CommandResult(standardOutput: "", standardError: "boom", exitStatus: 1)
    #expect(TmuxAvailability.from(result) == .unreadable)
  }

  @Test("only a usable tmux is ready, and each no has its own words")
  func messages() {
    #expect(TmuxAvailability.ready(version: "3.7c").isReady)
    #expect(!TmuxAvailability.notInstalled.isReady)
    #expect(!TmuxAvailability.tooOld(version: "2.7").isReady)
    #expect(!TmuxAvailability.unreadable.isReady)
    #expect(TmuxAvailability.ready(version: "3.7c").message == "tmux 3.7c")
    #expect(TmuxAvailability.tooOld(version: "2.7").message.contains("2.7"))
    #expect(TmuxAvailability.tooOld(version: "2.7").message.contains("3.2"))
    #expect(TmuxAvailability.notInstalled.message.contains("isn't installed"))
  }

  @Test("the control asks tmux -V and answers in both vocabularies")
  func control() async {
    let host = FakeTmuxHost(version: "tmux 3.7c")
    let control = TmuxControl(run: host.runner)
    #expect(await control.tmuxAvailability() == .ready(version: "3.7c"))
    #expect(await control.availability().isReady)
    #expect(await host.commands == ["tmux -u -V", "tmux -u -V"], "one -V for each question")

    let old = TmuxControl(run: FakeTmuxHost(version: "tmux 2.7").runner)
    #expect(await old.tmuxAvailability() == .tooOld(version: "2.7"))
    #expect(await !old.availability().isReady)

    let none = TmuxControl(run: FakeTmuxHost(version: nil).runner)
    #expect(await none.tmuxAvailability() == .notInstalled)
    #expect(await none.availability() == .tmuxNotInstalled)
  }

  @Test("a transport that throws is not installed")
  func throwing() async {
    let control = TmuxControl(run: { _ in throw AppError.notConnected(host: "box") })
    #expect(await control.tmuxAvailability() == .notInstalled)
  }
}
