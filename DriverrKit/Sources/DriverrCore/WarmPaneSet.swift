/// An LRU set of `TerminalTarget`s a scene keeps warm: the current target plus up to
/// `k` others.
///
/// Only the current target may hold a bridge controller; the others hold read-only
/// observers. The app's `TerminalSceneModel` says why.
///
/// `select(_:)` is the only way to change what is warm, and reports what happened. A warm
/// target is touched and promoted; a new target beyond capacity evicts the least recently
/// used observer. The current target is never evicted.
public struct WarmPaneSet: Sendable, Equatable {
  /// What changed as a result of a `select(_:)` call.
  public struct Selection: Sendable, Equatable {
    /// The previous current target, now an observer. `nil` when there was none, or the same
    /// target was reselected.
    public let demoted: TerminalTarget?
    /// The observer dropped to make room, if any. Its scrolled-row memory goes with it.
    public let evicted: TerminalTarget?

    public init(demoted: TerminalTarget?, evicted: TerminalTarget?) {
      self.demoted = demoted
      self.evicted = evicted
    }
  }

  /// How many panes besides the current one stay warm as observers.
  public static let defaultK = 2

  public let k: Int
  public private(set) var current: TerminalTarget?
  /// Warm targets other than the current one, least recently used first.
  public private(set) var observers: [TerminalTarget] = []
  private var scrolledRowsByTarget: [TerminalTarget: Int] = [:]

  public init(k: Int = WarmPaneSet.defaultK) {
    self.k = max(0, k)
  }

  /// The rows the phone had scrolled when this target was last warm, or zero for one never
  /// held or evicted.
  public func scrolledRows(for target: TerminalTarget) -> Int {
    scrolledRowsByTarget[target] ?? 0
  }

  public mutating func setScrolledRows(_ rows: Int, for target: TerminalTarget) {
    scrolledRowsByTarget[target] = rows
  }

  /// Makes `target` the current target, touching it if it was already warm.
  @discardableResult
  public mutating func select(_ target: TerminalTarget) -> Selection {
    guard target != current else {
      return Selection(demoted: nil, evicted: nil)
    }

    let previousCurrent = current
    // Already an observer: it becomes current, so it leaves the observer list.
    observers.removeAll { $0 == target }
    current = target

    guard let previousCurrent else {
      return Selection(demoted: nil, evicted: nil)
    }

    guard k > 0 else {
      scrolledRowsByTarget[previousCurrent] = nil
      return Selection(demoted: nil, evicted: previousCurrent)
    }

    // The old current joins the observers as the most recently used.
    observers.append(previousCurrent)
    guard observers.count > k else {
      return Selection(demoted: previousCurrent, evicted: nil)
    }

    let evicted = observers.removeFirst()
    scrolledRowsByTarget[evicted] = nil
    return Selection(demoted: previousCurrent, evicted: evicted)
  }

  /// Drops every observer at once, leaving only the current target. The response to a memory
  /// warning. Returns what was dropped so the caller can release it.
  @discardableResult
  public mutating func evictObservers() -> [TerminalTarget] {
    let dropped = observers
    for target in dropped { scrolledRowsByTarget[target] = nil }
    observers = []
    return dropped
  }
}
