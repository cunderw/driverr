import DriverrCore
import Foundation

/// herdr's wire format, and the only place in Driverr that knows it.
///
/// These types are `internal`, so the compiler enforces the layering rule in `CLAUDE.md`.
///
/// Fields Driverr does not use are absent, and used fields are optional unless herdr marks
/// them required. A snapshot that grows a field must keep decoding.
struct HerdrResponse<Result: Decodable & Sendable>: Decodable, Sendable {
  let id: String
  let result: Result
}

struct HerdrErrorResponse: Decodable, Sendable {
  struct Failure: Decodable, Sendable {
    let code: String?
    let message: String?
  }
  let id: String?
  let error: Failure
}

struct HerdrSnapshotResult: Decodable, Sendable {
  let snapshot: HerdrSessionSnapshot
}

struct HerdrSessionSnapshot: Decodable, Sendable {
  let version: String
  let protocolVersion: Int
  let workspaces: [HerdrWorkspace]
  let tabs: [HerdrTab]
  let panes: [HerdrPane]
  let agents: [HerdrAgent]
  let focusedPaneID: String?

  enum CodingKeys: String, CodingKey {
    case version
    case protocolVersion = "protocol"
    case workspaces, tabs, panes, agents
    case focusedPaneID = "focused_pane_id"
  }
}

struct HerdrWorkspace: Decodable, Sendable {
  let workspaceID: String
  let number: Int
  let label: String
  let focused: Bool
  let agentStatus: String?

  enum CodingKeys: String, CodingKey {
    case workspaceID = "workspace_id"
    case number, label, focused
    case agentStatus = "agent_status"
  }
}

struct HerdrTab: Decodable, Sendable {
  let tabID: String
  let workspaceID: String
  let number: Int
  let label: String
  let focused: Bool
  /// herdr's own roll-up for this tab, shown rather than recomputed from the panes.
  let agentStatus: String?

  enum CodingKeys: String, CodingKey {
    case tabID = "tab_id"
    case workspaceID = "workspace_id"
    case number, label, focused
    case agentStatus = "agent_status"
  }
}

/// The agent's own session reference, when a herdr integration reported one.
///
/// Reported on both the pane and the agent record, like `display_agent`. It needs an
/// installed integration, so absence is the ordinary case.
struct HerdrAgentSession: Decodable, Sendable {
  let agent: String?
  let kind: String?
  let value: String?
  let source: String?
}

struct HerdrPane: Decodable, Sendable {
  let paneID: String
  let tabID: String
  let workspaceID: String
  let focused: Bool
  let agentStatus: String
  /// What `herdr terminal attach` takes, which works for shell and agent panes alike.
  /// Optional, because protocol 19 requires it and the floor is 17.
  let terminalID: String?
  /// The pane's working directory, shown for a shell pane with no title.
  let cwd: String?
  let label: String?
  let title: String?
  let terminalTitleStripped: String?
  let terminalTitle: String?
  let agent: String?
  let displayAgent: String?
  /// Where the pane's viewport sits in its buffer, and how tall it is.
  ///
  /// Only `viewport_rows` is decoded, because it bounds a `pane read`. See
  /// `CLIControl.readScreenCommand`.
  let scroll: HerdrPaneScroll?
  let agentSession: HerdrAgentSession?

  enum CodingKeys: String, CodingKey {
    case paneID = "pane_id"
    case tabID = "tab_id"
    case workspaceID = "workspace_id"
    case focused
    case agentStatus = "agent_status"
    case terminalID = "terminal_id"
    case cwd
    case label, title, agent, scroll
    case terminalTitleStripped = "terminal_title_stripped"
    case terminalTitle = "terminal_title"
    case displayAgent = "display_agent"
    case agentSession = "agent_session"
  }
}

struct HerdrPaneScroll: Decodable, Sendable {
  let viewportRows: Int?

  enum CodingKeys: String, CodingKey {
    case viewportRows = "viewport_rows"
  }
}

/// An agent is reported *alongside* its pane rather than inside it, joined by `pane_id`.
///
/// Only the agent list says which agent runs, so it is joined to the pane.
struct HerdrAgent: Decodable, Sendable {
  let paneID: String
  let agentStatus: String
  let agent: String?
  let displayAgent: String?
  let name: String?
  let agentSession: HerdrAgentSession?

  enum CodingKeys: String, CodingKey {
    case paneID = "pane_id"
    case agentStatus = "agent_status"
    case agent, name
    case displayAgent = "display_agent"
    case agentSession = "agent_session"
  }
}
