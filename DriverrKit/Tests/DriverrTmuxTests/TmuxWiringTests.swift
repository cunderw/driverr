import DriverrCore
import DriverrHerdr
import Foundation
import Testing

@testable import DriverrTmux

/// What a tmux host says about itself once it is wired into the app beside herdr.
@Suite("TmuxControl wiring")
struct TmuxWiringTests {
  @Test("a ready tmux is not a ready herdr, and says tmux")
  func readyIsNotHerdr() async {
    let control = TmuxControl(run: FakeTmuxHost(version: "tmux 3.7c").runner)
    let availability = await control.availability()
    #expect(availability.isReady)
    #expect(availability.message == "tmux 3.7c")
    #expect(!availability.message.contains("herdr"))
    // herdr's own case carries a protocol number, which tmux does not speak.
    if case .ready = availability {
      Issue.record("A tmux host must not answer herdr's .ready: \(availability)")
    }
  }

  @Test("each tmux no names tmux and not herdr")
  func problemsSayTmux() async {
    let old = await TmuxControl(run: FakeTmuxHost(version: "tmux 2.7").runner).availability()
    let none = await TmuxControl(run: FakeTmuxHost(version: nil).runner).availability()
    let odd = await TmuxControl(run: FakeTmuxHost(version: "tmux openbsd-7.4").runner)
      .availability()
    for answer in [old, none, odd] {
      #expect(!answer.isReady)
      #expect(answer.message.contains("tmux"), "\(answer)")
      #expect(!answer.message.contains("herdr"), "\(answer)")
    }
    #expect(old.message.contains("2.7"))
    #expect(old.message.contains(TmuxVersion.minimum.text))
  }

  @Test("a missing tmux binary is a tmux error, not a herdr one")
  func missingBinaryNamesTmux() async throws {
    let control = TmuxControl(run: { _ in
      CommandResult(standardOutput: "", standardError: "sh: tmux: command not found", exitStatus: 127)
    })
    let error = await #expect(throws: AppError.self) { try await control.snapshot() }
    let description = try #require(error?.errorDescription)
    #expect(description.contains("tmux"))
    #expect(!description.contains("herdr"))
    #expect(error?.isRetryable == false)
  }

  @Test("no tmux pane opens a terminal until the live terminal lands")
  func noTerminalYet() async throws {
    let control = TmuxControl(binaryPath: "/opt/homebrew/bin/tmux", run: FakeTmuxHost.seeded().runner)
    let pane = try #require(try await control.snapshot().pane(id: "tmux:%3"))
    // `attach-session` shows the session's current pane, not this one, so there is no command.
    #expect(control.attachCommand(for: pane) == nil)
    #expect(control.paneAttacher(for: pane.id) == nil)
    // A started window could not be shown either.
    #expect(!control.canStartTerminal)
  }
}
