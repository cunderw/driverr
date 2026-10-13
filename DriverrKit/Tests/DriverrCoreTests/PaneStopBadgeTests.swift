import DriverrCore
import Foundation
import Testing

/// What the session tree's row and the switcher's tiles draw in place of a stopped pane's
/// Blocked badge.
struct PaneStopBadgeTests {
  /// 22:40 UTC.
  private static let resetsAt = Date(timeIntervalSince1970: 1_790_548_800)

  private static let limit = AgentStop(
    kind: .rateLimit, resetsAt: resetsAt,
    message: "You've hit your session limit · resets 5:40pm (America/Chicago)")

  private static func badge(
    _ status: AgentStatus?, _ stop: AgentStop?, secondsBeforeReset: TimeInterval = 60
  ) -> PaneStopBadge? {
    PaneStopBadge(
      status: status, stop: stop, asOf: resetsAt.addingTimeInterval(-secondsBeforeReset))
  }

  @Test("a blocked pane on a live limit is stopped, with the limit's glyph")
  func liveLimit() throws {
    let badge = try #require(Self.badge(.blocked, Self.limit))
    #expect(badge.label == "Stopped")
    #expect(badge.symbolName == "hourglass")
    #expect(!badge.isStale)
  }

  @Test("once the limit resets, the badge says so and takes the reset glyph")
  func resetLimit() throws {
    let badge = try #require(Self.badge(.blocked, Self.limit, secondsBeforeReset: -60))
    #expect(badge.label == "Usage limit reset")
    #expect(badge.symbolName == "clock.arrow.circlepath")
    #expect(badge.isStale)
  }

  @Test("a failed request with no reset time stays stopped, with its own glyph")
  func serverError() throws {
    let badge = try #require(
      Self.badge(.blocked, AgentStop(kind: .serverError), secondsBeforeReset: -3_600))
    #expect(badge.label == "Stopped")
    #expect(badge.symbolName == "wifi.exclamationmark")
  }

  /// While Claude Code waits to continue at the reset, herdr may report the pane idle or
  /// working.
  @Test("a stop replaces the badge whatever status herdr reports")
  func everyStatus() throws {
    for status in AgentStatus.allCases {
      let badge = try #require(Self.badge(status, Self.limit), "\(status)")
      #expect(badge.label == "Stopped", "\(status)")
    }
  }

  @Test("no stop, or no agent, keeps the pane's own badge")
  func noBadge() {
    for status in AgentStatus.allCases {
      #expect(Self.badge(status, nil) == nil, "\(status)")
    }
    #expect(Self.badge(nil, Self.limit) == nil)
  }

  @Test("the Needs You row's glyph label is this badge's label")
  func matchesTheNeedsYouRow() throws {
    let pane = Pane(
      id: "w1:p2", tabID: "t1", workspaceID: "w1", title: "claude",
      agent: Agent(name: "Claude", kind: "claude", status: .blocked))
    for seconds: TimeInterval in [60, -60] {
      let now = Self.resetsAt.addingTimeInterval(-seconds)
      let row = BlockedPaneRow(
        pane: pane, location: nil, lastMessage: nil, quietSince: nil, stop: Self.limit,
        asOf: now)
      let badge = try #require(PaneStopBadge(status: .blocked, stop: Self.limit, asOf: now))
      #expect(row.stopGlyphAccessibilityLabel == badge.label)
    }
  }
}
