import Foundation
import Testing

@testable import DriverrCore

/// The phone's derived navigation path. A wrong derivation strands the reader on a host
/// screen or ends a shell on Back.
@Suite("PhoneStackPath")
struct PhoneStackPathTests {
  private let host = UUID()
  private let other = UUID()

  @Test("no chosen host is an empty path, so the stack rests on the host list")
  func noSelectionIsTheRoot() {
    #expect(PhoneStackPath.path(selectedHostID: nil, hasRequest: false).isEmpty)
  }

  @Test("a chosen host is one level, and a presented scene is the second")
  func theTwoLevels() {
    #expect(PhoneStackPath.path(selectedHostID: host, hasRequest: false) == [.host(host)])
    #expect(PhoneStackPath.path(selectedHostID: host, hasRequest: true) == [.host(host), .pane])
  }

  /// Every route into `present` moves the selection first, but the answer is still a path.
  @Test("a scene with no chosen host has nothing to push onto")
  func aSceneWithNoHostIsNoPath() {
    #expect(PhoneStackPath.path(selectedHostID: nil, hasRequest: true).isEmpty)
  }

  /// SwiftUI may report a tap as a push, a selection write, or both.
  @Test("a path written back through the selection cannot grow a second copy")
  func theRoundTripIsIdempotent() {
    let once = PhoneStackPath.path(selectedHostID: host, hasRequest: true)
    let back = PhoneStackPath.selection(inWrite: once)
    #expect(PhoneStackPath.path(selectedHostID: back, hasRequest: true) == once)
  }

  /// A cross-host pick edits the path. A teardown left the pane presented over the host screen.
  @Test("moving to another host keeps the pane level in place")
  func aCrossHostPickKeepsThePaneLevel() {
    let before = PhoneStackPath.path(selectedHostID: host, hasRequest: true)
    let after = PhoneStackPath.path(selectedHostID: other, hasRequest: true)
    #expect(before == [.host(host), .pane])
    #expect(after == [.host(other), .pane])
    #expect(after.last == .pane, "the scene stays on top; only the screen under it changes")
  }

  @Test("a push unwinds nothing")
  func aPushUnwindsNothing() {
    #expect(PhoneStackPath.effect(ofWrite: [.host(host)], hadRequest: false) == .none)
    #expect(
      PhoneStackPath.effect(ofWrite: [.host(host), .pane], hadRequest: true) == .none
    )
  }

  @Test("popping the pane ends its scene and keeps the host")
  func poppingThePaneEndsTheScene() {
    #expect(PhoneStackPath.effect(ofWrite: [.host(host)], hadRequest: true) == .endScene)
    #expect(PhoneStackPath.selection(inWrite: [.host(host)]) == host)
  }

  @Test("popping to the host list with no scene up only forgets the host")
  func popWithoutASceneDeselects() {
    #expect(PhoneStackPath.effect(ofWrite: [], hadRequest: false) == .deselect)
    #expect(PhoneStackPath.selection(inWrite: []) == nil)
  }

  /// A long press on Back pops both levels in one write. Leaving the scene up would leave a
  /// pane presented behind the host screen.
  @Test("popping to the host list past an open pane ends the scene as well")
  func popPastASceneEndsIt() {
    #expect(PhoneStackPath.effect(ofWrite: [], hadRequest: true) == .endSceneAndDeselect)
  }
}
