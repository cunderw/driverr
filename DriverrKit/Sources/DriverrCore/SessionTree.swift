/// The agent's own session, as its herdr integration reported it.
///
/// The exact answer to "which transcript is this pane's", with no heuristic. Absent unless
/// the user installed a herdr integration for the agent, which for Claude Code is optional,
/// so Driverr cannot assume it.
public struct AgentSession: Hashable, Sendable {
  /// herdr's token for the agent, `claude`. Trusted over the pane's own agent slug.
  public let agent: String
  /// What `value` is. Only `id` is interpreted; anything else is carried.
  public let kind: String
  public let value: String
  /// Where herdr got it, such as `herdr:claude`.
  public let source: String?

  public init(agent: String, kind: String, value: String, source: String? = nil) {
    self.agent = agent
    self.kind = kind
    self.value = value
    self.source = source
  }

  /// The session identifier, or `nil` for any `kind` this build does not understand, so an
  /// unknown token is never treated as a filename.
  public var identifier: String? {
    kind == "id" && !value.isEmpty ? value : nil
  }
}

/// A coding agent herdr recognised in a pane, and what it is doing.
///
/// Name, status, `kind` and `session` travel together so that a shell pane with a status
/// or a session cannot be represented. herdr also reports them together.
public struct Agent: Hashable, Sendable {
  /// How to say the agent's name — "Claude", not the wire's `claude`.
  public let name: String
  /// herdr's token for the agent, `claude` or `codex`. `name` is presentable and cannot be
  /// turned back.
  ///
  /// The transcript reader needs it: pointing a Codex pane at `~/.claude/projects` could
  /// draw another agent's conversation. `nil` when herdr named the agent without a slug.
  public let kind: String?
  public let status: AgentStatus
  /// The agent's own session, when a herdr integration reported one. See `AgentSession`.
  public let session: AgentSession?

  public init(
    name: String,
    kind: String? = nil,
    status: AgentStatus,
    session: AgentSession? = nil
  ) {
    self.name = name
    self.kind = kind
    self.status = status
    self.session = session
  }
}

/// One pane in a herdr session: the leaf the sidebar shows and the terminal attaches to.
public struct Pane: Identifiable, Hashable, Sendable {
  public let id: String
  public let tabID: String
  public let workspaceID: String
  /// What to show for it. herdr offers a label, a terminal title and a stripped title, and
  /// the choice is made once, at the mapping boundary.
  public let title: String
  /// The coding agent running here, or `nil` for a plain shell, which is the common case.
  public let agent: Agent?
  /// herdr's id for the terminal behind this pane, which `herdr terminal attach` takes.
  ///
  /// Attaching by pane goes through `agent.get`, which fails on a pane with no agent.
  /// Optional because herdr requires the field only from protocol 19 and Driverr supports
  /// 17. Callers fall back to the pane id.
  public let terminalID: String?
  /// The pane's working directory. Optional like every wire field, so a snapshot without
  /// it still decodes. It is the subtitle for a shell pane.
  public let directory: String?
  public let isFocused: Bool
  /// How many rows this pane's screen has, from `scroll.viewport_rows`.
  ///
  /// The bound on a read. Asking `pane read` for more lines than the pane has returns the
  /// same bytes and costs about 420 ms instead of 30 ms, because herdr scrolls to capture.
  /// With no bound, a reader passes no `--lines` rather than guessing.
  public let viewportRows: Int?

  public init(
    id: String,
    tabID: String,
    workspaceID: String,
    title: String,
    agent: Agent? = nil,
    terminalID: String? = nil,
    directory: String? = nil,
    isFocused: Bool = false,
    viewportRows: Int? = nil
  ) {
    self.id = id
    self.tabID = tabID
    self.workspaceID = workspaceID
    self.title = title
    self.agent = agent
    self.terminalID = terminalID
    self.directory = directory
    self.isFocused = isFocused
    self.viewportRows = viewportRows
  }

  /// Where this pane sorts against its siblings: its agent's urgency, or behind every
  /// agent for a shell.
  public var sortPriority: Int {
    agent?.status.sortPriority ?? AgentStatus.noAgentSortPriority
  }

  /// What tells this pane apart from a later pane that reuses its id.
  ///
  /// herdr's pane ids are positional (`w1:p2`) and are reused when a session is rebuilt.
  /// `BlockedPaneActivityRoute.resumed` checks this beside the id.
  ///
  /// `terminalID` first. herdr allocates it from the clock and a counter and never derives
  /// it from position (`herdr/src/terminal/id.rs`), including on restore from persistence,
  /// so a rebuilt session cannot reproduce it. It survives a program respawning in the pane.
  ///
  /// `directory` second, for a herdr too old to send a terminal id. It misses a rebuild that
  /// reopened the same project in the same slot, but catches the common case.
  ///
  /// Not `agent?.session?.identifier`: restarting Claude in an unmoved pane changes it.
  ///
  /// `nil` when herdr reports neither, and the pane is then not remembered. See
  /// `ConnectionModel.noteLastPane`.
  public var sessionWitness: String? {
    if let terminalID, !terminalID.isEmpty { return terminalID }
    if let directory, !directory.isEmpty { return directory }
    return nil
  }
}

public struct Tab: Identifiable, Hashable, Sendable {
  public let id: String
  public let workspaceID: String
  public let number: Int
  public let label: String
  public let isFocused: Bool
  /// The most urgent agent under this tab, as herdr reported it, or `nil` with no agent.
  ///
  /// Stored, not recomputed, so every client agrees with herdr's roll-up. `nil` keeps a tab
  /// of shells from wearing a badge.
  public let status: AgentStatus?
  /// Whether herdr named this tab rather than the user. Drives `Workspace.showsTabHeaders`,
  /// so the view does not match strings.
  public let isAutoNamed: Bool
  public let panes: [Pane]

  public init(
    id: String,
    workspaceID: String,
    number: Int,
    label: String,
    isFocused: Bool = false,
    status: AgentStatus? = nil,
    isAutoNamed: Bool = false,
    panes: [Pane] = []
  ) {
    self.id = id
    self.workspaceID = workspaceID
    self.number = number
    self.label = label
    self.isFocused = isFocused
    self.status = status
    self.isAutoNamed = isAutoNamed
    self.panes = panes
  }

  /// This tab's panes, blocked first. Panes never leave their tab.
  public var panesByUrgency: [Pane] { sortedByUrgency(panes) }
}

/// Blocked first, then done, working, idle and unknown, then panes with no agent.
///
/// Stable, so a list does not reshuffle whenever an unrelated agent changes state. Swift's
/// `sorted(by:)` is not stable, hence the index tie-break.
func sortedByUrgency(_ panes: [Pane]) -> [Pane] {
  panes.enumerated()
    .sorted {
      $0.element.sortPriority == $1.element.sortPriority
        ? $0.offset < $1.offset
        : $0.element.sortPriority < $1.element.sortPriority
    }
    .map(\.element)
}

public struct Workspace: Identifiable, Hashable, Sendable {
  public let id: String
  public let number: Int
  public let label: String
  public let isFocused: Bool
  /// herdr's roll-up for this workspace, or `nil` with no agent. See `Tab.status`.
  public let status: AgentStatus?
  public let tabs: [Tab]

  public init(
    id: String,
    number: Int,
    label: String,
    isFocused: Bool = false,
    status: AgentStatus? = nil,
    tabs: [Tab] = []
  ) {
    self.id = id
    self.number = number
    self.label = label
    self.isFocused = isFocused
    self.status = status
    self.tabs = tabs
  }

  /// Whether this workspace's tab level is worth drawing. One tab herdr named itself adds
  /// nothing and costs a row. Two tabs, or a name the user typed, earn headers.
  public var showsTabHeaders: Bool {
    tabs.count > 1 || tabs.contains { !$0.isAutoNamed }
  }

  /// How the tab level is drawn, so the view only switches.
  ///
  /// One tab that earns its name does not earn a row, so it folds into the workspace row.
  /// Deriving this from `tabs.count` in the view drew a single auto-named tab as
  /// "driverr · Tab 1", the row `showsTabHeaders` suppresses.
  public var tabHeaderStyle: TabHeaderStyle {
    guard showsTabHeaders else { return .none }
    return tabs.count > 1 ? .headers : .inline
  }
}

/// What a workspace row does with the tab level under it. Three cases, because a tab can
/// be worth naming without being worth a row.
public enum TabHeaderStyle: Hashable, Sendable {
  /// No tab level: one tab, named by herdr after its position.
  case none
  /// Folded into the workspace row as "driverr · app": one tab, named by the user.
  case inline
  /// A header row per tab: two or more tabs.
  case headers
}

/// How many panes are in each `AgentStatus`, plus how many have no agent.
///
/// Shared by `SessionTree.agentStatusCounts` and `HostStatus`, so the host row's sentence
/// cannot drift from the tree's counts.
public struct AgentStatusCounts: Codable, Hashable, Sendable {
  public var blocked: Int
  public var done: Int
  public var working: Int
  public var idle: Int
  public var unknown: Int
  /// Panes with no agent. A shell has no lifecycle, so this is not an `AgentStatus` case.
  public var shells: Int

  public init(
    blocked: Int = 0,
    done: Int = 0,
    working: Int = 0,
    idle: Int = 0,
    unknown: Int = 0,
    shells: Int = 0
  ) {
    self.blocked = blocked
    self.done = done
    self.working = working
    self.idle = idle
    self.unknown = unknown
    self.shells = shells
  }

  /// "Nothing needs you · 2 working · 1 finished", so the app has something to say when
  /// nothing is blocked.
  ///
  /// `nil` when anything is blocked, because the blocked panes are the answer then. Zero
  /// counts are left out. The host row and the session tree both read this, so they word
  /// the same state the same way.
  public var calmSummary: String? {
    guard blocked == 0 else { return nil }
    var parts = ["Nothing needs you"]
    if working > 0 { parts.append("\(working) working") }
    if done > 0 { parts.append("\(done) finished") }
    if idle > 0 { parts.append("\(idle) idle") }
    if shells > 0 { parts.append("\(shells) \(shells == 1 ? "shell" : "shells")") }
    return parts.joined(separator: " · ")
  }

  /// The same clauses, for a Live Activity's second line.
  ///
  /// No "Nothing needs you" prefix, because the card's headline says it, and no blocked
  /// guard, because an escalated card still words its calm panes. An empty card says
  /// "Connected". `calmSummary` stays separate so two other screens do not change with it.
  public var activitySummary: String {
    var parts: [String] = []
    if working > 0 { parts.append("\(working) working") }
    if done > 0 { parts.append("\(done) finished") }
    if idle > 0 { parts.append("\(idle) idle") }
    if shells > 0 { parts.append("\(shells) \(shells == 1 ? "shell" : "shells")") }
    return parts.isEmpty ? "Connected" : parts.joined(separator: " · ")
  }

  /// Two hosts' panes as one set of numbers, for the aggregated card.
  public static func + (lhs: Self, rhs: Self) -> Self {
    AgentStatusCounts(
      blocked: lhs.blocked + rhs.blocked,
      done: lhs.done + rhs.done,
      working: lhs.working + rhs.working,
      idle: lhs.idle + rhs.idle,
      unknown: lhs.unknown + rhs.unknown,
      shells: lhs.shells + rhs.shells
    )
  }
}

/// A herdr session as a tree.
///
/// herdr's `session.snapshot` is four flat arrays joined by id. The tree is assembled once
/// at the module boundary, so the sidebar is a plain rendering and the assembly is testable.
public struct SessionTree: Hashable, Sendable {
  public let workspaces: [Workspace]
  public let focusedPaneID: String?

  public init(workspaces: [Workspace] = [], focusedPaneID: String? = nil) {
    self.workspaces = workspaces
    self.focusedPaneID = focusedPaneID
  }

  public static let empty = SessionTree()

  public var isEmpty: Bool { workspaces.isEmpty }

  /// Every pane, depth-first, in the order the tree presents them.
  public var allPanes: [Pane] {
    workspaces.flatMap { $0.tabs.flatMap(\.panes) }
  }

  public func pane(id: String) -> Pane? {
    allPanes.first { $0.id == id }
  }

  /// Blocked first, then done, working and idle. Ties keep herdr's order.
  public var panesByUrgency: [Pane] { sortedByUrgency(allPanes) }

  /// Only the panes waiting on a human, in tree order. The sidebar's top section.
  ///
  /// Only an agent can be blocked. herdr derives blocked from known agent output patterns,
  /// and a shell at a `[Y/n]` prompt is `unknown`, so it never appears here. That is herdr's
  /// limit, not a bug.
  public var blockedPanes: [Pane] {
    allPanes.filter { $0.agent?.status == .blocked }
  }

  /// The one pane waiting on a human, when exactly one is. It makes the host list's `1`
  /// badge a tap target with one destination.
  ///
  /// `nil` for two or more, because guessing which one was meant would often be wrong. `nil`
  /// for zero too, and then there is no badge.
  public var loneBlockedPane: Pane? {
    let blocked = blockedPanes
    return blocked.count == 1 ? blocked.first : nil
  }

  /// How many of this tree's panes are in each state, shells included. Zero counts are
  /// ordinary, and `HostStatus.calmSummary` leaves them out.
  public var agentStatusCounts: AgentStatusCounts {
    var counts = AgentStatusCounts()
    for pane in allPanes {
      guard let status = pane.agent?.status else {
        counts.shells += 1
        continue
      }
      switch status {
      case .blocked: counts.blocked += 1
      case .done: counts.done += 1
      case .working: counts.working += 1
      case .idle: counts.idle += 1
      case .unknown: counts.unknown += 1
      }
    }
    return counts
  }

  /// The workspaces a freshly loaded tree opens with: the focused one, and only it.
  ///
  /// Also expanding workspaces with blocked or done panes buries the rest, and blocked panes
  /// already appear in "Needs you". The fallbacks matter: herdr may report no focused
  /// workspace, and a fully collapsed tree reads as an empty session.
  public var defaultExpandedWorkspaceIDs: Set<String> {
    if let focused = workspaces.first(where: \.isFocused) {
      return [focused.id]
    }
    // No focused workspace, but a focused pane: open the workspace that holds it.
    if let focusedPaneID,
      let owner = workspaces.first(where: { $0.tabs.contains { $0.panes.contains { $0.id == focusedPaneID } } })
    {
      return [owner.id]
    }
    // Neither. Open the first, because an all-closed tree looks empty.
    return Set(workspaces.first.map { [$0.id] } ?? [])
  }

  /// Where a pane lives, for a row outside the tree: "myproject › 2: tests".
  public func location(of pane: Pane) -> String? {
    guard let workspace = workspaces.first(where: { $0.id == pane.workspaceID }),
      let tab = workspace.tabs.first(where: { $0.id == pane.tabID })
    else { return nil }
    return "\(workspace.label) › \(tab.label)"
  }
}
