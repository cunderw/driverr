import CoreGraphics
import Testing

@testable import Driverr

/// The reply chips' row rule, which both measuring and placing use (#109). A centred chip
/// block once wrapped its last chip onto a row of its own, because placing broke rows against
/// rounded bounds while measuring broke them against the proposed width.
@Suite("FlowLayout rows")
struct FlowLayoutRowsTests {
  @Test("a chip that does not fit after another starts a new row")
  func breaks() {
    #expect(FlowLayout.rows(of: [100, 100], spacing: 8, within: 207) == [[0], [1]])
  }

  @Test("an exact fit stays on one row")
  func exactFit() {
    #expect(FlowLayout.rows(of: [100, 100], spacing: 8, within: 208) == [[0, 1]])
  }

  @Test("a chip wider than the width overflows on a row of its own, with no empty row")
  func tooWide() {
    #expect(FlowLayout.rows(of: [300], spacing: 8, within: 200) == [[0]])
    #expect(FlowLayout.rows(of: [50, 300, 50], spacing: 8, within: 200) == [[0], [1], [2]])
  }

  @Test("no chips is no rows, and an unbounded width is one row")
  func edges() {
    #expect(FlowLayout.rows(of: [], spacing: 8, within: 200) == [])
    #expect(FlowLayout.rows(of: [100, 400], spacing: 8, within: .infinity) == [[0, 1]])
  }
}
