import DriverrCore
import SwiftUI

/// What an agent's state looks like at a glance.
///
/// Semantic colours only, and every badge carries a text label, because colour alone cannot
/// tell "waiting for you" from "busy". A pane with no agent never reaches this type:
/// `PaneBadge` gives a shell a terminal glyph instead.
struct AgentStatusBadge: View {
  let status: AgentStatus

  var body: some View {
    Image(systemName: status.symbolName)
      .foregroundStyle(status.tint)
      .accessibilityLabel(status.accessibleName)
      .accessibilityIdentifier("status.\(status.rawValue)")
  }
}

extension AgentStatus {
  /// The app target's half of `AgentStatusHue`: the role, in a system colour.
  ///
  /// A SwiftUI `Color` cannot live in `DriverrCore`, so each target resolves the role itself.
  /// `DriverrWatch/DriverrWatch.swift` holds the widget's copy of this switch. Both are
  /// exhaustive, so a new hue fails both compiles instead of drifting.
  var tint: Color {
    switch hue {
    case .red: .red
    case .teal: .teal
    case .yellow: .yellow
    case .green: .green
    case .neutral: .secondary
    }
  }
}

/// The glyph for one pane: its agent's state, or a terminal for a plain shell.
///
/// The branch lives here so the four call sites cannot disagree. A shell is not an
/// `AgentStatus`: it has no agent, so it carries no `status.*` identifier.
struct PaneBadge: View {
  let pane: Pane
  /// The agent's stop, drawn in the badge's place. herdr reports a stopped agent as blocked,
  /// which would draw "waiting for you" over an agent that is not waiting.
  var stop: PaneStopBadge? = nil

  var body: some View {
    if let stop {
      // Drawn over a hidden badge so it takes the badge's width and baseline at every text size.
      PaneBadge(pane: pane)
        .hidden()
        .accessibilityHidden(true)
        .overlay {
          Image(systemName: stop.symbolName)
            .foregroundStyle(stop.isStale ? Color.secondary : Color.orange)
            .accessibilityLabel(stop.label)
            // Not `status.*`: that family names a herdr status, and this is not one.
            .accessibilityIdentifier("pane.stopGlyph")
        }
    } else if let agent = pane.agent {
      AgentStatusBadge(status: agent.status)
    } else {
      Image(systemName: "terminal")
        .foregroundStyle(.secondary)
        .accessibilityLabel("Shell")
        // Not `status.shell`, so a test for "no status badge on a shell" can look for
        // `status.*` and find nothing.
        .accessibilityIdentifier("pane.shell")
    }
  }
}

#if DEBUG

  /// Every state side by side, to check by eye that no two differ only by colour.
  #Preview("Status vocabulary") {
    List {
      ForEach(AgentStatus.allCases, id: \.self) { status in
        HStack(spacing: 8) {
          AgentStatusBadge(status: status)
          Text(status.accessibleName)
        }
      }
      // A shell pane has no agent, so it wears a terminal rather than a status.
      HStack(spacing: 8) {
        PaneBadge(pane: PreviewSupport.shellPane)
        Text("Shell — no agent")
          .foregroundStyle(.secondary)
      }
    }
  }

  #Preview("Status vocabulary — dark") {
    List {
      ForEach(AgentStatus.allCases, id: \.self) { status in
        HStack(spacing: 8) {
          AgentStatusBadge(status: status)
          Text(status.accessibleName)
        }
      }
    }
    .preferredColorScheme(.dark)
  }

#endif
