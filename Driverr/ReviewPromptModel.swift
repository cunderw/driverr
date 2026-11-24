import DriverrCore
import Foundation
import Observation

/// Keeps the App Store rating rule's ledger in `UserDefaults`, and says when a request waits.
///
/// The rule is `DriverrCore.ReviewPrompt`. This object only persists its ledger and holds the
/// answer until `ContentView` can call the system's `requestReview`. The pending request is
/// in memory only: an app that dies before it is delivered skips that version's request,
/// because the version is already recorded.
@MainActor
@Observable
final class ReviewPromptModel {
  /// A rating request waits for `ContentView` to deliver it.
  private(set) var isRequestPending = false

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let arguments: [String]
  @ObservationIgnored private let appVersion: String?

  /// Namespaced, because `UserDefaults.standard` is shared with the other stores.
  static let ledgerKey = "com.cunderw.driverr.reviewPrompt"

  /// - Parameters:
  ///   - suiteName: `nil` in the app. Takes a name, not an instance, as
  ///     `UserDefaultsLastPaneStore` does, so a test can use a throwaway suite.
  ///   - arguments: The launch arguments, so a UI-test launch neither counts nor asks.
  ///   - appVersion: `CFBundleShortVersionString`. With none, nothing ever asks.
  init(suiteName: String?, arguments: [String], appVersion: String?) {
    defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    self.arguments = arguments
    self.appVersion = appVersion
  }

  /// Counts one reply that reached a blocked agent, and marks a request pending when the rule
  /// says so. A UI-test launch writes nothing.
  func replyReachedBlockedAgent() {
    guard !ReviewPrompt.isUITestLaunch(arguments) else { return }
    var ledger = storedLedger()
    let shouldAsk = ReviewPrompt.replyReachedBlockedAgent(
      &ledger, appVersion: appVersion, arguments: arguments)
    if let data = try? JSONEncoder().encode(ledger) {
      defaults.set(data, forKey: Self.ledgerKey)
    }
    if shouldAsk { isRequestPending = true }
  }

  /// The request reached the system. Whether a sheet showed is the system's choice.
  func requestDelivered() {
    isRequestPending = false
  }

  /// An absent or undecodable value starts a fresh ledger.
  private func storedLedger() -> ReviewPromptLedger {
    guard let data = defaults.data(forKey: Self.ledgerKey),
      let ledger = try? JSONDecoder().decode(ReviewPromptLedger.self, from: data)
    else { return ReviewPromptLedger() }
    return ledger
  }
}
