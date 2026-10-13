import CoreText
import DriverrCore
import Testing
import UIKit

/// The captured screen draws ⏺ as text, one cell wide.
///
/// Claude Code marks each turn with ⏺ U+23FA. The terminal face has no glyph for it, and
/// CoreText falls back to Apple Color Emoji, wider than a cell, pushing the row right.
/// `String.withTextPresentation` appends U+FE0E; these cases read back which face CoreText
/// picks and how wide the row is.
///
/// Hosted, because the answer is the iOS font cascade and the app's bundled face.
@Suite("Pane screen glyphs")
struct PaneScreenGlyphTests {
  /// The default face, which is what a fresh install draws in, and System Mono, whose
  /// cascade differs.
  static let faces: [TerminalFont] = [.default, .system]

  /// The face at the default size, resolved the way `PaneScreenView.advance` does.
  private func font(_ face: TerminalFont) throws -> UIFont {
    let size = TerminalSettings.defaultFontSize
    guard let name = face.systemFontName else {
      return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
    // A missing bundled face would measure the system's fallback and pass for it.
    return try #require(UIFont(name: name, size: size), "\(name) is not registered")
  }

  private struct Measured {
    let fonts: [String]
    let width: Double
  }

  private func measure(_ text: String, in font: UIFont) -> Measured {
    let attributed = NSAttributedString(string: text, attributes: [.font: font])
    let line = CTLineCreateWithAttributedString(attributed)
    let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
    let fonts = runs.map { run -> String in
      let attributes = CTRunGetAttributes(run) as NSDictionary
      guard let value = attributes[kCTFontAttributeName] else { return "?" }
      return CTFontCopyPostScriptName(value as! CTFont) as String
    }
    return Measured(fonts: fonts, width: CTLineGetTypographicBounds(line, nil, nil, nil))
  }

  /// Measured when this was written, at 13 pt. ⏺ with the selector is STIXTwoMath-Regular
  /// at 8.19 pt in both faces, against a 7.80 pt JetBrains Mono cell and an 8.04 pt System
  /// Mono cell. Bare ⏺ is AppleColorEmoji at 17 pt. ⚠ with the selector is JetBrains
  /// Mono's own glyph at 7.80 pt, and Menlo's at 7.83 pt from System Mono. ✔ with the
  /// selector is Menlo at 7.83 pt from both.
  @Test("⏺ with the text selector falls back to a text face", arguments: faces)
  func recordGlyphFallsBackToText(face: TerminalFont) throws {
    let font = try font(face)
    let measured = measure("⏺\u{FE0E}", in: font)
    #expect(!measured.fonts.contains { $0.hasPrefix("AppleColorEmoji") }, "\(measured.fonts)")
  }

  @Test("a row with ⏺ is as wide as the same row with a letter in its place", arguments: faces)
  func recordRowKeepsTheGrid(face: TerminalFont) throws {
    let font = try font(face)
    let record = measure("⏺ Bash(ls -la)".withTextPresentation, in: font)
    let letter = measure("x Bash(ls -la)", in: font)
    #expect(!record.fonts.contains { $0.hasPrefix("AppleColorEmoji") }, "\(record.fonts)")
    #expect(abs(record.width - letter.width) <= 1, "⏺ row \(record.width), x row \(letter.width)")
  }
}
