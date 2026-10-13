import Foundation
import Testing

@testable import DriverrCore

@Suite("TerminalSettings")
struct TerminalSettingsTests {
  @Test("defaults resolve to bundled values")
  func defaultsResolve() {
    let settings = TerminalSettings.default
    #expect(settings.theme == Theme.default)
    #expect(settings.font == TerminalFont.default)
    #expect(settings.fontSize == TerminalSettings.defaultFontSize)
  }

  /// Wrapped is the layout existing readers already see, so it is the default.
  @Test("the captured screen wraps by default")
  func wrapDefaultsOn() {
    #expect(TerminalSettings.default.wrapsScreenLines)
    #expect(TerminalSettings.default.screenLayout == .wrapped)
  }

  @Test("the wrap setting is the whole of which layout a captured screen gets")
  func wrapMapsToALayout() {
    #expect(TerminalSettings(wrapsScreenLines: true).screenLayout == .wrapped)
    #expect(TerminalSettings(wrapsScreenLines: false).screenLayout == .clipped)
  }

  @Test("font size is clamped at construction and on change")
  func fontSizeIsClamped() {
    #expect(TerminalSettings(fontSize: 200).fontSize == TerminalSettings.fontSizeRange.upperBound)
    #expect(TerminalSettings(fontSize: 0).fontSize == TerminalSettings.fontSizeRange.lowerBound)

    var settings = TerminalSettings()
    settings.setFontSize(-5)
    #expect(settings.fontSize == TerminalSettings.fontSizeRange.lowerBound)
  }

  @Test("a non-finite font size falls back rather than poisoning the layout")
  func nonFiniteFontSize() {
    // A NaN makes every cell dimension NaN, and the terminal silently draws nothing.
    #expect(TerminalSettings(fontSize: .nan).fontSize == TerminalSettings.defaultFontSize)
    #expect(
      TerminalSettings(fontSize: .infinity).fontSize == TerminalSettings.defaultFontSize
    )
  }

  @Test("growing and shrinking move one point and stop at the ends")
  func growAndShrink() {
    var settings = TerminalSettings(fontSize: 13)
    settings.growFont()
    #expect(settings.fontSize == 14)
    settings.shrinkFont()
    #expect(settings.fontSize == 13)

    var atTop = TerminalSettings(fontSize: TerminalSettings.fontSizeRange.upperBound)
    #expect(!atTop.canGrowFont)
    atTop.growFont()
    #expect(atTop.fontSize == TerminalSettings.fontSizeRange.upperBound)

    var atBottom = TerminalSettings(fontSize: TerminalSettings.fontSizeRange.lowerBound)
    #expect(!atBottom.canShrinkFont)
    atBottom.shrinkFont()
    #expect(atBottom.fontSize == TerminalSettings.fontSizeRange.lowerBound)
  }

  @Test("an id this build no longer ships resolves to the default, not a crash")
  func unknownIDsFallBack() {
    let settings = TerminalSettings(themeID: "gone", fontID: "also-gone")
    #expect(settings.theme == Theme.default)
    #expect(settings.font == TerminalFont.default)
  }

  /// A stored `system` moves to the new default because a deliberate choice cannot be told
  /// from a default. The decoder stores the resolved id so the settings row selects the face
  /// it draws.
  @Test("a stored System Mono choice decodes to the JetBrains Mono default")
  func storedSystemMovesToTheNewDefault() throws {
    let data = Data(#"{"themeID":"nord","fontID":"system","fontSize":15}"#.utf8)
    let decoded = try JSONDecoder().decode(TerminalSettings.self, from: data)
    #expect(decoded.fontID == "jetbrains-mono")
    #expect(decoded.font.id == "jetbrains-mono")
    #expect(decoded.font.systemFontName == "JetBrainsMonoNLNFM-Regular")
  }

  @Test("a stored Menlo or Courier choice is kept", arguments: ["menlo", "courier"])
  func storedIOSFacesAreKept(id: String) throws {
    let data = Data(#"{"fontID":"\#(id)"}"#.utf8)
    let decoded = try JSONDecoder().decode(TerminalSettings.self, from: data)
    #expect(decoded.fontID == id)
    #expect(decoded.font.id == id)
  }

  @Test("an empty blob gets the JetBrains Mono default")
  func emptyBlobGetsTheNewDefault() throws {
    let decoded = try JSONDecoder().decode(TerminalSettings.self, from: Data("{}".utf8))
    #expect(decoded.fontID == "jetbrains-mono")
    #expect(TerminalFont.default.id == "jetbrains-mono")
  }

  @Test("the bundled faces are JetBrains Mono first, then the three iOS faces")
  func bundledOrder() {
    #expect(TerminalFont.bundled.map(\.id) == ["jetbrains-mono", "system-mono", "menlo", "courier"])
  }

  /// Nerd Font glyphs sit in the private use area, and the sanitiser must not drop them as
  /// control characters.
  @Test("a captured screen keeps Nerd Font glyphs")
  func sanitiserKeepsPrivateUseGlyphs() {
    let screen = PaneScreen.sanitised("\u{F09B} main \u{E0B0} $ ", lines: 10)
    #expect(screen.text.contains("\u{F09B}"))
    #expect(screen.text.contains("\u{E0B0}"))
  }

  @Test("settings round trip through JSON")
  func roundTrips() throws {
    let original = TerminalSettings(themeID: "nord", fontID: "menlo", fontSize: 17)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(TerminalSettings.self, from: data)
    #expect(decoded == original)
  }

  @Test("Live Activities are on by default")
  func liveActivitiesDefaultOn() {
    #expect(TerminalSettings.default.liveActivities)
  }

  @Test("a blob missing a field keeps the other four")
  func partialBlobDecodes() throws {
    // The shape an older build wrote.
    let data = Data(#"{"themeID":"nord"}"#.utf8)
    let decoded = try JSONDecoder().decode(TerminalSettings.self, from: data)
    #expect(decoded.themeID == "nord")
    #expect(decoded.font == TerminalFont.default)
    #expect(decoded.fontSize == TerminalSettings.defaultFontSize)
    #expect(decoded.wrapsScreenLines)
    #expect(decoded.liveActivities)
  }

  /// Every blob written before `wrapsScreenLines` lacks the key, and those installs draw
  /// wrapped.
  @Test("a blob written before the wrap setting existed reads as wrapping")
  func blobWithoutWrapKeyWraps() throws {
    let data = Data(#"{"themeID":"nord","fontID":"menlo","fontSize":15}"#.utf8)
    let decoded = try JSONDecoder().decode(TerminalSettings.self, from: data)
    #expect(decoded.wrapsScreenLines)
  }

  /// A forgotten `decodeIfPresent` breaks this silently.
  @Test("turning wrapping off survives a round trip")
  func wrapChoiceRoundTrips() throws {
    let off = TerminalSettings(wrapsScreenLines: false)
    let data = try JSONEncoder().encode(off)
    let decoded = try JSONDecoder().decode(TerminalSettings.self, from: data)
    #expect(!decoded.wrapsScreenLines)
    #expect(decoded == off)
  }

  /// Installs from before this key existed are drawing Live Activities.
  @Test("a blob written before the Live Activities setting existed reads as on")
  func blobWithoutLiveActivityKeyIsOn() throws {
    let data = Data(#"{"themeID":"nord","fontID":"menlo","fontSize":15,"wrapsScreenLines":false}"#.utf8)
    let decoded = try JSONDecoder().decode(TerminalSettings.self, from: data)
    #expect(decoded.liveActivities)
    #expect(!decoded.wrapsScreenLines)
  }

  /// A forgotten `decodeIfPresent` would draw on the Lock Screen of someone who said no.
  @Test("turning Live Activities off survives a round trip")
  func liveActivityChoiceRoundTrips() throws {
    let off = TerminalSettings(liveActivities: false)
    let data = try JSONEncoder().encode(off)
    let decoded = try JSONDecoder().decode(TerminalSettings.self, from: data)
    #expect(!decoded.liveActivities)
    #expect(decoded == off)
  }

  @Test("a stored font size outside the range is clamped on decode")
  func decodedFontSizeIsClamped() throws {
    let data = Data(#"{"themeID":"system","fontID":"system","fontSize":999}"#.utf8)
    let decoded = try JSONDecoder().decode(TerminalSettings.self, from: data)
    #expect(decoded.fontSize == TerminalSettings.fontSizeRange.upperBound)
  }

  @Test("bundled fonts have unique ids and the default is one of them")
  func bundledFontsAreSane() {
    let ids = TerminalFont.bundled.map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(TerminalFont.bundled.contains(TerminalFont.default))
  }
}

@Suite("SettingsStore")
struct SettingsStoreTests {
  @Test("an untouched store hands back the defaults")
  func emptyStoreIsDefault() async {
    let store = InMemorySettingsStore()
    #expect(await store.settings() == .default)
  }

  @Test("a saved change reads back")
  func savePersists() async {
    let store = InMemorySettingsStore()
    await store.save(
      TerminalSettings(themeID: "nord", fontID: "menlo", fontSize: 16, wrapsScreenLines: false)
    )
    let read = await store.settings()
    #expect(read.themeID == "nord")
    #expect(read.fontID == "menlo")
    #expect(read.fontSize == 16)
    #expect(!read.wrapsScreenLines)
    #expect(read.screenLayout == .clipped)
  }
}
