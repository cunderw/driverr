import SwiftUI
import UIKit

/// The toolbar's Panes glyph with the count of waiting panes drawn on it.
///
/// **Not `.badge`.** A toolbar `.badge` becomes `UIBarButtonItem.badge`, whose font ignores
/// `.dynamicTypeSize(...)`, and at AX5 it grew to cover the glyph. `PanesButtonGlyph` is
/// plain SwiftUI, so its size cap applies to the count too.
///
/// Two bitmaps: the glyph with the count's shape cut out, and the count. Drawn live, the
/// toolbar draws the glyph in its own layer and the grid shows through the red fill as a
/// darker line. A live mask and `.compositingGroup()` did not remove it. A bitmap with a
/// hole has no ink there to show.
///
/// The glyph stays a template image, so it takes the toolbar's tint and disabled state. In
/// dark it is a shade darker than the "…" beside it, as every SwiftUI-drawn toolbar label
/// is. `ImageRenderer` does not inherit the environment, so every value the drawing depends
/// on is passed through.
///
/// The count is for the eye only. The button publishes it as its `accessibilityValue`.
struct PanesButtonLabel: View {
  let count: Int

  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.displayScale) private var displayScale
  @Environment(\.imageScale) private var imageScale
  @Environment(\.font) private var font
  @Environment(\.legibilityWeight) private var legibilityWeight
  @Environment(\.layoutDirection) private var layoutDirection
  @Environment(\.locale) private var locale

  var body: some View {
    if let glyph = render(PanesButtonGlyph(count: count, part: .glyph).padding(Self.overhang)),
      let bare = render(PanesButtonGlyph(count: 0))
    {
      // The layout frame is the bare glyph's. The toolbar centres the label by its layout
      // frame, so a count that widened it would push the grid off centre. Both bitmaps are
      // padded evenly, so their centre is the glyph's and they draw past the frame.
      Image(uiImage: glyph)
        .renderingMode(.template)
        .overlay {
          if count > 0,
            let badge = render(PanesButtonGlyph(count: count, part: .count).padding(Self.overhang))
          {
            Image(uiImage: badge).renderingMode(.original)
          }
        }
        .frame(width: bare.size.width, height: bare.size.height)
    } else {
      PanesButtonGlyph(count: count)
    }
  }

  /// Room on every side for the half of the count that hangs past the glyph's corner.
  static let overhang: CGFloat = 16

  private func render(_ content: some View) -> UIImage? {
    let renderer = ImageRenderer(
      content:
        content
        .font(font)
        .imageScale(imageScale)
        .environment(\.dynamicTypeSize, typeSize)
        .environment(\.colorScheme, colorScheme)
        .environment(\.legibilityWeight, legibilityWeight)
        .environment(\.layoutDirection, layoutDirection)
        .environment(\.locale, locale)
    )
    renderer.scale = displayScale
    return renderer.uiImage
  }
}

/// The grid glyph and the count, laid out live. `PanesButtonLabel` flattens it for the
/// toolbar, and `PanesButtonLabelLayoutTests` lays it out directly.
///
/// No count at 0, the same as `.badge(0)`.
struct PanesButtonGlyph: View {
  let count: Int

  /// What to draw. `PanesButtonLabel` renders the glyph and the count as separate bitmaps.
  enum Part {
    /// The glyph and the count together, as laid out.
    case whole
    /// The glyph alone, with the count's shape cut out of it.
    case glyph
    /// The count alone, where it sits on the glyph.
    case count
  }

  var part: Part = .whole

  /// Where a hosted layout test reads the glyph's and the count's resolved frames. Same
  /// contract as `ProvenanceRow.onCaptionFrame`.
  var onGlyphFrame: (@MainActor (CGRect) -> Void)?
  var onCountFrame: (@MainActor (CGRect) -> Void)?

  var body: some View {
    // **Not a `Label`.** Given a `Label`, the toolbar kept only its icon's symbol and dropped
    // the count.
    Image(systemName: "square.grid.2x2")
      .opacity(part == .count ? 0 : 1)
      .background { measurement(onGlyphFrame) }
      .overlay(alignment: .topTrailing) {
        if count > 0 {
          // Centred on the glyph's top-trailing corner, where the system badge sits. A
          // zero-size frame puts its centre on the corner and takes no layout space.
          // Alignment guides on an overlay's content are ignored here.
          Group {
            if part == .glyph {
              // The cut is the count's own capsule grown by 1 pt, so a thin gap parts the
              // count from the grid, as the system badge's does.
              countBadge
                .padding(1)
                .background(Capsule())
                .blendMode(.destinationOut)
            } else {
              countBadge
                .background { measurement(onCountFrame) }
            }
          }
          .frame(width: 0, height: 0)
        }
      }
      .compositingGroup()
      // Past `.accessibility1` the glyph and count stop growing, so their proportions hold.
      // The button's Large Content Viewer serves a reader who needs larger.
      .dynamicTypeSize(...DynamicTypeSize.accessibility1)
  }

  private var countBadge: some View {
    Text(count, format: .number)
      .font(.caption2.weight(.semibold).monospacedDigit())
      .foregroundStyle(.white)
      .padding(.horizontal, 4)
      .frame(minWidth: 16, minHeight: 16)
      .background(Capsule().fill(.red))
      .fixedSize()
  }

  @ViewBuilder private func measurement(_ sink: (@MainActor (CGRect) -> Void)?) -> some View {
    if let sink {
      GeometryReader { proxy in
        Color.clear.onAppear { sink(proxy.frame(in: .global)) }
      }
    }
  }
}
