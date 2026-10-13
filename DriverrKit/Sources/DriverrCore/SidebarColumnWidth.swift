import Foundation

/// How wide the host list column is allowed to get.
///
/// The iPad sidebar is a fixed 320 pt at every text size, so at accessibility sizes host
/// names hyphenate. `@ScaledMetric` grows the width with the text, but unclamped it reaches
/// about 900 pt, most of a 1032 pt iPad. So the scaled number is an input to this rule.
///
/// At the default text size the rule returns `nil` and leaves the system's width alone,
/// because that width varies (320 on iPad, 382 on a Pro Max in landscape).
///
/// The accepted cost: on a Pro Max in landscape, two text size bands (349 and 378.3) come
/// out under 382, narrowing the sidebar by up to 33 pt. A per-device floor would cost more.
/// On iPad the column only grows.
public enum SidebarColumnWidth {
  /// The base the view scales: the iPad sidebar's default width, so at the default size the
  /// rule declines.
  public static let base: Double = 320

  /// The widest the column may get. It binds from `xxxLarge` up. It leaves 612 pt of a
  /// 13-inch iPad for the host screen, still wider than the 402 pt phone the app is designed
  /// against.
  public static let maximum: Double = 420

  /// Half a point of slack, so rounding at the default size does not trip the comparison.
  private static let tolerance: Double = 0.5

  /// The ideal width for this text size, or `nil` to leave the platform's own alone.
  ///
  /// - Parameter scaledBase: `base` scaled as `@ScaledMetric(relativeTo: .body)` does.
  ///   `SidebarColumnWidthBandTests` feeds the real `UIFontMetrics` values.
  public static func ideal(scaledBase: Double) -> Double? {
    guard scaledBase > base + tolerance else { return nil }
    return min(scaledBase, maximum)
  }
}
