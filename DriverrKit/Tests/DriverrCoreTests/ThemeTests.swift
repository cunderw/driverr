import Foundation
import Testing
@testable import DriverrCore

/// WCAG 2 relative luminance, computed here so the tests do their own arithmetic rather
/// than trust the code under test. `https://www.w3.org/TR/WCAG20/#relativeluminancedef`.
private func srgbToLinear(_ channel: UInt8) -> Double {
  let c = Double(channel) / 255.0
  return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}

private func relativeLuminance(_ color: TerminalColor) -> Double {
  0.2126 * srgbToLinear(color.red)
    + 0.7152 * srgbToLinear(color.green)
    + 0.0722 * srgbToLinear(color.blue)
}

/// WCAG 2 contrast ratio, `https://www.w3.org/TR/WCAG20/#contrast-ratiodef`.
private func contrastRatio(_ a: TerminalColor, _ b: TerminalColor) -> Double {
  let (la, lb) = (relativeLuminance(a), relativeLuminance(b))
  let (lighter, darker) = la > lb ? (la, lb) : (lb, la)
  return (lighter + 0.05) / (darker + 0.05)
}

/// SwiftUI's `systemBackground`, transcribed because `DriverrCore` has no UIKit.
private func borderedSurface(_ appearance: ThemeAppearance) -> TerminalColor {
  switch appearance {
  case .dark: TerminalColor(hex: 0x1C1C_1E)
  case .light: TerminalColor(hex: 0xFFFF_FF)
  }
}

private func primaryLabel(in appearance: ThemeAppearance) -> TerminalColor {
  switch appearance {
  case .dark: TerminalColor(hex: 0xFFFF_FF)
  case .light: TerminalColor(hex: 0x0000_00)
  }
}

/// A dark `insetGrouped` row, `secondarySystemGroupedBackground`, sampled on a simulator.
private let darkGroupedRow = TerminalColor(hex: 0x2C2C_2E)

/// The dark toolbar glass behind a nav-bar item. It is adaptive, so this is one sample.
private let darkToolbarGlass = TerminalColor(hex: 0x3B3B_3D)

/// HSV hue in degrees, 0 up to 360.
private func hue(of color: TerminalColor) -> Double {
  let (r, g, b) = (Double(color.red), Double(color.green), Double(color.blue))
  let high = max(r, g, b)
  let span = high - min(r, g, b)
  guard span > 0 else { return 0 }
  let sector: Double
  if high == r {
    sector = ((g - b) / span).truncatingRemainder(dividingBy: 6)
  } else if high == g {
    sector = (b - r) / span + 2
  } else {
    sector = (r - g) / span + 4
  }
  let degrees = sector * 60
  return degrees < 0 ? degrees + 360 : degrees
}

/// What `.buttonStyle(.bordered)` fills with: the tint at 26 % over the screen behind it.
/// Modelled here because `TerminalColor`'s own blend is the code under test.
private func borderedFill(_ tint: TerminalColor, on appearance: ThemeAppearance) -> TerminalColor {
  let surface = borderedSurface(appearance)
  let alpha = 0.26
  func mix(_ over: UInt8, _ under: UInt8) -> UInt8 {
    UInt8((Double(over) * alpha + Double(under) * (1 - alpha)).rounded())
  }
  return TerminalColor(
    red: mix(tint.red, surface.red),
    green: mix(tint.green, surface.green),
    blue: mix(tint.blue, surface.blue)
  )
}

/// A slot held to a lower floor than the 3:1 `ansiClearsContrastFloor` enforces.
///
/// This list is permanent, not a backlog. Every entry is an upstream theme's published
/// value, kept because a user who picks a theme by name expects its real colours. A
/// Driverr-authored palette never belongs here. Each floor sits just under its measured
/// ratio so a further regression still fails; do not round the floors down.
private struct ContrastException {
  let themeID: String
  let appearance: ThemeAppearance
  let slot: Int
  /// Set just under the slot's measured ratio.
  let floor: Double

  static let all: [ContrastException] = solarized + gruvbox + tokyoNightDay + catppuccinLatte

  /// Solarized publishes one 16-colour table for light and dark. Dark slot 10 is base01, a
  /// muted comment colour.
  private static let solarized: [ContrastException] = [
    // green, ~2.97:1
    ContrastException(themeID: "solarized", appearance: .light, slot: 2, floor: 2.9),
    // bright blue / base0, ~2.93:1
    ContrastException(themeID: "solarized", appearance: .light, slot: 12, floor: 2.85),
    // bright green / base01, ~2.79:1
    ContrastException(themeID: "solarized", appearance: .dark, slot: 10, floor: 2.7),
  ]

  private static let gruvbox: [ContrastException] = [
    // red, ~2.69:1
    ContrastException(themeID: "gruvbox", appearance: .dark, slot: 1, floor: 2.6),
    // green, ~2.73:1
    ContrastException(themeID: "gruvbox", appearance: .light, slot: 2, floor: 2.65),
  ]

  /// Tokyo Night Day is upstream's own light variant, not a Driverr-derived light half.
  private static let tokyoNightDay: [ContrastException] = [
    // bright red, ~2.53:1
    ContrastException(themeID: "tokyo-night", appearance: .light, slot: 9, floor: 2.45),
    // bright blue, ~2.61:1
    ContrastException(themeID: "tokyo-night", appearance: .light, slot: 12, floor: 2.55),
  ]

  /// Upstream gives green and bright green the same hex, so this is one colour twice.
  private static let catppuccinLatte: [ContrastException] = [
    ContrastException(themeID: "catppuccin", appearance: .light, slot: 2, floor: 2.9),
    ContrastException(themeID: "catppuccin", appearance: .light, slot: 10, floor: 2.9),
  ]

  static func floor(themeID: String, appearance: ThemeAppearance, slot: Int) -> Double {
    all.first { $0.themeID == themeID && $0.appearance == appearance && $0.slot == slot }?
      .floor ?? 3.0
  }
}

@Suite("Theme")
struct ThemeTests {
  @Test("hex splits into the right channels")
  func hexSplitsChannels() {
    let color = TerminalColor(hex: 0x12_34_56)
    #expect(color.red == 0x12)
    #expect(color.green == 0x34)
    #expect(color.blue == 0x56)
  }

  @Test("every bundled palette has exactly sixteen ANSI slots")
  func bundledPalettesAreComplete() {
    for theme in Theme.bundled {
      for appearance in ThemeAppearance.allCases {
        #expect(
          theme.palette(for: appearance).ansi.count == TerminalPalette.ansiSlotCount,
          "\(theme.id)/\(appearance.rawValue)"
        )
      }
    }
  }

  @Test("a short ANSI list is padded rather than trapping")
  func shortANSIListIsPadded() {
    let foreground = TerminalColor(hex: 0xAB_CD_EF)
    let palette = TerminalPalette(
      background: TerminalColor(hex: 0),
      foreground: foreground,
      cursor: foreground,
      ansi: [TerminalColor(hex: 0x11_11_11)]
    )
    #expect(palette.ansi.count == TerminalPalette.ansiSlotCount)
    #expect(palette.ansi[0] == TerminalColor(hex: 0x11_11_11))
    #expect(palette.ansi[15] == foreground)
  }

  @Test("a long ANSI list is truncated to sixteen")
  func longANSIListIsTruncated() {
    let palette = TerminalPalette(
      background: TerminalColor(hex: 0),
      foreground: TerminalColor(hex: 0xFF_FF_FF),
      cursor: TerminalColor(hex: 0xFF_FF_FF),
      ansi: Array(repeating: TerminalColor(hex: 0x22_22_22), count: 20)
    )
    #expect(palette.ansi.count == TerminalPalette.ansiSlotCount)
  }

  @Test("light and dark differ in surface colour for every bundled theme")
  func appearancesDiffer() {
    for theme in Theme.bundled {
      #expect(theme.light.background != theme.dark.background, "\(theme.id)")
    }
  }

  @Test("bundled ids are unique")
  func bundledIDsAreUnique() {
    let ids = Theme.bundled.map(\.id)
    #expect(Set(ids).count == ids.count)
  }

  @Test("an unknown id falls back to the default theme rather than failing")
  func unknownIDFallsBack() {
    #expect(Theme.bundled(id: "no-such-theme") == Theme.default)
    #expect(Theme.bundled(id: "nord") == Theme.nord)
  }

  @Test("the default theme is one of the bundled ones")
  func defaultIsBundled() {
    #expect(Theme.bundled.contains(Theme.default))
  }

  /// The ids are persisted in settings. Renaming one resets everyone who chose that theme.
  @Test("the bundled set is exactly the eight shipped themes, by id and in order")
  func bundledIsTheEightShippedThemes() {
    #expect(
      Theme.bundled.map(\.id) == [
        "system", "solarized", "nord", "tokyo-night", "catppuccin", "gruvbox", "dracula",
        "one-dark",
      ]
    )
  }

  @Test("bundled(id:) round-trips every bundled theme")
  func bundledIDsRoundTrip() {
    for theme in Theme.bundled {
      #expect(Theme.bundled(id: theme.id) == theme, "\(theme.id)")
    }
  }

  /// `TerminalPalette.init` pads a short ANSI list with `foreground`, so a padded palette
  /// still counts sixteen. Padding shows as a run of `foreground` at the tail. Some palettes
  /// end on their foreground once, but none repeats it.
  @Test("no bundled palette was silently padded out to sixteen")
  func bundledPalettesWereNotPadded() {
    for theme in Theme.bundled {
      for appearance in ThemeAppearance.allCases {
        let palette = theme.palette(for: appearance)
        let padded = palette.ansi.reversed().prefix { $0 == palette.foreground }.count
        #expect(
          padded <= 1,
          "\(theme.id)/\(appearance.rawValue) ends in \(padded) foreground slots"
        )
      }
    }
  }

  /// The table in `altercation/solarized`, `README.md`, at commit `62f656a02f93`. The ANSI
  /// order is that table's TERMCOL column. Body text is base0 on base03 in dark and base00 on
  /// base3 in light, and the cursor is the emphasis tone, base1 and base01.
  ///
  /// ANSI 8 is base03, which is also the dark background. That is the published value.
  @Test("Solarized matches the published table in both appearances")
  func solarizedMatchesThePublishedTable() {
    let ansi: [UInt32] = [
      0x0736_42, 0xDC32_2F, 0x8599_00, 0xB589_00, 0x268B_D2, 0xD336_82, 0x2AA1_98, 0xEEE8_D5,
      0x002B_36, 0xCB4B_16, 0x586E_75, 0x657B_83, 0x8394_96, 0x6C71_C4, 0x93A1_A1, 0xFDF6_E3,
    ]
    let surfaces: [(ThemeAppearance, background: UInt32, foreground: UInt32, cursor: UInt32)] = [
      (.light, background: 0xFDF6_E3, foreground: 0x657B_83, cursor: 0x586E_75),
      (.dark, background: 0x002B_36, foreground: 0x8394_96, cursor: 0x93A1_A1),
    ]
    for (appearance, background, foreground, cursor) in surfaces {
      let palette = Theme.solarized.palette(for: appearance)
      let name = "solarized/\(appearance.rawValue)"
      #expect(palette.background == TerminalColor(hex: background), "\(name) background")
      #expect(palette.foreground == TerminalColor(hex: foreground), "\(name) foreground")
      #expect(palette.cursor == TerminalColor(hex: cursor), "\(name) cursor")
      for (slot, hex) in ansi.enumerated() {
        #expect(palette.ansi[slot] == TerminalColor(hex: hex), "\(name) ANSI \(slot)")
      }
    }
  }

  /// ANSI 1/2/4 and 9/10/12 are the slots diffs, test runners and agent status lines use.
  /// Below 3:1, WCAG's non-text minimum, fails unless listed in `ContrastException`.
  @Test("every bundled theme's red/green/blue ANSI clears 3:1 against its own background")
  func ansiClearsContrastFloor() {
    let checkedSlots = [1, 2, 4, 9, 10, 12]
    for theme in Theme.bundled {
      for appearance in ThemeAppearance.allCases {
        let palette = theme.palette(for: appearance)
        for slot in checkedSlots {
          let ratio = contrastRatio(palette.ansi[slot], palette.background)
          let floor = ContrastException.floor(
            themeID: theme.id, appearance: appearance, slot: slot
          )
          #expect(
            ratio >= floor,
            "\(theme.id)/\(appearance.rawValue) slot \(slot): \(ratio):1 < \(floor):1"
          )
        }
      }
    }
  }

  @Test("the System theme has one ANSI array for light and a different one for dark")
  func systemHasDistinctLightAndDarkANSI() {
    #expect(Theme.system.light.ansi != Theme.system.dark.ansi)
  }

  /// `systemLightANSI` inverts the greyscale relative to dark, so slot 0 or 15 loses contrast
  /// by design. A monochrome slot exactly equal to the background would render as nothing.
  /// Scoped to `system`: upstream light themes inherit slot 0 == background.
  @Test("System's greyscale ANSI slots never exactly match their own background")
  func systemGreyscaleSlotsStayDistinguishableFromBackground() {
    let greyscaleSlots = [0, 7, 8, 15]
    for appearance in ThemeAppearance.allCases {
      let palette = Theme.system.palette(for: appearance)
      for slot in greyscaleSlots {
        #expect(
          palette.ansi[slot] != palette.background,
          "system/\(appearance.rawValue) slot \(slot) matches its own background exactly"
        )
      }
    }
  }

  // MARK: - Dimming "dim" text without losing the reader

  /// A flat 65 % opacity dim on white read at about 2.2:1.
  @Test("a dimmed colour clears 4.5:1 against the background it was dimmed for")
  func dimmedColourClearsTheFloor() {
    for theme in Theme.bundled {
      for appearance in ThemeAppearance.allCases {
        let palette = theme.palette(for: appearance)
        let dim = palette.foreground.dimmed(against: palette.background)
        let ratio = contrastRatio(dim, palette.background)
        // `dimmed(against:)` returns `self` when the pair cannot reach the floor at any strength.
        let ceiling = contrastRatio(palette.foreground, palette.background)
        guard ceiling >= 4.5 else { continue }
        #expect(
          ratio >= 4.499,
          "\(theme.id)/\(appearance.rawValue): dimmed foreground is \(ratio):1 against its own background"
        )
      }
    }
  }

  @Test("dimming a colour that already clears the floor by a wide margin still reads as dim")
  func dimmingStillDimsWhenThereIsRoomToSpare() {
    let black = TerminalColor(red: 0, green: 0, blue: 0)
    let white = TerminalColor(red: 255, green: 255, blue: 255)
    let dim = black.dimmed(against: white)
    #expect(dim != black, "expected genuine dimming, not a no-op")
    #expect(contrastRatio(dim, white) >= 4.499)
    #expect(contrastRatio(dim, white) < 21)
  }

  @Test("a pair that cannot reach the floor at any strength is returned undimmed")
  func undimmableColourReturnsUnchanged() {
    let foreground = TerminalColor(red: 140, green: 140, blue: 140)
    let background = TerminalColor(red: 120, green: 120, blue: 120)
    #expect(contrastRatio(foreground, background) < 4.5)
    #expect(foreground.dimmed(against: background) == foreground)
  }

  @Test("contrast ratio is symmetric and 1:1 for identical colours")
  func contrastRatioBasics() {
    let colour = TerminalColor(red: 80, green: 80, blue: 80)
    #expect(DriverrCore.contrastRatio(colour, colour) == 1)
    let other = TerminalColor(red: 10, green: 10, blue: 10)
    #expect(DriverrCore.contrastRatio(colour, other) == DriverrCore.contrastRatio(other, colour))
  }

  // MARK: - The app accent derived from the theme

  /// The accent keeps the theme's colour and the foreground switches to black or white, so
  /// this asserts the pair. Catppuccin light is the worst case, clearing by under half a point.
  @Test("every bundled theme's accent carries a readable foreground at 4.5:1")
  func everyBundledAccentCarriesAReadableForeground() {
    for theme in Theme.bundled {
      for appearance in ThemeAppearance.allCases {
        let accent = theme.accent(for: appearance)
        let foreground = accent.readableForeground
        let ratio = contrastRatio(foreground, accent)
        #expect(
          ratio >= 4.5,
          "\(theme.id)/\(appearance.rawValue) accent: foreground reads at \(ratio):1"
        )
      }
    }
  }

  /// Accent drawn on a dark surface, as a checkmark or a toolbar glyph is. The default seed
  /// read 2.26:1 on the row and 1.81:1 on the glass, so the dark accent is lifted. Toolbar
  /// text takes `Color.primary` instead, because no usable blue reaches 4.5:1 on the glass.
  @Test("every bundled dark accent reads 4.5:1 on a grouped row and 3:1 on the toolbar glass")
  func everyBundledDarkAccentReadsOnTheDarkSurfaces() {
    for theme in Theme.bundled {
      let accent = theme.accent(for: .dark)
      let onRow = contrastRatio(accent, darkGroupedRow)
      let onGlass = contrastRatio(accent, darkToolbarGlass)
      #expect(onRow >= 4.5, "\(theme.id)/dark accent reads \(onRow):1 on #2C2C2E")
      #expect(onGlass >= 3.0, "\(theme.id)/dark accent reads \(onGlass):1 on #3B3B3D")
    }
  }

  /// The default light accent stays at 3.42:1 against white.
  @Test("every bundled light accent is ANSI 4 unchanged")
  func everyBundledLightAccentIsTheRawSeed() {
    for theme in Theme.bundled {
      #expect(
        theme.accent(for: .light) == theme.palette(for: .light).ansi[4],
        "\(theme.id)/light accent moved off its ANSI 4"
      )
    }
  }

  /// Every other dark seed already clears and is unchanged. Written out so a palette retune
  /// says which accent moved.
  @Test("the lifted dark accents match the pinned values")
  func theLiftedDarkAccentsArePinned() {
    let lifted: [String: (seed: UInt32, accent: UInt32)] = [
      "system": (0x064E_F4, 0x618F_F8),
      "solarized": (0x268B_D2, 0x419A_D8),
      "gruvbox": (0x4585_88, 0x679C_9E),
    ]
    for theme in Theme.bundled {
      let seed = theme.palette(for: .dark).ansi[4]
      let accent = theme.accent(for: .dark)
      if let pinned = lifted[theme.id] {
        #expect(seed == TerminalColor(hex: pinned.seed), "\(theme.id)/dark seed changed")
        #expect(accent == TerminalColor(hex: pinned.accent), "\(theme.id)/dark lift changed")
      } else {
        #expect(accent == seed, "\(theme.id)/dark accent moved off its ANSI 4")
      }
    }
  }

  /// No channel goes down, the hue stays within rounding, and the result lands just over the
  /// floor.
  @Test("a dark accent is lifted only when it must be, by the least that clears, on its own hue")
  func aDarkAccentIsLiftedMinimallyOnItsOwnHue() {
    for theme in Theme.bundled {
      let seed = theme.palette(for: .dark).ansi[4]
      let accent = theme.accent(for: .dark)
      guard contrastRatio(seed, darkGroupedRow) < 4.5 else {
        #expect(accent == seed, "\(theme.id)/dark cleared already and was moved anyway")
        continue
      }
      #expect(
        accent.red >= seed.red && accent.green >= seed.green && accent.blue >= seed.blue,
        "\(theme.id)/dark accent was not lifted toward white"
      )
      let hueDrift = abs(hue(of: accent) - hue(of: seed))
      #expect(min(hueDrift, 360 - hueDrift) < 2, "\(theme.id)/dark hue drifted \(hueDrift)°")
      let ratio = contrastRatio(accent, darkGroupedRow)
      #expect(ratio < 4.6, "\(theme.id)/dark was lifted further than it needed: \(ratio):1")
    }
  }

  /// UIKit draws a `swipeActions` pill's title white whatever the fill, so the usual cure of
  /// switching the foreground is not available there. `SwipeActionTint` depends on this.
  /// If it ever passes the other way, the fixed swipe tints can go.
  @Test("the default theme's accent cannot carry a label the system draws white")
  func theDefaultAccentCannotCarryAWhiteLabel() {
    let white = TerminalColor(hex: 0xFFFF_FF)
    let ratio = contrastRatio(white, Theme.system.accent(for: .light))
    // One string literal: `#expect`'s second argument is a `Comment`, which `"a" + "b"` is not.
    #expect(
      ratio < 4.5,
      """
      white reads \(ratio):1 on the default accent. If this now clears the floor, \
      SwipeActionTint's fixed tints are no longer needed.
      """
    )
  }

  /// A pinned measurement, written as the exact set so a retuned theme says which pair moved.
  /// It shows a fixed swipe tint is the right shape rather than a per-theme correction.
  @Test("only two of the sixteen bundled accents can carry a white label")
  func theBundledAccentsThatCanCarryAWhiteLabel() {
    let white = TerminalColor(hex: 0xFFFF_FF)
    var readable: [String] = []
    for theme in Theme.bundled {
      for appearance in ThemeAppearance.allCases where
        contrastRatio(white, theme.accent(for: appearance)) >= 4.5
      {
        readable.append("\(theme.id)/\(appearance.rawValue)")
      }
    }
    #expect(
      readable.sorted() == ["catppuccin/light", "dracula/light"],
      """
      the set of accents a white label reads on has changed to \(readable.sorted()). \
      A theme was added or retuned. Check that SwipeActionTint's fixed tints are still \
      the right shape before you update this list.
      """
    )
  }

  @Test("white clears 4.5:1 on every swipe action tint")
  func theSwipeActionTintsCarryAWhiteLabel() {
    let white = TerminalColor(hex: 0xFFFF_FF)
    for tint in [SwipeActionTint.neutral, SwipeActionTint.destructive] {
      let ratio = contrastRatio(white, tint)
      #expect(ratio >= 4.5, "white reads \(ratio):1 on the swipe tint \(tint)")
    }
  }

  /// `.bordered` colours both its 26 % fill and its label from the tint, so accent on
  /// accent read 2.30:1 on device; the model here computes 2.29 for that pair. The label is
  /// `Color.primary`, asserted as black and white rather than `readableForeground`, so a
  /// pass means the app's own colour reads.
  @Test("black or white on a bordered button's 26 % accent fill clears 4.5:1")
  func everyBundledAccentTintedFillCarriesAReadableLabel() {
    for theme in Theme.bundled {
      for appearance in ThemeAppearance.allCases {
        let fill = borderedFill(theme.accent(for: appearance), on: appearance)
        let label = primaryLabel(in: appearance)
        let ratio = contrastRatio(label, fill)
        #expect(
          ratio >= 4.5,
          """
          \(theme.id)/\(appearance.rawValue) bordered fill \
          rgb(\(fill.red), \(fill.green), \(fill.blue)): label reads at \(ratio):1
          """
        )
      }
    }
  }

  /// Documents an accepted deviation. The system destructive red on the system's untinted
  /// `.bordered` pill reads 5.22:1 in dark and 3.42:1 in light, and neither colour is
  /// Driverr's to change.
  ///
  /// The `>= 3.0` floor guards `.tint(Color?.none)` on `interruptConfirm` and on
  /// `PanePromptBar`'s confirm row. Without it `.bordered` takes the root accent and reads
  /// 2.30:1. It is not a claim to WCAG's large-text exemption, which 17 pt semibold does not
  /// meet. The constants are sampled from simulator screenshots.
  @Test("the destructive confirm label is the system's red, at its own measured contrast")
  func destructiveConfirmLabelIsTheSystemRedAtItsMeasuredContrast() {
    /// The untinted `.bordered` fill of both confirm buttons.
    let pill: [ThemeAppearance: TerminalColor] = [
      .dark: TerminalColor(hex: 0x1717_17),
      .light: TerminalColor(hex: 0xFAFA_FB),
    ]
    /// The system's destructive red, as it renders on that fill in each appearance.
    let destructive: [ThemeAppearance: TerminalColor] = [
      .dark: TerminalColor(hex: 0xFF42_45),
      .light: TerminalColor(hex: 0xFF38_3C),
    ]

    for appearance in ThemeAppearance.allCases {
      let ratio = contrastRatio(destructive[appearance]!, pill[appearance]!)
      #expect(
        ratio >= 3.0,
        """
        \(appearance.rawValue) destructive label reads at \(ratio):1 on its own pill — \
        under 3:1 means the label is no longer the system red, which is what dropping \
        `.tint(Color?.none)` does
        """
      )
    }

    // Cancel is `Color.primary` on the same fill and has no deviation to accept.
    for appearance in ThemeAppearance.allCases {
      let ratio = contrastRatio(primaryLabel(in: appearance), pill[appearance]!)
      #expect(
        ratio >= 4.5,
        "\(appearance.rawValue) Cancel label reads at \(ratio):1 on the confirm pill"
      )
    }
  }

  /// `.borderedProminent` fills with the accent at full strength and draws a fixed white
  /// label, so `ProminentButtonLabel` draws `\.themeAccentForeground` instead. The white
  /// expectation records why; if white ever becomes adequate everywhere it fails.
  @Test("a prominent button's full-strength accent fill carries a readable label")
  func everyBundledAccentProminentFillCarriesAReadableLabel() {
    let white = TerminalColor(hex: 0xFFFF_FF)
    var whiteFailures: [String] = []
    for theme in Theme.bundled {
      for appearance in ThemeAppearance.allCases {
        let fill = theme.accent(for: appearance)
        let label = fill.readableForeground
        #expect(
          contrastRatio(label, fill) >= 4.5,
          """
          \(theme.id)/\(appearance.rawValue) prominent fill \
          rgb(\(fill.red), \(fill.green), \(fill.blue)): \
          label reads at \(contrastRatio(label, fill)):1
          """
        )
        let whiteRatio = contrastRatio(white, fill)
        if whiteRatio < 4.5 {
          whiteFailures.append(
            "\(theme.id)/\(appearance.rawValue) \(whiteRatio):1"
          )
        }
      }
    }
    #expect(
      !whiteFailures.isEmpty,
      "a fixed white label is expected to fail on some bundled accent; none did"
    )
  }

  /// Picks by measured contrast, not a luminance threshold.
  @Test("a readable foreground is black on a light colour and white on a dark one")
  func readableForegroundPicksTheBetterAbsolute() {
    let black = TerminalColor(hex: 0x0000_00)
    let white = TerminalColor(hex: 0xFFFF_FF)
    #expect(TerminalColor(hex: 0xFFFF_00).readableForeground == black)
    #expect(TerminalColor(hex: 0x0000_80).readableForeground == white)
    #expect(white.readableForeground == black)
    #expect(black.readableForeground == white)
  }
}
