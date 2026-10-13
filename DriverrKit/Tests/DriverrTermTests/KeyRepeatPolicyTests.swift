import Foundation
import Testing

@testable import DriverrTerm

/// A scheduler that banks its work, so cadence is a value the test controls. Kept separate
/// from `FocusRetryPolicyTests`' copy, because the two policies have no reason to move
/// together.
@MainActor
private final class ManualScheduler {
  private(set) var pending: [(delay: Duration, work: () -> Void)] = []

  var schedule: KeyRepeatPolicy.Scheduler {
    { [weak self] delay, work in
      self?.pending.append((delay, work))
    }
  }

  /// Runs the oldest banked closure. Returns false when there was nothing to run.
  @discardableResult
  func fireNext() -> Bool {
    guard !pending.isEmpty else { return false }
    pending.removeFirst().work()
    return true
  }

  func fireAll(limit: Int = 20) {
    var fired = 0
    while fired < limit, fireNext() { fired += 1 }
  }
}

/// A key that never repeats is a bug, and a repeat that outlives its keypress is worse: it
/// deletes work the user meant to keep.
@MainActor
@Suite("KeyRepeatPolicy")
struct KeyRepeatPolicyTests {
  private static let delay: Duration = .milliseconds(600)
  private static let interval: Duration = .milliseconds(100)

  private func makePolicy(_ scheduler: ManualScheduler) -> KeyRepeatPolicy {
    KeyRepeatPolicy(delay: Self.delay, interval: Self.interval, schedule: scheduler.schedule)
  }

  /// Sending on the way up would make the first character of a hold look dropped.
  @Test("a press sends once immediately, and not again before the delay")
  func sendsOnceOnPress() {
    let scheduler = ManualScheduler()
    let policy = makePolicy(scheduler)
    var sent = 0

    policy.begin { sent += 1 }

    #expect(sent == 1)
    #expect(scheduler.pending.count == 1, "a held key must have its first repeat armed")
    #expect(scheduler.pending.first?.delay == Self.delay)
  }

  @Test("the first repeat waits the delay and every repeat after it waits the interval")
  func delayThenInterval() {
    let scheduler = ManualScheduler()
    let policy = makePolicy(scheduler)
    var sent = 0

    policy.begin { sent += 1 }
    var waits: [Duration] = []

    for _ in 0..<4 {
      waits.append(scheduler.pending.first!.delay)
      scheduler.fireNext()
    }

    #expect(waits == [Self.delay, Self.interval, Self.interval, Self.interval])
    #expect(sent == 5, "one on the press, then one per tick")
  }

  @Test("a held key keeps repeating for as long as it is held")
  func repeatsWhileHeld() {
    let scheduler = ManualScheduler()
    let policy = makePolicy(scheduler)
    var sent = 0

    policy.begin { sent += 1 }
    for _ in 0..<12 { scheduler.fireNext() }

    #expect(sent == 13)
  }

  /// Down and up inside the delay, the common case.
  @Test("releasing before the first repeat sends exactly once")
  func tapSendsOnce() {
    let scheduler = ManualScheduler()
    let policy = makePolicy(scheduler)
    var sent = 0

    policy.begin { sent += 1 }
    policy.stop()
    scheduler.fireAll()

    #expect(sent == 1, "a tap must not become a repeat because a banked tick ran late")
  }

  /// Release, slide-off, cancellation, the keyboard going away and backgrounding all arrive as
  /// `stop()`, and none may leave a tick armed.
  @Test("stopping mid-repeat stops it at once, with nothing left armed")
  func stopMidRepeat() {
    let scheduler = ManualScheduler()
    let policy = makePolicy(scheduler)
    var sent = 0

    policy.begin { sent += 1 }
    scheduler.fireNext()
    scheduler.fireNext()
    #expect(sent == 3)

    policy.stop()
    let afterStop = sent
    scheduler.fireAll()

    #expect(sent == afterStop, "a stopped repeat must not fire again")
  }

  /// A finger sliding from ← to → without lifting. Two live repeats would send both
  /// directions.
  @Test("a second press supersedes the first rather than racing it")
  func beginSupersedes() {
    let scheduler = ManualScheduler()
    let policy = makePolicy(scheduler)
    var left = 0
    var right = 0

    policy.begin { left += 1 }
    policy.begin { right += 1 }
    scheduler.fireAll()

    #expect(left == 1, "the superseded key must stop at its own press")
    #expect(right > 1, "the new key must be the one repeating")
  }

  @Test("stopping when nothing is held is harmless")
  func stopWithoutBegin() {
    let scheduler = ManualScheduler()
    let policy = makePolicy(scheduler)
    var sent = 0

    policy.stop()
    policy.begin { sent += 1 }

    #expect(sent == 1)
    #expect(scheduler.pending.count == 1)
  }
}
