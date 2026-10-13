import DriverrCore
import Testing

@testable import Driverr

/// How a status is *presented*, which is an accessibility claim as much as a visual one.
@MainActor
@Suite("AgentStatus presentation")
struct AgentStatusPresentationTests {
  // The glyph, hue role and spoken phrase are `DriverrCore`'s, because the widget draws the
  // same badge; `AgentStatusBadgeSpecTests` covers them. This is the SwiftUI `Color`.

  @Test("the app resolves every hue role to the system colour the widget also draws")
  func tintsResolveEveryHueRole() {
    // `DriverrWatch/DriverrWatch.swift` holds a second copy of this table, because the kit
    // carries no SwiftUI `Color`. Both switches are exhaustive, so a new hue fails both
    // compiles; the values are pinned only here.
    //
    // System colours stay right in both appearances and under Increase Contrast.
    #expect(AgentStatus.blocked.tint == .red)
    #expect(AgentStatus.done.tint == .teal)
    #expect(AgentStatus.working.tint == .yellow)
    #expect(AgentStatus.idle.tint == .green)
    // herdr cannot say what this agent is doing, so no colour claims it.
    #expect(AgentStatus.unknown.tint == .secondary)
  }

  @Test("the blocked badge the widget draws is the one the app draws")
  func theWidgetReadsTheAppsBadge() {
    // `DriverrWatch`'s `BlockedPaneGlyph` reads these three properties. No test target compiles
    // the widget, so this pins the values both sides resolve.
    #expect(AgentStatus.blocked.symbolName == "exclamationmark.circle.fill")
    #expect(AgentStatus.blocked.hue == .red)
    #expect(AgentStatus.blocked.tint == .red)
    #expect(AgentStatus.blocked.accessibleName == "Waiting for you")
  }

  @Test("a shell pane is not a sixth status")
  func shellIsNotAStatus() {
    // A shell pane reports `agent_status: "unknown"`, which must not draw a grey question
    // mark. There is no `AgentStatus` for "no agent"; `PaneBadge` branches on `Pane.agent`.
    #expect(!AgentStatus.allCases.contains { $0.rawValue == "shell" })
    #expect(!AgentStatus.allCases.contains { $0.accessibleName == "Shell" })
  }

  @Test("the badge's identifier stays keyed to the status, so tests can find it")
  func identifiersAreStable() {
    #expect(AgentStatus.blocked.rawValue == "blocked")
    // herdr's five, and no sixth for "no agent": the status lives inside `Pane.agent`, so a
    // shell pane carries no badge.
    #expect(AgentStatus.allCases.count == 5)
    #expect(AgentStatus.done.rawValue == "done")
  }
}
