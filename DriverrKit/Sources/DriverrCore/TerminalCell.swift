/// One character cell of a terminal's visible grid, counted from 0 at the top left.
///
/// Here because `DriverrTerm` turns a tap into one and `DriverrHerdr` sends it as
/// `terminal.mouse`, and neither may import the other. herdr counts from 0 too. A PTY mouse
/// report counts from 1, and SwiftTerm's encoder adds the one.
public struct TerminalCell: Hashable, Sendable {
  public var column: Int
  public var row: Int

  public init(column: Int, row: Int) {
    self.column = column
    self.row = row
  }

  /// The cell under a point in the terminal's viewport, or `nil` when there is no grid.
  ///
  /// The point is measured from the viewport's top left, not from a scroll view's content.
  /// The cell size has to be the one the grid is drawn at: the view is usually a little
  /// larger than `columns` × `cellWidth`, so dividing the view's own size by the grid's is
  /// wrong by up to a cell at the far edge.
  ///
  /// Clamped rather than refused. The strip past the last column or row belongs to no cell,
  /// and a finger there meant the nearest one.
  public static func at(
    x: Double,
    y: Double,
    cellWidth: Double,
    cellHeight: Double,
    columns: Int,
    rows: Int
  ) -> TerminalCell? {
    guard columns > 0, rows > 0, cellWidth > 0, cellHeight > 0, x.isFinite, y.isFinite else {
      return nil
    }
    // Clamped before the conversion, because `Int(_:)` traps on a value it cannot hold.
    let column = min(max(0, x) / cellWidth, Double(columns - 1))
    let row = min(max(0, y) / cellHeight, Double(rows - 1))
    return TerminalCell(column: Int(column), row: Int(row))
  }
}
