import CoreGraphics
import SwiftUI
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

  // MARK: - A chip wider than the row

  /// A chip that reads its label on one line at `natural`, and wraps to two lines when given
  /// less, as a capsule's `Text` does.
  private func measure(natural: [CGFloat]) -> (Int, ProposedViewSize) -> CGSize {
    { index, proposal in
      let width = natural[index]
      guard let offered = proposal.width, offered < width else {
        return CGSize(width: width, height: 44)
      }
      return CGSize(width: offered, height: 88)
    }
  }

  /// At an accessibility text size "Yes, I trust this folder" is wider than the column. Its
  /// own row is not enough: overflowing it widened the centred notice past the screen.
  @Test("a chip wider than the row is offered the row's width and wraps inside it")
  func tooWideWraps() {
    let arrangement = FlowLayout.arrange(
      count: 2, spacing: 8, within: 200, measure: measure(natural: [80, 300]))
    #expect(arrangement.proposals[1] == ProposedViewSize(width: 200, height: nil))
    #expect(arrangement.frames[1] == CGRect(x: 0, y: 52, width: 200, height: 88))
    #expect(arrangement.size == CGSize(width: 200, height: 140))
  }

  @Test("the reported width never passes the offered width")
  func neverWider() {
    for natural in [[300.0], [80.0, 300.0], [150.0, 150.0, 250.0]] {
      let size = FlowLayout.arrange(
        count: natural.count, spacing: 8, within: 200,
        measure: measure(natural: natural.map { CGFloat($0) })
      ).size
      #expect(size.width <= 200, "\(natural) reported \(size.width)")
    }
  }

  @Test("chips that fit keep their own size and are offered nothing")
  func fittingChips() {
    let arrangement = FlowLayout.arrange(
      count: 2, spacing: 8, within: 200, measure: measure(natural: [80, 100]))
    #expect(arrangement.proposals == [.unspecified, .unspecified])
    #expect(arrangement.frames == [
      CGRect(x: 0, y: 0, width: 80, height: 44), CGRect(x: 88, y: 0, width: 100, height: 44),
    ])
    #expect(arrangement.size == CGSize(width: 188, height: 44))
  }
}
