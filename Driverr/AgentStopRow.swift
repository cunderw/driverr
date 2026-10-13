import DriverrCore
import SwiftUI

/// The chat's notice that the agent stopped on a failed API request.
///
/// Inline, like `PanePromptBar`, because a modal from inside the pane scene would be a
/// presentation inside a presentation. It stands in for the record's own turn, which the
/// parser hides while the stop stands. See `AgentStop` for the record shapes.
///
/// The only timeline entry is the reset time, so nothing animates while the notice is up.
struct AgentStopRow: View {
  let stop: AgentStop
  let horizontalInset: CGFloat

  /// One width for all five glyphs, so the text does not move when the glyph changes.
  /// `wifi.exclamationmark`, the widest, is about 19 pt. Scaled with Dynamic Type.
  @ScaledMetric private var glyphWidth: CGFloat = 20

  var body: some View {
    // Read the clock here, not `context.date`: an explicit schedule renders its first frame
    // with the entry's date, which would show the reset as passed too early. The entry is one
    // second past the reset so the clock read when it fires is past it too.
    TimelineView(.explicit(stop.resetsAt.map { [$0.addingTimeInterval(1)] } ?? [])) { _ in
      let notice = AgentStopNotice(stop: stop, asOf: Date())
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Image(systemName: notice.symbolName)
          .foregroundStyle(notice.isStale ? Color.secondary : Color.orange)
          .frame(width: glyphWidth, alignment: .center)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(notice.title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(notice.isStale ? Color.secondary : Color.primary)
          if let detail = notice.detail {
            // Three lines at most. VoiceOver still reads the whole detail through the label.
            Text(detail)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .lineLimit(3)
          }
        }
        Spacer(minLength: 0)
      }
      // One accessibility element, so VoiceOver reads title and detail as one statement. The
      // identifier is here because the card's background and padding sit outside it.
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(notice.accessibilityLabel)
      .accessibilityIdentifier("pane.chat.agentStop")
      .padding(12)
      // `.thinMaterial` is about 1.02:1 against the chat's `secondarySystemBackground` in light,
      // so the card had no visible edge.
      .background(
        Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .padding(.horizontal, horizontalInset)
      .padding(.top, 4)
    }
  }
}
