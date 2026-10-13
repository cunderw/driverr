import DriverrCore
import SwiftUI

extension DriverrCore.TerminalColor {
  public var swiftUIColor: SwiftUI.Color {
    SwiftUI.Color(
      red: Double(red) / 255,
      green: Double(green) / 255,
      blue: Double(blue) / 255
    )
  }
}

extension DriverrCore.Theme {
  /// The terminal's surface colour, for painting behind it.
  ///
  /// The text stays inside the safe area, and this paints the strips outside it, which
  /// are 62 pt per side on a landscape iPhone.
  public func surfaceColor(for appearance: ThemeAppearance) -> SwiftUI.Color {
    palette(for: appearance).background.swiftUIColor
  }
}
