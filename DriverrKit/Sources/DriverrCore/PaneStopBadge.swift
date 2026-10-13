import Foundation

/// What a stopped pane wears in its status badge's place.
///
/// herdr's status says nothing about a stop, and as `blocked` it would draw the red
/// "waiting for you" badge over an agent that is not waiting. The Needs-you row, the session
/// tree and the pane switcher all take their glyph and words from here.
public struct PaneStopBadge: Hashable, Sendable {
  /// `AgentStopNotice.symbolName`, as the chat's card and the Needs-you row draw.
  public let symbolName: String
  /// The limit's reset time has passed. The view draws the glyph secondary rather than
  /// orange, as `AgentStopRow` does.
  public let isStale: Bool
  /// `Stopped`, or `Usage limit reset`. What VoiceOver reads off the glyph, and the status
  /// word a row draws where herdr's would go.
  public let label: String

  /// `nil` unless the pane has an agent and its transcript ends on a stop.
  ///
  /// Whatever herdr reports (idle, working or blocked), the stop is the true answer. The
  /// parser clears it when a later record lands.
  public init?(status: AgentStatus?, stop: AgentStop?, asOf now: Date) {
    guard status != nil, let stop else { return nil }
    self.init(notice: AgentStopNotice(stop: stop, asOf: now))
  }

  public init(notice: AgentStopNotice) {
    symbolName = notice.symbolName
    isStale = notice.isStale
    let state = Self.state(isStale: notice.isStale)
    label = state.prefix(1).uppercased() + state.dropFirst()
  }

  /// The state mid-sentence: `stopped`, or `usage limit reset` once the limit has reset and
  /// no longer holds the agent.
  static func state(isStale: Bool) -> String {
    isStale ? "usage limit reset" : "stopped"
  }
}
