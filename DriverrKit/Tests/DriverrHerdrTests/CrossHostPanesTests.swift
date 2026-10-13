import DriverrCore
import Foundation
import Testing

@testable import DriverrHerdr

/// The pane switcher's other-host sections. Here rather than in `DriverrCoreTests` because
/// the fixture is `FakeControl.seededTree`.
@Suite("CrossHostPanes")
struct CrossHostPanesTests {
  private let onScreen = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
  private let beta = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
  private let gamma = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!

  private func host(
    _ id: UUID,
    _ name: String,
    connected: Bool = true,
    tree: SessionTree = FakeControl.seededTree
  ) -> PaneSwitcherHost {
    PaneSwitcherHost(id: id, name: name, isConnected: connected, tree: tree)
  }

  @Test("the host on screen is never one of the sections")
  func theCurrentHostIsNotOffered() {
    let panes = CrossHostPanes(
      currentHostID: onScreen,
      hosts: [host(onScreen, "workbox"), host(beta, "beta")]
    )

    #expect(panes.sections.map(\.id) == [beta])
  }

  @Test("a host Driverr is not connected to is absent")
  func aDisconnectedHostIsAbsent() {
    let panes = CrossHostPanes(
      currentHostID: onScreen,
      hosts: [
        host(onScreen, "workbox"),
        host(beta, "beta", connected: false),
        host(gamma, "gamma"),
      ]
    )

    #expect(panes.sections.map(\.name) == ["gamma"])
  }

  @Test("a connected host with no panes is absent — a header over an empty grid goes nowhere")
  func aHostWithNoPanesIsAbsent() {
    let panes = CrossHostPanes(
      currentHostID: onScreen,
      hosts: [host(beta, "beta", tree: .empty), host(gamma, "gamma")]
    )

    #expect(panes.sections.map(\.name) == ["gamma"])
  }

  @Test("the sections are ordered by name, not by whatever order the registry answered in")
  func sectionsAreOrderedByName() {
    let panes = CrossHostPanes(
      currentHostID: onScreen,
      hosts: [host(gamma, "gamma"), host(onScreen, "workbox"), host(beta, "beta")]
    )

    #expect(panes.sections.map(\.name) == ["beta", "gamma"])
  }

  @Test("hosts sharing a name keep a stable order rather than swapping between openings")
  func hostsSharingANameAreOrderedStably() {
    let first = CrossHostPanes(
      currentHostID: onScreen,
      hosts: [host(gamma, "beta"), host(beta, "beta")]
    )
    let second = CrossHostPanes(
      currentHostID: onScreen,
      hosts: [host(beta, "beta"), host(gamma, "beta")]
    )

    #expect(first.sections.map(\.id) == second.sections.map(\.id))
  }

  @Test("a section's panes are the tree's own depth-first order")
  func panesKeepTheTreesOrder() {
    let panes = CrossHostPanes(currentHostID: onScreen, hosts: [host(beta, "beta")])

    #expect(
      panes.sections.first?.panes.map(\.id) == FakeControl.seededTree.allPanes.map(\.id)
    )
  }

  @Test("with no scene on screen every connected host with panes is offered")
  func withNoCurrentHostEveryConnectedHostIsOffered() {
    let panes = CrossHostPanes(
      currentHostID: nil,
      hosts: [host(onScreen, "workbox"), host(beta, "beta")]
    )

    #expect(panes.sections.map(\.name) == ["beta", "workbox"])
  }

  @Test("nothing to switch to is empty rather than a sheet section saying so")
  func nothingElseConnectedIsEmpty() {
    let panes = CrossHostPanes(currentHostID: onScreen, hosts: [host(onScreen, "workbox")])

    #expect(panes.isEmpty)
  }
}
