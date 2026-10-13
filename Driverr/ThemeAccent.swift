import DriverrCore
import DriverrTerm
import SwiftUI

/// The chosen theme's accent, published into the environment for the whole app. The rules
/// are in CLAUDE.md, Style.
///
/// Two values, because a fill and a label on it are different questions: `themeAccent` is
/// the accent, and `themeAccentForeground` is the black or white that reads on it. The
/// second is in the environment so a new accent fill cannot bring back a fixed white.
private struct ThemeAccentKey: EnvironmentKey {
  /// `Color.accentColor`, so a preview or hosted test without the modifier still renders.
  static let defaultValue: Color = .accentColor
}

private struct ThemeAccentForegroundKey: EnvironmentKey {
  static let defaultValue: Color = .white
}

extension EnvironmentValues {
  /// The accent to draw with. **Read this, never `Color.accentColor`**, which is the system
  /// accent and ignores `.tint`.
  var themeAccent: Color {
    get { self[ThemeAccentKey.self] }
    set { self[ThemeAccentKey.self] = newValue }
  }

  /// Black or white, whichever reads on top of `themeAccent`. For a label or a glyph drawn
  /// *on* an accent fill, not for accent-coloured text on the app's own background.
  var themeAccentForeground: Color {
    get { self[ThemeAccentForegroundKey.self] }
    set { self[ThemeAccentForegroundKey.self] = newValue }
  }
}

extension View {
  /// Publishes `model`'s theme accent for this view and everything below it, and applies it
  /// as the root `.tint` for every control that takes the tint.
  ///
  /// **Attach at the top of the `WindowGroup` chain.** An environment value set below a
  /// sheet's or cover's attachment point does not reach the presented content.
  ///
  /// The model is a parameter, not an `@Environment` read, because a modifier's environment
  /// resolves above it (CLAUDE.md, "Two environment rules"). A wrong order would silently
  /// fall back to the system accent.
  func themeAccent(from model: SettingsModel) -> some View {
    modifier(ThemeAccentModifier(model: model))
  }
}

private struct ThemeAccentModifier: ViewModifier {
  /// Reading `settings` in `body` subscribes this modifier to theme changes.
  let model: SettingsModel

  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    let appearance: ThemeAppearance = colorScheme == .dark ? .dark : .light
    let accent = model.settings.theme.accent(for: appearance)
    let accentColor = accent.swiftUIColor
    let foregroundColor = accent.readableForeground.swiftUIColor
    return
      content
      .environment(\.themeAccent, accentColor)
      .environment(\.themeAccentForeground, foregroundColor)
      .tint(accentColor)
  }
}
