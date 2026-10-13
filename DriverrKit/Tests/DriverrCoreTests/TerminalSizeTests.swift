import Testing
@testable import DriverrCore

@Suite("TerminalSize")
struct TerminalSizeTests {
  @Test("clamps zero and negative dimensions up to one")
  func clampsToMinimumOfOne() {
    let size = TerminalSize(columns: 0, rows: -5)
    #expect(size.columns == 1)
    #expect(size.rows == 1)
  }

  @Test("keeps sane dimensions untouched")
  func keepsSaneDimensions() {
    let size = TerminalSize(columns: 120, rows: 40)
    #expect(size.columns == 120)
    #expect(size.rows == 40)
  }

  @Test("pixel dimensions default to zero, meaning unspecified")
  func pixelDimensionsDefaultToZero() {
    let size = TerminalSize(columns: 80, rows: 24)
    #expect(size.pixelWidth == 0)
    #expect(size.pixelHeight == 0)
  }
}
