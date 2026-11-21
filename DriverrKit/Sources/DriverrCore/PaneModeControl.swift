/// The chat's control that sends Shift-Tab, which cycles Claude Code's mode (manual, accept
/// edits, plan and any others the user has turned on).
///
/// The mode it shows comes from the pane's screen, not the session file, which Claude Code
/// writes the mode to only with the next prompt. See `ClaudeMode` and `PaneModeReading`.
public enum PaneModeControl: Equatable, Sendable {
  /// Not drawn: the pane is not Claude Code, or Shift would not survive the trip.
  case hidden
  case ready
  /// Drawn and disabled. Claude Code is asking something, and its permission prompt binds
  /// Shift-Tab to "Yes, and switch to accept edits", so a tap would approve.
  case blocked

  /// `deliversShiftTab` is the host's answer, from `HerdrAvailability.deliversShiftTab`.
  ///
  /// Claude Code is decided as the transcript reader decides it: the reported session's
  /// agent outranks the pane's slug.
  public init(pane: Pane, deliversShiftTab: Bool) {
    guard deliversShiftTab, let agent = pane.agent,
      let token = agent.session?.agent ?? agent.kind,
      TranscriptAgent(rawValue: token.lowercased()) == .claude
    else {
      self = .hidden
      return
    }
    self = agent.status == .blocked ? .blocked : .ready
  }

  /// The button's name, for VoiceOver and the tests.
  public static let label = "Change mode"
  /// What a tap does.
  public static let hint = "Sends Shift-Tab. Claude Code moves to its next mode."
  /// Why the button is off.
  public static let blockedHint = "Answer Claude first. Shift-Tab would approve its request."
}
