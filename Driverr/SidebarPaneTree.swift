import DriverrCore
import SwiftUI

/// One connected host's panes in the iPad sidebar: workspace, tab, pane.
///
/// Rows of the sidebar's `List`, under the host's own row. A pane row is a
/// `NavigationLink(value: SidebarSelection.pane(…))`, so a tap writes the list's selection,
/// and `ContentView`'s setter opens the pane. The tab level follows the host screen's rule
/// (`SidebarDisclosure.showsTabRows`).
///
/// Plain inputs, so `DriverrTests` can lay it out with no connection.
struct SidebarPaneTree: View {
  let hostID: DriverrCore.Host.ID
  /// The host's tree as the sidebar shows it. `ContentView` passes `tree(keeping:)` for the
  /// host with the open pane, so the pane's row is there to highlight.
  let tree: SessionTree
  @Binding var disclosure: SidebarDisclosure
  /// Added before every row's content, because the host above is a plain row and the
  /// `List`'s outline starts at the host's own level. Nesting adds the levels below it.
  var indent: CGFloat = 0
  /// The stop a pane's transcript ends on, or `nil`. `ContentView` reads it through
  /// `existingModel` only, so drawing a row never fetches a transcript.
  var stop: (Pane) -> AgentStop? = { _ in nil }
  /// Kept polling by every workspace row. The host row holds it too, but a lazy `List`
  /// releases that hold when the host row scrolls off, and the panes below would go stale.
  var session: SessionModel?
  /// Where a hosted layout test reads each pane title's frame. See `SidebarPaneRow`.
  var onPaneTitleFrame: (@MainActor (String, CGRect) -> Void)?

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  /// One outline level, as the sidebar `List` indents a `DisclosureGroup`'s rows (measured
  /// on Driverr iPad). The host level is drawn by hand with it.
  static let hostIndent: CGFloat = 20

  var body: some View {
    ForEach(tree.workspaces) { workspace in
      DisclosureGroup(isExpanded: workspaceBinding(workspace)) {
        if SidebarDisclosure.showsTabRows(workspace) {
          ForEach(workspace.tabs) { tab in
            DisclosureGroup(isExpanded: tabBinding(tab)) {
              paneRows(tab)
            } label: {
              tabLabel(tab)
            }
          }
        } else {
          ForEach(workspace.tabs) { tab in
            paneRows(tab)
          }
        }
      } label: {
        workspaceLabel(workspace)
      }
    }
  }

  private func workspaceBinding(_ workspace: Workspace) -> Binding<Bool> {
    Binding(
      get: { disclosure.isWorkspaceExpanded(workspace.id, hostID: hostID, tree: tree) },
      set: { disclosure.setWorkspace(workspace.id, hostID: hostID, expanded: $0) }
    )
  }

  private func tabBinding(_ tab: DriverrCore.Tab) -> Binding<Bool> {
    Binding(
      get: { disclosure.isTabExpanded(tab.id, hostID: hostID) },
      set: { disclosure.setTab(tab.id, hostID: hostID, expanded: $0) }
    )
  }

  @ViewBuilder
  private func paneRows(_ tab: DriverrCore.Tab) -> some View {
    // herdr's order, as on the host screen, so a status change moves a badge and not a row.
    ForEach(tab.panes) { pane in
      NavigationLink(value: SidebarSelection.pane(hostID: hostID, paneID: pane.id)) {
        SidebarPaneRow(pane: pane, stop: stop(pane), onTitleFrame: titleFrameReport(for: pane))
          .padding(.leading, indent)
      }
      // On the link, as `hosts.row` is, so the row is one element and one selection.
      .accessibilityIdentifier("sidebar.pane")
    }
  }

  private func titleFrameReport(for pane: Pane) -> (@MainActor (CGRect) -> Void)? {
    guard let onPaneTitleFrame else { return nil }
    let id = pane.id
    return { frame in onPaneTitleFrame(id, frame) }
  }

  /// The workspace row: its roll-up badge while closed, its name, a single named tab folded
  /// in, and its pane count. The host screen's `workspaceLabel`, without the rename menu.
  private func workspaceLabel(_ workspace: Workspace) -> some View {
    HStack(spacing: 6) {
      if !disclosure.isWorkspaceExpanded(workspace.id, hostID: hostID, tree: tree),
        let status = workspace.status
      {
        AgentStatusBadge(status: status)
      }
      // One `Text`, so at the accessibility sizes the name and its tab wrap between words.
      // Two views split the width and broke the name mid-word.
      workspaceTitle(workspace)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
      Spacer(minLength: 4)
      let paneCount = workspace.tabs.reduce(into: 0) { $0 += $1.panes.count }
      Text("\(paneCount)")
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .accessibilityLabel("\(paneCount) pane\(paneCount == 1 ? "" : "s")")
      // Draws nothing. See `SessionPollHold`.
      if let session {
        SessionPollHold(session: session)
      }
    }
    .padding(.leading, indent)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("sidebar.workspace")
  }

  private func workspaceTitle(_ workspace: Workspace) -> Text {
    let name = Text(workspace.label).font(.subheadline.weight(.semibold))
    guard workspace.tabHeaderStyle == .inline, let tab = workspace.tabs.first else { return name }
    return Text("\(name) \(Text("· \(tab.label)").font(.subheadline).foregroundStyle(.secondary))")
  }

  private func tabLabel(_ tab: DriverrCore.Tab) -> some View {
    HStack(spacing: 6) {
      Text(tab.label)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .padding(.leading, indent)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("sidebar.tab")
  }
}

/// One pane in the sidebar: badge, title and the host screen's second line.
///
/// One element, so the badge's `status.*` identifier does not repeat beside the host
/// screen's on iPad, where both are on screen at once.
struct SidebarPaneRow: View {
  let pane: Pane
  let stop: AgentStop?

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    // Stale at the reset without a re-read, as on the host screen.
    let reset = stop?.resetsAt.map { [$0.addingTimeInterval(1)] } ?? []
    TimelineView(.explicit(reset)) { _ in
      let badge = PaneStopBadge(status: pane.agent?.status, stop: stop, asOf: Date())
      HStack(spacing: 8) {
        PaneBadge(pane: pane, stop: badge)
        VStack(alignment: .leading, spacing: 1) {
          Text(pane.title)
            .foregroundStyle(pane.agent == nil ? .secondary : .primary)
            // Two lines at the accessibility sizes, where one holds a word or two after
            // three levels of indent.
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
          if let subtitle = pane.rowSubtitle(stop: badge) {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
              // Two lines at the accessibility sizes too, or the head truncation that keeps a
              // directory's end drops the agent's name.
              .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
              .truncationMode(.head)
          }
        }
        // The column takes the rest of the row, so its frame is the room the title has.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { titleMeasurement }
      }
    }
    .accessibilityElement(children: .combine)
  }

  /// Where a hosted layout test reads the frame of the title's column: the room the title
  /// has, whatever its length. A `GeometryReader` in a background
  /// takes no part in layout, and nothing is installed when `nil`. See `ProvenanceRow`.
  var onTitleFrame: (@MainActor (CGRect) -> Void)?

  @ViewBuilder private var titleMeasurement: some View {
    if let onTitleFrame {
      GeometryReader { proxy in
        Color.clear.onAppear { onTitleFrame(proxy.frame(in: .global)) }
      }
    }
  }
}
