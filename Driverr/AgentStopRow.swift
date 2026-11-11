import DriverrCore
import SwiftUI

/// The chat's notice that the agent stopped on a failed API request.
///
/// Inline, like `PanePromptBar`, because a modal from inside the pane scene would be a
/// presentation inside a presentation. It stands in for the record's own turn, which the
/// parser hides while the stop stands. See `AgentStop` for the record shapes.
///
/// A glass capsule floating over the top of the conversation, not a strip pinned above it.
/// Title and detail are one run of text, so the live limit, `Usage limit reached · Resets at
/// 5:40 PM.`, is one line and the shape is a capsule; a longer detail wraps to a second line
/// and the shape becomes a rounded card. The reset time leads the detail, so it is always in
/// the part that shows.
///
/// The only timeline entry is the reset time, so nothing animates while the notice is up.
struct AgentStopRow: View {
  let stop: AgentStop

  /// One width for all five glyphs, so the text does not move when the glyph changes.
  /// `wifi.exclamationmark`, the widest, is about 19 pt. Scaled with Dynamic Type.
  @ScaledMetric private var glyphWidth: CGFloat = 20

  /// At accessibility sizes two lines hold little more than the title, so the reset time
  /// would be cut. The limit is lifted there.
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    // Read the clock here, not `context.date`: an explicit schedule renders its first frame
    // with the entry's date, which would show the reset as passed too early. The entry is one
    // second past the reset so the clock read when it fires is past it too.
    TimelineView(.explicit(stop.resetsAt.map { [$0.addingTimeInterval(1)] } ?? [])) { _ in
      let notice = AgentStopNotice(stop: stop, asOf: Date())
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: notice.symbolName)
          .foregroundStyle(notice.isStale ? Color.secondary : Color.orange)
          .frame(width: glyphWidth, alignment: .center)
          .accessibilityHidden(true)
        // Two lines at most, so a long error does not cover the conversation; none at
        // accessibility sizes, where two would cut the reset time. VoiceOver reads the whole
        // detail through the label either way.
        text(for: notice)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
          .fixedSize(horizontal: false, vertical: true)
      }
      .font(.footnote)
      .padding(.leading, 10)
      .padding(.trailing, 14)
      .padding(.vertical, 8)
      .chatCapsuleGlass(RoundedRectangle(cornerRadius: ChatCapsuleGlass.radius, style: .continuous))
      // One accessibility element, so VoiceOver reads title and detail as one statement.
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(notice.accessibilityLabel)
      .accessibilityIdentifier("pane.chat.agentStop")
    }
  }

  private func text(for notice: AgentStopNotice) -> Text {
    let title = Text(notice.title)
      .fontWeight(.semibold)
      .foregroundStyle(notice.isStale ? Color.secondary : Color.primary)
    guard let detail = notice.detail else { return title }
    return Text("\(title) · \(Text(detail).foregroundStyle(Color.secondary))")
  }
}

/// The chat's floating capsules: the composer's surface, `.regularMaterial` with an
/// `opaqueSeparator` border, so they read as one family with the card below. See
/// `PaneComposerBar.card`.
enum ChatCapsuleGlass {
  /// Half a one-line capsule's height, so one line draws as a capsule and two as a card.
  static let radius: CGFloat = 17
}

extension View {
  /// The composer's material and border, in `shape`.
  func chatCapsuleGlass<S: InsettableShape>(_ shape: S) -> some View {
    background(.regularMaterial, in: shape)
      .overlay { shape.strokeBorder(Color(.opaqueSeparator), lineWidth: 1) }
  }
}
