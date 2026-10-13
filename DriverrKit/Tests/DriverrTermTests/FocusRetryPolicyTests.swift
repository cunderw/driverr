import Foundation
import Testing

@testable import DriverrTerm

/// A scheduler that banks its work, so time is a value the test controls rather than
/// waits out.
@MainActor
private final class ManualScheduler {
  private(set) var pending: [(delay: Duration, work: () -> Void)] = []

  var schedule: FocusRetryPolicy.Scheduler {
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
    while fireNext(), fired < limit { fired += 1 }
  }
}

@MainActor
@Suite("FocusRetryPolicy")
struct FocusRetryPolicyTests {
  private static let delays: [Duration] = [.milliseconds(10), .milliseconds(20), .milliseconds(30)]

  private func makePolicy(_ scheduler: ManualScheduler) -> FocusRetryPolicy {
    FocusRetryPolicy(delays: Self.delays, schedule: scheduler.schedule)
  }

  @Test("a request that is granted at once is not asked again")
  func grantedFirstTime() {
    let scheduler = ManualScheduler()
    let policy = makePolicy(scheduler)
    var attempts = 0
    var exhausted = 0

    policy.begin(attempt: { attempts += 1; return true }, onExhausted: { _ in exhausted += 1 })

    #expect(attempts == 1)
    #expect(scheduler.pending.isEmpty, "a granted request must not leave a retry armed")
    #expect(exhausted == 0)
  }

  @Test("a refusal is asked again, and stops the moment it is granted")
  func retriesUntilGranted() {
    let scheduler = ManualScheduler()
    let policy = makePolicy(scheduler)
    var attempts = 0
    var exhausted = 0

    policy.begin(
      attempt: {
        attempts += 1
        return attempts == 3
      },
      onExhausted: { _ in exhausted += 1 }
    )
    #expect(attempts == 1)

    scheduler.fireNext()
    #expect(attempts == 2)

    scheduler.fireNext()
    #expect(attempts == 3)

    #expect(scheduler.pending.isEmpty, "granting must disarm the rest of the schedule")
    #expect(exhausted == 0)
    scheduler.fireAll()
    #expect(attempts == 3, "nothing may run after the request was granted")
  }

  @Test("the schedule is bounded, and running out is reported rather than swallowed")
  func boundedAndVisible() {
    let scheduler = ManualScheduler()
    let policy = makePolicy(scheduler)
    var attempts = 0
    var exhaustedAfter: [Int] = []

    policy.begin(attempt: { attempts += 1; return false }, onExhausted: { exhaustedAfter.append($0) })
    scheduler.fireAll()

    // One immediate ask plus one per delay, not a loop.
    #expect(attempts == Self.delays.count + 1)
    #expect(exhaustedAfter == [Self.delays.count + 1])
    #expect(scheduler.pending.isEmpty)
  }

  @Test("the delays are the ones given, in order")
  func usesTheGivenDelays() {
    let scheduler = ManualScheduler()
    let policy = makePolicy(scheduler)

    policy.begin(attempt: { false }, onExhausted: { _ in })
    var seen: [Duration] = []
    while let next = scheduler.pending.first {
      seen.append(next.delay)
      scheduler.fireNext()
    }

    #expect(seen == Self.delays)
  }

  /// The hide-keyboard key resigns first responder, and a retry in flight would take it back,
  /// leaving the keyboard undismissable. `testTheKeyboardCanBePutAwayAndBroughtBack` guards
  /// the same thing in the UI tier.
  @Test("cancelling stops a retry that is already in flight")
  func cancelStopsRetries() {
    let scheduler = ManualScheduler()
    let policy = makePolicy(scheduler)
    var attempts = 0
    var exhausted = 0

    policy.begin(attempt: { attempts += 1; return false }, onExhausted: { _ in exhausted += 1 })
    #expect(attempts == 1)

    policy.cancel()
    scheduler.fireAll()

    #expect(attempts == 1, "a cancelled retry must not ask again")
    #expect(exhausted == 0, "a cancelled retry has not run out, it was called off")
  }

  @Test("a new request supersedes one in flight rather than racing it")
  func beginSupersedes() {
    let scheduler = ManualScheduler()
    let policy = makePolicy(scheduler)
    var first = 0
    var second = 0

    policy.begin(attempt: { first += 1; return false }, onExhausted: { _ in })
    policy.begin(attempt: { second += 1; return false }, onExhausted: { _ in })
    scheduler.fireAll()

    #expect(first == 1, "the superseded schedule must not keep asking")
    #expect(second == Self.delays.count + 1)
  }
}
