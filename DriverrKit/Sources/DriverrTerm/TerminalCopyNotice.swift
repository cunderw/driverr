import Foundation
import Observation

/// Whether the terminal should say that a Copy happened.
///
/// SwiftTerm clears the selection on copy, so a Copy looks the same as a dismissed menu.
/// `isShowing` goes back to `false` after `duration`. The clock is a closure, so a test
/// fires the hide by hand.
@MainActor
@Observable
public final class TerminalCopyNotice {
  /// Runs `work` after `delay`. See `FocusRetryPolicy.Scheduler`.
  public typealias Scheduler = FocusRetryPolicy.Scheduler

  /// Long enough to read four words, short enough not to sit over the top rows.
  public static let defaultDuration: Duration = .seconds(2)

  /// The words drawn and the words VoiceOver announces, the same for both.
  public static let text = "Copied to clipboard"

  public private(set) var isShowing = false

  private let duration: Duration
  @ObservationIgnored private let schedule: Scheduler
  /// Which hide is the live one. See `FocusRetryPolicy.generation`. The notice stays a
  /// full `duration` after the last Copy.
  @ObservationIgnored private var generation = 0

  public init(
    duration: Duration = TerminalCopyNotice.defaultDuration,
    schedule: @escaping Scheduler = FocusRetryPolicy.mainQueueScheduler
  ) {
    self.duration = duration
    self.schedule = schedule
  }

  /// A Copy put text on the pasteboard. Shows the notice and restarts its timer.
  public func copied() {
    generation += 1
    let generation = generation
    isShowing = true
    schedule(duration) { [weak self] in
      guard let self, generation == self.generation else { return }
      self.isShowing = false
    }
  }
}
