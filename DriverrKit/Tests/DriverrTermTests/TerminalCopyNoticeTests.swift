import Foundation
import Testing

@testable import DriverrTerm

/// Banks each scheduled hide so the test decides when time passes.
@MainActor
private final class ManualScheduler {
  private(set) var pending: [(delay: Duration, work: () -> Void)] = []

  var schedule: TerminalCopyNotice.Scheduler {
    { [weak self] delay, work in
      self?.pending.append((delay, work))
    }
  }

  func fireNext() {
    guard !pending.isEmpty else { return }
    pending.removeFirst().work()
  }
}

@MainActor
@Suite("TerminalCopyNotice")
struct TerminalCopyNoticeTests {
  private static let duration: Duration = .milliseconds(1500)

  @Test("nothing is shown before a copy")
  func hiddenAtRest() {
    let scheduler = ManualScheduler()
    let notice = TerminalCopyNotice(duration: Self.duration, schedule: scheduler.schedule)

    #expect(!notice.isShowing)
    #expect(scheduler.pending.isEmpty)
  }

  @Test("a copy shows the notice and arms one hide for the duration")
  func copyShows() {
    let scheduler = ManualScheduler()
    let notice = TerminalCopyNotice(duration: Self.duration, schedule: scheduler.schedule)

    notice.copied()

    #expect(notice.isShowing)
    #expect(scheduler.pending.map(\.delay) == [Self.duration])
  }

  @Test("the notice hides when the duration runs out")
  func hidesAfterDuration() {
    let scheduler = ManualScheduler()
    let notice = TerminalCopyNotice(duration: Self.duration, schedule: scheduler.schedule)

    notice.copied()
    scheduler.fireNext()

    #expect(!notice.isShowing)
  }

  @Test("a second copy restarts the timer, so the first hide does nothing")
  func secondCopyRestarts() {
    let scheduler = ManualScheduler()
    let notice = TerminalCopyNotice(duration: Self.duration, schedule: scheduler.schedule)

    notice.copied()
    notice.copied()
    #expect(scheduler.pending.count == 2)

    scheduler.fireNext()
    #expect(notice.isShowing, "the first copy's hide must not cut the second one short")

    scheduler.fireNext()
    #expect(!notice.isShowing)
  }

  @Test("the default duration is about two seconds")
  func defaultDuration() {
    #expect(TerminalCopyNotice.defaultDuration == .seconds(2))
  }
}
