import DriverrCore
import Foundation
import Testing

@testable import Driverr

/// What the app keeps for the App Store rating rule. The rule itself is
/// `DriverrCoreTests.ReviewPromptTests`; this is the persistence and the pending request.
///
/// Each test takes a suite of its own and removes it, because Swift Testing runs tests in
/// parallel and has no teardown.
@MainActor
@Suite("ReviewPromptModel")
struct ReviewPromptModelTests {
  private func withSuite(_ body: (String) -> Void) {
    let suite = "com.cunderw.driverr.tests.reviewPrompt.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    body(suite)
  }

  @Test("the count survives a relaunch, so the third reply asks even across launches")
  func theCountSurvivesARelaunch() {
    withSuite { suite in
      let first = ReviewPromptModel(suiteName: suite, arguments: [], appVersion: "1.3")
      first.replyReachedBlockedAgent()
      first.replyReachedBlockedAgent()
      #expect(!first.isRequestPending)

      let relaunched = ReviewPromptModel(suiteName: suite, arguments: [], appVersion: "1.3")
      relaunched.replyReachedBlockedAgent()
      #expect(relaunched.isRequestPending)

      relaunched.requestDelivered()
      #expect(!relaunched.isRequestPending)

      let again = ReviewPromptModel(suiteName: suite, arguments: [], appVersion: "1.3")
      again.replyReachedBlockedAgent()
      #expect(!again.isRequestPending, "a version asked twice")
    }
  }

  @Test("a UI-test launch never marks a request pending and writes nothing")
  func uiTestsNeverAsk() {
    withSuite { suite in
      let model = ReviewPromptModel(
        suiteName: suite, arguments: ["-uiTesting", "-uiTestingConnected"], appVersion: "1.3")
      for _ in 0..<5 { model.replyReachedBlockedAgent() }

      #expect(!model.isRequestPending)
      #expect(UserDefaults(suiteName: suite)?.object(forKey: ReviewPromptModel.ledgerKey) == nil)
    }
  }
}
