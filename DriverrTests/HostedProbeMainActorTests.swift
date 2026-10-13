import Foundation
import SwiftUI
import Testing

@testable import Driverr

/// `HostedProbe.window` holds the main actor for the whole of its layout.
///
/// Its `RunLoop.current.run(until:)` turns are synchronous and do not drain the main actor's
/// queue, so a task parked on `Task.yield()` gets no turn across it. The hosted layout suites
/// therefore delay every other `@MainActor` test in the bundle. Measured for one such test:
///
/// | run | the test's duration | one main-actor `Task.yield()` |
/// | --- | --- | --- |
/// | `PaneSurfaceSwitchTests` alone | 0.032 s | — |
/// | the hosted layout suites plus it | 16.96 s | 231 ms |
/// | the whole `DriverrTests` bundle | 17.19 s | 264 ms |
///
/// The assertion is on a turn being taken, not on a duration.
///
/// This fails the day those turns start draining the main actor, which would remove that delay.
@MainActor
@Suite("Hosted probe main-actor sharing", .timeLimit(.minutes(1)))
struct HostedProbeMainActorTests {
  /// Counts the turns a competing main-actor task got. A class so the task and the test
  /// read the same box.
  @MainActor
  final class Turns {
    var count = 0
    var stop = false
  }

  @Test("laying out a hosted probe window gives another main-actor task no turn")
  func theProbeHoldsTheMainActor() async {
    let turns = Turns()
    // `Task.yield()` does not throw, so without the cancellation check the loop spins until
    // the suite's time limit.
    let competitor = Task { @MainActor in
      while !turns.stop && !Task.isCancelled {
        await Task.yield()
        turns.count += 1
      }
    }
    // Let the competitor park first, so the count is turns taken during the layout.
    await Task.yield()
    let before = turns.count

    let window = HostedProbe.window(Text("probe"), size: HostedProbe.phone)
    let during = turns.count - before

    turns.stop = true
    competitor.cancel()
    withExtendedLifetime(window) {}

    #expect(
      during == 0,
      Comment(
        rawValue: "A task parked on Task.yield() took \(during) turns across "
          + "HostedProbe.window's layout, so the run loop drains the main actor now and the "
          + "queueing delay in this file's table should be gone. Re-measure and update the "
          + "table."
      )
    )
  }
}
