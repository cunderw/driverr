/// Lifecycle state of a coding agent running in a herdr pane.
///
/// herdr's own five, spelled its way. `unknown` is not "no agent": herdr documents it as
/// "plain shell or unrecognized program", an agent whose output nothing recognised. No agent
/// is `Pane.agent == nil`. An unrecognised value degrades to `unknown` rather than failing
/// the snapshot decode.
public enum AgentStatus: String, Hashable, Codable, Sendable, CaseIterable {
  case blocked
  case done
  case working
  case idle
  case unknown

  public init(wireValue: String) {
    self = AgentStatus(rawValue: wireValue) ?? .unknown
  }

  /// Blocked sorts first, because it is the only state that is a request.
  ///
  /// `done` above `working` differs from herdr on purpose. On a phone a finished agent is
  /// news the user has not seen, while a working one has nothing to report yet.
  public var sortPriority: Int {
    switch self {
    case .blocked: 0
    case .done: 1
    case .working: 2
    case .idle: 3
    case .unknown: 4
    }
  }

  /// Where a pane with no agent sorts: after every agent state, even `unknown`, because a
  /// shell is nobody waiting. Not a case, because a shell has no lifecycle.
  public static let noAgentSortPriority = AgentStatus.allCases.count

  /// The bare status word for a row's subtitle: title case, not the wire token. Surfaces
  /// with a reason for a fuller sentence keep their own.
  public var displayName: String {
    switch self {
    case .blocked: "Blocked"
    case .done: "Done"
    case .working: "Working"
    case .idle: "Idle"
    case .unknown: "Unknown"
    }
  }
}
