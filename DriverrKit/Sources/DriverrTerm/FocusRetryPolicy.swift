import Foundation

/// Ask for the keyboard; if refused, ask again for a moment, then say so.
///
/// Kept out of UIKit so `swift test` can drive it. The clock is a closure, so a test fires
/// the schedule by hand.
///
/// - Bounded: one immediate ask plus one per delay.
/// - Cancellable: a retry in flight after the hide-keyboard key would take the keyboard
///   back.
/// - Reports failure: running out calls `onExhausted`, so a refusal is logged.
@MainActor
public final class FocusRetryPolicy {
  /// Runs `work` after `delay`. Production uses `DispatchQueue.main.asyncAfter`, and a
  /// test banks the work.
  public typealias Scheduler = @MainActor (Duration, @escaping @MainActor () -> Void) -> Void

  /// Five asks spread over about 1.85 s.
  ///
  /// Front-loaded, because the usual cause is a presentation of a few hundred ms still in
  /// flight. The tail is short, because a longer retry would hide a different fault.
  public static let defaultDelays: [Duration] = [
    .milliseconds(100),
    .milliseconds(250),
    .milliseconds(500),
    .milliseconds(1000),
  ]

  private let delays: [Duration]
  private let schedule: Scheduler

  /// Which run of the schedule is the live one.
  ///
  /// A banked closure cannot be unscheduled, so it checks this and does nothing if it was
  /// superseded or cancelled.
  private var generation = 0

  public init(
    delays: [Duration] = FocusRetryPolicy.defaultDelays,
    schedule: @escaping Scheduler = FocusRetryPolicy.mainQueueScheduler
  ) {
    self.delays = delays
    self.schedule = schedule
  }

  public static let mainQueueScheduler: Scheduler = { delay, work in
    DispatchQueue.main.asyncAfter(deadline: .now() + delay.seconds) {
      MainActor.assumeIsolated(work)
    }
  }

  /// Ask now, and keep asking on the schedule until granted or out of tries.
  ///
  /// - Parameters:
  ///   - attempt: asks for focus and reports whether it was granted.
  ///   - onExhausted: every ask was refused; the argument is how many were made.
  public func begin(
    attempt: @escaping @MainActor () -> Bool,
    onExhausted: @escaping @MainActor (Int) -> Void
  ) {
    generation += 1
    ask(attempt: attempt, onExhausted: onExhausted, next: 0, made: 0, generation: generation)
  }

  /// Call the schedule off. Anything already banked becomes a no-op.
  public func cancel() {
    generation += 1
  }

  private func ask(
    attempt: @escaping @MainActor () -> Bool,
    onExhausted: @escaping @MainActor (Int) -> Void,
    next: Int,
    made: Int,
    generation: Int
  ) {
    guard generation == self.generation else { return }
    let made = made + 1
    if attempt() { return }
    guard next < delays.count else {
      onExhausted(made)
      return
    }
    schedule(delays[next]) { [weak self] in
      self?.ask(
        attempt: attempt,
        onExhausted: onExhausted,
        next: next + 1,
        made: made,
        generation: generation
      )
    }
  }
}

extension Duration {
  /// `Duration` to the `TimeInterval` `DispatchQueue` wants. Shared with `KeyRepeatPolicy`.
  var seconds: Double {
    let (whole, attoseconds) = components
    return Double(whole) + Double(attoseconds) / 1e18
  }
}
