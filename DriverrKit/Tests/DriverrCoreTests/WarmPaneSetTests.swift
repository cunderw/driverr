import Testing

@testable import DriverrCore

@Suite("WarmPaneSet")
struct WarmPaneSetTests {
  @Test("the first selection becomes current with nothing to demote or evict")
  func firstSelectionHasNoSideEffects() {
    var set = WarmPaneSet(k: 2)
    let selection = set.select(.pane(id: "p1"))

    #expect(selection == .init(demoted: nil, evicted: nil))
    #expect(set.current == .pane(id: "p1"))
    #expect(set.observers.isEmpty)
  }

  @Test("selecting the current target again just touches it")
  func selectingCurrentAgainIsANoOp() {
    var set = WarmPaneSet(k: 2)
    set.select(.pane(id: "p1"))
    let selection = set.select(.pane(id: "p1"))

    #expect(selection == .init(demoted: nil, evicted: nil))
    #expect(set.current == .pane(id: "p1"))
    #expect(set.observers.isEmpty)
  }

  @Test("selecting an existing observer touches it: it becomes current, the old current demotes")
  func selectingAnExistingObserverPromotesIt() {
    var set = WarmPaneSet(k: 2)
    set.select(.pane(id: "a"))
    set.select(.pane(id: "b"))
    // current: b, observers: [a]

    let selection = set.select(.pane(id: "a"))

    #expect(selection == .init(demoted: .pane(id: "b"), evicted: nil))
    #expect(set.current == .pane(id: "a"))
    #expect(set.observers == [.pane(id: "b")])
  }

  @Test("selecting a new target beyond capacity evicts the least recently used non-current target")
  func selectingBeyondCapacityEvictsTheLRUObserver() {
    var set = WarmPaneSet(k: 2)
    set.select(.pane(id: "a"))  // current: a
    set.select(.pane(id: "b"))  // current: b, observers: [a]
    set.select(.pane(id: "c"))  // current: c, observers: [a, b]
    // a is the least recently touched non-current target.

    let selection = set.select(.pane(id: "d"))

    #expect(selection == .init(demoted: .pane(id: "c"), evicted: .pane(id: "a")))
    #expect(set.current == .pane(id: "d"))
    #expect(set.observers == [.pane(id: "b"), .pane(id: "c")])
  }

  @Test("touching an observer protects it from eviction")
  func touchingAnObserverProtectsItFromEviction() {
    var set = WarmPaneSet(k: 2)
    set.select(.pane(id: "a"))  // current: a
    set.select(.pane(id: "b"))  // current: b, observers: [a]
    set.select(.pane(id: "c"))  // current: c, observers: [a, b]
    set.select(.pane(id: "a"))  // touch a: current: a, observers: [b, c]

    // Now the least recently touched non-current target is b, not a.
    let selection = set.select(.pane(id: "d"))

    #expect(selection == .init(demoted: .pane(id: "a"), evicted: .pane(id: "b")))
    #expect(set.current == .pane(id: "d"))
    #expect(set.observers == [.pane(id: "c"), .pane(id: "a")])
  }

  @Test("K = 0 degenerates to current only — every switch evicts the old current immediately")
  func zeroCapacityDegeneratesToCurrentOnly() {
    var set = WarmPaneSet(k: 0)
    set.select(.pane(id: "a"))
    let selection = set.select(.pane(id: "b"))

    #expect(selection == .init(demoted: nil, evicted: .pane(id: "a")))
    #expect(set.current == .pane(id: "b"))
    #expect(set.observers.isEmpty)
  }

  @Test("a demoted entry keeps the rows the phone had scrolled")
  func demotionKeepsScrolledRows() {
    var set = WarmPaneSet(k: 2)
    set.select(.pane(id: "a"))
    set.setScrolledRows(12, for: .pane(id: "a"))

    set.select(.pane(id: "b"))  // a demoted, not evicted

    #expect(set.scrolledRows(for: .pane(id: "a")) == 12)
  }

  @Test("an evicted entry drops the rows the phone had scrolled")
  func evictionDropsScrolledRows() {
    var set = WarmPaneSet(k: 0)
    set.select(.pane(id: "a"))
    set.setScrolledRows(12, for: .pane(id: "a"))

    set.select(.pane(id: "b"))  // a evicted immediately, k == 0

    #expect(set.scrolledRows(for: .pane(id: "a")) == 0)
  }

  @Test("a target never seen before has zero scrolled rows")
  func unseenTargetHasZeroScrolledRows() {
    let set = WarmPaneSet(k: 2)
    #expect(set.scrolledRows(for: .shell) == 0)
  }

  @Test("the current target is never evicted")
  func currentTargetIsNeverEvicted() {
    var set = WarmPaneSet(k: 0)
    set.select(.shell)
    let selection = set.select(.shell)

    #expect(selection == .init(demoted: nil, evicted: nil))
    #expect(set.current == .shell)
  }

  @Test("evicting observers drops every one of them at once, not just the LRU one")
  func evictObserversDropsAllOfThem() {
    var set = WarmPaneSet(k: 2)
    set.select(.pane(id: "a"))
    set.select(.pane(id: "b"))
    set.select(.pane(id: "c"))
    // current: c, observers: [a, b]

    let dropped = set.evictObservers()

    #expect(dropped == [.pane(id: "a"), .pane(id: "b")])
    #expect(set.observers.isEmpty)
    #expect(set.current == .pane(id: "c"), "the current target is never touched")
  }

  @Test("evicting observers drops their scrolled-row memory too")
  func evictObserversDropsScrolledRows() {
    var set = WarmPaneSet(k: 2)
    set.select(.pane(id: "a"))
    set.setScrolledRows(12, for: .pane(id: "a"))
    set.select(.pane(id: "b"))
    // current: b, observers: [a]

    set.evictObservers()

    #expect(set.scrolledRows(for: .pane(id: "a")) == 0)
  }

  @Test("evicting observers when there are none is a harmless no-op")
  func evictObserversWithNoneIsANoOp() {
    var set = WarmPaneSet(k: 2)
    set.select(.pane(id: "a"))

    let dropped = set.evictObservers()

    #expect(dropped.isEmpty)
    #expect(set.current == .pane(id: "a"))
  }
}
