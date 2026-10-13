import DriverrCore
import SwiftUI
import Testing
import UIKit

@testable import Driverr

/// The card's bottom strip, the only thing between Send and the keys.
///
/// The bar is a `safeAreaBar`, so it rises with the keyboard without a correction. If a
/// keyboard correction ever comes back as padding inside `PaneComposerBar`, pin here that it is
/// applied exactly once: a doubled correction looks like a jump on screen and passes every frame
/// assertion.
///
/// This tier has no keyboard. `PaneSwitchUITests` and `PaneComposerUITests` assert the
/// clearance against the keys.
@MainActor
@Suite("Composer keyboard clearance layout", .serialized)
struct ComposerKeyboardClearanceLayoutTests {
  /// The strip is the same in both shapes. At 4 pt collapsed, Send's 44 pt tap target sat
  /// 1.17 pt off the keys in landscape.
  @Test("the card's bottom strip does not shrink when the composer collapses")
  func collapsedKeepsTheCardsBottomStrip() {
    #expect(PaneComposerBar.cardBottomInset == 8)
  }

  /// `onLayoutProbe` is `nil` in shipping builds, and `PaneComposerBar` then attaches no
  /// `onGeometryChange`. The bar must resolve to the same height either way.
  @Test("attaching the layout probe does not change the bar's own layout")
  func theProbeDoesNotMoveTheBar() {
    var probedHeight: Double = 0
    let probed = HostedProbe.window(bar(onLayoutProbe: { probedHeight = Double($0.height) }))
    withExtendedLifetime(probed) {}

    var unprobedHeight: Double = 0
    let unprobed = HostedProbe.window(
      bar(onLayoutProbe: nil).measuredFrame { unprobedHeight = Double($0.height) }
    )
    withExtendedLifetime(unprobed) {}

    #expect(probedHeight > 0)
    #expect(abs(probedHeight - unprobedHeight) < 0.5)
  }

  private func bar(onLayoutProbe: ((CGRect) -> Void)?) -> some View {
    let composer = PreviewSupport.composer(
      for: PreviewSupport.agentPane,
      in: PaneComposerState()
    )
    return PaneComposerBar(
      model: composer,
      transcript: nil,
      header: PaneComposerHeader(pane: PreviewSupport.agentPane),
      onLayoutProbe: onLayoutProbe,
      isCollapsed: false
    )
  }
}
