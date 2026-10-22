import DriverrCore
import SwiftUI
import Testing
import UIKit

@testable import Driverr

/// The sub-agent list under the provenance row, collapsed and open.
///
/// Laid out the way `PaneChatView` lays it out: a sibling of the conversation with the
/// column's gutter handed in, inside the readable column the pad's route gives the chat. What
/// is asserted is that the bar sits inside the column's edges on the phone and on the pad,
/// that an open short list is drawn at its own height, and that an open long list stops at
/// its cap so the chat under it keeps its room.
@MainActor
@Suite("Sub-agent list bar", .serialized)
struct SubagentListBarLayoutTests {
  private struct Measured {
    var header = CGRect.zero
    var list = CGRect.zero
    var below = CGRect.zero
  }

  private static func summaries(_ count: Int) -> [SubagentSummary] {
    (0..<count).map { index in
      SubagentSummary(
        id: "a\(index)",
        name: index.isMultiple(of: 2) ? "verifier-\(index)-with-a-name-long-enough-to-truncate" : nil,
        description: "Review the config loader on the latest commit, then report back",
        agentType: "Explore", toolUseID: index.isMultiple(of: 2) ? nil : "toolu_\(index)",
        isFinished: index > 0,
        spawnedAt: Date().addingTimeInterval(-Double(index) * 600),
        writtenAt: Date().addingTimeInterval(-Double(index) * 600))
    }
  }

  private func measure(window size: CGSize, column: CGFloat, count: Int, isExpanded: Bool)
    -> Measured
  {
    var measured = Measured()
    let gutter = ChatColumn.gutter(forColumnWidth: column)
    let list = SubagentList(total: count, summaries: Self.summaries(count))
    let window = HostedProbe.window(
      VStack(spacing: 0) {
        SubagentListBar(
          list: list, turns: [], isExpanded: .constant(isExpanded), horizontalInset: gutter,
          onOpen: { _ in }, onHeaderFrame: { measured.header = $0 },
          onListFrame: { measured.list = $0 })
        // What comes next in the chat: its top is where the list ends. Read on every change,
        // not once, because the open list settles its height a pass after it appears.
        Color.clear.frame(height: 1)
          .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { measured.below = $0 }
        Spacer(minLength: 0)
      }
      .frame(maxWidth: column)
      .frame(maxWidth: .infinity, maxHeight: .infinity),
      size: size
    )
    // The open list sizes itself from its rows a pass after it appears.
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    window.layoutIfNeeded()
    withExtendedLifetime(window) {}
    return measured
  }

  private static let devices = [
    ("phone", HostedProbe.phone, HostedProbe.phone.width),
    ("pad", HostedProbe.pad, ChatColumn.width),
  ]

  @Test("the collapsed bar sits inside the column on the phone and the pad")
  func collapsedInsideTheColumn() {
    for (device, size, column) in Self.devices {
      let measured = measure(window: size, column: column, count: 3, isExpanded: false)
      let gutter = ChatColumn.gutter(forColumnWidth: column)
      let left = (size.width - column) / 2 + gutter
      let right = (size.width + column) / 2 - gutter
      print("[sub-agent list] \(device) collapsed: header \(measured.header), column \(left)...\(right)")
      #expect(measured.header.width > 0, "\(device): the header never laid out")
      #expect(measured.header.minX >= left - 0.5, "\(device): the header starts left of the column")
      #expect(measured.header.maxX <= right + 0.5, "\(device): the header ends right of the column")
      #expect(measured.list == .zero, "\(device): a collapsed bar drew its rows")
      // Tappable at the platform minimum.
      #expect(measured.header.height >= 44 - 0.5, "\(device): the header is \(measured.header.height) pt tall")
    }
  }

  @Test("an open short list is drawn at its own height, under the header")
  func shortListAtItsHeight() {
    for (device, size, column) in Self.devices {
      let measured = measure(window: size, column: column, count: 2, isExpanded: true)
      print(
        "[sub-agent list] \(device) two rows: header \(measured.header), list \(measured.list), "
          + "below \(measured.below)")
      #expect(measured.list.height > 60, "\(device): two rows measure \(measured.list.height) pt")
      #expect(measured.list.height < 200, "\(device): two rows took the long list's cap")
      #expect(measured.list.minY >= measured.header.maxY, "\(device): the rows start under the header")
      #expect(measured.below.minY >= measured.list.maxY - 0.5, "\(device): the chat starts inside the list")
    }
  }

  @Test("an open long list stops at its cap and the chat starts under it")
  func longListAtTheCap() {
    for (device, size, column) in Self.devices {
      let measured = measure(window: size, column: column, count: 50, isExpanded: true)
      print("[sub-agent list] \(device) fifty rows: header \(measured.header), list \(measured.list)")
      #expect(measured.list.height > 200, "\(device): fifty rows measure \(measured.list.height) pt")
      #expect(measured.list.height <= 232 + 0.5, "\(device): fifty rows passed the cap at \(measured.list.height) pt")
      #expect(measured.below.minY - measured.header.minY < size.height / 2, "\(device): the list took half the window")
    }
  }
}
