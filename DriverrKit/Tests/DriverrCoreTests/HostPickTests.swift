import Foundation
import Testing

@testable import DriverrCore

/// The hook offer follows a row tap, never a route that selected the host for the user: a
/// restored launch, a Live Activity, a notification or a URL.
@Suite("Host pick")
struct HostPickTests {
  private let workbox = UUID(uuidString: "00000000-0000-0000-0000-00000000C001")!
  private let laptop = UUID(uuidString: "00000000-0000-0000-0000-00000000C002")!

  @Test("a selection restored at launch makes no offer")
  func restoredSelectionDoesNotOffer() {
    var pick = HostPick()
    pick.selectionChanged(to: workbox)
    #expect(!pick.offersHooksOnConnect(for: workbox))
  }

  @Test("a row tap offers for that host only")
  func rowTapOffers() {
    var pick = HostPick()
    pick.userPicked(workbox)
    pick.selectionChanged(to: workbox)
    #expect(pick.offersHooksOnConnect(for: workbox))
    #expect(!pick.offersHooksOnConnect(for: laptop))
  }

  @Test("a route to another host clears the pick, and a route back does not restore it")
  func routeClearsThePick() {
    var pick = HostPick()
    pick.userPicked(workbox)
    pick.selectionChanged(to: workbox)
    pick.selectionChanged(to: laptop)
    #expect(!pick.offersHooksOnConnect(for: laptop))
    pick.selectionChanged(to: workbox)
    #expect(!pick.offersHooksOnConnect(for: workbox))
  }

  @Test("a deselect clears the pick")
  func deselectClears() {
    var pick = HostPick()
    pick.userPicked(workbox)
    pick.selectionChanged(to: nil)
    #expect(pick.pickedByUser == nil)
  }
}
