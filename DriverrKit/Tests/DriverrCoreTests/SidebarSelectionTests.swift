import Foundation
import Testing

@testable import DriverrCore

/// The iPad sidebar's derived selection. A wrong read highlights a host the detail column is
/// not showing; a wrong write closes the pane a tap meant to open.
@Suite("SidebarSelection")
struct SidebarSelectionTests {
  private let host = UUID()
  private let other = UUID()

  @Test("with no scene, the selected host is the selection, and no host is none")
  func noScene() {
    #expect(SidebarSelection.derived(selectedHostID: host, open: nil) == .host(host))
    #expect(SidebarSelection.derived(selectedHostID: nil, open: nil) == nil)
  }

  @Test("an open pane is the selection, whatever host is selected")
  func openPane() {
    #expect(
      SidebarSelection.derived(selectedHostID: other, open: (host, .pane(id: "w1:p2")))
        == .pane(hostID: host, paneID: "w1:p2"))
  }

  /// A shell names no pane, so its host's row carries the highlight.
  @Test("an open plain shell highlights its host")
  func openShell() {
    #expect(SidebarSelection.derived(selectedHostID: other, open: (host, .shell)) == .host(host))
  }

  @Test("a host write always selects the host, even the one already selected")
  func hostWrite() {
    #expect(SidebarSelection.effect(ofWrite: .host(host), current: .host(host)) == .selectHost(host))
    #expect(
      SidebarSelection.effect(ofWrite: .host(host), current: .pane(hostID: host, paneID: "p"))
        == .selectHost(host))
    #expect(SidebarSelection.effect(ofWrite: nil, current: .host(host)) == .selectHost(nil))
  }

  @Test("a pane write opens the pane, and never selects a host instead")
  func paneWrite() {
    #expect(
      SidebarSelection.effect(ofWrite: .pane(hostID: host, paneID: "w1:p2"), current: .host(host))
        == .openPane(hostID: host, paneID: "w1:p2"))
    #expect(
      SidebarSelection.effect(
        ofWrite: .pane(hostID: other, paneID: "w1:p2"),
        current: .pane(hostID: host, paneID: "w1:p2"))
        == .openPane(hostID: other, paneID: "w1:p2"))
  }

  /// Reopening the open pane would reload the scene under the reader.
  @Test("a write of the pane already open does nothing")
  func samePane() {
    let open = SidebarSelection.pane(hostID: host, paneID: "w1:p2")
    #expect(SidebarSelection.effect(ofWrite: open, current: open) == .none)
  }
}
