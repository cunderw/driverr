import Foundation

/// A run of tool calls, opened, and which runs the reader has opened.
///
/// Sessions are mostly tool calls, so closed is the resting state. Opening a run names the
/// few calls that say what it touched, then says how many it did not name. The wording is
/// here so `swift test` asserts it.

// MARK: - What an opened run says

extension ToolRun {
  /// How many calls an opened run names. Six fits on a phone under the summary row without
  /// turning the run into a second transcript.
  public static let openLimit = 6

  /// The calls an opened run lists: the most recent six, because the agent's next message is
  /// about where it got to. `mostRecent(_:)` keeps them in call order.
  public var openedCalls: [ToolCall] { mostRecent(ToolRun.openLimit) }

  /// How many calls a closed run names.
  ///
  /// Three shows the whole run for most runs (median run length is 2 to 3) and the three the
  /// next message is about for long ones. Half of `openLimit`, so opening a run is still
  /// worth the tap.
  public static let closedLimit = 3

  /// The calls a closed run names: the most recent three, in call order.
  public var closedCalls: [ToolCall] { mostRecent(ToolRun.closedLimit) }

  /// `+37 more`, or `nil` when the closed row named the whole run. Terse, because readers
  /// scroll past closed rows. It says nothing about what the unnamed calls were.
  public var moreCalls: String? {
    let more = count - ToolRun.closedLimit
    guard more > 0 else { return nil }
    return "+\(more) more"
  }

  /// `…and 34 earlier calls, same kinds.`, or `nil` when the run opened to all of itself.
  ///
  /// "same kinds" points at the row's `kindsSummary`, which tallies every call in the run.
  /// It does not claim the earlier calls resemble the recent ones, which is why the tally is
  /// drawn in the opened state too.
  public var earlierCalls: String? {
    let earlier = count - ToolRun.openLimit
    guard earlier > 0 else { return nil }
    let calls = earlier == 1 ? "1 earlier call" : "\(earlier) earlier calls"
    return "…and \(calls), same kinds."
  }
}

extension ToolCall {
  /// `name`, shortened for an opened row:
  /// `mcp__plugin_chrome-devtools-mcp_chrome-devtools__take_screenshot` becomes
  /// `take_screenshot · plugin_chrome-devtools-mcp_chrome-devtools`.
  ///
  /// Display only. `kinds` and `kindsSummary` count by `name`, because two servers can expose
  /// tools with the same short name.
  public var displayName: String {
    let parts = name.components(separatedBy: "__")
    guard parts.count >= 3, parts[0] == "mcp" else { return name }
    let tool = parts[parts.count - 1]
    let server = parts[1..<(parts.count - 1)].joined(separator: "__")
    return "\(tool) · \(server)"
  }

  /// One call in words, `Edit, PTYBridge.swift`: two columns on screen, one sentence spoken.
  /// A call with no target says only its name.
  public var accessibilityLabel: String {
    guard let target, !target.isEmpty else { return name }
    return "\(name), \(target)"
  }
}

// MARK: - Which runs are open

/// Which runs of tool calls the reader has opened.
///
/// Stored on the model, not in `@State`, for two reasons:
///
/// - Open state survives switching to Terminal and back. The chat is a plain `if` in
///   `TerminalScreen.paneSurfaces` (hiding it with `opacity` left its rows in the
///   accessibility tree), so `PaneChatView` is rebuilt. `PaneTranscriptModel` outlives it.
/// - It must not survive a re-fetch that reuses the id for a different run. A run takes the
///   id of its opening record, so a grown or re-cut run comes back under the same id.
///
/// Storing the opened run itself, not a flag, handles both: staying open is `==`, and a
/// changed run is simply closed.
public struct OpenToolRuns: Equatable, Sendable {
  /// The run the reader opened, keyed by its turn. One entry per turn, so repeated re-reads
  /// cannot accumulate old runs.
  private var open: [String: ToolRun] = [:]

  public init() {}

  /// Whether this turn's run is the run that was opened. `false` for a turn with no run.
  public func isOpen(_ turn: TranscriptTurn) -> Bool {
    guard let run = turn.toolRun else { return false }
    return open[turn.id] == run
  }

  /// Opens a closed run, or closes an open one. A run the reader has not opened, including
  /// a different run under a reused id, opens.
  public mutating func toggle(_ turn: TranscriptTurn) {
    guard let run = turn.toolRun else { return }
    if open[turn.id] == run {
      open.removeValue(forKey: turn.id)
    } else {
      open[turn.id] = run
    }
  }
}
