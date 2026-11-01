import DriverrCore
import DriverrHerdr
import DriverrTerm
import Foundation
import SwiftUI
import UIKit

/// The pane's captured screen, drawn as a screen.
///
/// A floor, not an error state. It needs nothing installed, works for every agent kind,
/// and is the permanent Chat side for agents without a transcript. It claims nothing the
/// captured screen does not show.
///
/// **Terminal output in the terminal theme, never in bubbles.** A bubble asserts speaker,
/// order and boundary, and a screen proves none of them. Composer text carries the same `❯`
/// as a sent turn, so a bubble could show an unsent message as sent. `PaneScreenParser`
/// marks only the last `⏺` block, drawn as emphasis and a label. An unmarked screen gets
/// no placeholder.
///
/// The copy and layout rules come from `DriverrCore` (`PaneScreenCaption`,
/// `PaneScreenCopy`, `PaneScreenLayout`) and are tested there.
struct PaneScreenView: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.settingsModel) private var settingsModel
  @Environment(\.themeAccent) private var themeAccent

  let model: PaneScreenModel
  /// The agent's own name, so a marked message does not call a Codex agent Claude.
  let agentName: String

  private var settings: TerminalSettings { settingsModel.settings }

  /// Wrapped or clipped. A global setting with no per-screen override, because a control on
  /// every pane cost more space than a choice made once is worth.
  private var layout: PaneScreenLayout { settings.screenLayout }
  private var appearance: ThemeAppearance { colorScheme == .dark ? .dark : .light }
  private var palette: TerminalPalette { settings.theme.palette(for: appearance) }

  var body: some View {
    VStack(spacing: 0) {
      switch model.state {
      case .idle, .loading:
        reading
      case .ready(let screen):
        if screen.isEmpty {
          // A blank capture offers a retry, because this surface only shows live panes and
          // a live pane's screen can change.
          notice(
            title: PaneScreenCopy.blankTitle,
            message: PaneScreenCopy.blankMessage,
            offersRetry: true
          )
        } else {
          captured(screen)
        }
      case .failed(let error):
        notice(
          title: PaneScreenCopy.refusalTitle,
          message: error.errorDescription ?? PaneScreenCopy.refusalTitle,
          offersRetry: true
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // Re-read on every appearance, unlike the transcript. See `PaneScreenModel.refresh()`.
    // Keyed on the pane because a pane switch hands this view a different model in the same
    // place, and a bare `.task` does not re-run for that.
    .task(id: model.pane.id) { model.refresh() }
  }

  // MARK: - A screen

  /// The width this surface was last laid out at, read by `onGeometryChange` below the
  /// frame, so it describes the slot and not the content.
  ///
  /// **Do not replace this with a `GeometryReader` around the screen.** Laying out the rows
  /// inside a `GeometryReader`'s body stopped converging on the second build of this
  /// surface (a switch to Terminal and back), and the main thread never went idle again.
  /// Report one axis, then compute from the stored value, so nothing feeds back into the
  /// geometry that produced it.
  ///
  /// Zero until the first pass. `fittingColumns(in:)` returns `nil` for zero, which draws
  /// one unwrapped frame until the real width arrives.
  @State private var measuredWidth: CGFloat = 0

  @ViewBuilder
  private func captured(_ screen: PaneScreen) -> some View {
    caption(screen)
    // Clipped scrolls sideways rather than truncating, so each row stays one-to-one with
    // the pane's line and its end is still reachable.
    let axes: Axis.Set = layout == .wrapped ? .vertical : [.vertical, .horizontal]
    let columns = layout == .wrapped ? fittingColumns(in: measuredWidth) : nil
    let rows = screen.rows(wrappedTo: columns)
    let markerLabel = screen.agentMessageLabel(agentName: agentName)
    // Hoisted out of the row loop. `continuationInset` builds a `UIFont` and measures a
    // string, and a wrapped iPad screen can have hundreds of rows.
    let inset = continuationInset
    ScrollView(axes) {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(rows) { row in
          if let markerLabel, isFirstMarkedRow(row, in: screen) {
            marker(markerLabel)
          }
          line(row, continuationInset: inset)
        }
      }
      .padding(.horizontal, Self.gutter)
      .padding(.vertical, 10)
      .frame(minWidth: measuredWidth, alignment: .leading)
    }
    // Opens at the bottom, where the newest output and the agent's latest message are.
    // `.bottomLeading` when clipped, because `.bottom` is (0.5, 1) and would open in the
    // middle of the widest line.
    .defaultScrollAnchor(layout == .wrapped ? .bottom : .bottomLeading)
    // A vertical-only `ScrollView` takes its content's width, and the surface must fill the
    // slot for the border and fill to land on the right rectangle.
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // Below the frame, so it reads the slot and not the rows derived from it. Above the
    // frame it would feed back into itself.
    .onGeometryChange(for: CGFloat.self, of: \.size.width) { measuredWidth = $0 }
    // On the scroll view, not the stack: a container's identifier overwrites its children's.
    .accessibilityIdentifier("pane.screen")
    .background(settings.theme.surfaceColor(for: appearance))
    // In light appearance the default theme's background matches the chat page. A border
    // marks the surface under every theme.
    .overlay {
      RoundedRectangle(cornerRadius: 0)
        .strokeBorder(Color(.separator), lineWidth: 1)
    }
  }

  /// One drawn row: a screen line, or the hanging tail of a wrapped one. The inset is
  /// passed in; see `captured(_:)`.
  @ViewBuilder
  private func line(_ row: PaneScreenRow, continuationInset: CGFloat) -> some View {
    HStack(alignment: .top, spacing: Self.ruleSpacing) {
      // A rule beside marked rows, and nothing beside unmarked ones.
      Rectangle()
        .fill(row.marker == nil ? Color.clear : themeAccent)
        .frame(width: Self.ruleWidth)
        .accessibilityHidden(true)
      // An empty `Text` has no height, so a blank row gets a space to keep the grid.
      Text(row.spans.isEmpty ? AttributedString(" ") : styled(row))
        .font(terminalFont)
        // Already laid out to fit. A second wrap would undo the hanging indent and add an
        // ellipsis.
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        // Not selectable. `.textSelection(.enabled)` writes selection state while the rows
        // are built, which logs "Modifying state during view update".
        .padding(.leading, row.isContinuation ? continuationInset : 0)
      // The line was cut at `PaneScreen.maximumLineLength`, which differs from wrapping.
      // A symbol, not an ellipsis, so it cannot be mistaken for pane output.
      if row.isTruncated {
        Image(systemName: "scissors")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .accessibilityLabel("This line was cut at \(PaneScreen.maximumLineLength) characters")
      }
      Spacer(minLength: 0)
    }
    .background(row.marker == nil ? Color.clear : themeAccent.opacity(0.10))
    .accessibilityElement(children: .combine)
  }

  /// The label over a marked block, drawn only where `PaneScreenParser` named a message.
  private func marker(_ label: String) -> some View {
    Text(label)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(themeAccent)
      .padding(.leading, 6)
      .padding(.top, 8)
      .padding(.bottom, 2)
      .accessibilityIdentifier("pane.screen.marker")
  }

  private func isFirstMarkedRow(_ row: PaneScreenRow, in screen: PaneScreen) -> Bool {
    guard let range = screen.agentMessage else { return false }
    return row.line == range.lowerBound && !row.isContinuation
  }

  // MARK: - What the screen is

  /// The one sentence that says this is a screen, not a conversation. No material band and
  /// no divider: one line does not earn one.
  ///
  /// The leading inset is 18, not the app's usual 16, so the sentence starts on the rows'
  /// first character column (`gutter` + `ruleWidth` + `ruleSpacing`).
  private func caption(_ screen: PaneScreen) -> some View {
    let caption = PaneScreenCaption(
      screen: screen, earlierOutputIsKept: CorePaneID.isCore(model.pane.id))
    return HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(caption.lines)
        .font(.caption2)
        .foregroundStyle(.secondary)
        // One element, so the identifier does not overwrite any child's.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption.accessibilityLabel)
        .accessibilityIdentifier("pane.screen.caption")
      Spacer(minLength: 0)
      // The only sign of a re-read, because the surface stays drawn during one.
      if model.isRereading {
        ProgressView()
          .controlSize(.mini)
          .accessibilityHidden(true)
      }
    }
    .padding(.leading, Self.gutter + Self.ruleWidth + Self.ruleSpacing)
    .padding(.trailing, 16)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Everything that is not a screen

  private var reading: some View {
    // Always resolves, because the model owns the read. See `PaneScreenModel.currentLoad`.
    ProgressView(PaneScreenCopy.reading)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(.systemBackground))
      .accessibilityIdentifier("pane.screen.progress")
  }

  /// No identifier on this stack, because it would overwrite the children's. System colours,
  /// not the terminal theme: this is app chrome, and `.primary` on a dark theme in light
  /// appearance would be black on near-black.
  private func notice(title: String, message: String, offersRetry: Bool = false) -> some View {
    VStack(spacing: 8) {
      Spacer(minLength: 0)
      Text(title)
        .font(.headline)
        .multilineTextAlignment(.center)
      Text(message)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .accessibilityIdentifier("pane.screen.notice")
      if offersRetry {
        Button { model.reload() } label: {
          BorderedButtonLabel(PaneScreenCopy.retry)
        }
          .buttonStyle(.bordered)
          .padding(.top, 4)
          .accessibilityIdentifier("pane.screen.retry")
      }
      Spacer(minLength: 0)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
  }

  // MARK: - Drawing terminal output in a Text

  /// The horizontal inset either side of the rows. The column count is measured against the
  /// width left after it.
  private static let gutter: CGFloat = 12
  /// The marker rule beside every row, and the space after it. Also subtracted before the
  /// column count.
  private static let ruleWidth: CGFloat = 2
  private static let ruleSpacing: CGFloat = 4

  /// The terminal's face and size, fixed rather than Dynamic Type, because scaling would
  /// break the column arithmetic and the pane's grid.
  private var terminalFont: Font {
    if let name = settings.font.systemFontName {
      return .custom(name, fixedSize: settings.fontSize)
    }
    return .system(size: settings.fontSize, design: .monospaced)
  }

  /// One character's width in the terminal face. Every `TerminalFont` is monospaced.
  private var advance: CGFloat {
    let font: UIFont =
      settings.font.systemFontName.flatMap { UIFont(name: $0, size: settings.fontSize) }
      ?? .monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
    return ("0" as NSString).size(withAttributes: [.font: font]).width
  }

  private var continuationInset: CGFloat { advance * CGFloat(PaneScreen.continuationIndent) }

  /// How many columns fit across, or `nil` when the width is not known yet. One column of
  /// slack, because a font metric and the rendered layout can disagree by one.
  private func fittingColumns(in width: CGFloat) -> Int? {
    guard advance > 0, width > 0 else { return nil }
    // The gutter each side, plus the rule and the space beside it that every row carries.
    let usable = width - (Self.gutter * 2) - (Self.ruleWidth + Self.ruleSpacing)
    return max(8, Int(usable / advance) - 1)
  }

  /// A row's spans as one attributed string, in the theme's terminal palette.
  /// `PaneScreenParser` drops any colour outside the sixteen named slots.
  private func styled(_ row: PaneScreenRow) -> AttributedString {
    var text = AttributedString()
    for span in row.spans {
      // ⏺ as text, not as Apple Color Emoji. Done here, not in `PaneScreen.sanitised`,
      // whose parser matches "⏺" as a `Character`.
      var piece = AttributedString(span.text.withTextPresentation)
      let rawForeground = rawColour(span.style.foreground) ?? palette.foreground
      // Dim in the theme's RGB space, clamped to 4.5:1 against the background. An opacity
      // dim fails contrast on a light theme.
      let foreground =
        span.style.isDim
        ? rawForeground.dimmed(against: palette.background).swiftUIColor
        : rawForeground.swiftUIColor
      // Attribute types, not the shorthand setters: this file imports UIKit and SwiftUI,
      // and `foregroundColor` names an attribute in both scopes.
      piece[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = foreground
      if let background = colour(span.style.background) {
        piece[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = background
      }
      var intent: InlinePresentationIntent = []
      if span.style.isBold { intent.insert(.stronglyEmphasized) }
      if span.style.isItalic { intent.insert(.emphasized) }
      if !intent.isEmpty {
        piece[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self] =
          intent
      }
      text.append(piece)
    }
    return text
  }

  private func colour(_ colour: PaneScreenColor?) -> Color? {
    rawColour(colour)?.swiftUIColor
  }

  /// The raw `TerminalColor` behind a span's ANSI slot, for `dimmed(against:)`, which works
  /// before conversion to `SwiftUI.Color`.
  private func rawColour(_ colour: PaneScreenColor?) -> TerminalColor? {
    guard let colour, let index = PaneScreenColor.allCases.firstIndex(of: colour) else {
      return nil
    }
    return palette.ansi[index]
  }
}

#if DEBUG

  /// A Claude Code screen with the agent's latest message marked.
  #Preview("Pane screen") {
    PaneScreenView(model: PreviewSupport.paneScreen(), agentName: "Claude")
  }

  /// A shell pane's screen with no marker, drawn as plain output.
  #Preview("Pane screen — nothing marked") {
    PaneScreenView(
      model: PreviewSupport.paneScreen(for: PreviewSupport.shellPane),
      agentName: "Claude"
    )
  }

  /// A refusal. herdr refuses a working pane with `agent_not_idle`, so this is common.
  #Preview("Pane screen — herdr refused the read") {
    PaneScreenView(
      model: PreviewSupport.paneScreen(failing: .herdrCommandFailed(reason: "agent_not_idle")),
      agentName: "Claude"
    )
  }

  /// A blank screen, which is a different state from the refusal.
  #Preview("Pane screen — the pane is showing nothing") {
    PaneScreenView(model: PreviewSupport.paneScreen(showing: .blank), agentName: "Claude")
  }

#endif
