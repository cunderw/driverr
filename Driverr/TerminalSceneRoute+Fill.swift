import DriverrCore
import SwiftUI

extension TerminalSceneRoute {
  /// The safe-area edges a full-bleed fill on this route ignores.
  ///
  /// Every edge, except the leading one in the detail column while the sidebar shows. See
  /// `fillsLeadingSafeArea(isSidebarCollapsed:)` for the rule and why.
  func fillEdges(isSidebarCollapsed: Bool) -> Edge.Set {
    fillsLeadingSafeArea(isSidebarCollapsed: isSidebarCollapsed)
      ? .all : [.top, .bottom, .trailing]
  }
}
