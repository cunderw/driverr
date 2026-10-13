import DriverrCore
import Foundation
import SwiftTerm
import Testing

@testable import DriverrTerm

@Suite("Palette → SwiftTerm")
struct PaletteSwiftTermTests {
  @Test("a full channel becomes a full 16-bit channel, not 0xFF00")
  func scalesChannelsWithTheRightMultiplier() {
    let white = TerminalColor(hex: 0xFF_FF_FF).swiftTermColor
    #expect(white.red == 65535)
    #expect(white.green == 65535)
    #expect(white.blue == 65535)

    let black = TerminalColor(hex: 0x00_00_00).swiftTermColor
    #expect(black.red == 0)
  }

  @Test("channels keep their order")
  func keepsChannelOrder() {
    let color = TerminalColor(hex: 0x11_22_33).swiftTermColor
    #expect(color.red == 0x11 * 257)
    #expect(color.green == 0x22 * 257)
    #expect(color.blue == 0x33 * 257)
  }

  @Test("every bundled palette converts to the sixteen SwiftTerm wants")
  func bundledPalettesConvertToSixteen() {
    // `installPalette` silently ignores any count but sixteen.
    for theme in Theme.bundled {
      for appearance in ThemeAppearance.allCases {
        #expect(theme.palette(for: appearance).swiftTermANSI.count == 16, "\(theme.id)")
      }
    }
  }

  @Test("an installed palette is the one the emulator reports back")
  func installedPaletteReachesTheEmulator() {
    // Through OSC 4, the path a remote program uses, so the palette is shown to be in effect.
    final class ResponseRecorder: TerminalDelegate {
      var response = ""
      func send(source: Terminal, data: ArraySlice<UInt8>) {
        response += String(decoding: data, as: UTF8.self)
      }
    }

    let recorder = ResponseRecorder()
    let terminal = Terminal(delegate: recorder)
    let palette = Theme.nord.palette(for: .dark)
    terminal.installPalette(colors: palette.swiftTermANSI)

    terminal.feed(text: "\u{1B}]4;1;?\u{1B}\\")

    let red = palette.ansi[1]
    let expected = String(
      format: "rgb:%04x/%04x/%04x",
      Int(red.red) * 257,
      Int(red.green) * 257,
      Int(red.blue) * 257
    )
    #expect(recorder.response.contains(expected), "\(recorder.response.debugDescription)")
  }
}
