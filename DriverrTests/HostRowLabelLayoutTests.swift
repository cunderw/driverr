import DriverrCore
import SwiftUI
import Testing
import UIKit

@testable import Driverr

/// The phone's host row with a blocked badge, at the default text size and at the largest.
///
/// A short name must stay whole on one line, and the badge must keep its whole capsule. At the
/// largest size the row cannot hold the name, the dot and the badge side by side: the name
/// hyphenated "workbox" to "work-" / "box", and giving it layout priority squeezed the count
/// capsule to a sliver instead. There the dot and the badge take a line of their own under the
/// address. At the default size they stay beside the name.
@MainActor
@Suite("Host row label layout")
struct HostRowLabelLayoutTests {
  private static let name = "workbox"

  /// The status the store tour's connected host shows, with `blocked` panes waiting.
  private static func status(blocked: Int) -> HostStatus {
    HostStatus(
      hostname: "10.1.0.9",
      connection: .connected,
      herdrVersion: "0.9.1",
      agentStatusCounts: AgentStatusCounts(blocked: blocked)
    )
  }

  /// The row as the phone's host list draws it: a link in a list on a navigation stack.
  private func row(
    blocked: Int,
    size: DynamicTypeSize,
    reporting sink: @escaping @MainActor (HostRowPart, CGRect) -> Void
  ) -> some View {
    // One blocked pane makes the badge a button that opens it; several make it a label.
    let lonePane = blocked == 1 ? HostRowLonePane(title: "claude", open: {}) : nil
    return NavigationStack {
      List {
        NavigationLink(value: 1) {
          HostRowLabel(
            name: Self.name, status: Self.status(blocked: blocked), lonePane: lonePane,
            onFrame: sink)
        }
      }
    }
    .environment(\.dynamicTypeSize, size)
  }

  /// The name on one line and the capsule at its own size, with nothing to squeeze them.
  private func naturalSizes(
    badge: String,
    size: DynamicTypeSize
  ) -> (name: CGSize, capsule: CGSize) {
    var name = CGSize.zero
    var capsule = CGSize.zero
    let window = HostedProbe.window(
      VStack(alignment: .leading) {
        Text(Self.name).fixedSize().measuredFrame { name = $0.size }
        HostBadgeCapsule(badge: badge).fixedSize().measuredFrame { capsule = $0.size }
      }
      .environment(\.dynamicTypeSize, size)
    )
    withExtendedLifetime(window) {}
    return (name, capsule)
  }

  /// `.large` is the default size. `.accessibility5` is the size the UI tests launch with,
  /// `UICTContentSizeCategoryAccessibilityXXXL`.
  @Test(
    "the name stays on one line and the capsule whole, the dot and badge beside or under it",
    arguments: [DynamicTypeSize.large, .accessibility5], [1, 2])
  func nameAndBadgeStayWhole(size: DynamicTypeSize, blocked: Int) throws {
    let natural = naturalSizes(badge: String(blocked), size: size)
    var frames: [HostRowPart: CGRect] = [:]
    let window = HostedProbe.window(
      row(blocked: blocked, size: size, reporting: { frames[$0] = $1 }))
    defer { withExtendedLifetime(window) {} }

    let name = try #require(frames[.name], "The name never reported a frame.")
    let capsule = try #require(frames[.badge], "The badge never reported a frame.")
    let dot = try #require(frames[.dot], "The dot never reported a frame.")
    let address = try #require(frames[.address], "The address never reported a frame.")
    let measured = """
      name \(name), one line \(natural.name); capsule \(capsule), natural \(natural.capsule); \
      dot \(dot); address \(address)
      """
    #expect(
      abs(name.height - natural.name.height) < 1,
      "The name wraps: \(name.height) pt tall, one line is \(natural.name.height) pt. \(measured)")
    #expect(
      capsule.width >= natural.capsule.width - 0.5,
      "The capsule is squeezed: \(capsule.width) pt of \(natural.capsule.width) pt. \(measured)")
    // The row's 8 pt gap between the dot and the badge, whole. A badge layout box narrower
    // than the capsule lets the capsule spill sideways over the dot.
    #expect(
      capsule.minX - dot.maxX >= 7.5,
      "The badge is \(capsule.minX - dot.maxX) pt after the dot, not 8. \(measured)")
    if size.isAccessibilitySize {
      // Under the address, not only the name: a badge box smaller than the capsule lets the
      // capsule spill up over the address.
      #expect(dot.minY >= address.maxY, "The dot is not under the address. \(measured)")
      #expect(capsule.minY >= address.maxY, "The badge is not under the address. \(measured)")
    } else {
      #expect(dot.minX >= name.maxX, "The dot is not beside the name. \(measured)")
      #expect(capsule.minX >= dot.maxX, "The badge is not after the dot. \(measured)")
    }
  }
}
