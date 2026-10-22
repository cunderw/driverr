import DriverrCore
import SwiftUI

/// The pane chat's list of every sub-agent its session spawned, under the provenance row.
///
/// **Inline, not a sheet**, for the reason `AgentStopRow` is: the chat is inside the pane
/// scene's presentation. Collapsed it is one row, `3 sub-agents · 1 running`; a tap opens the
/// rows under it. A row opens that sub-agent's chat, as its spawn line does.
///
/// The rows come from the session's meta files (`PaneTranscriptModel.subagentList`), so an
/// agent whose spawn line is far up the session is listed. Hidden when there are none, and
/// never drawn over a sub-agent's own chat, which has the back bar in this place.
///
/// **The open list is capped at `maxListHeight`** and scrolls inside that, because a session
/// has been seen with hundreds of sub-agents and the chat under it must keep its room.
struct SubagentListBar: View {
  let list: SubagentList
  /// The page, so a row whose spawn line is on it takes that line's state.
  let turns: [TranscriptTurn]
  @Binding var isExpanded: Bool
  var horizontalInset: CGFloat = ChatColumn.inset
  let onOpen: (SubagentRow) -> Void

  /// Where a hosted layout test reads the header's and the open list's frames. Nothing is
  /// installed when nobody is measuring, as with `ProvenanceRow.onCaptionFrame`.
  var onHeaderFrame: (@MainActor (CGRect) -> Void)?
  var onListFrame: (@MainActor (CGRect) -> Void)?

  @Environment(\.themeAccent) private var accent

  /// About four and a half rows at the default size, so a fifth row shows it scrolls.
  @ScaledMetric(relativeTo: .footnote) private var maxListHeight: CGFloat = 232
  /// The rows' own height, so a short list is drawn at its size and a long one at the cap.
  @State private var rowsHeight: CGFloat = 0

  /// The row and time labels' tick, `PaneChatView.ageTick`'s value.
  private static let tick: TimeInterval = 30

  var body: some View {
    TimelineView(.periodic(from: .now, by: Self.tick)) { context in
      let rows = list.rows(merging: turns, asOf: context.date)
      VStack(alignment: .leading, spacing: 0) {
        header(rows: rows)
        if isExpanded {
          Divider()
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.leading, 12) }
                rowButton(row, asOf: context.date)
              }
              if list.total > rows.count {
                Text(TranscriptChatCopy.subagentListCapped(shown: rows.count, of: list.total))
                  .font(.caption)
                  .foregroundStyle(Color.secondary)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 8)
                  .accessibilityIdentifier("pane.chat.subagents.capped")
              }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { rowsHeight = $0 }
          }
          .scrollBounceBehavior(.basedOnSize)
          // Bounded: the rows' height does not depend on this frame, so the two cannot chase.
          .frame(height: min(rowsHeight, maxListHeight))
          .background(measurement(onListFrame))
        }
      }
      .background(
        Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    // The provenance row's cap: a row is two lines with a status beside them.
    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    .padding(.horizontal, horizontalInset)
    .padding(.top, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func header(rows: [SubagentRow]) -> some View {
    let running = rows.filter { $0.state == .running }.count
    let title = TranscriptChatCopy.subagentCount(total: list.total, running: running)
    return Button {
      isExpanded.toggle()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "person.2")
          .foregroundStyle(accent)
          .accessibilityHidden(true)
        Text(title)
          .font(.footnote.weight(.semibold))
          .foregroundStyle(Color.primary)
          .lineLimit(1)
        Spacer(minLength: 0)
        Image(systemName: "chevron.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(accent)
          .rotationEffect(.degrees(isExpanded ? 180 : 0))
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    .accessibilityHint(TranscriptChatCopy.subagentListHint)
    .accessibilityIdentifier("pane.chat.subagents")
    .background(measurement(onHeaderFrame))
  }

  private func rowButton(_ row: SubagentRow, asOf now: Date) -> some View {
    Button {
      onOpen(row)
    } label: {
      HStack(alignment: .center, spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(row.summary.title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.primary)
            .lineLimit(1)
            .truncationMode(.middle)
          if let description = row.summary.description, description != row.summary.title {
            Text(description)
              .font(.caption)
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
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
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

  /// Reports every change, not only the first frame, because the open list settles its
  /// height a pass after it appears.
  @ViewBuilder
  private func measurement(_ report: (@MainActor (CGRect) -> Void)?) -> some View {
    if let report {
      Color.clear.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { report($0) }
    }
  }
}
