import DriverrCore
import SwiftUI
import Testing
import UIKit

@testable import Driverr

/// The back bar over a sub-agent's chat, and the chat's first row under it.
///
/// Laid out the way `PaneChatView` lays them out: the bar is a sibling of the conversation
/// with the column's gutter handed in, and a turn row is capped at `ChatColumn.width` inside
/// the same gutter, all inside the readable column the pad's route gives the chat. What is
/// asserted is that both sit inside the column's inked edges on the phone and on the pad, and
/// that the bar's button and the sub-agent's name do not overlap.
@MainActor
@Suite("Sub-agent back bar", .serialized)
struct SubagentBackBarLayoutTests {
  private struct Measured {
    var button = CGRect.zero
    var title = CGRect.zero
    var firstRow = CGRect.zero
  }

  private static let longTitle = "verifier-7-with-a-name-that-is-long-enough-to-truncate-on-a-phone"

  private func measure(window size: CGSize, column: CGFloat) -> Measured {
    var measured = Measured()
    let gutter = ChatColumn.gutter(forColumnWidth: column)
    let prompt = TranscriptTurn(
      id: "p", speech: .human("Review the config loader on the latest commit."),
      isParentPrompt: true)
    let window = HostedProbe.window(
      VStack(spacing: 0) {
        SubagentBackBar(
          title: Self.longTitle, horizontalInset: gutter, onBack: {},
          onButtonFrame: { measured.button = $0 }, onTitleFrame: { measured.title = $0 })
        TranscriptTurnView(
          turn: prompt, agentName: "Claude", isNewest: false, previousTurn: nil,
          isFinalBlockedAnswer: false, agentStatus: nil, isOpen: false, isExpanded: false,
          onToggleOpen: {}, onToggleExpand: {}
        )
        .frame(maxWidth: ChatColumn.width, alignment: .leading)
        // The row's own frame, inside the gutter the section gives a cell.
        .measuredFrame(into: { measured.firstRow = $0 })
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .padding(.horizontal, gutter)
        Spacer(minLength: 0)
      }
      .frame(maxWidth: column)
      .frame(maxWidth: .infinity, maxHeight: .infinity),
      size: size
    )
    withExtendedLifetime(window) {}
    return measured
  }

  @Test("the back bar and the first row sit inside the column on the phone and the pad")
  func insideTheColumn() {
    for (device, size, column) in [
      ("phone", HostedProbe.phone, HostedProbe.phone.width),
      ("pad", HostedProbe.pad, ChatColumn.width),
    ] {
      let measured = measure(window: size, column: column)
      let gutter = ChatColumn.gutter(forColumnWidth: column)
      let left = (size.width - column) / 2 + gutter
      let right = (size.width + column) / 2 - gutter
      print(
        "[back bar] \(device): button \(measured.button), title \(measured.title), "
          + "row \(measured.firstRow), column \(left)...\(right)")

      #expect(measured.button.width > 0, "\(device): the back button never laid out")
      #expect(measured.firstRow.width > 0, "\(device): the first row never laid out")
      #expect(
        measured.button.minX >= left - 0.5,
        "\(device): the back button starts at x \(measured.button.minX), left of the column's \(left)")
      #expect(
        measured.title.maxX <= right + 0.5,
        "\(device): the title ends at x \(measured.title.maxX), right of the column's \(right)")
      #expect(
        measured.title.minX >= measured.button.maxX,
        "\(device): the title starts at \(measured.title.minX), under the button ending at \(measured.button.maxX)")
      #expect(measured.firstRow.minX >= left - 0.5, "\(device): the first row starts left of the column")
      #expect(measured.firstRow.maxX <= right + 0.5, "\(device): the first row ends right of the column")
      #expect(
        measured.firstRow.minY >= measured.button.maxY,
        "\(device): the first row starts at y \(measured.firstRow.minY), under the bar ending at \(measured.button.maxY)")
    }
  }
}
