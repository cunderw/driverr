import DriverrCore
import SwiftUI
import Testing
import UIKit

@testable import Driverr

/// The iPad sidebar's pane tree at the largest text sizes, in a narrow sidebar.
///
/// Three levels of indent (host, workspace, tab) come out of the title's width before a word
/// is drawn. At AX3 in a 420 pt column the title must still hold a usable width, and every row
/// must stay a 44 pt target.
@MainActor
@Suite("Sidebar pane tree layout")
struct SidebarPaneTreeLayoutTests {
  /// The sidebar width this test lays out at: the platform's 320 pt floor scaled toward
  /// `SidebarColumnWidth`'s clamp, near what an accessibility size gives the column.
  private static let width: CGFloat = 420

  /// One focused workspace of two tabs, so every pane sits three levels in.
  private static let tree = SessionTree(workspaces: [
    Workspace(
      id: "w1", number: 1, label: "driverr", isFocused: true,
      tabs: [
        Tab(
          id: "w1:t1", workspaceID: "w1", number: 1, label: "app",
          panes: [
            Pane(
              id: "w1:p1", tabID: "w1:t1", workspaceID: "w1",
              title: "needs a decision about the connection pool",
              agent: Agent(name: "claude", status: .blocked), directory: "~/dev/driverr"),
            Pane(
              id: "w1:p2", tabID: "w1:t1", workspaceID: "w1", title: "zsh",
              directory: "~/dev/driverr/DriverrKit"),
          ]),
        Tab(
          id: "w1:t2", workspaceID: "w1", number: 2, label: "tests",
          panes: [
            Pane(
              id: "w1:p3", tabID: "w1:t2", workspaceID: "w1", title: "swift test",
              agent: Agent(name: "claude", status: .working))
          ]),
      ])
  ])

  private func sidebar(reporting sink: @escaping @MainActor (String, CGRect) -> Void) -> some View {
    List {
      Text("workbox")
      SidebarPaneTree(
        hostID: UUID(),
        tree: Self.tree,
        disclosure: .constant(SidebarDisclosure()),
        indent: SidebarPaneTree.hostIndent,
        onPaneTitleFrame: sink
      )
    }
    .listStyle(.sidebar)
    .environment(\.dynamicTypeSize, .accessibility3)
  }

  /// Every list cell in the window, top to bottom.
  private func cells(in view: UIView) -> [CGRect] {
    var found: [CGRect] = []
    func walk(_ view: UIView) {
      if view is UICollectionViewCell, !view.isHidden {
        found.append(view.convert(view.bounds, to: nil))
      }
      view.subviews.forEach(walk)
    }
    walk(view)
    return found.sorted { $0.minY < $1.minY }
  }

  @Test("at AX3 in a narrow sidebar every pane title keeps a usable width")
  func titlesKeepTheirWidth() {
    var titles: [String: CGRect] = [:]
    let window = HostedProbe.window(
      sidebar(reporting: { titles[$0] = $1 }),
      size: CGSize(width: Self.width, height: HostedProbe.pad.height)
    )
    defer { withExtendedLifetime(window) {} }

    #expect(titles.count == 3, "Expected all three pane rows to lay out; got \(titles.keys).")
    // Half the column. Less, and an AX3 title holds one short word per line.
    for (id, frame) in titles {
      #expect(
        frame.width >= Self.width / 2,
        "\(id)'s title is \(frame.width) pt wide in a \(Self.width) pt sidebar.")
    }
  }

  @Test("at AX3 every row of the tree is at least a 44 pt target")
  func rowsAreTargets() {
    let window = HostedProbe.window(
      sidebar(reporting: { _, _ in }),
      size: CGSize(width: Self.width, height: HostedProbe.pad.height)
    )
    defer { withExtendedLifetime(window) {} }

    let rows = cells(in: window)
    // Host, workspace, two tabs, three panes.
    #expect(rows.count == 7, "Expected seven rows; found \(rows.count).")
    for row in rows {
      #expect(row.height >= 44, "A row is \(row.height) pt tall at \(row.minY).")
    }
  }
}
