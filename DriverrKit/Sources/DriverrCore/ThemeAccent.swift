import Foundation

/// The app's accent colour, derived from the chosen theme.
///
/// The theme drives the accent and nothing else. Every other surface stays semantic, so the
/// app still reads as a system app. ANSI 4 is the seed rather than a hand-authored field,
/// so a new theme cannot ship without an accent and `ThemeTests` checks every bundled one.
/// The cursor slot is not used, because every bundled cursor is a near-foreground grey.
extension Theme {
  /// The accent for the appearance being rendered: ANSI 4, lifted in dark until it reads.
  ///
  /// Light is the palette's raw value. Upstream palettes keep their published values, and
  /// where the accent is a fill the foreground switches instead
  /// (`TerminalColor.readableForeground`). Never fall back to the system accent.
  ///
  /// Dark lifts the seed, because in dark the accent is mostly drawn on a dark surface (a
  /// checkmark, a toolbar glyph) with no foreground to switch. The default theme's `#064EF4`
  /// reads 2.26:1 on the `#2C2C2E` grouped row, so ANSI 4 is blended toward white, keeping
  /// its hue, by the least amount that reads 4.5:1. A seed that already clears is unchanged.
  /// The terminal palette never changes.
  public func accent(for appearance: ThemeAppearance) -> TerminalColor {
    let seed = palette(for: appearance).ansi[4]
    switch appearance {
    case .light: return seed
    case .dark: return seed.lifted(toReach: 4.5, against: Self.darkGroupedRow)
    }
  }

  /// `secondarySystemGroupedBackground` in dark, an `insetGrouped` list's row colour. The
  /// dark accent is lifted against this.
  static let darkGroupedRow = TerminalColor(hex: 0x2C2C_2E)
}

extension TerminalColor {
  /// `self`, blended toward white by the **least** amount that clears `minimumContrast`
  /// against `background`, found by binary search. Returns `self` when it already clears.
  /// The mirror of `dimmed(against:)`, which finds the *most* it can move. Assumes white
  /// clears the floor, which holds only against a dark background.
  func lifted(toReach minimumContrast: Double, against background: TerminalColor) -> TerminalColor {
    guard contrastRatio(self, background) < minimumContrast else { return self }
    let white = TerminalColor(hex: 0xFFFF_FF)
    var failing = 0.0
    var passing = 1.0
    for _ in 0..<24 {
      let midpoint = (passing + failing) / 2
      if contrastRatio(blended(toward: white, by: midpoint), background) >= minimumContrast {
        passing = midpoint
      } else {
        failing = midpoint
      }
    }
    return blended(toward: white, by: passing)
  }
}

extension TerminalColor {
  /// Black or white, whichever reads better on top of `self`.
  ///
  /// For a label or glyph on an accent fill (the Send button today), instead of a fixed white
  /// that fails on a light theme's blue. Only the two absolutes, so the label does not compete
  /// with the fill; one of them always clears 4.5:1, which `ThemeTests` asserts for the
  /// bundled themes.
  public var readableForeground: TerminalColor {
    let black = TerminalColor(hex: 0x0000_00)
    let white = TerminalColor(hex: 0xFFFF_FF)
    return contrastRatio(black, self) >= contrastRatio(white, self) ? black : white
  }
}
