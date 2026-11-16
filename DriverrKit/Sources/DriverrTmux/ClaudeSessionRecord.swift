import DriverrCore
import Foundation

/// Claude Code's own record of one running process, `~/.claude/sessions/<pid>.json`.
///
/// tmux keeps no agent metadata, so this file is the only signal for which agent is in a pane
/// and whether it waits on the user. It exists while the process runs and goes when `/exit`
/// ends it. It is Claude Code's file and not a contract: every field is optional on read, and
/// a file that does not say who it is leaves the pane with no agent.
///
/// **A pure mapper over the file's bytes.** Reading the file is `TmuxControl`'s business.
public struct ClaudeSessionRecord: Equatable, Sendable {
  public let pid: Int?
  public let sessionID: String
  /// The raw word: `idle`, `busy` or `waiting`, and whatever a later Claude Code adds.
  public let status: String?
  /// What Claude says it waits for, such as `permission prompt` or `input needed`.
  ///
  /// **Display text only.** It was `dialog open` in the binary and never seen on the wire, so
  /// nothing may branch on it. `status == "waiting"` is the signal.
  public let waitingFor: String?
  public let directory: String?

  /// The words `status` takes that this build maps.
  public enum Word {
    public static let idle = "idle"
    public static let busy = "busy"
    public static let waiting = "waiting"
  }

  public init(
    pid: Int? = nil,
    sessionID: String,
    status: String? = nil,
    waitingFor: String? = nil,
    directory: String? = nil
  ) {
    self.pid = pid
    self.sessionID = sessionID
    self.status = status
    self.waitingFor = waitingFor
    self.directory = directory
  }

  private struct Wire: Decodable {
    let pid: Int?
    let sessionId: String?
    let status: String?
    let waitingFor: String?
    let cwd: String?
  }

  /// The record in `data`, or `nil` for anything that is not one: not JSON, no session id, or
  /// an id the reader could never match to a filename.
  ///
  /// Never throws and never crashes. A half-written file reads as `nil`, and the next poll
  /// reads it whole.
  public static func parse(_ data: Data) -> ClaudeSessionRecord? {
    guard let wire = try? JSONDecoder().decode(Wire.self, from: data),
      let id = wire.sessionId, isSessionID(id)
    else { return nil }
    return ClaudeSessionRecord(
      pid: wire.pid,
      sessionID: id,
      status: nonEmpty(wire.status),
      waitingFor: nonEmpty(wire.waitingFor),
      directory: nonEmpty(wire.cwd)
    )
  }

  /// What the record says the agent is doing.
  ///
  /// `waiting` is `blocked`. A word this build does not know is `unknown`, which keeps the
  /// pane an agent without making it a request.
  public var agentStatus: AgentStatus {
    switch status {
    case Word.idle: .idle
    case Word.busy: .working
    case Word.waiting: .blocked
    default: .unknown
    }
  }

  /// The agent this record describes.
  public var agent: Agent {
    Agent(
      name: "Claude",
      kind: TranscriptAgent.claude.rawValue,
      status: agentStatus,
      session: AgentSession(
        agent: TranscriptAgent.claude.rawValue,
        kind: "id",
        value: sessionID,
        source: AgentSession.claudeRecordSource
      )
    )
  }

  /// The reader refuses the same ids, in `CoreSessionFiles`.
  private static func isSessionID(_ id: String) -> Bool {
    !id.isEmpty && !id.contains("/") && id == id.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func nonEmpty(_ text: String?) -> String? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}
