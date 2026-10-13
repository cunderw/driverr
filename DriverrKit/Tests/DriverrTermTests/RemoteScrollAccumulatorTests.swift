import Foundation
import Testing

@testable import DriverrTerm

/// A pane's scroll gesture in points, turned into lines. `.ended` cannot be delivered to a
/// real `UIPanGestureRecognizer` in process.
@Suite("RemoteScrollAccumulator")
struct RemoteScrollAccumulatorTests {
  private let cell: CGFloat = 20

  @Test("small deltas add up to a line instead of rounding away")
  func smallDeltasAccumulate() {
    var accumulator = RemoteScrollAccumulator()
    accumulator.begin()
    #expect(accumulator.add(8, cellHeight: cell) == 0)
    #expect(accumulator.add(8, cellHeight: cell) == 0)
    #expect(accumulator.add(8, cellHeight: cell) == 1)
  }

  @Test("the translation left at the end is spent in whole lines", arguments: [false, true])
  func endSpendsWholeLines(indirect: Bool) {
    var accumulator = RemoteScrollAccumulator()
    accumulator.begin()
    #expect(accumulator.end(-40, cellHeight: cell, indirect: indirect) == -2)
  }

  @Test("a touch drops a remainder under one line at the end")
  func touchDropsTheRemainder() {
    var accumulator = RemoteScrollAccumulator()
    accumulator.begin()
    #expect(accumulator.add(30, cellHeight: cell) == 1)
    #expect(accumulator.end(5, cellHeight: cell, indirect: false) == 0)
  }

  /// A wheel notch may move less than one line.
  @Test("an indirect scroll under one line still scrolls one line, in its direction")
  func indirectRoundsUpInItsDirection() {
    var up = RemoteScrollAccumulator()
    up.begin()
    #expect(up.add(3, cellHeight: cell) == 0)
    #expect(up.end(2, cellHeight: cell, indirect: true) == 1)

    var down = RemoteScrollAccumulator()
    down.begin()
    #expect(down.end(-4, cellHeight: cell, indirect: true) == -1)
  }

  @Test("an indirect scroll that ends on a line boundary adds nothing")
  func indirectOnABoundaryAddsNothing() {
    var accumulator = RemoteScrollAccumulator()
    accumulator.begin()
    #expect(accumulator.add(40, cellHeight: cell) == 2)
    #expect(accumulator.end(0, cellHeight: cell, indirect: true) == 0)
  }

  /// A trackpad swipe rarely ends on a line boundary; rounding up would overshoot.
  @Test("an indirect scroll that has already scrolled drops its remainder")
  func indirectAfterLinesDropsTheRemainder() {
    var accumulator = RemoteScrollAccumulator()
    accumulator.begin()
    #expect(accumulator.add(45, cellHeight: cell) == 2)
    #expect(accumulator.end(0, cellHeight: cell, indirect: true) == 0)
  }

  @Test("a small reversal at the end of an indirect scroll scrolls nothing")
  func indirectReversalAtTheEndScrollsNothing() {
    var accumulator = RemoteScrollAccumulator()
    accumulator.begin()
    #expect(accumulator.add(41, cellHeight: cell) == 2)
    #expect(accumulator.end(-2, cellHeight: cell, indirect: true) == 0)
  }

  /// `add` follows each ending with no `begin()`, so the ending must clear both.
  @Test("a remainder does not carry into the next gesture")
  func remainderDoesNotCarry() {
    var cancelled = RemoteScrollAccumulator()
    cancelled.begin()
    #expect(cancelled.add(15, cellHeight: cell) == 0)
    cancelled.cancel()
    #expect(cancelled.add(15, cellHeight: cell) == 0)

    var ended = RemoteScrollAccumulator()
    ended.begin()
    #expect(ended.add(15, cellHeight: cell) == 0)
    #expect(ended.end(0, cellHeight: cell, indirect: false) == 0)
    #expect(ended.add(15, cellHeight: cell) == 0)
  }
}
