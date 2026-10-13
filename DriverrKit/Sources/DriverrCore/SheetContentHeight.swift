import Foundation

/// What a form sheet's scroll view reported about itself. One `ScrollGeometry` read gives
/// both numbers, and a height means something only beside its container's.
public struct SheetContentMeasurement: Equatable, Sendable {
  /// `contentSize.height` plus the top content inset, which in a `NavigationStack` is the
  /// bar. Not the bottom inset, which takes keyboard avoidance and would grow the sheet while
  /// typing.
  public var content: Double

  /// `containerSize.height`: the sheet's current inner height.
  public var container: Double

  public init(content: Double, container: Double) {
    self.content = content
    self.container = container
  }
}

/// How tall a form sheet should be, once its content has measured itself.
///
/// `PresentationSizing` cannot do it. `.presentationSizing(.fitted)` is ignored on a `Form`
/// or `List` and collapses a `NavigationStack` to a small stub, because a scroll view has no
/// ideal size. A custom `PresentationSizing` is read once at presentation and later changes
/// are ignored, so a height measured after the first frame can never reach it.
///
/// `preferredContentSize` on the presented view controller is re-read by UIKit.
/// `FittedSheetHeight` sets that; this is its arithmetic, here so `swift test` covers it.
public enum SheetContentHeight {
  /// The shortest sheet this rule asks for. A scroll view reports zero content on its first
  /// frame, and a height from that is the stub collapse. Anything shorter reads as "not
  /// measured yet" and gets `nil`, so the worst case is the full-height sheet.
  public static let minimum: Double = 240

  /// How much shorter than natural a sheet must be to be worth resizing.
  public static let slack: Double = 8

  /// The height to ask for, or `nil` to leave the platform's own height alone.
  ///
  /// `natural` is the sheet's height before anything was applied, captured once. The
  /// container shrinks once a height is applied, so comparing against the current container
  /// would find no difference, restore the natural height, and shrink again: an unbounded
  /// oscillation.
  ///
  /// - Parameters:
  ///   - content: the measured content height, or `nil` before the first measurement.
  ///   - natural: the sheet's own height before this rule touched it, or `nil` if unknown.
  ///   - minimum: the height below which a number is read as "not measured yet".
  /// - Returns: the height to ask for, or `nil` to leave it alone, including for a sheet
  ///   already shrunk whose content has since outgrown it.
  public static func fitted(
    content: Double?,
    natural: Double?,
    minimum: Double = minimum
  ) -> Double? {
    guard let content, let natural else { return nil }
    guard content > minimum, natural > minimum else { return nil }
    guard natural - content >= slack else { return nil }
    return content
  }
}
