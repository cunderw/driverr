import Testing
@testable import DriverrCore

@Suite("TerminalCell")
struct TerminalCellTests {
  private func cell(_ x: Double, _ y: Double) -> TerminalCell? {
    TerminalCell.at(x: x, y: y, cellWidth: 8, cellHeight: 16, columns: 80, rows: 24)
  }

  @Test("a point maps to the cell it falls in, counted from 0")
  func mapsPointToCell() {
    #expect(cell(0, 0) == TerminalCell(column: 0, row: 0))
    #expect(cell(7.9, 15.9) == TerminalCell(column: 0, row: 0))
    #expect(cell(8, 16) == TerminalCell(column: 1, row: 1))
    #expect(cell(8 * 12 + 3, 16 * 5 + 1) == TerminalCell(column: 12, row: 5))
  }

  @Test("a point past the grid's edge clamps to the last cell")
  func clampsPastTheEdge() {
    #expect(cell(8 * 80 + 5, 16 * 24 + 5) == TerminalCell(column: 79, row: 23))
    #expect(cell(1e300, 1e300) == TerminalCell(column: 79, row: 23))
  }

  @Test("a point above or left of the grid clamps to the first cell")
  func clampsBeforeTheOrigin() {
    #expect(cell(-4, -20) == TerminalCell(column: 0, row: 0))
  }

  @Test(
    "no grid, no cell",
    arguments: [(0, 24, 8.0, 16.0), (80, 0, 8, 16), (80, 24, 0, 16), (80, 24, 8, 0)]
  )
  func noGridNoCell(columns: Int, rows: Int, cellWidth: Double, cellHeight: Double) {
    #expect(
      TerminalCell.at(
        x: 10, y: 10, cellWidth: cellWidth, cellHeight: cellHeight, columns: columns, rows: rows
      ) == nil
    )
  }

  @Test("a point that is not a number has no cell")
  func nonFinitePoint() {
    #expect(cell(.nan, 0) == nil)
    #expect(cell(0, .infinity) == nil)
  }
}
