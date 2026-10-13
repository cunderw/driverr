import Testing

@testable import DriverrCore

/// The sidebar's width rule. `DriverrTests` asserts the real per-size numbers, which need
/// `UIFontMetrics`.
@Suite("Sidebar column width")
struct SidebarColumnWidthTests {
  @Test("the default text size leaves the platform's own width alone")
  func defaultSizeDeclines() {
    #expect(SidebarColumnWidth.ideal(scaledBase: SidebarColumnWidth.base) == nil)
  }

  /// 264 pt would be narrower than the platform draws a sidebar anywhere.
  @Test("a smaller text size leaves it alone as well")
  func smallerSizeDeclines() {
    #expect(SidebarColumnWidth.ideal(scaledBase: 264) == nil)
  }

  /// `xLarge` and `xxLarge`; see `SidebarColumnWidthBandTests`.
  @Test("a larger text size asks for the scaled width")
  func largerSizeScales() {
    #expect(SidebarColumnWidth.ideal(scaledBase: 349) == 349)
    #expect(SidebarColumnWidth.ideal(scaledBase: 378.3) == 378.3)
  }

  /// Unclamped, `AccessibilityXXXL` reaches 901.7 and leaves a 13-inch iPad's host screen a
  /// strip.
  @Test("the accessibility sizes are capped rather than left to scale")
  func accessibilitySizesAreCapped() {
    #expect(SidebarColumnWidth.ideal(scaledBase: 494.7) == SidebarColumnWidth.maximum)
    #expect(SidebarColumnWidth.ideal(scaledBase: 901.7) == SidebarColumnWidth.maximum)
  }

  /// Catches `>=` slipping in for `>`.
  @Test("half a point over the base is still the platform's own width")
  func toleranceHoldsAtTheBoundary() {
    #expect(SidebarColumnWidth.ideal(scaledBase: 320.4) == nil)
    #expect(SidebarColumnWidth.ideal(scaledBase: 321) == 321)
  }
}
