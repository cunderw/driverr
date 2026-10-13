import Foundation
import Testing

@testable import DriverrCore

/// The hook catalog, and the checksum the install's compare-and-swap relies on.
@Suite("Agent hook catalog")
struct AgentHookCatalogTests {
  /// Verified live on Claude Code 2.1.282. This text runs on every host, so a change needs
  /// verifying again.
  @Test("the AskUserQuestion hook's command is the measured one")
  func askUserQuestionCommand() {
    let hook = AgentHook.claudeAskUserQuestion
    #expect(hook.command == "cat >/dev/null # driverr:claude.ask-user-question:v1")
    #expect(hook.event == "PreToolUse")
    #expect(hook.matcher == "AskUserQuestion")
    #expect(hook.marker == "driverr:claude.ask-user-question:v")
  }

  @Test("the catalog holds Claude Code under herdr's token, with its one hook")
  func catalog() {
    #expect(AgentIntegration.catalog.map(\.agent) == ["claude"])
    #expect(AgentIntegration.forAgent("Claude") == .claudeCode)
    #expect(AgentIntegration.forAgent("codex") == nil)
    #expect(AgentIntegration.claudeCode.hooks == [.claudeAskUserQuestion])
    #expect(AgentIntegration.claudeCode.format == .claudeCodeJSON)
  }

  /// A hook set version lower than one of its hooks' would never offer that hook's update.
  @Test("every integration's version is at least each of its hooks' versions, and hook ids are unique")
  func versionsAndIds() {
    for integration in AgentIntegration.catalog {
      #expect(integration.hooks.allSatisfy { $0.version <= integration.version })
      #expect(Set(integration.hooks.map(\.id)).count == integration.hooks.count)
      #expect(integration.hooks.allSatisfy { $0.command.hasSuffix("# \($0.marker)\($0.version)") })
    }
  }

  /// Values printed by `/usr/bin/cksum`.
  @Test(
    "the checksum matches POSIX cksum",
    arguments: [
      ("", UInt32(4_294_967_295)),
      ("a", 1_220_704_766),
      ("hello\n", 3_015_617_425),
      ("{\n  \"x\": 1\n}\n", 565_515_344),
    ]
  )
  func checksum(input: String, crc: UInt32) {
    let sum = POSIXChecksum(of: input.utf8)
    #expect(sum.crc == crc)
    #expect(sum.byteCount == input.utf8.count)
    #expect(sum.text == "\(crc) \(input.utf8.count)")
  }
}
