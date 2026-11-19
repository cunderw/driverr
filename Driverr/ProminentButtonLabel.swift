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
/// or white on it read at 1.68:1 in dark. Disabled, the label is left to the style, which draws
/// the platform's disabled colour.
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
      content
    }
  }
}

extension ProminentButtonLabel where Content == Text {
  /// A label that is only a title.
  init(_ title: String) {
    self.init { Text(title) }
  }
}
