import Testing
@testable import DriverrCore

@Suite("CommandResult")
struct CommandResultTests {
  @Test("succeeded is true only for exit status zero")
  func succeededOnZero() {
    let ok = CommandResult(standardOutput: "hi\n", standardError: "", exitStatus: 0)
    #expect(ok.succeeded)
  }

  @Test("a non-zero exit status is a failure even with output on stdout")
  func failsOnNonZero() {
    let bad = CommandResult(standardOutput: "partial\n", standardError: "boom", exitStatus: 1)
    #expect(!bad.succeeded)
  }

  @Test("trimmedOutput strips the trailing newline shells always add")
  func trimsTrailingNewline() {
    let result = CommandResult(standardOutput: "/home/carson\n", standardError: "", exitStatus: 0)
    #expect(result.trimmedOutput == "/home/carson")
  }
}
