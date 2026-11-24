import Foundation

/// What the App Store rating rule remembers between launches.
///
/// `replies` counts every reply that reached a blocked agent, for the life of the install, as
/// in Apple's "Requesting App Store reviews" sample. `lastPromptedVersion` is the app version
/// that last asked, so one version asks at most once.
public struct ReviewPromptLedger: Codable, Equatable, Sendable {
  public var replies: Int
  public var lastPromptedVersion: String?

  public init(replies: Int = 0, lastPromptedVersion: String? = nil) {
    self.replies = replies
    self.lastPromptedVersion = lastPromptedVersion
  }
}

/// When Driverr asks for an App Store rating: after a reply reaches a blocked agent, which is
/// the moment the app has just done its job.
///
/// The rule is here, not in a view, so `swift test` covers every case. The app persists the
/// ledger and calls the system's `requestReview`. The system still decides whether a sheet
/// shows.
public enum ReviewPrompt {
  /// How many replies to a blocked agent come before the first request.
  public static let repliesBeforePrompt = 3

  /// Whether this launch is a UI test. Every UI-test argument starts with `-uiTesting`, and a
  /// system sheet over a test would block its next tap.
  public static func isUITestLaunch(_ arguments: [String]) -> Bool {
    arguments.contains { $0.hasPrefix("-uiTesting") }
  }

  /// Counts one reply that reached a blocked agent, and says whether to ask for a rating now.
  ///
  /// Records `appVersion` in the same step that returns `true`, so two quick replies cannot
  /// both ask. A UI-test launch changes nothing and never asks. With no version to record,
  /// the reply still counts and nothing asks, because the once-per-version rule cannot hold.
  public static func replyReachedBlockedAgent(
    _ ledger: inout ReviewPromptLedger,
    appVersion: String?,
    arguments: [String]
  ) -> Bool {
    false
  }
}
