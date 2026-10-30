/// Lifecycle state of a coding agent running in a herdr pane.
///
/// herdr's own five, spelled its way, and `error`, which only a program reporting to
/// herdr-core says. `unknown` is not "no agent": herdr documents it as "plain shell or
/// unrecognized program", an agent whose output nothing recognised. No agent is
/// `Pane.agent == nil`. An unrecognised value degrades to `unknown` rather than failing the
/// snapshot decode.
public enum AgentStatus: String, Hashable, Codable, Sendable, CaseIterable {
  case blocked
  case error
  case done
  case working
  case idle
  case unknown

  public init(wireValue: String) {
    self = AgentStatus(rawValue: wireValue) ?? .unknown
  }

  /// Blocked sorts first, because it is the only state that is a request.
  ///
  /// `error` is next and is not a request: nothing is waiting on the reader, so it stays out
  /// of `SessionTree.blockedPanes`, and out of notifications and the Live Activity with it.
  ///
  /// `done` above `working` differs from herdr on purpose. On a phone a finished agent is
  /// news the user has not seen, while a working one has nothing to report yet.
  public var sortPriority: Int {
    switch self {
    case .blocked: 0
    case .error: 1
    case .done: 2
    case .working: 3
    case .idle: 4
    case .unknown: 5
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
    case .error: "Failed"
    case .done: "Done"
    case .working: "Working"
    case .idle: "Idle"
    case .unknown: "Unknown"
    }
  }
}
