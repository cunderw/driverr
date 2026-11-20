import DriverrCore
import SwiftUI
import Testing
import UIKit

@testable import Driverr

/// The iPad sidebar's pane tree at the largest text sizes, in a narrow sidebar.
///
/// Three levels of indent (host, workspace, tab) come out of the title's width before a word
/// is drawn. At AX3 in a 420 pt column the title must still hold every word whole, and every
/// row must stay a 44 pt target.
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
              title: longTitle,
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

  /// The longest title in the tree, whose every word has to fit the column whole.
  private static let longTitle = "needs a decision about the connection pool"

  /// How wide each word of `longTitle` is at AX3, in the row title's font.
  private func wordWidths() -> [String: CGFloat] {
    var widths: [String: CGFloat] = [:]
    let words = Self.longTitle.split(separator: " ").map(String.init)
    let window = HostedProbe.window(
      VStack(alignment: .leading) {
        ForEach(words, id: \.self) { word in
          Text(word).fixedSize().measuredFrame { widths[word] = $0.width }
        }
      }
      .environment(\.dynamicTypeSize, .accessibility3),
      size: CGSize(width: Self.width, height: HostedProbe.pad.height)
    )
    withExtendedLifetime(window) {}
    return widths
  }

  /// "Usable" is measured, not guessed: the column must hold the title's widest word without
  /// breaking it. Three levels of indent and the badge come out of the row first.
  @Test("at AX3 in a narrow sidebar every title column holds the widest word whole")
  func titlesKeepTheirWidth() throws {
    let widest = try #require(wordWidths().values.max())
    var columns: [String: CGRect] = [:]
    let window = HostedProbe.window(
      sidebar(reporting: { columns[$0] = $1 }),
      size: CGSize(width: Self.width, height: HostedProbe.pad.height)
    )
    defer { withExtendedLifetime(window) {} }

    #expect(columns.count == 3, "Expected all three pane rows to lay out; got \(columns.keys).")
    for (id, frame) in columns {
      #expect(
        frame.width >= widest,
        "\(id)'s title column is \(frame.width) pt wide; the widest word needs \(widest) pt.")
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
