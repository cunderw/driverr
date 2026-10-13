import DriverrCore
import SwiftTerm

/// The one place a `DriverrCore` colour becomes a SwiftTerm colour.
///
/// SwiftTerm stores 16-bit channels. The multiplier is 257, not 256, so `0xFF` becomes
/// `0xFFFF` and white stays pure.
extension DriverrCore.TerminalColor {
  var swiftTermColor: SwiftTerm.Color {
    SwiftTerm.Color(
      red: UInt16(red) * 257,
      green: UInt16(green) * 257,
      blue: UInt16(blue) * 257
    )
  }
}

extension DriverrCore.TerminalPalette {
  /// The sixteen ANSI slots, in the order `Terminal.installPalette` expects.
  ///
  /// SwiftTerm silently ignores an array that is not exactly sixteen long.
  /// `TerminalPalette` guarantees the count.
  var swiftTermANSI: [SwiftTerm.Color] {
    ansi.map(\.swiftTermColor)
  }
}
