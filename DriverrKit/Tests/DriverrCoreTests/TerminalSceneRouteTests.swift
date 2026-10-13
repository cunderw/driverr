import Testing

@testable import DriverrCore

/// Where a pane scene is drawn, as a value rather than a size-class check in a view body.
@Suite("TerminalSceneRoute")
struct TerminalSceneRouteTests {
  @Test("nothing asked for is nowhere to draw, at either width")
  func noRequestIsNoRoute() {
    #expect(TerminalSceneRoute.route(hasRequest: false, isRegularWidth: true) == .none)
    #expect(TerminalSceneRoute.route(hasRequest: false, isRegularWidth: false) == .none)
  }

  @Test("regular width puts the scene in the detail column")
  func regularWidthGoesToTheDetailColumn() {
    #expect(TerminalSceneRoute.route(hasRequest: true, isRegularWidth: true) == .detailColumn)
  }

  /// The phone authors its own `NavigationStack`, so there is no collapsed detail column.
  @Test("compact width pushes the scene onto the phone's stack")
  func compactWidthPushesOntoTheStack() {
    #expect(TerminalSceneRoute.route(hasRequest: true, isRegularWidth: false) == .stack)
  }

  /// A compact window is already narrower than the cap.
  @Test("only the detail column caps the reading measure")
  func onlyTheDetailColumnCapsTheWidth() {
    #expect(TerminalSceneRoute.detailColumn.readableContentWidth == TerminalSceneRoute.readableWidth)
    #expect(TerminalSceneRoute.stack.readableContentWidth == nil)
    #expect(TerminalSceneRoute.none.readableContentWidth == nil)
  }

  @Test("the readable measure is 680 pt")
  func theMeasureIsSixEighty() {
    #expect(TerminalSceneRoute.readableWidth == 680)
  }
}
