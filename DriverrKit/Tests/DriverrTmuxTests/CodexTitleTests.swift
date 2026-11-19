import DriverrCore
import Testing

@testable import DriverrTmux

@Suite("CodexTitle")
struct CodexTitleTests {
  @Test("both frames of the Action Required blink are blocked", arguments: [
    "[ ! ] Action Required | driverr",
    "[ . ] Action Required | driverr",
    "● [ ! ] Action Required | driverr",
    "[ ! ] Action Required",
  ])
  func blocked(title: String) {
    #expect(CodexTitle.status(of: title) == .blocked)
  }

  @Test("a braille spinner frame in front is working", arguments: [
    "⠋ driverr", "⠙ driverr", "⠏ driverr", "⠸",
  ])
  func working(title: String) {
    #expect(CodexTitle.status(of: title) == .working)
  }

  @Test("anything else is idle", arguments: [
    "driverr", "", "Action Required", "[ ? ] Action Required", "my /title", "✳ Claude Code",
    "x ⠋ driverr",
  ])
  func idle(title: String) {
    #expect(CodexTitle.status(of: title) == .idle)
  }

  @Test("the display form drops the marker, so the label is the same in both blink frames")
  func displayBlocked() {
    #expect(CodexTitle.display("[ ! ] Action Required | driverr") == "driverr")
    #expect(CodexTitle.display("[ . ] Action Required | driverr") == "driverr")
    #expect(CodexTitle.display("● [ ! ] Action Required | driverr") == "driverr")
    #expect(CodexTitle.display("[ ! ] Action Required") == "")
  }

  /// The titles one real turn produced on codex 0.164.0 in a folder named `work`: idle, working
  /// once Codex named the thread, and idle again. The approval prompt was not reached, so the
  /// blocked form here is the source-derived marker in front of the same rest.
  @Test("the measured titles keep one label through every state")
  func measured() {
    #expect(CodexTitle.status(of: "work") == .idle)
    #expect(CodexTitle.status(of: "⠧ work") == .working)
    #expect(CodexTitle.status(of: "⠏ Create probe.txt | work") == .working)
    #expect(CodexTitle.status(of: "Create probe.txt | work") == .idle)
    for title in [
      "⠏ Create probe.txt | work", "Create probe.txt | work",
      "[ ! ] Action Required | Create probe.txt | work",
      "[ . ] Action Required | Create probe.txt | work",
    ] {
      #expect(CodexTitle.display(title) == "Create probe.txt | work", "\(title)")
    }
  }

  @Test("the display form drops a spinner frame, and leaves any other title alone")
  func displayOther() {
    #expect(CodexTitle.display("⠋ driverr") == "driverr")
    #expect(CodexTitle.display("driverr") == "driverr")
    #expect(CodexTitle.display("my | title") == "my | title")
  }
}
