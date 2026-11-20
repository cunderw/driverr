import DriverrCore
import SwiftUI
import Testing
import UIKit

@testable import Driverr

/// The phone's host row at AX3, with a blocked badge.
///
/// A short name must stay whole on one line, and the badge must keep its whole capsule. The
/// name alone gives way first: it hyphenated "workbox" to "work-" / "box". The name's layout
/// priority alone squeezes the count capsule to a sliver instead. Both halves are checked.
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
    lonePane: HostRowLonePane?,
    reporting sink: @escaping @MainActor (HostRowPart, CGRect) -> Void
  ) -> some View {
    NavigationStack {
      List {
        NavigationLink(value: 1) {
          HostRowLabel(
            name: Self.name, status: Self.status(blocked: blocked), lonePane: lonePane,
            onFrame: sink)
        }
      }
    }
    .environment(\.dynamicTypeSize, .accessibility3)
  }

  /// The name on one line and the capsule at its own size, both at AX3, with nothing to
  /// squeeze them.
  private func naturalSizes(badge: String) -> (name: CGSize, capsule: CGSize) {
    var name = CGSize.zero
    var capsule = CGSize.zero
    let window = HostedProbe.window(
      VStack(alignment: .leading) {
        Text(Self.name).fixedSize().measuredFrame { name = $0.size }
        HostBadgeCapsule(badge: badge).fixedSize().measuredFrame { capsule = $0.size }
      }
      .environment(\.dynamicTypeSize, .accessibility3)
    )
    withExtendedLifetime(window) {}
    return (name, capsule)
  }

  private func check(blocked: Int, lonePane: HostRowLonePane?) throws {
    let natural = naturalSizes(badge: String(blocked))
    var frames: [HostRowPart: CGRect] = [:]
    let window = HostedProbe.window(
      row(blocked: blocked, lonePane: lonePane, reporting: { frames[$0] = $1 }))
    defer { withExtendedLifetime(window) {} }

    let name = try #require(frames[.name], "The name never reported a frame.")
    let capsule = try #require(frames[.badge], "The badge never reported a frame.")
    let measured = """
      name \(name), one line \(natural.name); \
      capsule \(capsule), natural \(natural.capsule); window \(window.bounds.width) pt
      """
    #expect(
      abs(name.height - natural.name.height) < 1,
      "The name wraps: \(name.height) pt tall, one line is \(natural.name.height) pt. \(measured)")
    #expect(
      capsule.width >= natural.capsule.width - 0.5,
      "The capsule is squeezed: \(capsule.width) pt of \(natural.capsule.width) pt. \(measured)")
  }

  @Test("at AX3 a row counting several blocked panes keeps its name and its capsule whole")
  func countKeepsNameAndCapsule() throws {
    try check(blocked: 2, lonePane: nil)
  }

  @Test("at AX3 a row whose badge opens one pane keeps its name and its capsule whole")
  func lonePaneKeepsNameAndCapsule() throws {
    try check(blocked: 1, lonePane: HostRowLonePane(title: "claude", open: {}))
  }
}
