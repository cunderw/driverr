import DriverrCore
import Testing

/// When Driverr asks for an App Store rating, as a rule on a value, so every case runs with
/// no StoreKit and no simulator.
@Suite("ReviewPrompt")
struct ReviewPromptTests {
  private let launch = ["/path/to/Driverr"]

  @Test("the first two replies to a blocked agent do not ask, and the third does")
  func asksOnTheThirdReply() {
    var ledger = ReviewPromptLedger()

    #expect(!ReviewPrompt.replyReachedBlockedAgent(&ledger, appVersion: "1.3", arguments: launch))
    #expect(!ReviewPrompt.replyReachedBlockedAgent(&ledger, appVersion: "1.3", arguments: launch))
    #expect(ReviewPrompt.replyReachedBlockedAgent(&ledger, appVersion: "1.3", arguments: launch))
    #expect(ledger == ReviewPromptLedger(replies: 3, lastPromptedVersion: "1.3"))
  }

  @Test("a version that has asked once does not ask again")
  func asksOncePerVersion() {
    var ledger = ReviewPromptLedger(replies: 3, lastPromptedVersion: "1.3")

    for _ in 0..<5 {
      #expect(
        !ReviewPrompt.replyReachedBlockedAgent(&ledger, appVersion: "1.3", arguments: launch))
    }
    #expect(ledger == ReviewPromptLedger(replies: 8, lastPromptedVersion: "1.3"))
  }

  @Test("a new version asks on its next reply, because the count is lifetime")
  func aNewVersionAsksAgain() {
    var ledger = ReviewPromptLedger(replies: 7, lastPromptedVersion: "1.3")

    #expect(ReviewPrompt.replyReachedBlockedAgent(&ledger, appVersion: "1.4", arguments: launch))
    #expect(ledger == ReviewPromptLedger(replies: 8, lastPromptedVersion: "1.4"))
    #expect(!ReviewPrompt.replyReachedBlockedAgent(&ledger, appVersion: "1.4", arguments: launch))
  }

  @Test(
    "a UI-test launch neither counts nor asks",
    arguments: [
      ["-uiTesting"],
      ["-uiTestingSeedHost"],
      ["-uiTesting", "-uiTestingConnected", "-uiTestingSlowTranscript"],
    ]
  )
  func uiTestsNeverAsk(flags: [String]) {
    let start = ReviewPromptLedger(replies: 2, lastPromptedVersion: "1.2")
    var ledger = start

    #expect(
      !ReviewPrompt.replyReachedBlockedAgent(
        &ledger, appVersion: "1.3", arguments: launch + flags))
    #expect(ledger == start)
    #expect(ReviewPrompt.isUITestLaunch(launch + flags))
  }

  @Test("an ordinary launch argument is not a UI test")
  func otherArgumentsStillCount() {
    let arguments = launch + ["-AppleLanguages", "(en)", "-NSDoubleLocalizedStrings", "YES"]
    var ledger = ReviewPromptLedger(replies: 2)

    #expect(!ReviewPrompt.isUITestLaunch(arguments))
    #expect(ReviewPrompt.replyReachedBlockedAgent(&ledger, appVersion: "1.3", arguments: arguments))
  }

  @Test("with no version to record, a reply counts and nothing asks")
  func noVersionNeverAsks() {
    var ledger = ReviewPromptLedger(replies: 5)

    #expect(!ReviewPrompt.replyReachedBlockedAgent(&ledger, appVersion: nil, arguments: launch))
    #expect(ledger == ReviewPromptLedger(replies: 6))
  }
}
