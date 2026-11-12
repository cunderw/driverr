import DriverrCore
import SwiftUI

/// The pane's session's active sub-agents, in a sheet the bar's sub-agents button opens: the
/// running ones and the freshly idle (`SubagentList.activeRows(merging:asOf:)`). A row opens
/// that sub-agent's chat, as its spawn line does. A finished one is reached from its spawn line.
///
/// The rows come from the session's meta files (`PaneTranscriptModel.subagentList`), so an
/// agent whose spawn line is far up the session is listed. Presented by
/// `TerminalSceneSheets`, because the detail column must not present (CLAUDE.md).
///
/// **The last one ending leaves the sheet open**, on `noSubagentsRunning` with Done, rather
/// than dismissing it under the user's finger. The bar's button goes on its own tick.
///
/// Everything arrives as an argument, so nothing here reads an environment the sheet does not
/// inherit.
struct SubagentSheetView: View {
  let list: SubagentList
  /// The page, so a row whose spawn line is on it takes that line's state.
  let turns: [TranscriptTurn]
  /// Whether the scene is in the iPad's detail column, where a form sheet takes no detents.
  /// See `PaneSheetView.isRegularWidth`.
  var isRegularWidth = false
  let onOpen: (SubagentRow) -> Void
  let onDone: () -> Void

  /// The row and title labels' tick, `PaneChatView.ageTick`'s value.
  private static let tick: TimeInterval = 30

  @ViewBuilder
  var body: some View {
    if isRegularWidth {
      sheet
    } else {
      // Half height on the phone, so the chat the list is about stays in view.
      sheet
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
  }

  private var sheet: some View {
    NavigationStack {
      TimelineView(.periodic(from: .now, by: Self.tick)) { context in
        let rows = list.activeRows(merging: turns, asOf: context.date)
        let running = rows.filter { $0.state == .running }.count
        Group {
          if rows.isEmpty {
            ContentUnavailableView(
              TranscriptChatCopy.noSubagentsRunning, systemImage: "person.2",
              description: Text(TranscriptChatCopy.finishedSubagentsStayInChat))
          } else {
            List {
              ForEach(rows) { row in
                rowButton(row, asOf: context.date)
              }
            }
          }
        }
        .navigationTitle(
          TranscriptChatCopy.subagentActiveTitle(running: running, idle: rows.count - running))
        .navigationBarTitleDisplayMode(.inline)
      }
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: onDone)
            // Toolbar text takes `Color.primary`. See CLAUDE.md, Style.
            .tint(Color.primary)
            .accessibilityIdentifier("pane.subagents.done")
        }
      }
    }
    // The provenance row's cap: a row is two lines with a status beside them.
    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
  }

  private func rowButton(_ row: SubagentRow, asOf now: Date) -> some View {
    Button {
      onOpen(row)
    } label: {
      HStack(alignment: .center, spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(row.summary.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.primary)
            .lineLimit(1)
            .truncationMode(.middle)
          if let description = row.summary.description, description != row.summary.title {
            Text(description)
              .font(.footnote)
              .foregroundStyle(Color.secondary)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 8)
        // The spawn line's styling (`TranscriptTurnView.taskText`), so one state reads the
        // same in both places.
        Text(row.statusLine(asOf: now))
          .font(.caption.weight(row.state == .running ? .semibold : .regular).monospacedDigit())
          .foregroundStyle(Self.statusColor(row.state))
          .lineLimit(1)
          .layoutPriority(1)
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(Color.secondary)
          .accessibilityHidden(true)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(row.accessibilityLabel(asOf: now))
    .accessibilityHint(TranscriptChatCopy.opensSubagent)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("pane.chat.subagents.row")
  }

  private static func statusColor(_ state: TaskProgress.State?) -> Color {
    switch state {
    case .running: Color.primary
    case .failed: Color.red
    default: Color.secondary
    }
  }
}
