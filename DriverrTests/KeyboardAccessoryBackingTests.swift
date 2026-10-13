import SwiftTerm
import Testing
import UIKit

@testable import DriverrTerm

/// The terminal's key row draws one opaque backing on an iPad and none on a phone.
///
/// On an iPad the row spans the split view, and with no backing its translucent keys took the
/// sidebar's tone on one side and the terminal's on the other. On a phone the gaps between the
/// keys show the terminal's theme surface, which a backing would replace.
///
/// The backing is `systemGray5` in light and `secondarySystemBackground` in dark, because no
/// single system colour sits near the keyboard's own band in both. Measured on the iPad
/// simulator, the band reads about (226, 227, 232) in light and (32, 32, 32) in dark.
/// `systemGray5` is 12 lighter than it in dark, and `secondarySystemBackground` is 16 lighter
/// in light. Each shows as a stripe above the keyboard.
///
/// Hosted, because `DriverrKeyboardAccessory` is a UIKit view and the Kit tier does not build
/// it. This pins which idiom gets a backing, that it is opaque, and which colour each
/// appearance takes. What the band looks like against the keyboard is checked by looking,
/// with `scripts/look.sh --kind ipad`.
@MainActor
@Suite("DriverrKeyboardAccessory backing")
struct KeyboardAccessoryBackingTests {
  private func row(_ idiom: UIUserInterfaceIdiom) -> DriverrKeyboardAccessory {
    DriverrKeyboardAccessory(terminalView: TerminalView(frame: .zero), idiom: idiom)
  }

  /// A dynamic colour can hand back another dynamic colour, so resolve until it is plain.
  private func components(_ color: UIColor, _ style: UIUserInterfaceStyle) -> [CGFloat] {
    let traits = UITraitCollection(userInterfaceStyle: style)
    let resolved = color.resolvedColor(with: traits).resolvedColor(with: traits)
    var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return [red, green, blue, alpha]
  }

  @Test("An iPad row has an opaque backing in light and in dark")
  func padRowIsOpaque() throws {
    let backing = try #require(row(.pad).backgroundColor)
    #expect(components(backing, .light).last == 1)
    #expect(components(backing, .dark).last == 1)
  }

  @Test("An iPad row is systemGray5 in light and secondarySystemBackground in dark")
  func padRowTakesTheKeyboardsToneInEachAppearance() throws {
    let backing = try #require(row(.pad).backgroundColor)
    #expect(components(backing, .light) == components(.systemGray5, .light))
    #expect(components(backing, .dark) == components(.secondarySystemBackground, .dark))
  }

  @Test("A phone row draws no backing, so its gaps show the terminal")
  func phoneRowHasNoBacking() {
    #expect(row(.phone).backgroundColor == nil)
  }
}
