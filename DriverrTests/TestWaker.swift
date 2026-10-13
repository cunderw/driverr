import Foundation
import Observation
import Testing

/// Wakes a waiter when something it is watching has moved, in place of a clock.
///
/// A generation counter rather than a flag: a signal that lands between a waiter reading
/// the generation and parking is not lost, because the parked call sees the number has
/// already changed and returns to re-check. Signals can arrive from any thread, so they
/// hop to the main actor before touching anything here.
///
/// **Cancellation is the caller's job.** `next(after:)` resumes a cancelled caller
/// immediately, the same as a signal. A loop that does not check `Task.isCancelled` after the
/// `await` re-parks on a cancelled task and is resumed again forever. That busy loop never
/// suspends, so `.timeLimit` cannot catch it.
@MainActor
final class Waker {
  private(set) var generation = 0
  private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var nextID = 0

  /// How many callers are parked in `next(after:)` right now.
  var waiterCount: Int { waiters.count }

  nonisolated func signalFromAnywhere() {
    Task { @MainActor in self.signal() }
  }

  func signal() {
    generation += 1
    let resuming = waiters
    waiters.removeAll()
    for waiter in resuming { waiter.continuation.resume() }
  }

  /// Suspends until `signal()` lands a generation past `seen`, or returns at once if that has
  /// already happened. A cancelled caller also returns; see the type's doc comment.
  func next(after seen: Int) async {
    guard generation == seen else { return }
    let id = nextID
    nextID += 1
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled {
          continuation.resume()
        } else {
          waiters.append((id, continuation))
        }
      }
    } onCancel: {
      Task { @MainActor in self.cancel(id) }
    }
  }

  private func cancel(_ id: Int) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    waiters.remove(at: index).continuation.resume()
  }
}

/// A loop on `Waker.next(after:)` that never checks `Task.isCancelled` busy-loops once its
/// task is cancelled. Swift Testing enforces a time limit by cancelling the task, so a time
/// limit cannot stop that loop. This suite's `.timeLimit` only turns a hang into a failure.
@MainActor
@Suite("Waker", .timeLimit(.minutes(1)))
struct WakerTests {
  /// What the waiting loop saw each time `next(after:)` returned, so the test can assert why
  /// the wait ended. Written before the loop's guard, so it reads the state the guard reads.
  @MainActor
  final class Exit {
    var resumes = 0
    var cancelledOnLastResume = false
    var generationOnLastResume = -1
    var returned = false
  }

  @Test("a wait built on Waker ends because its task was cancelled, not because a signal arrived")
  func cancellationEndsTheWait() async {
    let waker = Waker()
    let exit = Exit()
    let waiting = Task<Void, Never> {
      while true {
        let seen = waker.generation
        await waker.next(after: seen)
        exit.resumes += 1
        exit.cancelledOnLastResume = Task.isCancelled
        exit.generationOnLastResume = waker.generation
        // The guard under test. Deleting these three lines is the defect: the loop
        // re-parks on an already-cancelled task, is resumed at once, and spins forever.
        if Task.isCancelled {
          exit.returned = true
          return
        }
      }
    }

    // Wait until the loop has parked, so cancellation resumes a parked waiter instead of
    // taking the already-cancelled shortcut in `next(after:)`. Bounded, so a loop that never
    // parks fails here instead of hanging.
    var spins = 0
    while waker.waiterCount == 0, spins < 1_000 {
      await Task.yield()
      spins += 1
    }
    #expect(waker.waiterCount == 1, "the loop never parked, so this run did not test cancellation")

    let start = ContinuousClock.now
    waiting.cancel()
    await waiting.value
    let elapsed = ContinuousClock.now - start

    // The loop ended because its task was cancelled. `generation` is still 0, so a signal
    // did not wake it.
    #expect(exit.returned, "the waiting loop never returned")
    #expect(exit.resumes == 1, "the loop parked and resumed more than once")
    #expect(exit.cancelledOnLastResume, "the loop returned without its task being cancelled")
    #expect(exit.generationOnLastResume == 0, "a signal, not cancellation, is what ended the wait")
    #expect(waker.generation == 0, "the waker was signalled during the test")

    // A backstop, not the claim. It names a cancellation that resumes late rather than
    // promptly. A loaded simulator running the whole bundle took 1.246 s, so 1 s was too
    // tight; 30 s still fails before the suite's one-minute limit.
    #expect(
      elapsed < .seconds(30),
      "cancelling the task ended the wait, but took \(elapsed) to do it"
    )
  }
}

extension Waker {
  /// The one waker every signal wait in `DriverrTests` parks on.
  ///
  /// Shared because some signals come from places that cannot be handed an instance, such as
  /// `FakeSSHTransport`'s activity hook in `DriverrSSH`. Sharing across parallel suites only
  /// adds spurious wake-ups, which cost a cheap re-check. A missed wake-up is the failure that
  /// matters.
  @MainActor static let shared = Waker()

  /// Signals `shared` from anywhere, including off the main actor.
  nonisolated static func signalShared() {
    Task { @MainActor in Waker.shared.signal() }
  }
}

/// Waits for `condition` to hold, driven by the observation that makes it hold.
///
/// There is no clock. A wall-clock deadline measures the machine: a hosted suite laying
/// SwiftUI out holds the main actor long enough for a deadline in a different suite to
/// expire, and the failure lands in that other suite's name.
///
/// `withObservationTracking` registers whatever `@Observable` properties the predicate reads.
/// State that observation cannot reach, such as an actor's log or a locked counter, has to
/// signal `Waker.shared` itself. A condition that never holds is caught by the suite's
/// `.timeLimit`. The `Task.isCancelled` check is required; see `Waker`.
@MainActor
func waitUntil(
  _ description: String = "a condition",
  sourceLocation: SourceLocation = #_sourceLocation,
  _ condition: @MainActor () -> Bool
) async {
  while true {
    let seen = Waker.shared.generation
    var satisfied = false
    withObservationTracking {
      satisfied = condition()
    } onChange: {
      Waker.signalShared()
    }
    if satisfied { return }
    await Waker.shared.next(after: seen)
    if Task.isCancelled {
      Issue.record(
        "waitUntil was cancelled before it held: \(description)",
        sourceLocation: sourceLocation
      )
      return
    }
  }
}

/// `waitUntil` for a condition that has to `await` something observation cannot reach.
///
/// `withObservationTracking` has a synchronous body, so this form has no observation and is
/// woken only by a `Waker.shared` signal. The predicate must read state something signals,
/// such as `FakeSSHTransport` state with its `onActivity` hook installed. Without a hook the
/// wait lasts until the suite's `.timeLimit`.
///
/// Keep predicates to the awaited state alone. An observable property mixed in would wake
/// only when the actor also happens to be written.
@MainActor
func waitUntilSignalled(
  _ description: String = "a condition",
  sourceLocation: SourceLocation = #_sourceLocation,
  _ condition: @MainActor () async -> Bool
) async {
  while true {
    let seen = Waker.shared.generation
    if await condition() { return }
    await Waker.shared.next(after: seen)
    if Task.isCancelled {
      Issue.record(
        "waitUntilSignalled was cancelled before it held: \(description)",
        sourceLocation: sourceLocation
      )
      return
    }
  }
}
