import Foundation

/// A colour, as three 8-bit channels.
///
/// Not `SwiftUI.Color` or `UIColor`, because `DriverrCore` has no dependencies and a theme
/// has to compare in tests, encode into settings and reach SwiftTerm. Each renderer
/// converts at its own boundary.
public struct TerminalColor: Hashable, Sendable, Codable {
  public let red: UInt8
  public let green: UInt8
  public let blue: UInt8

  public init(red: UInt8, green: UInt8, blue: UInt8) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  /// `0xRRGGBB`, the form palettes are published in, so values copy without transcription.
  public init(hex: UInt32) {
    self.init(
      red: UInt8((hex >> 16) & 0xFF),
      green: UInt8((hex >> 8) & 0xFF),
      blue: UInt8(hex & 0xFF)
    )
  }

  /// WCAG relative luminance, which `contrastRatio` uses.
  public var relativeLuminance: Double {
    func linear(_ channel: UInt8) -> Double {
      let value = Double(channel) / 255
      return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  /// A point between `self` and `other`: `fraction` 0 is `self`, 1 is `other`.
  func blended(toward other: TerminalColor, by fraction: Double) -> TerminalColor {
    func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
      UInt8((Double(a) * (1 - fraction) + Double(b) * fraction).rounded().clamped(to: 0...255))
    }
    return TerminalColor(red: mix(red, other.red), green: mix(green, other.green), blue: mix(blue, other.blue))
  }

  /// `self` dimmed toward `background` as far as it can go while still clearing
  /// `minimumContrast`. A fixed opacity dim fails contrast on light themes.
  ///
  /// Binary search for the most-dimmed passing point, so dim text reads as dim. When full
  /// strength already fails the floor, returns `self` undimmed, the least-wrong answer.
  public func dimmed(against background: TerminalColor, minimumContrast: Double = 4.5) -> TerminalColor {
    guard contrastRatio(self, background) >= minimumContrast else { return self }
    var passing = 0.0
    var failing = 1.0
    for _ in 0..<24 {
      let midpoint = (passing + failing) / 2
      let candidate = blended(toward: background, by: midpoint)
      if contrastRatio(candidate, background) >= minimumContrast {
        passing = midpoint
      } else {
        failing = midpoint
      }
    }
    return blended(toward: background, by: passing)
  }
}

extension Comparable {
  fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}

/// The WCAG contrast ratio between two colours: 1:1 is none, 21:1 is black on white.
public func contrastRatio(_ first: TerminalColor, _ second: TerminalColor) -> Double {
  let lighter = max(first.relativeLuminance, second.relativeLuminance)
  let darker = min(first.relativeLuminance, second.relativeLuminance)
  return (lighter + 0.05) / (darker + 0.05)
}

/// The colours a terminal needs: a surface, a cursor, and the sixteen ANSI slots. The
/// emulator computes the 256-colour cube and 24-bit colours itself.
public struct TerminalPalette: Hashable, Sendable {
  public let background: TerminalColor
  public let foreground: TerminalColor
  public let cursor: TerminalColor
  /// ANSI 0–15: black, red, green, yellow, blue, magenta, cyan, white, then their bright
  /// variants.
  ///
  /// Always `Self.ansiSlotCount` entries. `init` pads with `foreground` or truncates rather
  /// than trapping, so a short palette renders slightly wrong instead of crashing.
  public let ansi: [TerminalColor]

  public static let ansiSlotCount = 16

  public init(
    background: TerminalColor,
    foreground: TerminalColor,
    cursor: TerminalColor,
    ansi: [TerminalColor]
  ) {
    self.background = background
    self.foreground = foreground
    self.cursor = cursor
    if ansi.count == Self.ansiSlotCount {
      self.ansi = ansi
    } else if ansi.count > Self.ansiSlotCount {
      self.ansi = Array(ansi.prefix(Self.ansiSlotCount))
    } else {
      self.ansi = ansi + Array(repeating: foreground, count: Self.ansiSlotCount - ansi.count)
    }
  }
}

/// A named pair of palettes, one for each system appearance. The terminal follows the
/// system appearance and offers no override, so each theme carries both halves.
public struct Theme: Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let light: TerminalPalette
  public let dark: TerminalPalette

  public init(id: String, name: String, light: TerminalPalette, dark: TerminalPalette) {
    self.id = id
    self.name = name
    self.light = light
    self.dark = dark
  }

  public func palette(for appearance: ThemeAppearance) -> TerminalPalette {
    switch appearance {
    case .light: light
    case .dark: dark
    }
  }
}

/// Which half of a `Theme` to render with. A stand-in for `SwiftUI.ColorScheme`, so this
/// module stays free of SwiftUI.
public enum ThemeAppearance: String, Hashable, Sendable, CaseIterable {
  case light
  case dark
}

extension Theme {
  /// The bundled set. A new theme has to argue its case, like a new setting.
  ///
  /// Upstream palettes (Solarized, Tokyo Night, Catppuccin, Gruvbox, Dracula, One Dark) are
  /// transcribed as published and are not held to Driverr's 3:1 ANSI floor. A user who picks
  /// Solarized asks for Solarized. Their slots under 3:1 are listed in
  /// `ThemeTests.ContrastException`. Do not change one of those values: it would fork the
  /// theme.
  ///
  /// Driverr's own palettes (`system` in both halves, and `nordLightANSI`) are held to the
  /// floor with headroom. Anything invented here later joins them.
  public static let bundled: [Theme] = [
    .system, .solarized, .nord, .tokyoNight, .catppuccin, .gruvbox, .dracula, .oneDark,
  ]

  /// A fresh install's theme: readable ANSI on the system's own surface colours.
  public static let `default`: Theme = .system

  /// Looks a theme up by `id`, falling back to the default, so a build that drops a theme
  /// can still render a persisted id.
  public static func bundled(id: String) -> Theme {
    bundled.first { $0.id == id } ?? .default
  }

  public static let system = Theme(
    id: "system",
    name: "System",
    light: TerminalPalette(
      background: TerminalColor(hex: 0xFFFF_FF),
      foreground: TerminalColor(hex: 0x1C1C_1E),
      cursor: TerminalColor(hex: 0x1C1C_1E),
      ansi: Theme.systemLightANSI
    ),
    dark: TerminalPalette(
      background: TerminalColor(hex: 0x0000_00),
      foreground: TerminalColor(hex: 0xE5E5_EA),
      cursor: TerminalColor(hex: 0xE5E5_EA),
      ansi: Theme.systemDarkANSI
    )
  )

  public static let solarized = Theme(
    id: "solarized",
    name: "Solarized",
    light: TerminalPalette(
      background: TerminalColor(hex: 0xFDF6_E3),
      foreground: TerminalColor(hex: 0x657B_83),
      cursor: TerminalColor(hex: 0x586E_75),
      ansi: Theme.solarizedANSI
    ),
    dark: TerminalPalette(
      background: TerminalColor(hex: 0x002B_36),
      foreground: TerminalColor(hex: 0x8394_96),
      cursor: TerminalColor(hex: 0x93A1_A1),
      ansi: Theme.solarizedANSI
    )
  )

  public static let nord = Theme(
    id: "nord",
    name: "Nord",
    light: TerminalPalette(
      background: TerminalColor(hex: 0xECEF_F4),
      foreground: TerminalColor(hex: 0x2E34_40),
      cursor: TerminalColor(hex: 0x2E34_40),
      ansi: Theme.nordLightANSI
    ),
    dark: TerminalPalette(
      background: TerminalColor(hex: 0x2E34_40),
      foreground: TerminalColor(hex: 0xD8DE_E9),
      cursor: TerminalColor(hex: 0xD8DE_E9),
      ansi: Theme.nordDarkANSI
    )
  )

  /// Tokyo Night, with its Day variant for light. From `folke/tokyonight.nvim`'s kitty
  /// extras, the only published form that names a cursor.
  public static let tokyoNight = Theme(
    id: "tokyo-night",
    name: "Tokyo Night",
    light: TerminalPalette(
      background: TerminalColor(hex: 0xE1E2_E7),
      foreground: TerminalColor(hex: 0x3760_BF),
      cursor: TerminalColor(hex: 0x3760_BF),
      ansi: Theme.tokyoNightDayANSI
    ),
    dark: TerminalPalette(
      background: TerminalColor(hex: 0x1A1B_26),
      foreground: TerminalColor(hex: 0xC0CA_F5),
      cursor: TerminalColor(hex: 0xC0CA_F5),
      ansi: Theme.tokyoNightANSI
    )
  )

  /// Catppuccin: Mocha for dark, Latte for light. From `catppuccin/alacritty`, cursor
  /// Rosewater as published.
  public static let catppuccin = Theme(
    id: "catppuccin",
    name: "Catppuccin",
    light: TerminalPalette(
      background: TerminalColor(hex: 0xEFF1_F5),
      foreground: TerminalColor(hex: 0x4C4F_69),
      cursor: TerminalColor(hex: 0xDC8A_78),
      ansi: Theme.catppuccinLatteANSI
    ),
    dark: TerminalPalette(
      background: TerminalColor(hex: 0x1E1E_2E),
      foreground: TerminalColor(hex: 0xCDD6_F4),
      cursor: TerminalColor(hex: 0xF5E0_DC),
      ansi: Theme.catppuccinMochaANSI
    )
  )

  /// Gruvbox at medium contrast, from `morhetz/gruvbox-contrib`'s xresources. Neither file
  /// sets a cursor, so the foreground is used.
  public static let gruvbox = Theme(
    id: "gruvbox",
    name: "Gruvbox",
    light: TerminalPalette(
      background: TerminalColor(hex: 0xFBF1_C7),
      foreground: TerminalColor(hex: 0x3C38_36),
      cursor: TerminalColor(hex: 0x3C38_36),
      ansi: Theme.gruvboxLightANSI
    ),
    dark: TerminalPalette(
      background: TerminalColor(hex: 0x2828_28),
      foreground: TerminalColor(hex: 0xEBDB_B2),
      cursor: TerminalColor(hex: 0xEBDB_B2),
      ansi: Theme.gruvboxDarkANSI
    )
  )

  /// Dracula, with Alucard for light. ANSI sets from `spec.draculatheme.com`. The dark
  /// surface, foreground and cursor from `dracula/alacritty`.
  ///
  /// Alucard is newer and less familiar than Dracula, but it is the project's own light
  /// theme. Dracula's colours are unreadable on a light surface, so this is the better
  /// choice.
  public static let dracula = Theme(
    id: "dracula",
    name: "Dracula",
    light: TerminalPalette(
      // Alucard Classic. The spec gives no cursor colour, so the foreground is used.
      background: TerminalColor(hex: 0xFFFB_EB),
      foreground: TerminalColor(hex: 0x1F1F_1F),
      cursor: TerminalColor(hex: 0x1F1F_1F),
      ansi: Theme.alucardANSI
    ),
    dark: TerminalPalette(
      background: TerminalColor(hex: 0x282A_36),
      foreground: TerminalColor(hex: 0xF8F8_F2),
      cursor: TerminalColor(hex: 0xF8F8_F2),
      ansi: Theme.draculaANSI
    )
  )

  /// One Dark, with One Light.
  ///
  /// The dark half is from `alacritty/alacritty-theme`'s `one_dark.toml`. Every colour is
  /// one of `atom/one-dark-syntax`'s hues.
  ///
  /// One Light publishes no terminal palette, and the circulated ones are wrong (green and
  /// cyan share a value). So the light half takes `atom/one-light-syntax`'s colours in One
  /// Dark's hue mapping, with the monochrome slots ordered for a light surface: 0 the
  /// surface, 8 `@mono-3`, 7 `@mono-2`, 15 `@mono-1`. That mapping is the one authored
  /// decision here.
  ///
  /// Both cursors are Atom's `@syntax-accent` as the VS Code ports publish it. Recomputing
  /// it would round One Light's green channel, exactly `110.5`, either way.
  public static let oneDark = Theme(
    id: "one-dark",
    name: "One Dark",
    light: TerminalPalette(
      background: TerminalColor(hex: 0xFAFA_FA),
      foreground: TerminalColor(hex: 0x383A_42),
      cursor: TerminalColor(hex: 0x526F_FF),
      ansi: Theme.oneLightANSI
    ),
    dark: TerminalPalette(
      background: TerminalColor(hex: 0x282C_34),
      foreground: TerminalColor(hex: 0xABB2_BF),
      cursor: TerminalColor(hex: 0x528B_FF),
      ansi: Theme.oneDarkANSI
    )
  )

  /// Solarized uses one ANSI table for both appearances, as upstream publishes it. Every
  /// other theme gives each appearance its own array, because a light surface needs darker
  /// ink. Sharing one array is what made System's and Nord's light halves unreadable.
  ///
  /// System's arrays are Driverr's own. The traditional VGA and Terminal.app values fail
  /// contrast (green `#00CD00` on white is 2.16:1), so there is no upstream to copy. Red,
  /// green, blue and their brights clear 3:1 against white or black with headroom, so
  /// rounding cannot drop a slot under the floor `ThemeTests` enforces.
  ///
  /// `systemLightANSI` inverts the greyscale: slot 0 (black) is a near-background grey and
  /// slot 15 (bright white) is the ink. On a light surface black text is common and must be
  /// legible, while bright white is rare. Gruvbox Light and One Light make the same choice.
  /// Slot 0 is `#F2F2F7`, not `#FFFFFF`, so it stays distinct from the background; see
  /// `ThemeTests.systemGreyscaleSlotsStayDistinguishableFromBackground`.
  private static let systemLightANSI: [TerminalColor] = [
    TerminalColor(hex: 0xF2F2_F7), TerminalColor(hex: 0xF153_61),
    TerminalColor(hex: 0x0DA1_32), TerminalColor(hex: 0xB582_0A),
    TerminalColor(hex: 0x5786_F6), TerminalColor(hex: 0xDF49_DF),
    TerminalColor(hex: 0x0998_AE), TerminalColor(hex: 0x8E8E_93),
    TerminalColor(hex: 0x6C6C_70), TerminalColor(hex: 0xFA35_46),
    TerminalColor(hex: 0x049A_2A), TerminalColor(hex: 0xAF7B_00),
    TerminalColor(hex: 0x467D_FF), TerminalColor(hex: 0xE61C_E6),
    TerminalColor(hex: 0x0091_A8), TerminalColor(hex: 0x1C1C_1E),
  ]

  private static let systemDarkANSI: [TerminalColor] = [
    TerminalColor(hex: 0x2C2C_2E), TerminalColor(hex: 0xC310_1F),
    TerminalColor(hex: 0x1071_28), TerminalColor(hex: 0x7560_09),
    TerminalColor(hex: 0x064E_F4), TerminalColor(hex: 0xAA18_AA),
    TerminalColor(hex: 0x0E6B_7A), TerminalColor(hex: 0xAEAE_B2),
    TerminalColor(hex: 0x8E8E_93), TerminalColor(hex: 0xFA2D_3E),
    TerminalColor(hex: 0x0C98_2F), TerminalColor(hex: 0x9E80_04),
    TerminalColor(hex: 0x427B_FF), TerminalColor(hex: 0xE412_E4),
    TerminalColor(hex: 0x0990_A4), TerminalColor(hex: 0xE5E5_EA),
  ]

  /// As published. ANSI 8 is base03, which is also Solarized's dark background.
  private static let solarizedANSI: [TerminalColor] = [
    TerminalColor(hex: 0x0736_42), TerminalColor(hex: 0xDC32_2F),
    TerminalColor(hex: 0x8599_00), TerminalColor(hex: 0xB589_00),
    TerminalColor(hex: 0x268B_D2), TerminalColor(hex: 0xD336_82),
    TerminalColor(hex: 0x2AA1_98), TerminalColor(hex: 0xEEE8_D5),
    TerminalColor(hex: 0x002B_36), TerminalColor(hex: 0xCB4B_16),
    TerminalColor(hex: 0x586E_75), TerminalColor(hex: 0x657B_83),
    TerminalColor(hex: 0x8394_96), TerminalColor(hex: 0x6C71_C4),
    TerminalColor(hex: 0x93A1_A1), TerminalColor(hex: 0xFDF6_E3),
  ]

  /// Nord's dark half, as published. Its red, green, blue and their brights already clear
  /// 3:1.
  private static let nordDarkANSI: [TerminalColor] = [
    TerminalColor(hex: 0x3B42_52), TerminalColor(hex: 0xBF61_6A),
    TerminalColor(hex: 0xA3BE_8C), TerminalColor(hex: 0xEBCB_8B),
    TerminalColor(hex: 0x81A1_C1), TerminalColor(hex: 0xB48E_AD),
    TerminalColor(hex: 0x88C0_D0), TerminalColor(hex: 0xE5E9_F0),
    TerminalColor(hex: 0x4C56_6A), TerminalColor(hex: 0xBF61_6A),
    TerminalColor(hex: 0xA3BE_8C), TerminalColor(hex: 0xEBCB_8B),
    TerminalColor(hex: 0x81A1_C1), TerminalColor(hex: 0xB48E_AD),
    TerminalColor(hex: 0x8FBC_BB), TerminalColor(hex: 0xECEF_F4),
  ]

  /// Nord's light half, Driverr's own. Nord publishes no light palette, and its pastels are
  /// unreadable on light. Darker inks in Nord's hue families, with red, green, blue and their
  /// brights clearing 3:1 against `#ECEFF4`. Brights repeat the normals, as in
  /// `nordDarkANSI`. The last slot is Nord's dark background, used as ink.
  private static let nordLightANSI: [TerminalColor] = [
    TerminalColor(hex: 0xECEF_F4), TerminalColor(hex: 0xCA5F_68),
    TerminalColor(hex: 0x658B_43), TerminalColor(hex: 0xA27A_29),
    TerminalColor(hex: 0x4D84_BC), TerminalColor(hex: 0xAE69_A2),
    TerminalColor(hex: 0x3D8A_A0), TerminalColor(hex: 0x9096_A6),
    TerminalColor(hex: 0x7B83_94), TerminalColor(hex: 0xCA5F_68),
    TerminalColor(hex: 0x658B_43), TerminalColor(hex: 0xA27A_29),
    TerminalColor(hex: 0x4D84_BC), TerminalColor(hex: 0xAE69_A2),
    TerminalColor(hex: 0x3D8A_A0), TerminalColor(hex: 0x2E34_40),
  ]

  /// folke/tokyonight.nvim, `extras/kitty/tokyonight_night.conf`.
  private static let tokyoNightANSI: [TerminalColor] = [
    TerminalColor(hex: 0x1516_1E), TerminalColor(hex: 0xF776_8E),
    TerminalColor(hex: 0x9ECE_6A), TerminalColor(hex: 0xE0AF_68),
    TerminalColor(hex: 0x7AA2_F7), TerminalColor(hex: 0xBB9A_F7),
    TerminalColor(hex: 0x7DCF_FF), TerminalColor(hex: 0xA9B1_D6),
    TerminalColor(hex: 0x4148_68), TerminalColor(hex: 0xFF89_9D),
    TerminalColor(hex: 0x9FE0_44), TerminalColor(hex: 0xFABA_4A),
    TerminalColor(hex: 0x8DB0_FF), TerminalColor(hex: 0xC7A9_FF),
    TerminalColor(hex: 0xA4DA_FF), TerminalColor(hex: 0xC0CA_F5),
  ]

  /// folke/tokyonight.nvim, `extras/kitty/tokyonight_day.conf`.
  private static let tokyoNightDayANSI: [TerminalColor] = [
    TerminalColor(hex: 0xB4B5_B9), TerminalColor(hex: 0xF52A_65),
    TerminalColor(hex: 0x5875_39), TerminalColor(hex: 0x8C6C_3E),
    TerminalColor(hex: 0x2E7D_E9), TerminalColor(hex: 0x9854_F1),
    TerminalColor(hex: 0x0071_97), TerminalColor(hex: 0x6172_B0),
    TerminalColor(hex: 0xA1A6_C5), TerminalColor(hex: 0xFF47_74),
    TerminalColor(hex: 0x5C85_24), TerminalColor(hex: 0xA276_29),
    TerminalColor(hex: 0x358A_FF), TerminalColor(hex: 0xA463_FF),
    TerminalColor(hex: 0x007E_A8), TerminalColor(hex: 0x3760_BF),
  ]

  /// catppuccin/alacritty, `catppuccin-mocha.toml`.
  private static let catppuccinMochaANSI: [TerminalColor] = [
    TerminalColor(hex: 0x4547_5A), TerminalColor(hex: 0xF38B_A8),
    TerminalColor(hex: 0xA6E3_A1), TerminalColor(hex: 0xF9E2_AF),
    TerminalColor(hex: 0x89B4_FA), TerminalColor(hex: 0xF5C2_E7),
    TerminalColor(hex: 0x94E2_D5), TerminalColor(hex: 0xBAC2_DE),
    TerminalColor(hex: 0x585B_70), TerminalColor(hex: 0xF38B_A8),
    TerminalColor(hex: 0xA6E3_A1), TerminalColor(hex: 0xF9E2_AF),
    TerminalColor(hex: 0x89B4_FA), TerminalColor(hex: 0xF5C2_E7),
    TerminalColor(hex: 0x94E2_D5), TerminalColor(hex: 0xA6AD_C8),
  ]

  /// catppuccin/alacritty, `catppuccin-latte.toml`.
  private static let catppuccinLatteANSI: [TerminalColor] = [
    TerminalColor(hex: 0xBCC0_CC), TerminalColor(hex: 0xD20F_39),
    TerminalColor(hex: 0x40A0_2B), TerminalColor(hex: 0xDF8E_1D),
    TerminalColor(hex: 0x1E66_F5), TerminalColor(hex: 0xEA76_CB),
    TerminalColor(hex: 0x1792_99), TerminalColor(hex: 0x5C5F_77),
    TerminalColor(hex: 0xACB0_BE), TerminalColor(hex: 0xD20F_39),
    TerminalColor(hex: 0x40A0_2B), TerminalColor(hex: 0xDF8E_1D),
    TerminalColor(hex: 0x1E66_F5), TerminalColor(hex: 0xEA76_CB),
    TerminalColor(hex: 0x1792_99), TerminalColor(hex: 0x6C6F_85),
  ]

  /// morhetz/gruvbox-contrib, `xresources/gruvbox-dark.xresources`, in `*color0`…`*color15`
  /// order rather than the file's printed order.
  private static let gruvboxDarkANSI: [TerminalColor] = [
    TerminalColor(hex: 0x2828_28), TerminalColor(hex: 0xCC24_1D),
    TerminalColor(hex: 0x9897_1A), TerminalColor(hex: 0xD799_21),
    TerminalColor(hex: 0x4585_88), TerminalColor(hex: 0xB162_86),
    TerminalColor(hex: 0x689D_6A), TerminalColor(hex: 0xA899_84),
    TerminalColor(hex: 0x9283_74), TerminalColor(hex: 0xFB49_34),
    TerminalColor(hex: 0xB8BB_26), TerminalColor(hex: 0xFABD_2F),
    TerminalColor(hex: 0x83A5_98), TerminalColor(hex: 0xD386_9B),
    TerminalColor(hex: 0x8EC0_7C), TerminalColor(hex: 0xEBDB_B2),
  ]

  /// morhetz/gruvbox-contrib, `xresources/gruvbox-light.xresources`.
  private static let gruvboxLightANSI: [TerminalColor] = [
    TerminalColor(hex: 0xFDF4_C1), TerminalColor(hex: 0xCC24_1D),
    TerminalColor(hex: 0x9897_1A), TerminalColor(hex: 0xD799_21),
    TerminalColor(hex: 0x4585_88), TerminalColor(hex: 0xB162_86),
    TerminalColor(hex: 0x689D_6A), TerminalColor(hex: 0x7C6F_64),
    TerminalColor(hex: 0x9283_74), TerminalColor(hex: 0x9D00_06),
    TerminalColor(hex: 0x7974_0E), TerminalColor(hex: 0xB576_14),
    TerminalColor(hex: 0x0766_78), TerminalColor(hex: 0x8F3F_71),
    TerminalColor(hex: 0x427B_58), TerminalColor(hex: 0x3C38_36),
  ]

  /// spec.draculatheme.com, "ANSI Color Palette" → Dracula Classic.
  private static let draculaANSI: [TerminalColor] = [
    TerminalColor(hex: 0x2122_2C), TerminalColor(hex: 0xFF55_55),
    TerminalColor(hex: 0x50FA_7B), TerminalColor(hex: 0xF1FA_8C),
    TerminalColor(hex: 0xBD93_F9), TerminalColor(hex: 0xFF79_C6),
    TerminalColor(hex: 0x8BE9_FD), TerminalColor(hex: 0xF8F8_F2),
    TerminalColor(hex: 0x6272_A4), TerminalColor(hex: 0xFF6E_6E),
    TerminalColor(hex: 0x69FF_94), TerminalColor(hex: 0xFFFF_A5),
    TerminalColor(hex: 0xD6AC_FF), TerminalColor(hex: 0xFF92_DF),
    TerminalColor(hex: 0xA4FF_FF), TerminalColor(hex: 0xFFFF_FF),
  ]

  /// spec.draculatheme.com, "ANSI Color Palette" → Alucard Classic. Slots 0 and 7 are not
  /// swapped: the spec puts the surface in `AnsiBlack` and the ink in `AnsiWhite`.
  private static let alucardANSI: [TerminalColor] = [
    TerminalColor(hex: 0xFFFB_EB), TerminalColor(hex: 0xCB3A_2A),
    TerminalColor(hex: 0x1471_0A), TerminalColor(hex: 0x846E_15),
    TerminalColor(hex: 0x644A_C9), TerminalColor(hex: 0xA314_4D),
    TerminalColor(hex: 0x036A_96), TerminalColor(hex: 0x1F1F_1F),
    TerminalColor(hex: 0x6C66_4B), TerminalColor(hex: 0xD74C_3D),
    TerminalColor(hex: 0x198D_0C), TerminalColor(hex: 0x9E84_1A),
    TerminalColor(hex: 0x7862_D0), TerminalColor(hex: 0xBF18_5A),
    TerminalColor(hex: 0x047F_B4), TerminalColor(hex: 0x2C2B_31),
  ]

  /// alacritty/alacritty-theme, `themes/one_dark.toml`; every value also appears in
  /// `atom/one-dark-syntax`, `styles/colors.less`.
  private static let oneDarkANSI: [TerminalColor] = [
    TerminalColor(hex: 0x1E21_27), TerminalColor(hex: 0xE06C_75),
    TerminalColor(hex: 0x98C3_79), TerminalColor(hex: 0xD19A_66),
    TerminalColor(hex: 0x61AF_EF), TerminalColor(hex: 0xC678_DD),
    TerminalColor(hex: 0x56B6_C2), TerminalColor(hex: 0xABB2_BF),
    TerminalColor(hex: 0x5C63_70), TerminalColor(hex: 0xE06C_75),
    TerminalColor(hex: 0x98C3_79), TerminalColor(hex: 0xD19A_66),
    TerminalColor(hex: 0x61AF_EF), TerminalColor(hex: 0xC678_DD),
    TerminalColor(hex: 0x56B6_C2), TerminalColor(hex: 0xFFFF_FF),
  ]

  /// `atom/one-light-syntax`, `styles/colors.less`, in One Dark's slot order. See `oneDark`.
  private static let oneLightANSI: [TerminalColor] = [
    TerminalColor(hex: 0xFAFA_FA), TerminalColor(hex: 0xE456_49),
    TerminalColor(hex: 0x50A1_4F), TerminalColor(hex: 0x9868_01),
    TerminalColor(hex: 0x4078_F2), TerminalColor(hex: 0xA626_A4),
    TerminalColor(hex: 0x0184_BC), TerminalColor(hex: 0x696C_77),
    TerminalColor(hex: 0xA0A1_A7), TerminalColor(hex: 0xE456_49),
    TerminalColor(hex: 0x50A1_4F), TerminalColor(hex: 0x9868_01),
    TerminalColor(hex: 0x4078_F2), TerminalColor(hex: 0xA626_A4),
    TerminalColor(hex: 0x0184_BC), TerminalColor(hex: 0x383A_42),
  ]
}
