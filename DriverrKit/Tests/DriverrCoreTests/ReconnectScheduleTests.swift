import Testing

@testable import DriverrCore

@Suite("ReconnectSchedule")
struct ReconnectScheduleTests {
  @Test("yields the doubling backoff, capped at 30s, until the 120s deadline")
  func yieldsTheStatedSequence() {
    let delays = Array(ReconnectSchedule())

    #expect(
      delays == [1, 2, 4, 8, 16, 30, 30].map { Duration.seconds($0) }
    )
  }

  @Test("stops yielding once the deadline is reached rather than exceeding it")
  func stopsAtTheDeadline() {
    let delays = Array(ReconnectSchedule())
    let total = delays.reduce(Duration.zero, +)

    #expect(total <= ReconnectSchedule.deadline)
    #expect(total + ReconnectSchedule.steps.last! > ReconnectSchedule.deadline)
  }

  @Test("a fresh schedule always starts at one second")
  func startsAtOneSecond() {
    var iterator = ReconnectSchedule().makeIterator()
    #expect(iterator.next() == .seconds(1))
  }
}
