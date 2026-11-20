import DriverrCore
import SwiftUI

/// The one blocked pane a host row's badge opens, with what a tap on the badge does.
struct HostRowLonePane {
  let title: String
  let open: @MainActor () -> Void
}

/// The parts of a host row a hosted layout test reads the frame of.
enum HostRowPart {
  /// The host's name.
  case name
  /// The address line under the name.
  case address
  /// The drawn capsule of the blocked badge, not its layout box.
  case badge
  /// The connection dot.
  case dot
}

/// One host, answering "is anything waiting on me?" before it is opened. Every word comes
/// from `DriverrCore.HostStatus`, where `swift test` covers it.
///
/// The row's label only: the caller wraps it in its link. `accessory` ends the row as its
/// direct content, so a view it leaves out adds no gap.
///
/// At the accessibility sizes the dot and the badge take a line of their own under the
/// address. Side by side, the name, the dot and the badge need about 30 pt more than a phone
/// row has at the largest size, and the name broke mid-word ("work-" / "box"). `accessory`
/// stays at the trailing edge at every size, so the iPad sidebar's chevron stays in line with
/// the tree's own chevrons.
struct HostRowLabel<Accessory: View>: View {
  let name: String
  let status: HostStatus
  /// The pane the badge opens, or `nil` when it counts several (`SessionTree.loneBlockedPane`).
  var lonePane: HostRowLonePane?
  /// Where a hosted layout test reads each part's frame. Nothing is installed when `nil`. See
  /// `SidebarPaneRow.onTitleFrame`.
  var onFrame: (@MainActor (HostRowPart, CGRect) -> Void)?
  @ViewBuilder var accessory: Accessory

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    let stacked = dynamicTypeSize.isAccessibilitySize
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(name)
          .background { measurement(.name) }
        Text(status.subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .background { measurement(.address) }
        if stacked {
          HStack(spacing: 8) {
            indicators
          }
          .padding(.top, 4)
        }
      }
      Spacer(minLength: 8)
      if !stacked {
        indicators
      }
      accessory
    }
  }

  /// The dot and the badge. Direct content of whichever stack holds them, so each keeps that
  /// stack's 8 pt gap.
  @ViewBuilder private var indicators: some View {
    connectionDot
    if let badge = status.badge, let spoken = status.badgeAccessibilityLabel {
      blockedBadge(badge: badge, spoken: spoken)
    }
  }

  /// Whether Driverr is holding this host's connection, as a dot.
  ///
  /// The label matters, not the colour: one element that says the word, without the trait
  /// a symbol can bring. Three shapes, because a dropped link must not look like a host never
  /// reached. `HostConnectionState.glyphRole` decides which kind; the view picks symbol and
  /// colour.
  private var connectionDot: some View {
    Image(systemName: Self.glyph(for: status.connection.glyphRole))
      .font(.caption2)
      .foregroundStyle(Self.tint(for: status.connection.glyphRole))
      .background { measurement(.dot) }
      .accessibilityLabel(status.connectionAccessibilityLabel)
      .accessibilityRemoveTraits(.isSelected)
      .accessibilityIdentifier(Self.identifier(for: status.connection))
  }

  private static func glyph(for role: HostConnectionGlyphRole) -> String {
    switch role {
    case .none: "circle"
    case .ok: "circle.fill"
    // A filled circle, not a triangle: the other states here are `circle` and `circle.fill`,
    // and a triangle carries more ink, so one lost host would outweigh ten connected ones. The
    // detail pill keeps the triangle.
    case .warning: "exclamationmark.circle.fill"
    }
  }

  private static func tint(for role: HostConnectionGlyphRole) -> Color {
    switch role {
    case .none: .secondary
    case .ok: .green
    case .warning: .orange
    }
  }

  private static func identifier(for connection: HostConnectionState) -> String {
    switch connection {
    case .idle: "hosts.disconnected"
    case .connected: "hosts.connected"
    case .lost: "hosts.lost"
    }
  }

  /// How many of this host's panes are waiting on a human.
  ///
  /// Red and filled, like `AgentStatus.blocked`, because it is the one thing that wants you.
  /// Spoken as "2 panes need you".
  ///
  /// A button when it names one pane, a label when it counts several: with two there is no
  /// single destination. `.buttonStyle(.borderless)` stops the enclosing `NavigationLink` row
  /// from taking the tap.
  ///
  /// Both forms hold the capsule at its own width, so a long name cannot squeeze it.
  @ViewBuilder
  private func blockedBadge(badge: String, spoken: String) -> some View {
    if let lonePane {
      Button {
        lonePane.open()
      } label: {
        capsule(badge)
      }
      .badgeHitArea()
      .buttonStyle(.borderless)
      // The count, then what a tap does. `spoken` is already a sentence.
      .accessibilityLabel("\(spoken). Opens \(lonePane.title).")
      .accessibilityIdentifier("hosts.blocked")
    } else {
      capsule(badge)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier("hosts.blocked")
    }
  }

  private func capsule(_ badge: String) -> some View {
    HostBadgeCapsule(badge: badge)
      .background { measurement(.badge) }
  }

  @ViewBuilder
  private func measurement(_ part: HostRowPart) -> some View {
    if let onFrame {
      GeometryReader { proxy in
        Color.clear.onAppear { onFrame(part, proxy.frame(in: .global)) }
      }
    }
  }
}

extension HostRowLabel where Accessory == EmptyView {
  init(
    name: String,
    status: HostStatus,
    lonePane: HostRowLonePane? = nil,
    onFrame: (@MainActor (HostRowPart, CGRect) -> Void)? = nil
  ) {
    self.init(
      name: name, status: status, lonePane: lonePane, onFrame: onFrame
    ) { EmptyView() }
  }
}

/// The blocked badge itself, with nothing said about whether it does anything.
struct HostBadgeCapsule: View {
  let badge: String

  var body: some View {
    Text(badge)
      .font(.caption2.weight(.semibold))
      .monospacedDigit()
      .foregroundStyle(.white)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Color.red, in: Capsule())
  }
}

extension View {
  /// The blocked badge's hit area: 12 pt past the capsule on every side, without making its
  /// row taller.
  ///
  /// The layout box is the capsule's own size, at least 20 x 20, so the hit area is at least
  /// 44 x 44. At the default size that box is 20 x 20. At the accessibility sizes it grows
  /// with the capsule, so the capsule does not spill over the address above it. There the hit
  /// area reaches 12 pt above the capsule, past the 6 pt gap, and covers the bottom 6 pt of
  /// the address's last line; the target stays at least 44 pt. `fixedSize`,
  /// so a neighbour cannot squeeze the capsule. Keep `contentShape` between the two paddings:
  /// before them it shapes only the capsule, and after them it shrinks the shape.
  fileprivate func badgeHitArea() -> some View {
    fixedSize()
      .frame(minWidth: 20, minHeight: 20)
      .padding(12)
      .contentShape(Rectangle())
      .padding(-12)
  }
}
