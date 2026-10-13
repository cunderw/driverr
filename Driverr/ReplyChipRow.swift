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

  var body: some View {
    // 16 between groups against 6 inside one, so a heading reads as belonging to the chips
    // below it.
    VStack(alignment: .leading, spacing: 16) {
      ForEach(groups) { group in
        VStack(alignment: .leading, spacing: 6) {
          // The picker's tab label, the agent's only short name for the question.
          if let header = group.header {
            QuestionHeaderTag(header)
              .accessibilityIdentifier("pane.chat.turn.pending.header.\(group.id)")
          }
          // The question itself. The chat rests at this band's top while a question waits,
          // which scrolls the turn asking it off screen. The identifier is on the leaf.
          if let question = group.question {
            // Footnote, so it does not compete with the chips it labels.
            Text(question)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("pane.chat.turn.pending.question.\(group.id)")
          }
          // Says a group takes several answers, until it has one; then the chips' glyphs say
          // it. Secondary at caption size: tertiary failed contrast.
          if group.allowsMultiple, !isAnswered(group) {
            Text(PaneComposerCopy.chooseAny)
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("pane.chat.turn.pending.hint.\(group.id)")
          }
          // A list when options have descriptions, so each description sits under its chip.
          if group.describesItsOptions {
            VStack(alignment: .leading, spacing: 10) {
              ForEach(group.chips) { chip in
                VStack(alignment: .leading, spacing: 4) {
                  chipButton(chip, in: group)
                  if let detail = chip.detail {
                    Text(detail)
                      .font(.footnote)
                      .foregroundStyle(.secondary)
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
private struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(
    proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) -> CGSize {
    let width = proposal.width ?? .infinity
    var origin = CGPoint.zero
    var rowHeight: CGFloat = 0
    var maxWidth: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if origin.x + size.width > width, origin.x > 0 {
        origin.x = 0
        origin.y += rowHeight + spacing
        rowHeight = 0
      }
      origin.x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
      maxWidth = max(maxWidth, origin.x - spacing)
    }
    return CGSize(width: maxWidth, height: origin.y + rowHeight)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var origin = bounds.origin
    var rowHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if origin.x + size.width > bounds.maxX, origin.x > bounds.minX {
        origin.x = bounds.minX
        origin.y += rowHeight + spacing
        rowHeight = 0
      }
      subview.place(at: origin, proposal: .unspecified)
      origin.x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}
