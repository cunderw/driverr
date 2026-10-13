import Foundation

/// Turns a pane's scroll gesture, in points, into whole lines for `terminal.scroll`.
///
/// Translation short of a whole line is kept, or a slow drag of small deltas would round
/// to nothing. A separate type so a Kit test can drive `.ended`.
///
/// Positive lines mean a downward drag, which reveals older output.
struct RemoteScrollAccumulator {
  private var unspent: CGFloat = 0
  /// Whether this gesture has scrolled any line yet.
  private var spentAny = false

  mutating func begin() {
    unspent = 0
    spentAny = false
  }

  /// Adds `translation` and returns the whole lines it completes.
  mutating func add(_ translation: CGFloat, cellHeight: CGFloat) -> Int {
    unspent += translation
    let lines = Int(unspent / cellHeight)
    unspent -= CGFloat(lines) * cellHeight
    if lines != 0 { spentAny = true }
    return lines
  }

  /// Adds the gesture's last translation and returns the lines still to scroll.
  ///
  /// A touch drops a remainder under one line. An indirect scroll that has scrolled no line
  /// yet rounds up to one line, because a wheel notch can arrive as a gesture shorter than
  /// a line. Once a gesture has scrolled, its remainder is dropped, or trackpad swipes
  /// would overshoot.
  mutating func end(_ translation: CGFloat, cellHeight: CGFloat, indirect: Bool) -> Int {
    var lines = add(translation, cellHeight: cellHeight)
    if indirect && !spentAny && unspent != 0 {
      lines += unspent > 0 ? 1 : -1
    }
    unspent = 0
    spentAny = false
    return lines
  }

  /// Drops the remainder of a cancelled or failed gesture.
  mutating func cancel() {
    unspent = 0
    spentAny = false
  }
}
