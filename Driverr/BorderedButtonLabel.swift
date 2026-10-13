import SwiftUI

/// The label of a `.bordered` button, in the flat label colour rather than in the tint.
///
/// `.bordered` colours both its fill and its label from the ambient `.tint`, which is the
/// theme's accent. The label then reads accent on 26 % accent, below 4.5:1 for most bundled
/// themes. `ThemeTests` checks the contrast of this label across the bundled set.
///
/// Use `Color.primary`, not the `.primary` shape style. `HierarchicalShapeStyle.primary`
/// resolves relative to the ambient foreground, so inside a tinted button it blends back to
/// the tint. Only a screenshot tells the two apart.
///
/// Apply it inside the button's label. A `.foregroundStyle` on the `Button` itself is
/// overridden by `.bordered`, which recolours the label from the tint.
struct BorderedButtonLabel<Content: View>: View {
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content.foregroundStyle(Color.primary)
  }
}

extension BorderedButtonLabel where Content == Text {
  /// The common case: a button whose whole label is one word of title.
  init(_ title: String) {
    self.init { Text(title) }
  }
}
