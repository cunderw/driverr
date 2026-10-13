import DriverrCore
import Testing
import UIKit

/// What the sidebar rule answers, one value per text size band.
///
/// The rule is asserted in `DriverrKit`; this is the half that needs UIKit.
/// `@ScaledMetric(relativeTo: .body)` scales by exactly what
/// `UIFontMetrics(forTextStyle: .body).scaledValue(for:compatibleWith:)` returns, so this is
/// the arithmetic `ContentView` does at runtime.
///
/// The expected column is measured, not derived: `UIFontMetrics` does not scale by the ratio of
/// body's point sizes. Scaled base, then width asked for:
///
///     xSmall            276.3   ->  nil
///     Small             291.0   ->  nil
///     Medium            305.3   ->  nil
///     Large (default)   320.0   ->  nil
///     xLarge            349.0   ->  349.0
///     xxLarge           378.3   ->  378.3
///     xxxLarge          421.7   ->  420   (capped)
///     AX Medium         494.7   ->  420   (capped)
///     AX Large          581.7   ->  420   (capped)
///     AX xLarge         698.3   ->  420   (capped)
///     AX xxLarge        814.7   ->  420   (capped)
///     AX xxxLarge       901.7   ->  420   (capped)
///
/// So the cap binds from `xxxLarge` up, and at the largest size it is holding back 902 pt of
/// scaled sidebar on a 1032 pt iPad.
@MainActor
@Suite("Sidebar column width bands")
struct SidebarColumnWidthBandTests {
  /// One band and the width the app asks for at it. `nil` means "leave the platform's own
  /// sidebar width alone", which is the answer at and below the default size.
  private struct Band {
    let category: UIContentSizeCategory
    let name: String
    let expected: Double?
  }

  private static let bands: [Band] = [
    Band(category: .extraSmall, name: "xSmall", expected: nil),
    Band(category: .small, name: "Small", expected: nil),
    Band(category: .medium, name: "Medium", expected: nil),
    Band(category: .large, name: "Large (default)", expected: nil),
    Band(category: .extraLarge, name: "xLarge", expected: 349),
    Band(category: .extraExtraLarge, name: "xxLarge", expected: 378.3),
    Band(category: .extraExtraExtraLarge, name: "xxxLarge", expected: 420),
    Band(category: .accessibilityMedium, name: "AX Medium", expected: 420),
    Band(category: .accessibilityLarge, name: "AX Large", expected: 420),
    Band(category: .accessibilityExtraLarge, name: "AX xLarge", expected: 420),
    Band(category: .accessibilityExtraExtraLarge, name: "AX xxLarge", expected: 420),
    Band(category: .accessibilityExtraExtraExtraLarge, name: "AX xxxLarge", expected: 420),
  ]

  /// What `@ScaledMetric(relativeTo: .body)` would hand the rule at this band.
  private func scaledBase(at category: UIContentSizeCategory) -> Double {
    Double(
      UIFontMetrics(forTextStyle: .body).scaledValue(
        for: CGFloat(SidebarColumnWidth.base),
        compatibleWith: UITraitCollection(preferredContentSizeCategory: category)
      )
    )
  }

  @Test("every text size band gets the width it was designed for")
  func everyBandAnswers() {
    for band in Self.bands {
      let scaled = scaledBase(at: band.category)
      let actual = SidebarColumnWidth.ideal(scaledBase: scaled)
      switch (actual, band.expected) {
      case (nil, nil):
        continue
      case (let actual?, let expected?):
        #expect(
          abs(actual - expected) < 1.5,
          """
          \(band.name): asked for \(actual) pt, expected about \(expected) pt \
          (scaled base \(scaled)).
          """
        )
      default:
        Issue.record(
          """
          \(band.name): asked for \(String(describing: actual)), expected \
          \(String(describing: band.expected)) (scaled base \(scaled)).
          """
        )
      }
    }
  }

  /// The property the table above is an instance of, so a band added by a future iOS is
  /// still held to it: the column never shrinks as text grows, and never passes the cap.
  @Test("the width never shrinks as text grows, and never passes the cap")
  func monotonicAndCapped() {
    var previous = SidebarColumnWidth.base
    for band in Self.bands {
      let width = SidebarColumnWidth.ideal(scaledBase: scaledBase(at: band.category))
        ?? SidebarColumnWidth.base
      #expect(width >= previous, "\(band.name) is narrower than the band below it.")
      #expect(width <= SidebarColumnWidth.maximum, "\(band.name) passed the cap.")
      previous = width
    }
  }
}
