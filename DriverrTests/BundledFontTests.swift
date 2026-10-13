import CoreText
import DriverrCore
import Foundation
import Testing
import UIKit

/// The terminal's default face is a font in the app bundle, not one iOS ships.
///
/// The kit tier cannot see any of this, because SwiftPM does not build the app and so has no
/// `Info.plist` and no `Fonts` folder. `DriverrTests` is app-hosted, so `Bundle.main` here
/// is the Driverr app and a `UIFont(name:)` lookup goes through the fonts `UIAppFonts`
/// registered at launch. A missing registration is not a build error. The terminal would
/// fall back to the system monospaced face and the Nerd Font glyphs would draw as boxes.
@Suite("Bundled font")
@MainActor
struct BundledFontTests {
  private static let regularName = "JetBrainsMonoNLNFM-Regular"
  private static let boldName = "JetBrainsMonoNLNFM-Bold"

  @Test("every UIAppFonts entry is in the app bundle")
  func everyRegisteredFileShips() {
    let files = Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String]
    #expect(files != nil, "Info.plist has no UIAppFonts array")
    let names = files ?? []
    #expect(
      names == [
        "JetBrainsMonoNLNerdFontMono-Regular.ttf", "JetBrainsMonoNLNerdFontMono-Bold.ttf",
        "JetBrainsMonoNLNerdFontMono-Italic.ttf", "JetBrainsMonoNLNerdFontMono-BoldItalic.ttf",
      ]
    )
    for file in names {
      #expect(Bundle.main.url(forResource: file, withExtension: nil) != nil, "\(file) is not in the bundle")
    }
    // The licence travels with the font (OFL 1.1, section 2).
    #expect(Bundle.main.url(forResource: "OFL", withExtension: "txt") != nil)
  }

  @Test("the default face and its bold load by PostScript name")
  func bothFacesLoad() {
    #expect(TerminalFont.default.systemFontName == Self.regularName)
    #expect(UIFont(name: Self.regularName, size: 13)?.fontName == Self.regularName)
    #expect(UIFont(name: Self.boldName, size: 13)?.fontName == Self.boldName)
  }

  /// The glyphs the face was bundled for: a powerline separator and the GitHub icon, both in
  /// the private use area. Any face without them answers glyph 0.
  @Test("the default face has the Nerd Font glyphs", arguments: [0xE0B0, 0xF09B] as [UInt16])
  func nerdGlyphsArePresent(scalar: UInt16) throws {
    let font = try #require(UIFont(name: Self.regularName, size: 13))
    var characters: [UniChar] = [scalar]
    var glyphs: [CGGlyph] = [0]
    let found = CTFontGetGlyphsForCharacters(font as CTFont, &characters, &glyphs, 1)
    #expect(found)
    #expect(glyphs[0] != 0)
  }

  /// SwiftTerm derives its bold face with `withSymbolicTraits(.traitBold)` on the normal
  /// face's descriptor. That has to land on the bundled Bold, or bold text draws in the
  /// Regular weight or in some other family.
  @Test("bold derived the way SwiftTerm derives it is the bundled Bold")
  func derivedBoldIsTheBundledBold() throws {
    let regular = try #require(UIFont(name: Self.regularName, size: 13))
    let descriptor = try #require(regular.fontDescriptor.withSymbolicTraits([.traitBold]))
    #expect(UIFont(descriptor: descriptor, size: 0).fontName == Self.boldName)
  }

  /// The same derivation for italic and bold italic, which ship too.
  ///
  /// A `nil` descriptor fails rather than skips: SwiftTerm falls back to the Regular face
  /// then, and italic text draws upright with nothing reporting it.
  @Test(
    "italic and bold italic derived the way SwiftTerm derives them are the bundled faces",
    arguments: [
      (UIFontDescriptor.SymbolicTraits.traitItalic, "JetBrainsMonoNLNFM-Italic"),
      ([.traitItalic, .traitBold], "JetBrainsMonoNLNFM-BoldItalic"),
    ] as [(UIFontDescriptor.SymbolicTraits, String)]
  )
  func derivedItalicsAreTheBundledFaces(traits: UIFontDescriptor.SymbolicTraits, name: String)
    throws
  {
    let regular = try #require(UIFont(name: Self.regularName, size: 13))
    let descriptor = try #require(regular.fontDescriptor.withSymbolicTraits(traits))
    #expect(UIFont(descriptor: descriptor, size: 0).fontName == name)
  }
}
