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
  /// The drawn capsule of the blocked badge, not its layout box.
  case badge
}

/// One host, answering "is anything waiting on me?" before it is opened. Every word comes
/// from `DriverrCore.HostStatus`, where `swift test` covers it.
///
/// The row's label only: the caller wraps it in its link. `accessory` follows the blocked
/// badge as direct content of the row, so a view it leaves out adds no gap.
struct HostRowLabel<Accessory: View>: View {
  let name: String
  let status: HostStatus
  /// The pane the badge opens, or `nil` when it counts several (`SessionTree.loneBlockedPane`).
  var lonePane: HostRowLonePane?
  var growsWithCapsule = false
  /// Where a hosted layout test reads each part's frame. Nothing is installed when `nil`. See
  /// `SidebarPaneRow.onTitleFrame`.
  var onFrame: (@MainActor (HostRowPart, CGRect) -> Void)?
  @ViewBuilder var accessory: Accessory

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(name)
          .background { measurement(.name) }
        Text(status.subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      // First claim on the width in a row with the sidebar's chevron, or at AX3 the name
      // breaks mid-word while its row is selected. Other rows lay out as they did.
      .layoutPriority(1)
      Spacer(minLength: 8)
      connectionDot
      if let badge = status.badge, let spoken = status.badgeAccessibilityLabel {
        blockedBadge(badge: badge, spoken: spoken)
      }
      accessory
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
  /// `growsWithCapsule` is for a row that also draws the sidebar's chevron. Its layout box
  /// takes the capsule's size, so at the accessibility sizes the capsule does not spill into
  /// the chevron. Every other row keeps the fixed box, so the phone lays out as it did.
  @ViewBuilder
  private func blockedBadge(badge: String, spoken: String) -> some View {
    if let lonePane {
      Button {
        lonePane.open()
      } label: {
        capsule(badge)
      }
      .badgeHitArea(growsWithCapsule: growsWithCapsule)
      .buttonStyle(.borderless)
      // The count, then what a tap does. `spoken` is already a sentence.
      .accessibilityLabel("\(spoken). Opens \(lonePane.title).")
      .accessibilityIdentifier("hosts.blocked")
    } else {
      capsule(badge)
        // Fixed on a chevron row, where the name's layout priority would squeeze it.
        .fixedSize(horizontal: growsWithCapsule, vertical: false)
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
    growsWithCapsule: Bool = false,
    onFrame: (@MainActor (HostRowPart, CGRect) -> Void)? = nil
  ) {
    self.init(
      name: name, status: status, lonePane: lonePane, growsWithCapsule: growsWithCapsule,
      onFrame: onFrame
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
  /// The blocked badge's 44 pt hit area, without making its row taller.
  ///
  /// The fixed form: a 44 x 44 hit area on 20 x 20 of layout; keep these three modifiers in
  /// this order. A plain 44 pt `frame` would make the rows taller than their neighbours.
  /// `frame` sizes the hit box, `contentShape` makes all of it hittable, and the negative
  /// padding returns the layout space. `contentShape` before `frame` shapes only the capsule,
  /// and padding before `contentShape` shrinks the shape.
  ///
  /// The growing form takes the capsule's own size, at least 20 x 20, and pads the hit area
  /// 12 pt past it on every side. `fixedSize`, so a neighbour with layout priority cannot
  /// squeeze the capsule.
  @ViewBuilder
  fileprivate func badgeHitArea(growsWithCapsule: Bool) -> some View {
    if growsWithCapsule {
      fixedSize()
        .frame(minWidth: 20, minHeight: 20)
        .padding(12)
        .contentShape(Rectangle())
        .padding(-12)
    } else {
      frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .padding(-12)
    }
  }
}
