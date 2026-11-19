import DriverrCore
import SwiftUI

/// The tappable answers to a pending call, drawn by `PaneChatView.replyRow` under the turn
/// they answer. A chip answers this question, so it sits beside it, not in the composer.
/// The send path is `PaneComposerModel.send(_:)`.
///
/// Bordered with a solid tinted stroke and a semibold `Color.primary` label. A plain
/// `.bordered` chip read as disabled next to the filled Send, and a tinted label fell under
/// 4.5:1. **Not `.borderedProminent`:** a row of filled chips would out-shout the composer's
/// Send, which must stay the loudest control.
struct ReplyChipRow: View {
  @Environment(\.themeAccent) private var themeAccent
  /// The label colour on an accent fill. Only a chosen chip has one.
  @Environment(\.themeAccentForeground) private var themeAccentForeground

  /// One group per question the call asked. A single-question call has one unlabelled
  /// group.
  let groups: [ReplyChipGroup]
  /// What has been chosen so far. Owned by `PaneChatView`, so a choice survives a redraw.
  let selection: ReplyChipSelection
  let isSending: Bool
  let onTap: (ReplyChipGroup, ReplyChip) -> Void
  /// Presses Send on a call that needs one. The button is enabled only while
  /// `selection.isComplete`, and the value refuses an incomplete confirmation anyway.
  let onSend: () -> Void
  /// `.leading` under the turn it answers, `.center` under a centred notice
  /// (`PaneChatView.centred(_:answering:)`). Centred, each group's chips stay one block, with
  /// their rows flush left inside it, and the words above and under them are centred.
  var alignment: HorizontalAlignment = .leading

  /// A group whose options have descriptions stays leading even under a notice: centred, a
  /// list of chips with paragraphs under them reads as ragged, and the descriptions are what
  /// is read. The trust prompt's flow row has none and centres.
  private func alignment(for group: ReplyChipGroup) -> HorizontalAlignment {
    group.describesItsOptions ? .leading : alignment
  }

  var body: some View {
    // 16 between groups against 6 inside one, so a heading reads as belonging to the chips
    // below it.
    VStack(alignment: alignment, spacing: 16) {
      ForEach(groups) { group in
        let alignment = self.alignment(for: group)
        VStack(alignment: alignment, spacing: 6) {
          // The picker's tab label, the agent's only short name for the question.
          if let header = group.header {
            QuestionHeaderTag(header)
              .accessibilityIdentifier("pane.chat.turn.pending.header.\(group.id)")
          }
          // The question itself. The chat rests at this band's top while a question waits,
          // which scrolls the turn asking it off screen. The identifier is on the leaf.
          if let question = group.question {
            // Footnote, so it does not compete with the chips it labels. `Color.primary`, not
            // `.secondary`: that grey measured 2.66:1 here in light, under 4.5:1, the fix the
            // chat's notices took. The size keeps it below the chips.
            Text(question)
              .font(.footnote)
              .foregroundStyle(Color.primary)
              .multilineTextAlignment(alignment == .center ? .center : .leading)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("pane.chat.turn.pending.question.\(group.id)")
          }
          // Says a group takes several answers, until it has one; then the chips' glyphs say
          // it. `Color.primary` at caption size, for the question's reason: the secondary
          // grey failed contrast too.
          if group.allowsMultiple, !isAnswered(group) {
            Text(PaneComposerCopy.chooseAny)
              .font(.caption)
              .foregroundStyle(Color.primary)
              .accessibilityIdentifier("pane.chat.turn.pending.hint.\(group.id)")
          }
          // A list when options have descriptions, so each description sits under its chip.
          if group.describesItsOptions {
            VStack(alignment: alignment, spacing: 10) {
              ForEach(group.chips) { chip in
                VStack(alignment: alignment, spacing: 4) {
                  chipButton(chip, in: group)
                  // `Color.primary` for the question's reason. Codex's warnings, such as Full
                  // Access's "Use with caution", are in these lines.
                  if let detail = chip.detail {
                    Text(detail)
                      .font(.footnote)
                      .foregroundStyle(Color.primary)
                      .multilineTextAlignment(alignment == .center ? .center : .leading)
                      .fixedSize(horizontal: false, vertical: true)
                      .accessibilityIdentifier(
                        identifier(for: chip, in: group, kind: "detail"))
                  }
                }
              }
            }
          } else {
            // `AskUserQuestion` labels can be long, so the chips wrap rather than run off the
            // edge.
            FlowLayout(spacing: 8) {
              ForEach(group.chips) { chip in chipButton(chip, in: group) }
            }
          }
        }
        // A leading group under a centred row spans it, so it starts at the edge rather than
        // centring as a narrow block.
        .frame(maxWidth: alignment == self.alignment ? nil : .infinity, alignment: .leading)
      }
      // Shown from the start and disabled until every question has an answer, so the reader
      // knows a Send is coming. Absent when no question is multi-select, because that call
      // sends on the last answering tap. Removed once sent, because a disabled Send looks
      // the same before and after; the `Sent` line says the exchange is over.
      if selection.needsConfirmation, !selection.hasSent {
        sendButton
      }
    }
  }

  /// Whether this group has an answer yet, which retires the `Choose any` hint.
  private func isAnswered(_ group: ReplyChipGroup) -> Bool {
    group.chips.contains { selection.isChosen($0, in: group) }
  }

  /// The one control that sends a multi-select call. Filled, unlike the chips, because it
  /// is the one control on the band that ends the exchange.
  ///
  /// Full width, with the band's largest gap above it (the `VStack`'s 16 plus 8). As a
  /// left-aligned capsule it read as one more chip, or on iPad as an option that wrapped.
  ///
  /// **Its own style, not `.borderedProminent`.** A disabled `.borderedProminent` ignores
  /// `.tint` and paints a system grey that, in dark, out-weighed the unselected chips and,
  /// in light, nearly vanished under a label brighter than the headings. The style recolours
  /// under any outer modifier, so the colours are set here: a disabled fill no heavier than
  /// a chip and a disabled label no brighter than the headings. `Color.secondary`, not the
  /// `.secondary` shape style, for the reason in `chipButton(_:in:)`.
  private var sendButton: some View {
    // Unpressable only while incomplete or sending. After the send it is not drawn.
    let isSendable = selection.isComplete && !isSending
    return Button(action: onSend) { Text(PaneComposerCopy.send) }
      .buttonStyle(
        ReplySendButtonStyle(
          fill: isSendable ? themeAccent : Color(.quaternarySystemFill),
          foreground: isSendable ? themeAccentForeground : Color.secondary
        )
      )
      .disabled(!isSendable)
      .padding(.top, 8)
      .accessibilityIdentifier("pane.chat.turn.pending.send")
  }

  private func chipButton(_ chip: ReplyChip, in group: ReplyChipGroup) -> some View {
    let tint = self.tint(of: chip)
    let isChosen = selection.isChosen(chip, in: group)
    return Button {
      onTap(group, chip)
    } label: {
      // **Width only, on the label.** A bordered style sizes its chrome from the label, and a
      // frame applied after the style does not reach the accessibility frame XCUITest
      // reads. No height: 44 pt is a floor for a target, and `.controlSize(.large)` already
      // clears it. A 44 pt label inside the style's padding drew a 60 pt slab.
      //
      // `Color.primary`, not the tint and not the `.primary` shape style. A tinted label
      // falls under 4.5:1. `.primary` is a `HierarchicalShapeStyle` that blends with the
      // ambient foreground, which under `.bordered` is the tint. A chosen chip sits on an
      // accent fill and takes `\.themeAccentForeground` instead.
      //
      // Only a multi-select chip carries a glyph, the iOS pair for "choose several".
      // `.imageScale(.small)` keeps it within the line height, so the chip stays under the
      // 52 pt ceiling `AccessibilityUITests` asserts. Hidden, because `accessibilityValue`
      // already speaks the state.
      HStack(spacing: 6) {
        if group.allowsMultiple {
          Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
            .imageScale(.small)
            .accessibilityHidden(true)
        }
        Text(chip.label)
          .fontWeight(.semibold)
      }
      .foregroundStyle(isChosen ? themeAccentForeground : Color.primary)
      .frame(minWidth: 44)
    }
    .buttonStyle(.bordered)
    .controlSize(.large)
    .buttonBorderShape(.capsule)
    .tint(tint)
    // The stroke and the chosen fill are overlays, so they change no size and keep the
    // 52 pt ceiling. The shape must match `buttonBorderShape` or they disagree at the
    // corners.
    .background {
      if isChosen { Capsule().fill(tint) }
    }
    .overlay {
      Capsule().strokeBorder(tint, lineWidth: 1.5)
    }
    // Dimmed while sending, so the border does not signal a live control.
    .opacity(isSending ? 0.5 : 1)
    .disabled(isSending)
    // Inert once sent but drawn unchanged, so the answer stays legible under `Sent`.
    // `disabled` would dim it.
    .allowsHitTesting(!selection.hasSent)
    // Qualified by group only when there are several, because two questions may offer the
    // same word. One group keeps the unqualified identifier the tests use.
    .accessibilityIdentifier(identifier(for: chip, in: group))
    // Whether this chip is chosen. It does not say what a tap sends, because that depends
    // on the call.
    .accessibilityValue(isChosen ? "Chosen" : "")
  }

  /// `kind` is `chip` for the chip itself and `detail` for the description under it.
  private func identifier(
    for chip: ReplyChip, in group: ReplyChipGroup, kind: String = "chip"
  ) -> String {
    groups.count > 1
      ? "pane.chat.turn.pending.\(kind).\(group.id).\(chip.label)"
      : "pane.chat.turn.pending.\(kind).\(chip.label)"
  }

  /// Red for the chip that stops the agent, the accent for every other answer. The border
  /// takes the same tint as the fill.
  private func tint(of chip: ReplyChip) -> Color {
    chip.action == .key(.interrupt) ? .red : themeAccent
  }
}

/// An `AskUserQuestion` question's `header` as a small tag, over pending and answered
/// questions alike. The same shape as the `command` tag in `TranscriptTurnView`.
struct QuestionHeaderTag: View {
  let header: String

  init(_ header: String) {
    self.header = header
  }

  var body: some View {
    Text(header)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Color(.tertiarySystemFill), in: Capsule())
    // Not `.isHeader`. The headings rotor lists who spoke, and a one-word tag there would
    // be a stop that says nothing on its own.
  }
}

/// The Send under a multi-select call. See `ReplyChipRow.sendButton` for why it has its own
/// style.
///
/// Vertical padding, not a height: 15 pt each side matches `.controlSize(.large)` at the
/// default size, and at accessibility sizes the text sets the height. `.contentShape` makes
/// the whole capsule the target.
private struct ReplySendButtonStyle: ButtonStyle {
  let fill: Color
  let foreground: Color

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.body.weight(.semibold))
      .foregroundStyle(foreground)
      .padding(.vertical, 15)
      .frame(maxWidth: .infinity)
      .background(Capsule().fill(fill))
      .contentShape(Capsule())
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}

/// A left-aligned wrapping layout. `HStack` does not wrap, and the lazy grids use fixed
/// columns rather than content width.
struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  /// Which subviews go on which row, by index, for chips of `widths` within `limit`.
  ///
  /// One rule for measuring and placing, so the two cannot disagree. A chip that does not fit
  /// after another starts a new row, and an exact fit does not break. A chip wider than the
  /// limit gets a row of its own and overflows it, rather than leaving an empty row above.
  static func rows(of widths: [CGFloat], spacing: CGFloat, within limit: CGFloat) -> [[Int]] {
    var rows: [[Int]] = []
    var x: CGFloat = 0
    for (index, width) in widths.enumerated() {
      if rows.isEmpty || (x + width > limit && !rows[rows.count - 1].isEmpty) {
        rows.append([])
        x = 0
      }
      rows[rows.count - 1].append(index)
      x += width + spacing
    }
    return rows
  }

  /// Where each chip goes and how big the whole is, for chips measured by `measure`.
  struct Arrangement: Equatable {
    var frames: [CGRect]
    var proposals: [ProposedViewSize]
    var size: CGSize
  }

  /// Lays chips out within `limit`, by `rows(of:spacing:within:)`.
  ///
  /// A chip that fits is measured and placed at its own size. A chip wider than `limit` is
  /// offered `limit` as its width, so its label wraps inside the capsule. Overflowing its row
  /// instead reported a width past the offer, and a centred notice above the chips grew past
  /// the screen at accessibility text sizes. So the size reported never passes `limit`.
  static func arrange(
    count: Int, spacing: CGFloat, within limit: CGFloat,
    measure: (Int, ProposedViewSize) -> CGSize
  ) -> Arrangement {
    var proposals = Array(repeating: ProposedViewSize.unspecified, count: count)
    var sizes = (0..<count).map { measure($0, .unspecified) }
    for index in sizes.indices where sizes[index].width > limit {
      proposals[index] = ProposedViewSize(width: limit, height: nil)
      sizes[index] = measure(index, proposals[index])
    }
    let rows = rows(of: sizes.map(\.width), spacing: spacing, within: limit)
    var frames = Array(repeating: CGRect.zero, count: count)
    var y: CGFloat = 0
    var width: CGFloat = 0
    for row in rows {
      var x: CGFloat = 0
      for index in row {
        frames[index] = CGRect(origin: CGPoint(x: x, y: y), size: sizes[index])
        x += sizes[index].width + spacing
      }
      width = max(width, x - spacing)
      y += (row.map { sizes[$0].height }.max() ?? 0) + spacing
    }
    return Arrangement(
      frames: frames, proposals: proposals,
      size: CGSize(width: min(width, limit), height: rows.isEmpty ? 0 : y - spacing))
  }

  func sizeThatFits(
    proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) -> CGSize {
    Self.arrange(
      count: subviews.count, spacing: spacing, within: proposal.width ?? .infinity,
      measure: { subviews[$0].sizeThatFits($1) }
    ).size
  }

  /// Rows break against the proposed width, as in `sizeThatFits`, not against the bounds.
  /// The bounds are the reported width, the widest row, and a row that exactly fills it can
  /// measure a hair over it after rounding, which once wrapped the last chip of a centred
  /// block onto a row of its own.
  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let arrangement = Self.arrange(
      count: subviews.count, spacing: spacing, within: proposal.width ?? .infinity,
      measure: { subviews[$0].sizeThatFits($1) })
    for (index, frame) in arrangement.frames.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        proposal: arrangement.proposals[index])
    }
  }
}
