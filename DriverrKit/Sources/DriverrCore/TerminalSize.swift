/// Dimensions of a pseudo-terminal, in character cells and optionally pixels.
///
/// SSH carries these as `UInt32`, and a zero-column terminal wedges the remote side rather
/// than failing, so dimensions are clamped here for every caller.
public struct TerminalSize: Hashable, Sendable {
  public let columns: Int
  public let rows: Int
  /// Zero means "unspecified", which is what SSH expects when only cells are known.
  public let pixelWidth: Int
  public let pixelHeight: Int

  public init(columns: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) {
    self.columns = max(1, columns)
    self.rows = max(1, rows)
    self.pixelWidth = max(0, pixelWidth)
    self.pixelHeight = max(0, pixelHeight)
  }
}
