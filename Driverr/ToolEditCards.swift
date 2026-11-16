import DriverrCore
import SwiftUI

/// One diff card for each `Edit`, `MultiEdit` and `Write` call in a run of tool calls, drawn
/// under the run's row.
///
/// **Drawn whether the run is open or closed**, by the owner's choice. A file edit is the
/// most reviewable thing an agent does, and the run's rows name only its newest calls. A
/// pending edit's card is what its permission prompt is asking about.
///
/// What each card says (the lines, the collapse, the cap) is `FileEdit`, tested in
/// `DriverrCore`. This view decides only how it looks.
struct ToolEditCards: View {
  @Environment(\.themeAccent) private var themeAccent

  let run: ToolRun
  /// The run's turn id, for the identifiers.
  let runID: String
  let contentWidth: CGFloat
  /// The pane's working directory, which each card's path is shown relative to.
  let paneDirectory: String?
  /// Whether the card for the call at this position in the run is expanded.
  let isExpanded: (Int) -> Bool
  let onToggle: (Int) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // By position in the whole run, which does not change as the run grows.
      ForEach(run.calls.indices.filter { run.calls[$0].edit != nil }, id: \.self) { index in
        if let edit = run.calls[index].edit {
          card(edit, index: index)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func card(_ edit: FileEdit, index: Int) -> some View {
    let expanded = isExpanded(index)
    let shown = edit.shownLines(isExpanded: expanded)
    let hidden = edit.hiddenLineCount(isExpanded: expanded)
    let identifier = "pane.chat.turn.tools.\(runID).edit.\(index)"
    VStack(alignment: .leading, spacing: 0) {
      // The identifier on the card itself, which is one element with its children ignored.
      // The button below is a sibling, so neither overwrites the other's.
      TranscriptDiffCard(
        diff: edit.diff,
        lineLimit: nil,
        contentWidth: contentWidth,
        lines: shown,
        spokenValue: hidden > 0
          ? TranscriptChatCopy.editLinesShown(shown.count, of: edit.diff.lines.count) : "",
        shownPath: FileEdit.displayPath(edit.filePath, paneDirectory: paneDirectory)
      )
      .accessibilityIdentifier(identifier)

      // Only an expanded card can still be cut, by `FileEdit.expandedLineCap`.
      if expanded, hidden > 0 {
        Text(TranscriptChatCopy.editLinesNotShown(hidden))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .padding(.top, 4)
      }

      if edit.isCollapsible {
        // Styled as a turn's own `Show All`, so the two read as one control.
        Button(expanded ? TranscriptChatCopy.showLess : TranscriptChatCopy.showAll) {
          onToggle(index)
        }
        .font(.caption)
        .buttonStyle(.plain)
        .foregroundStyle(themeAccent)
        // A 44 pt target on a caption-sized label.
        .frame(minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityIdentifier("\(identifier).expand")
      }
    }
  }
}
