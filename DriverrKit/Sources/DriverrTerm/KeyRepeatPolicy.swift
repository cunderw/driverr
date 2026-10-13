import Foundation

/// Hold a key down and it keeps sending; let go and it stops at once.
///
/// Kept out of UIKit for the reason in `FocusRetryPolicy`.
///
/// **A repeat that outlives its keypress destroys work.** So it stops on an event, never
/// on a timeout. `stop()` is called from every way a press can end, and a tick already
/// banked checks `generation` and does nothing.
@MainActor
public final class KeyRepeatPolicy {
  /// See `FocusRetryPolicy.Scheduler`.
  public typealias Scheduler = @MainActor (Duration, @escaping @MainActor () -> Void) -> Void

  /// SwiftTerm's own accessory cadence: 0.6 s, then 0.1 s. iOS does not expose the user's
  /// key-repeat setting to apps.
  ///
  /// The system keyboard's keys keep the platform's own repeat and do not use this.
  public static let defaultDelay: Duration = .milliseconds(600)
  public static let defaultInterval: Duration = .milliseconds(100)

  private let delay: Duration
  private let interval: Duration
  private let schedule: Scheduler

  /// Which press is the live one. See `FocusRetryPolicy.generation`.
  private var generation = 0

  public init(
    delay: Duration = KeyRepeatPolicy.defaultDelay,
    interval: Duration = KeyRepeatPolicy.defaultInterval,
    schedule: @escaping Scheduler = KeyRepeatPolicy.mainQueueScheduler
  ) {
    self.delay = delay
    self.interval = interval
    self.schedule = schedule
  }

  public static let mainQueueScheduler: Scheduler = { delay, work in
    DispatchQueue.main.asyncAfter(deadline: .now() + delay.seconds) {
      MainActor.assumeIsolated(work)
    }
  }

  /// The key went down: send now, and keep sending until `stop()`.
  ///
  /// Sending on the way down makes the first character of a hold arrive on time.
  public func begin(_ fire: @escaping @MainActor () -> Void) {
    generation += 1
    let generation = generation
    fire()
    schedule(delay) { [weak self] in
      self?.tick(fire, generation: generation)
    }
  }

  /// The press ended, by any route. Anything already banked becomes a no-op.
  public func stop() {
    generation += 1
  }

  private func tick(_ fire: @escaping @MainActor () -> Void, generation: Int) {
    guard generation == self.generation else { return }
    fire()
    schedule(interval) { [weak self] in
      self?.tick(fire, generation: generation)
    }
  }
}
