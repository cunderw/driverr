import Foundation
import Testing

@testable import DriverrCore

/// WCAG 2 contrast computed here rather than with `DriverrCore.contrastRatio`, the code
/// under test. `https://www.w3.org/TR/WCAG20/#relativeluminancedef`.
private func srgbToLinear(_ channel: UInt8) -> Double {
  let c = Double(channel) / 255.0
  return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}

private func relativeLuminance(_ color: TerminalColor) -> Double {
  0.2126 * srgbToLinear(color.red)
    + 0.7152 * srgbToLinear(color.green)
    + 0.0722 * srgbToLinear(color.blue)
}

private func contrastRatio(_ a: TerminalColor, _ b: TerminalColor) -> Double {
  let (la, lb) = (relativeLuminance(a), relativeLuminance(b))
  let (lighter, darker) = la > lb ? (la, lb) : (lb, la)
  return (lighter + 0.05) / (darker + 0.05)
}

/// The card's most favourable ground, not its worst. `Color.black.opacity(0.85)` sits over
/// the user's wallpaper, which nothing here controls, so the assertion is a floor on the
/// palette. On a bright wallpaper the capsule relies on its label's contrast against the
/// fill.
private let cardGround = TerminalColor(hex: 0x0000_00)

@Suite("WidgetThemeSnapshot")
struct WidgetThemeSnapshotTests {
  @Test("Every bundled theme round-trips through the container's encoding unchanged")
  func roundTripsForEveryBundledTheme() throws {
    for theme in Theme.bundled {
      let snapshot = WidgetThemeSnapshot(theme: theme)
      let data = try #require(snapshot.encoded(), "\(theme.id) produced no payload")
      let decoded = try #require(
        WidgetThemeSnapshot.decode(data), "\(theme.id) did not decode back")
      #expect(decoded == snapshot, "\(theme.id) changed on the way through")
      #expect(decoded.themeID == theme.id)
    }
  }

  /// No key written yet, a truncated blob, and a payload from a build that changed the shape.
  @Test("An absent, empty, unreadable or future payload decodes to nil")
  func decodeRefusesWhatItCannotUnderstand() throws {
    #expect(WidgetThemeSnapshot.decode(nil) == nil)
    #expect(WidgetThemeSnapshot.decode(Data()) == nil)
    #expect(WidgetThemeSnapshot.decode(Data("not json".utf8)) == nil)

    // v1's field names in a v2 payload, so only the version check can reject it.
    let v1 = try #require(WidgetThemeSnapshot(theme: .system).encoded())
    var object = try #require(
      try JSONSerialization.jsonObject(with: v1) as? [String: Any])
    object["version"] = WidgetThemeSnapshot.currentVersion + 1
    let v2 = try JSONSerialization.data(withJSONObject: object)
    #expect(
      WidgetThemeSnapshot.decode(v2) == nil,
      "A payload from a newer build must fall back, not be half-read")
  }

  /// If the snapshot invented a colour, the card would silently disagree with the app.
  @Test("The payload carries the theme's own accent and its own readable foreground")
  func carriesTheThemesOwnColours() {
    for theme in Theme.bundled {
      let snapshot = WidgetThemeSnapshot(theme: theme)
      for appearance in ThemeAppearance.allCases {
        let half = appearance == .dark ? snapshot.dark : snapshot.light
        let accent = theme.accent(for: appearance)
        #expect(half.accent == accent, "\(theme.id) \(appearance) accent was rewritten")
        #expect(
          half.accentForeground == accent.readableForeground,
          "\(theme.id) \(appearance) foreground was not derived from the accent")
      }
    }
  }

  /// The calm card's capsule. The card draws only the dark half (`DriverrWatch.swift`,
  /// `half`), but both are asserted.
  @Test("The published foreground clears 4.5:1 on the published accent, every theme")
  func everyPublishedPairIsReadable() {
    for theme in Theme.bundled {
      let snapshot = WidgetThemeSnapshot(theme: theme)
      for appearance in ThemeAppearance.allCases {
        let half = appearance == .dark ? snapshot.dark : snapshot.light
        let ratio = contrastRatio(half.accentForeground, half.accent)
        #expect(
          ratio >= 4.5,
          """
          \(theme.id) \(appearance): the capsule's label reads at \
          \(ratio):1 on its own fill
          """)
      }
    }
  }

  /// The capsule's edge is a graphics boundary, so 3:1. The tight light case is dracula
  /// (`#644AC9`), a little over 3.3:1.
  @Test("Every published accent clears 3:1 against the card's black ground")
  func everyPublishedAccentIsVisibleOnTheCard() {
    for theme in Theme.bundled {
      let snapshot = WidgetThemeSnapshot(theme: theme)
      for appearance in ThemeAppearance.allCases {
        let half = appearance == .dark ? snapshot.dark : snapshot.light
        let ratio = contrastRatio(half.accent, cardGround)
        #expect(
          ratio >= 3,
          """
          \(theme.id) \(appearance): the capsule's fill reads at \
          \(ratio):1 against the card's ground
          """)
      }
    }
  }

  /// The capsule holds one line, so a joined line must fall back to a count before it could
  /// wrap. The budget includes the capsule's padding. Both sides of the boundary are pinned.
  @Test("a joined host line falls back to the count at the capsule's one-line budget")
  func theJoinedLineIsBoundedByTheCapsulesOneLineBudget() {
    let budget = BlockedPaneActivityAttributes.ContentState.nameBudget
    #expect(budget == 31, "the capsule is one line; see nameBudget's own note for the column")

    func line(_ names: [String]) -> String {
      BlockedPaneActivityAttributes.ContentState(
        hosts: names.map {
          BlockedPaneActivityAttributes.HostSummary(
            hostID: UUID(), hostName: $0, counts: AgentStatusCounts())
        },
        lastConfirmedAt: Date()
      ).hostsLine
    }

    // Exactly at the budget: 13 + 3 + 15 = 31.
    let atBudget = line(["buildbox-east", "sandbox-west-01"])
    #expect(atBudget.count == budget)
    #expect(atBudget == "buildbox-east · sandbox-west-01")

    #expect(line(["buildbox-east", "sandbox-west-012"]) == "2 hosts")

    #expect(line(["workbox", "buildbox", "sandbox-west"]) == "3 hosts")

    // A single host has no count to fall back to; the widget truncates it instead.
    let long = "workbox-with-a-long-descriptive-host-name"
    #expect(long.count > budget)
    #expect(line([long]) == long)
  }

  /// Written by hand in two entitlements files and read by a separate process.
  @Test("The container's identifiers are what both entitlements files name")
  func identifiersArePinned() {
    #expect(WidgetThemeSnapshot.appGroupID == "group.com.cunderw.driverr")
    #expect(WidgetThemeSnapshot.defaultsKey == "com.cunderw.driverr.widgetTheme.v1")
    #expect(WidgetThemeSnapshot.currentVersion == 1)
  }

  @Test("An in-memory store records what it was handed")
  func inMemoryStoreRecordsPublishes() async {
    let store = InMemoryWidgetThemeStore()
    await store.publish(WidgetThemeSnapshot(theme: .solarized))
    await store.publish(WidgetThemeSnapshot(theme: .nord))
    let published = await store.published
    #expect(published.map(\.themeID) == ["solarized", "nord"])
  }
}
