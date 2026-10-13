import DriverrCore
import SwiftUI
import UIKit

/// An assistant turn's markdown, drawn. The view half of `TranscriptMarkdown.blocks(from:)`.
///
/// **A stack of blocks, not one styled `AttributedString`.** An attributed string cannot
/// scroll a code block sideways or give each diff line its own background, so code wrapped
/// mid-token and patches wrapped into walls of `+` and `-`.
///
/// What the markdown is (the split, the diff parse, the line budget) is decided in
/// `DriverrCore` and tested there. This file decides only how each block looks.
///
/// Semantic colours, never a hex. The chat is app chrome, not the themed terminal, so
/// system green, red and fills work in light and dark.
struct TranscriptMarkdownView: View {
  /// The turn's blocks and inline strings, parsed when the page settled, so this body
  /// parses nothing. `TranscriptTurnRender`'s fallbacks let a preview draw.
  let render: TranscriptTurnRender
  /// One line allowance per block, or `nil` to draw every block whole. A block allowed no
  /// lines is not drawn; see `TranscriptMarkdown.allowances(forLineCounts:budget:)`.
  var allowances: [Int]?
  /// The width the turn is drawn at, so code and diff rows reach the card's edge. `0`
  /// before the first layout, which draws ragged for one frame.
  var contentWidth: CGFloat = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(render.blocks.enumerated()), id: \.offset) { index, block in
        let allowance = allowances.map { index < $0.count ? $0[index] : 0 }
        if (allowance ?? 1) > 0 {
          view(for: block, lineLimit: allowance)
            // Extra space above a heading, except the first block, where the card's top
            // inset already opens the gap.
            .padding(.top, block.isHeading && index > 0 ? 6 : 0)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func view(for block: TranscriptMarkdown.Block, lineLimit: Int?) -> some View {
    switch block {
    case .paragraph(let raw):
      Text(render.inline(raw))
        .font(.body)
        .lineLimit(lineLimit)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .heading(let title, let level):
      Text(render.inline(title))
        .font(Self.headingFont(level: level))
        .lineLimit(lineLimit)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .list(let items, let isOrdered):
      listView(items, isOrdered: isOrdered, lineLimit: lineLimit)
    case .code(let code, _):
      TranscriptCodeBlock(code: code, lineLimit: lineLimit, contentWidth: contentWidth)
    case .diff(let diff):
      TranscriptDiffCard(diff: diff, lineLimit: lineLimit, contentWidth: contentWidth)
    }
  }

  /// A list, as rows of marker plus text.
  ///
  /// **Not `Text("• " + item)`**, whose wrapped lines run back under the marker. The marker's
  /// own column hangs the indent.
  @ViewBuilder
  private func listView(
    _ items: [TranscriptMarkdown.ListItem], isOrdered: Bool, lineLimit: Int?
  ) -> some View {
    let shown = lineLimit.map { Array(items.prefix($0)) } ?? items
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          // Drawn from `item.number`, not `isOrdered`: a nested bullet inside an ordered run
          // has no number and gets a bullet, not another "1.".
          Text(item.number.map { "\($0)." } ?? "•")
            .font(.body)
            .foregroundStyle(.secondary)
            // A fixed column, so every item's text lines up, two-digit numbers included.
            .frame(minWidth: 18, alignment: .trailing)
          Text(render.inline(item.text))
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(min(item.depth, 4)) * 16)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private static func headingFont(level: Int) -> Font {
    switch level {
    case 1: .title3.weight(.bold)
    case 2: .headline
    default: .subheadline.weight(.semibold)
    }
  }
}

// MARK: - A fenced code block

/// A fenced block, monospaced and **scrolling sideways rather than wrapping**. Wrapping
/// breaks identifiers and indentation, shrinking fails at accessibility sizes, and clipping
/// loses line ends.
private struct TranscriptCodeBlock: View {
  let code: String
  let lineLimit: Int?
  let contentWidth: CGFloat

  var body: some View {
    ScrollView(.horizontal) {
      Text(code)
        .font(.system(.caption, design: .monospaced))
        .lineLimit(lineLimit)
        .textSelection(.enabled)
        // Ideal width, so nothing wraps. Vertical is left free so `lineLimit` can cut.
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // At least the card's width, so short lines sit on a full block.
        .frame(minWidth: contentWidth, alignment: .leading)
    }
    // A block narrower than the card does not bounce.
    .scrollBounceBehavior(.basedOnSize)
    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

// MARK: - A unified diff

/// A unified diff, drawn as one.
///
/// **The stripes are a layer behind the scrolling text**, so they stay full width. A
/// background on each row would end with its characters. Both stacks draw one fixed-height
/// row per line from the same array, so they stay aligned.
///
/// Colour is never the only signal. Each changed line keeps its `+` or `−` in a gutter,
/// and the card speaks as one sentence (`TranscriptDiff.accessibilityLabel`).
private struct TranscriptDiffCard: View {
  let diff: TranscriptDiff
  let lineLimit: Int?
  let contentWidth: CGFloat

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    let lines = shownLines
    VStack(alignment: .leading, spacing: 0) {
      header
      ZStack(alignment: .topLeading) {
        VStack(spacing: 0) {
          ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            stripe(for: line)
              .frame(height: rowHeight)
              .frame(maxWidth: .infinity)
          }
        }
        ScrollView(.horizontal) {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
              row(for: line)
            }
          }
        }
        .scrollBounceBehavior(.basedOnSize)
      }
    }
    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(diff.accessibilityLabel)
  }

  /// The file the patch is about, and how much changed.
  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: "plusminus")
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(diff.filePath ?? TranscriptChatCopy.diffWithNoFile)
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        // A path's head and tail identify it.
        .truncationMode(.middle)
      Spacer(minLength: 0)
      Text(diff.changeSummary)
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.quaternarySystemFill))
  }

  private var shownLines: [TranscriptDiff.Line] {
    guard let lineLimit else { return diff.body }
    // One line of the budget is the header, which is always drawn.
    return Array(diff.body.prefix(max(0, lineLimit - 1)))
  }

  @ViewBuilder
  private func stripe(for line: TranscriptDiff.Line) -> some View {
    switch line {
    case .addition: Color.green.opacity(0.18)
    case .removal: Color.red.opacity(0.18)
    case .hunk: Color(.quaternarySystemFill)
    case .context, .meta: Color.clear
    }
  }

  private func row(for line: TranscriptDiff.Line) -> some View {
    HStack(spacing: 0) {
      Text(marker(for: line))
        .font(font)
        .foregroundStyle(markerTint(for: line))
        .frame(width: markerWidth, alignment: .center)
      Text(line.text)
        .font(font)
        .foregroundStyle(textTint(for: line))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .textSelection(.enabled)
      // **No `Spacer`.** In a horizontal scroll it would make the row infinitely wide. The
      // frame below left-aligns a short row.
    }
    .padding(.trailing, 10)
    .frame(height: rowHeight)
    .frame(minWidth: contentWidth, alignment: .leading)
  }

  private func marker(for line: TranscriptDiff.Line) -> String {
    switch line {
    case .addition: "+"
    case .removal: "−"
    case .hunk, .meta, .context: " "
    }
  }

  private func markerTint(for line: TranscriptDiff.Line) -> Color {
    // `.secondary` for every case. The stripe carries the colour and the glyph the shape;
    // a green `+` on the green stripe failed contrast.
    .secondary
  }

  private func textTint(for line: TranscriptDiff.Line) -> Color {
    switch line {
    // Full-strength ink, because green text on a green stripe fails contrast.
    case .addition, .removal, .context: .primary
    case .hunk, .meta: .secondary
    }
  }

  private var font: Font { .system(.caption, design: .monospaced) }

  /// A square gutter, so every line's text starts at the same x at any text size.
  private var markerWidth: CGFloat { rowHeight }

  /// One row's height, from the rows' font, so it grows with text size. Both stacks in
  /// `body` use it, or the stripes drift from their lines. Reading `dynamicTypeSize`
  /// recomputes it when the size changes.
  private var rowHeight: CGFloat {
    _ = dynamicTypeSize
    return (UIFont.preferredFont(forTextStyle: .caption1).lineHeight + 4).rounded()
  }
}
