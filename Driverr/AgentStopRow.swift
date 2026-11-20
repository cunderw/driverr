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
///
/// A live limit with a reset time also offers the reset alert's Continue, off until the
/// reader turns it on, as a second capsule under the notice. It is its own accessibility
/// element, because the notice's capsule ignores its children.
///
/// At accessibility text sizes the notice, the opt-in and Show the Screen covered most of a
/// phone's chat (#107), so there the row draws in two parts. The header is one capsule with
/// the glyph, `AgentStopNotice.compactLine` and a chevron, the same card folded or open. A
/// tap opens the body under it: the whole notice, in its own card, and the opt-in.
/// `PaneChatView` places the two and draws Show the Screen after the body.
struct AgentStopRow: View {
  let stop: AgentStop
  /// Whether this pane's reset alert offers Continue. `nil` draws no control.
  var continueAtReset: Binding<Bool>?
  /// What to draw. `.all` at the sizes where the notice never folds, so it lays out as it
  /// always did.
  var part: Part = .all

  enum Part {
    /// The notice and the opt-in under it.
    case all
    /// The folding header at accessibility sizes, a button that opens and closes the body.
    case header(expanded: Binding<Bool>)
    /// The open body at accessibility sizes: the whole notice and the opt-in under it.
    case body
  }

  /// One width for all five glyphs, so the text does not move when the glyph changes.
  /// `wifi.exclamationmark`, the widest, is about 19 pt. Scaled with Dynamic Type.
  @ScaledMetric private var glyphWidth: CGFloat = 20

  /// At accessibility sizes two lines hold little more than the title, so the reset time
  /// would be cut. The limit is lifted there.
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.themeAccent) private var themeAccent

  /// The Continue capsule's vertical padding, as `PaneChatView`'s Show the Screen capsule.
  @ScaledMetric private var continuePadding: CGFloat = 8

  var body: some View {
    // Read the clock here, not `context.date`: an explicit schedule renders its first frame
    // with the entry's date, which would show the reset as passed too early. The entry is one
    // second past the reset so the clock read when it fires is past it too.
    TimelineView(.explicit(stop.resetsAt.map { [$0.addingTimeInterval(1)] } ?? [])) { _ in
      let notice = AgentStopNotice(stop: stop, asOf: Date())
      VStack(spacing: 0) {
        switch part {
        case .all:
          capsule(notice)
          continueControl(for: notice)
        case .header(let expanded):
          foldingCapsule(notice, expanded: expanded)
        case .body:
          card(notice)
          continueControl(for: notice)
        }
      }
    }
  }

  private func capsule(_ notice: AgentStopNotice) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      glyph(notice)
      words(for: notice)
    }
    .noticeGlass()
    // One accessibility element, so VoiceOver reads title and detail as one statement.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(notice.accessibilityLabel)
    .accessibilityIdentifier("pane.chat.agentStop")
  }

  /// The body's notice, in the notice's glass, without the glyph the header already shows.
  /// Title and detail for a live limit, whose header shows the reset; the detail alone for a
  /// stop whose header is its title (`AgentStopNotice.foldedBodyTitle`), and no card at all
  /// when that stop has no detail. One accessibility element reading the whole notice, as the
  /// notice is at other sizes.
  @ViewBuilder
  private func card(_ notice: AgentStopNotice) -> some View {
    if notice.foldedBodyTitle != nil {
      bodyCard(words(for: notice), notice)
    } else if let detail = notice.detail {
      bodyCard(
        Text(detail)
          .foregroundStyle(Color.secondary)
          .fixedSize(horizontal: false, vertical: true),
        notice)
    }
  }

  private func bodyCard(_ content: some View, _ notice: AgentStopNotice) -> some View {
    content
      .noticeGlass()
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(notice.accessibilityLabel)
      .accessibilityIdentifier("pane.chat.agentStop.detail")
  }

  /// The header at accessibility sizes: a button that opens and closes the body. The glyph and
  /// the compact line, at most two lines on an iPhone 17 at the largest size, in both states,
  /// so it keeps its height as the body opens. The chevron says which state. VoiceOver reads
  /// the whole notice, with the fold as the value.
  private func foldingCapsule(_ notice: AgentStopNotice, expanded: Binding<Bool>) -> some View {
    Button { expanded.wrappedValue.toggle() } label: {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        glyph(notice)
        Text(notice.compactLine)
          .fontWeight(.semibold)
          .foregroundStyle(notice.isStale ? Color.secondary : Color.primary)
          .fixedSize(horizontal: false, vertical: true)
        Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
          .fontWeight(.semibold)
          .foregroundStyle(Color.secondary)
          .accessibilityHidden(true)
      }
      .noticeGlass()
      .contentShape(RoundedRectangle(cornerRadius: ChatCapsuleGlass.radius, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(notice.accessibilityLabel)
    .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("pane.chat.agentStop")
  }

  private func glyph(_ notice: AgentStopNotice) -> some View {
    Image(systemName: notice.symbolName)
      .foregroundStyle(notice.isStale ? Color.secondary : Color.orange)
      .frame(width: glyphWidth, alignment: .center)
      .accessibilityHidden(true)
  }

  /// The opt-in, only for a live limit with a reset time: after the reset there is no alert
  /// left to change.
  @ViewBuilder
  private func continueControl(for notice: AgentStopNotice) -> some View {
    if let continueAtReset, stop.kind == .rateLimit, stop.resetsAt != nil, !notice.isStale {
      continueControl(continueAtReset)
    }
  }

  /// The opt-in for the reset alert's Continue. A button with a check, not a `Toggle`, so it
  /// sits in the chat's glass like Show the Screen. Its target is 44 pt, as that capsule's is.
  private func continueControl(_ isOn: Binding<Bool>) -> some View {
    Button { isOn.wrappedValue.toggle() } label: {
      HStack(spacing: 6) {
        Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isOn.wrappedValue ? themeAccent : Color.secondary)
          .frame(width: glyphWidth, alignment: .center)
        Text(LimitResetReminder.optInTitle)
          .foregroundStyle(Color.primary)
      }
      .font(.footnote.weight(.semibold))
      .padding(.leading, 10)
      .padding(.trailing, 14)
      .padding(.vertical, continuePadding)
      .frame(minHeight: 2 * ChatCapsuleGlass.radius)
      // The notice's shape, not a capsule: at large text the label wraps, and a capsule's
      // ends would round into it.
      .chatCapsuleGlass(RoundedRectangle(cornerRadius: ChatCapsuleGlass.radius, style: .continuous))
      .padding(.vertical, (44 - 2 * ChatCapsuleGlass.radius) / 2)
      .contentShape(RoundedRectangle(cornerRadius: ChatCapsuleGlass.radius, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(LimitResetReminder.optInTitle)
    .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
    .accessibilityAddTraits([.isButton, .isToggle])
    .accessibilityIdentifier("pane.chat.agentStop.continue")
  }

  /// Two lines at most, so a long error does not cover the conversation; none at
  /// accessibility sizes, where two would cut the reset time. VoiceOver reads the whole detail
  /// through the label either way.
  private var lineLimit: Int? { dynamicTypeSize.isAccessibilitySize ? nil : 2 }

  /// Title and detail as one run, `title · detail`, while the title, the dot and the detail's
  /// first word fit on the first line. Otherwise the dot would end the first line alone, so the
  /// detail goes under the title with no dot.
  ///
  /// The first choice is the whole run on one line, so the one-line capsule hugs its text. The
  /// second wraps the run, and is offered only when its probe, the title, the dot and the first
  /// word on one line, fits: the wrapped run reports no ideal width of its own, so the probe's
  /// is what `ViewThatFits` measures.
  @ViewBuilder
  private func words(for notice: AgentStopNotice) -> some View {
    if let detail = notice.detail {
      ViewThatFits(in: .horizontal) {
        run(title: notice, detail: detail)
          .fixedSize(horizontal: true, vertical: false)
          .lineLimit(1)
        ZStack(alignment: .topLeading) {
          let firstWord = detail.split(separator: " ").first.map(String.init) ?? detail
          run(title: notice, detail: firstWord)
            .fixedSize(horizontal: true, vertical: false)
            .lineLimit(1)
            .hidden()
          run(title: notice, detail: detail)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 0, idealWidth: 0, alignment: .leading)
        }
        VStack(alignment: .leading, spacing: 2) {
          title(notice)
            .fixedSize(horizontal: false, vertical: true)
          Text(detail)
            .foregroundStyle(Color.secondary)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    } else {
      title(notice)
        .lineLimit(lineLimit)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func title(_ notice: AgentStopNotice) -> Text {
    Text(notice.title)
      .fontWeight(.semibold)
      .foregroundStyle(notice.isStale ? Color.secondary : Color.primary)
  }

  private func run(title notice: AgentStopNotice, detail: String) -> Text {
    Text("\(title(notice)) · \(Text(detail).foregroundStyle(Color.secondary))")
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
  /// The stop notice's type, padding and glass, shared by its plain and folding forms.
  fileprivate func noticeGlass() -> some View {
    font(.footnote)
      .padding(.leading, 10)
      .padding(.trailing, 14)
      .padding(.vertical, 8)
      .chatCapsuleGlass(
        RoundedRectangle(cornerRadius: ChatCapsuleGlass.radius, style: .continuous))
  }

  /// The composer's material and border, in `shape`.
  func chatCapsuleGlass<S: InsettableShape>(_ shape: S) -> some View {
    background(.regularMaterial, in: shape)
      .overlay { shape.strokeBorder(Color(.opaqueSeparator), lineWidth: 1) }
  }
}
