import Foundation

/// Where a pane scene is drawn: pushed onto the phone's own `NavigationStack`, or placed in
/// the split view's detail column. A value so `swift test` asserts the rule.
///
/// - Nothing asked for is `.none`, whatever the width.
/// - Regular width puts the scene in the detail column. A full-screen cover on a 13-inch
///   iPad is a 1032 pt phone with a Done button.
/// - Compact width pushes onto the stack `ContentView` authors for the phone. The phone has
///   no split view, so the "second push from a detail column pops to the list" trap cannot
///   fire there.
///
/// Read the width from the window, at `ContentView`'s root, never inside a column. A
/// `NavigationSplitView` gives its columns their own traits, so a column would answer about
/// itself.
public enum TerminalSceneRoute: Equatable, Sendable {
  /// No scene has been asked for.
  case none
  /// Pushed onto the phone's own `NavigationStack`: compact width.
  case stack
  /// The split view's detail column — regular width.
  case detailColumn

  /// The routing rule.
  ///
  /// - Parameters:
  ///   - hasRequest: whether `TerminalPresenter.request` is set.
  ///   - isRegularWidth: the **window's** horizontal size class, not a column's.
  public static func route(hasRequest: Bool, isRegularWidth: Bool) -> TerminalSceneRoute {
    guard hasRequest else { return .none }
    return isRegularWidth ? .detailColumn : .stack
  }

  /// The widest a column of prose may get, about the platform's body-text measure. At full
  /// iPad width a conversation and its composer are too wide to read.
  ///
  /// Not applied to the terminal grid, whose width is the remote pane's; narrowing it would
  /// reflow someone's PTY.
  ///
  /// 680 is the column's width, not the text's, as with `ChatColumn.width`. The chat's prose
  /// sits inside `ChatColumn.inset` on each side, at 648 pt, and
  /// `HostDetailView.readableDetailColumn` does the same with a `Form`.
  public static let readableWidth: Double = 680

  /// The cap this route puts on the chat and its composer, or `nil` where there is none.
  ///
  /// `nil` on the stack route, where a compact window is already narrower than the cap.
  public var readableContentWidth: Double? {
    switch self {
    case .detailColumn: TerminalSceneRoute.readableWidth
    case .stack, .none: nil
    }
  }

  /// Whether a full-bleed fill on this route may paint the leading safe area.
  ///
  /// In the detail column, while the sidebar shows, the leading safe area is the sidebar's
  /// width. The glass sidebar is translucent over what is painted there, so a fill under it
  /// changes the sidebar's colour. With the sidebar collapsed the leading safe area is the
  /// device's own, such as a landscape Pro Max's Dynamic Island inset, and must be painted.
  ///
  /// - Parameter isSidebarCollapsed: whether nothing of the sidebar sits beside the detail
  ///   column, from `isSidebarCollapsed(detailLeadingInset:windowLeadingInset:)`. Ignored off
  ///   the detail column.
  public func fillsLeadingSafeArea(isSidebarCollapsed: Bool) -> Bool {
    switch self {
    case .detailColumn: isSidebarCollapsed
    case .stack, .none: true
    }
  }

  /// How far, in points, the detail column's leading inset may exceed the window's and still
  /// count as equal. Rounding of a fractional inset, never a sidebar.
  public static let sidebarInsetTolerance: Double = 1

  /// Whether the sidebar is collapsed, judged from two leading safe-area insets.
  ///
  /// While the sidebar shows beside the detail, the detail column's leading inset is the
  /// sidebar's width. With it collapsed the inset is the window's own (zero on an iPad, the
  /// Dynamic Island's on a landscape Pro Max). An overlaid sidebar leaves the detail's inset
  /// alone, so it counts as collapsed too, and a fill paints under it as under any overlay.
  public static func isSidebarCollapsed(
    detailLeadingInset: Double, windowLeadingInset: Double
  ) -> Bool {
    detailLeadingInset <= windowLeadingInset + sidebarInsetTolerance
  }
}
