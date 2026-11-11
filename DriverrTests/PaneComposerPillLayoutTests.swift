import DriverrCore
import SwiftUI
import Testing
import UIKit

@testable import Driverr

/// The composer at rest is a one-row pill, and the two-row card whenever it holds a draft or
/// the text is at an accessibility size. Measured through `onLayoutProbe`, which reports the
/// whole bar: the card plus the bar's 6 pt top and `cardBottomInset` bottom padding.
///
/// Focus is the third way to the card, and a hosted window cannot give a field focus, so that
/// half is the look pass and `PaneComposerUITests`.
@MainActor
@Suite("Composer pill layout")
struct PaneComposerPillLayoutTests {
  /// The pill's own height: 44 pt targets and 2 pt above and below.
  private static let pillHeight: Double = 48

  private func barHeight(text: String, size: DynamicTypeSize = .large) -> Double {
    var height: Double = 0
    var state = PaneComposerState()
    state.text = text
    let composer = PreviewSupport.composer(for: PreviewSupport.agentPane, in: state)
    let bar = PaneComposerBar(
      model: composer,
      header: PaneComposerHeader(pane: PreviewSupport.agentPane),
      onLayoutProbe: { height = Double($0.height) },
      onAttach: { _ in }
    )
    .environment(\.dynamicTypeSize, size)
    let window = HostedProbe.window(bar)
    withExtendedLifetime(window) {}
    return height
  }

  @Test("an empty bar at rest is one 48 pt row")
  func restIsOneRow() {
    let rest = barHeight(text: "")
    #expect(abs(rest - (Self.pillHeight + 6 + PaneComposerBar.cardBottomInset)) < 1)
  }

  @Test("a draft keeps the two-row card, with no focus")
  func draftIsTheCard() {
    let rest = barHeight(text: "")
    let draft = barHeight(text: "x")
    // The card's second row is a 44 pt control row, so the difference is well past a rounding.
    #expect(draft > rest + 30)
  }

  @Test("at an accessibility size an empty bar is the card, not the pill")
  func accessibilitySizeIsTheCard() {
    let rest = barHeight(text: "", size: .accessibility1)
    let draft = barHeight(text: "x", size: .accessibility1)
    #expect(rest > 0)
    #expect(rest == draft)
  }
}
