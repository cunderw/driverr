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

  @Test("the display form drops a spinner frame, and leaves any other title alone")
  func displayOther() {
    #expect(CodexTitle.display("⠋ driverr") == "driverr")
    #expect(CodexTitle.display("driverr") == "driverr")
    #expect(CodexTitle.display("my | title") == "my | title")
  }
}
