import SwiftUI

/// The label of a `.borderedProminent` button, in `\.themeAccentForeground` rather than the
/// style's fixed white. The accent fill stays unchanged; see CLAUDE.md, Style.
///
/// **It must be inside the label.** A `.foregroundStyle` on the `Button` is overridden by the
/// prominent style. Same shape as `BorderedButtonLabel`.
///
/// A `View`, not a `ViewModifier`, because a modifier's `@Environment` resolves above its
/// attachment point (CLAUDE.md, "Two environment rules").
struct ProminentButtonLabel<Content: View>: View {
  @Environment(\.themeAccentForeground) private var themeAccentForeground

  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content.foregroundStyle(themeAccentForeground)
  }
}

extension ProminentButtonLabel where Content == Text {
  /// A label that is only a title.
  init(_ title: String) {
    self.init { Text(title) }
  }
}
