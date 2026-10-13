import DriverrCore
import DriverrHerdr
import Testing

@testable import Driverr

/// `TerminalScreen.showsPanesButton(strip:)`.
///
/// The predicate takes a `PaneStripModel` and no link state. Link state cannot tell "the tree
/// has not arrived yet" from "this host has no herdr session", so a herdr-less host would show
/// the button for as long as its link is down.
/// `ShellWithoutHerdrUITests.testKeepsThePanesButtonAwayWhileTheLinkIsDown` checks the
/// behaviour on a simulator.
///
/// `@MainActor` because `TerminalScreen`'s static members are main-actor isolated, and a
/// nonisolated call warns under Swift 6.
@MainActor
@Suite("TerminalScreen.showsPanesButton")
struct TerminalScreenPanesButtonTests {
  @Test("hidden on a herdr-less host, regardless of link state")
  func hiddenWithNoPanes() {
    let strip = PaneStripModel(tree: .empty, current: .shell, openedAsShell: true)

    // No link-state argument: a herdr-less host's answer must not change while its link is
    // down.
    #expect(!TerminalScreen.showsPanesButton(strip: strip))
  }

  @Test("shown once a host has any panes")
  func shownWithPanes() {
    let strip = PaneStripModel(
      tree: FakeControl.seededTree,
      current: .shell,
      openedAsShell: true
    )

    #expect(TerminalScreen.showsPanesButton(strip: strip))
  }
}
