import SwiftUI
import Testing
import UIKit

@testable import Driverr

/// The Panes button's count must not cover its glyph at large text sizes.
///
/// A toolbar `.badge` draws with UIKit's own font and grew over the glyph at AX5.
/// `PanesButtonGlyph` draws the count itself and caps both at `.accessibility1`, and
/// `PanesButtonLabel` hands the toolbar two bitmaps. A toolbar glyph does not grow with Dynamic
/// Type while a `Text` does, so a count growing past the cap is the defect even where this
/// probe's own glyph grows with it.
///
/// `.serialized`: see `ChatGlassLayoutTests`.
@MainActor
@Suite("Panes button count", .serialized)
struct PanesButtonLabelLayoutTests {
  /// The live layout's glyph and count, and the toolbar label's own layout frame, at `size`.
  private func frames(at size: DynamicTypeSize) -> (glyph: CGRect, count: CGRect, label: CGRect) {
    var glyph = CGRect.zero
    var count = CGRect.zero
    var label = CGRect.zero
    let live = HostedProbe.window(
      PanesButtonGlyph(
        count: 1,
        onGlyphFrame: { glyph = $0 },
        onCountFrame: { count = $0 }
      )
      .environment(\.dynamicTypeSize, size),
      size: HostedProbe.phone
    )
    withExtendedLifetime(live) {}
    let flattened = HostedProbe.window(
      PanesButtonLabel(count: 1)
        .measuredFrame(into: { label = $0 })
        .environment(\.dynamicTypeSize, size),
      size: HostedProbe.phone
    )
    withExtendedLifetime(flattened) {}
    return (glyph, count, label)
  }

  /// The toolbar centres the label by its layout frame. A count that widened it pushed the grid
  /// off the centre of the "…" glyph beside it, so the label lays out exactly as the glyph does.
  @Test("the count takes no layout space", arguments: [DynamicTypeSize.large, .accessibility5])
  func theCountTakesNoLayoutSpace(size: DynamicTypeSize) {
    let (glyph, count, label) = frames(at: size)
    #expect(count.width > 0, "The count was not measured at \(size): \(count).")
    #expect(
      abs(label.width - glyph.width) < 0.5 && abs(label.height - glyph.height) < 0.5,
      """
      At \(size) the label lays out at \(label.size) against the glyph's \(glyph.size). The \
      count is taking layout space, so the toolbar centres glyph and count together and the \
      grid sits off the centre of its neighbour.
      """
    )
  }

  @Test("the count stops growing at AX1")
  func theCountIsCappedAtAX1() {
    let capped = frames(at: .accessibility1).count
    let largest = frames(at: .accessibility5).count
    #expect(capped.height > 0, "The count was not measured at AX1: \(capped).")
    #expect(
      largest.height <= capped.height + 0.5,
      """
      The count is \(largest.height) pt tall at AX5 against \(capped.height) pt at AX1, so it \
      is still growing past the cap. In the toolbar the glyph keeps its bar size \
      and a growing count ends up covering it. Check the `.dynamicTypeSize` cap in \
      `PanesButtonGlyph`.
      """
    )
  }

  @Test("the count covers less than half of the glyph at AX5")
  func theCountLeavesTheGlyphVisible() {
    let (glyph, count, _) = frames(at: .accessibility5)
    #expect(glyph.width > 0 && count.width > 0, "Not measured: glyph \(glyph), count \(count).")
    let overlap = glyph.intersection(count)
    let covered = overlap.isNull ? 0 : overlap.width * overlap.height
    let fraction = covered / (glyph.width * glyph.height)
    #expect(
      fraction < 0.5,
      """
      The count \(count) covers \(Int(fraction * 100))% of the glyph \(glyph) at AX5. The \
      count sits on the grid instead of on its corner.
      """
    )
  }
}
