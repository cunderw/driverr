import Testing

@testable import DriverrCore

/// What the terminal's accessory row draws and how it is sized.
@Suite("PaneKey accessory row")
struct PaneKeyTests {
  @Test("the cursor keys are drawn as glyphs, never as words")
  func cursorKeysAreGlyphs() {
    #expect(PaneKey.left.accessoryGlyph == "←")
    #expect(PaneKey.down.accessoryGlyph == "↓")
    #expect(PaneKey.up.accessoryGlyph == "↑")
    #expect(PaneKey.right.accessoryGlyph == "→")
  }

  /// `label` stays the word, for prose about a key; the row must not draw it.
  @Test("no cursor key's glyph is its label")
  func glyphsAreNotLabels() {
    for key in [PaneKey.left, .down, .up, .right] {
      #expect(key.accessoryGlyph != key.label, "\(key) is still drawn as a word")
    }
  }

  @Test("every other key draws its own label")
  func wordKeysAreUnchanged() {
    for key in [PaneKey.esc, .tab, .enter, .yes, .no, .interrupt] {
      #expect(key.accessoryGlyph == key.label)
    }
  }

  @Test("the row is exactly the key height plus its insets")
  func rowHeightFollowsTheKeys() {
    let metrics = PaneKey.AccessoryRowMetrics.self
    #expect(metrics.keyHeight == 44)
    #expect(metrics.rowHeight == metrics.keyHeight + 2 * metrics.verticalInset)
  }

  /// The 375 pt phones get 42.75 pt keys, under the 44 pt floor. That was accepted rather
  /// than dropping a key.
  @Test("eight keys are 44 pt wide from 385 pt up, and 42.75 pt at 375")
  func eightKeysFitTheFloor() {
    let metrics = PaneKey.AccessoryRowMetrics.self
    #expect(metrics.keyWidth(rowWidth: 385, keyCount: 8) >= 44)
    #expect(metrics.keyWidth(rowWidth: 390, keyCount: 8) >= 44)
    #expect(metrics.keyWidth(rowWidth: 402, keyCount: 8) >= 44)
    #expect(metrics.keyWidth(rowWidth: 375, keyCount: 8) == 42.75)
  }

  /// The picker numbers options 1 to 9.
  @Test("a digit key exists for 1 to 9 and nothing else")
  func digitsCoverOneToNine() {
    #expect(PaneKey.digit(0) == nil)
    #expect(PaneKey.digit(10) == nil)
    for number in 1...9 {
      let key = PaneKey.digit(number)
      #expect(key?.rawValue == String(number))
      #expect(key?.digitValue == number)
    }
    #expect(PaneKey.right.digitValue == nil)
  }

  /// A glyph read aloud is "leftwards arrow".
  @Test("arrow keys are spoken, not read off the glyph")
  func arrowsAreSpoken() {
    #expect(PaneKey.left.accessibleName == "Left arrow")
    #expect(PaneKey.right.accessibleName == "Right arrow")
    for key in PaneKey.allCases {
      #expect(!key.accessibleName.isEmpty)
    }
  }
}
