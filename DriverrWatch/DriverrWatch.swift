import ActivityKit
import DriverrCore
import SwiftUI
import WidgetKit

@main
struct DriverrWatch: WidgetBundle {
  var body: some Widget { BlockedPaneActivityWidget() }
}

struct BlockedPaneActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: BlockedPaneActivityAttributes.self) { context in
      let isStale = context.isStale || context.state.isStale(at: .now)
      let theme = currentWidgetTheme()
      // Where a tap lands. The widget holds no rule: `BlockedPaneActivityRoute` chooses the
      // pane or the host's tree and builds the URL, so `swift test` covers it.
      // `Driverr/ActivityURLRouter.swift` is the receiving end.
      let url = BlockedPaneActivityRoute.url(for: context.state)
      BlockedPaneCard(state: context.state, isStale: isStale, showsGlyph: true, theme: theme)
        .padding()
        // The ground stays black. The theme's own surface would break the status hues: on the
        // worst light theme the system red reads 2.74:1 and the working yellow 1.17:1, and even
        // dark theme grounds leave the red headline under 4.5:1. The theme reaches this card
        // only as an accent fill on the calm headline; see `BlockedPaneCard`.
        .activityBackgroundTint(Color.black.opacity(0.85))
        // Matches the app's root `.tint`. No system action element is drawn today, so this is
        // invisible. A future system action should match the capsule: an accent fill with
        // `readableForeground` on it.
        .activitySystemActionForegroundColor(theme.map { Color($0.dark.accent) } ?? .white)
        .widgetURL(url)
    } dynamicIsland: { context in
      let isStale = context.isStale || context.state.isStale(at: .now)
      let theme = currentWidgetTheme()
      let url = BlockedPaneActivityRoute.url(for: context.state)
      let island = DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          // The leading slot sits under the island's top-left corner mask. Without the inset the
          // mask clipped the glyph's circle and it hung left of the text column below. The value
          // was found by cropping captures at native resolution.
          BlockedPaneGlyph(state: context.state, isStale: isStale)
            .padding(.leading, 6)
            .padding(.top, 4)
            // Silent, like the Lock Screen card's glyph: the card below says "Needs you", so
            // VoiceOver would read the state twice. The compact and minimal presentations keep
            // their labels, because no card sits beside them.
            .accessibilityHidden(true)
        }
        DynamicIslandExpandedRegion(.trailing) {
          // The blocked count when anything is blocked, otherwise the working count, and nothing
          // when stale. The card is up for the whole connected session, so a blocked count alone
          // would read 0 most of the time. The leading glyph says which count it is. It is drawn
          // only there; a copy here would put one state in both corners.
          IslandCount(state: context.state, isStale: isStale)
            .font(.headline)
            .lineLimit(1)
            // Clear of the island's top-right corner radius, which clipped the last character.
            .padding(.trailing, 6)
            .padding(.top, 4)
            // Silent, like the leading glyph: the card below says the count in words. The compact
            // trailing count keeps its value, because no card sits beside it.
            .accessibilityHidden(true)
        }
        DynamicIslandExpandedRegion(.bottom) {
          // Less than the default 16 pt, which put the text 13 pt right of the glyph, but not
          // zero: below about 4 pt the card's last line runs into the island's bottom-left
          // corner radius and is clipped. `showsGlyph: false` because the leading region has
          // the glyph.
          BlockedPaneCard(
            state: context.state, isStale: isStale, showsGlyph: false, theme: theme
          )
          .padding(.horizontal, 6)
          .padding(.bottom, 6)
        }
      } compactLeading: {
        BlockedPaneGlyph(state: context.state, isStale: isStale)
      } compactTrailing: {
        // The same count as the expanded trailing slot. It keeps its spoken label, because no
        // card sits beside it; the working label says what it counts ("2 working"). Empty when
        // stale, where the leading clock stands alone.
        IslandCount(state: context.state, isStale: isStale)
      } minimal: {
        BlockedPaneGlyph(state: context.state, isStale: isStale)
      }
      // `DynamicIsland.widgetURL(_:)` covers all four presentations at once.
      return island.widgetURL(url)
    }
  }
}

/// The theme the app last published into the shared App Group, or `nil`.
///
/// Built fresh on every render, never cached in a `static`: the extension's process is reused
/// across renders, so a cached `UserDefaults` would never see a later theme change, silently.
///
/// `nil` covers a fresh install, a missing entitlement, an unreadable blob and a payload from
/// a newer build. Every caller draws the fixed colours then.
private func currentWidgetTheme() -> WidgetThemeSnapshot? {
  let defaults = UserDefaults(suiteName: WidgetThemeSnapshot.appGroupID)
  return WidgetThemeSnapshot.decode(defaults?.data(forKey: WidgetThemeSnapshot.defaultsKey))
}

extension Color {
  /// `TerminalColor` to SwiftUI, the widget's own copy of a two-line conversion.
  ///
  /// The kit's version is in `DriverrTerm`, which wraps SwiftTerm and must not be linked into
  /// this extension (`APPLICATION_EXTENSION_API_ONLY` with a Metal renderer fails confusingly).
  /// `DriverrCore` cannot own a `Color`.
  fileprivate init(_ terminal: TerminalColor) {
    self.init(
      red: Double(terminal.red) / 255,
      green: Double(terminal.green) / 255,
      blue: Double(terminal.blue) / 255
    )
  }
}

/// The mark the card wears, the same one the state wears in the host list.
///
/// Blocked uses `AgentStatus.blocked`'s mark, the only filled shape and the red hue. A calm
/// card uses `AgentStatus.working`'s, because the card is up for the whole session and an
/// alarm mark on it all the time would mean nothing.
///
/// Shape, hue role and spoken name come from `DriverrCore`. The hue-to-`Color` step is written
/// here and in the app, each an exhaustive `switch`, so a new hue fails both compiles. The
/// stale variant is not an `AgentStatus`, so its clock and sentence stay here, worded as
/// `ContentState.headline(isStale:)`.
private struct BlockedPaneGlyph: View {
  let state: BlockedPaneActivityAttributes.ContentState
  let isStale: Bool

  var body: some View {
    let status: AgentStatus = state.needsYou ? .blocked : .working
    Image(systemName: isStale ? "clock" : status.symbolName)
      .foregroundStyle(
        isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(Self.color(for: status.hue))
      )
      .accessibilityLabel(isStale ? "Status may have changed" : status.accessibleName)
  }

  /// The widget's half of `AgentStatusHue`. `Driverr/AgentStatusBadge.swift` holds the app's.
  static func color(for hue: AgentStatusHue) -> Color {
    switch hue {
    case .red: .red
    case .orange: .orange
    case .teal: .teal
    case .yellow: .yellow
    case .green: .green
    case .neutral: .secondary
    }
  }
}

/// The Dynamic Island's trailing number: blocked when anything is blocked, working otherwise,
/// and nothing when stale.
///
/// A number, never a mark. The state belongs to the leading glyph in every presentation, and a
/// mark here would repeat it.
///
/// Empty rather than zero when stale, because Driverr could not confirm any number, and the
/// headline already says so. No `accessibilityLabel`: the leading glyph's label speaks that
/// sentence.
private struct IslandCount: View {
  let state: BlockedPaneActivityAttributes.ContentState
  let isStale: Bool

  var body: some View {
    if !isStale {
      let status: AgentStatus = state.needsYou ? .blocked : .working
      let count = state.needsYou ? state.blockedCount : state.totals.working
      Text("\(count)")
        .monospacedDigit()
        .foregroundStyle(BlockedPaneGlyph.color(for: status.hue))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.needsYou ? "\(count) blocked" : "\(count) working")
    }
  }
}

private struct BlockedPaneCard: View {
  let state: BlockedPaneActivityAttributes.ContentState
  let isStale: Bool

  /// The Lock Screen card carries the mark itself, because red type alone reads as an error.
  /// The expanded island passes `false`, because its leading region has the glyph.
  let showsGlyph: Bool

  /// What the app published across the App Group, or `nil` for the fixed colours.
  let theme: WidgetThemeSnapshot?

  /// The dark half in both system appearances. The card and the island are drawn on their own
  /// black grounds, never on the system's light surface.
  private var half: WidgetThemeSnapshot.Half? { theme?.dark }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      if showsGlyph {
        BlockedPaneGlyph(state: state, isStale: isStale)
          .font(.headline)
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 5) {
        // Red when something is waiting, the accent capsule when nothing is, plain when stale.
        // See `headline`.
        headline
        Text(state.detail(isStale: isStale))
          .font(.subheadline)
          .foregroundStyle(isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(.foreground))
        // The blocked pane's own caption. A calm card has no single pane, so `context` is `nil`.
        // No `lineLimit(1)`, which let a long title push the host name off; the stack's
        // two-line limit bounds it.
        if !isStale, state.blockedCount == 1, let context = state.context {
          Text(context)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        // A date style, not a formatted string: the system refreshes a style without waking the
        // widget, so it keeps counting after the card is archived. A format style freezes.
        Text("Last confirmed \(state.lastConfirmedAt, style: .relative) ago")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .lineLimit(2)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// The card's first line, and the one place the user's theme reaches this surface.
  ///
  /// The accent is a fill, not the type. An accent fill with `readableForeground` on it reads
  /// 4.5:1 for every bundled theme, and the fill's edge clears 3:1 against black.
  ///
  /// Only the calm headline takes it. `Needs you` keeps the red role hue, and a stale headline
  /// stays plain. The calm headline is a host name or "3 hosts", which no colour can
  /// contradict.
  ///
  /// One line, because a second line inside a capsule looks wrong.
  /// `ContentState.nameBudget` makes a joined multi-host line fall back to "N hosts" before it
  /// would truncate. A single host's name is not budgeted and truncates here.
  @ViewBuilder
  private var headline: some View {
    let text = Text(state.headline(isStale: isStale)).font(.headline)
    if !isStale, !state.needsYou, let half {
      text
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(Color(half.accentForeground))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        // A background and padding, so VoiceOver still reads the host's name as one element.
        .background(Capsule().fill(Color(half.accent)))
    } else {
      text.foregroundStyle(
        !isStale && state.needsYou ? AnyShapeStyle(Color.red) : AnyShapeStyle(.foreground))
    }
  }
}
