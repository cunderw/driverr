/// What an agent's state looks like: the one definition.
///
/// The app and `DriverrWatch` both draw badges and the extension cannot import the app, so
/// the glyph and hue pairing lives here, where both link it. The hue is a role, not a
/// `Color`, because this module has no SwiftUI. Each target maps `AgentStatusHue` with an
/// exhaustive `switch`, so a new hue breaks both compiles rather than drifting in one.
extension AgentStatus {
  /// The SF Symbol for this state.
  ///
  /// Blocked gets the only filled, high-contrast shape, because it must be findable across
  /// a screen of rows. `working`'s half-filled circle is a partial fill on purpose; a dotted
  /// circle was too faint to tell from `idle` at row size.
  public var symbolName: String {
    switch self {
    case .blocked: "exclamationmark.circle.fill"
    case .error: "exclamationmark.triangle"
    case .done: "checkmark.circle"
    case .working: "circle.lefthalf.filled"
    case .idle: "circle"
    case .unknown: "questionmark.circle"
    }
  }

  /// herdr's hue **role** for this state.
  ///
  /// herdr's palette cannot be matched literally: it is 24-bit hex, per theme, and
  /// user-overridable. The stable part is which role each hue plays (red wants you, green is
  /// at rest), so that is what Driverr matches. Each target resolves the role to a system
  /// colour, which works in both appearances and under Increase Contrast.
  public var hue: AgentStatusHue {
    switch self {
    case .blocked: .red
    // Not red: red is "wants you", and a failed agent is not asking for anything.
    case .error: .orange
    case .done: .teal
    case .working: .yellow
    case .idle: .green
    // No hue: herdr cannot say what this agent is doing, and a colour would claim otherwise.
    case .unknown: .neutral
    }
  }

  /// Said the way a person would, not the way the wire spells it.
  ///
  /// What VoiceOver reads off a badge. `displayName` is the bare word for a row's subtitle;
  /// this is the phrase.
  public var accessibleName: String {
    switch self {
    case .blocked: "Waiting for you"
    case .error: "Failed"
    case .done: "Finished"
    case .working: "Working"
    case .idle: "Idle"
    case .unknown: "State unclear"
    }
  }
}

/// The hue roles a status badge can carry, named by role rather than by colour value.
///
/// `neutral` is the absence of a hue: what `unknown` wears, drawn as the platform's secondary
/// colour.
public enum AgentStatusHue: Hashable, Sendable {
  case red
  case orange
  case teal
  case yellow
  case green
  case neutral
}
