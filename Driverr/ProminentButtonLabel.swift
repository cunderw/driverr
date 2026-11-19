import SwiftUI

/// The label of a `.borderedProminent` button, in `\.themeAccentForeground` rather than the
/// style's fixed white. The accent fill stays unchanged; see CLAUDE.md, Style.
///
/// **It must be inside the label.** A `.foregroundStyle` on the `Button` is overridden by the
/// prominent style. Same shape as `BorderedButtonLabel`.
///
/// A `View`, not a `ViewModifier`, because a modifier's `@Environment` resolves above its
/// attachment point (CLAUDE.md, "Two environment rules").
///
/// **Only while enabled.** A disabled prominent button draws a grey fill, and the accent's black
/// or white on it read at 1.68:1 in dark. The style's own disabled label measured 1.78:1 on the
/// same fill, so a disabled label is `Color.secondary`, which measured 3.31:1 there. Not
/// `.secondary`, which blends with the button's tint.
struct ProminentButtonLabel<Content: View>: View {
  @Environment(\.themeAccentForeground) private var themeAccentForeground
  @Environment(\.isEnabled) private var isEnabled

  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  @ViewBuilder
  var body: some View {
    if isEnabled {
      content.foregroundStyle(themeAccentForeground)
    } else {
      content.foregroundStyle(Color.secondary)
    }
  }
}

extension ProminentButtonLabel where Content == Text {
  /// A label that is only a title.
  init(_ title: String) {
    self.init { Text(title) }
  }
}
