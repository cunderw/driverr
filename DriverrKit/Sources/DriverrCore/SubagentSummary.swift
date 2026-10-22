import Foundation

/// One sub-agent a session spawned, read off its `.meta.json` rather than the page.
///
/// **The meta file, not the page**, because a spawn line scrolls off a long session's first
/// page and an agent spawned hours ago would then be unlisted. The page still knows more
/// about a spawn it carries, so `SubagentList.rows(merging:asOf:)` prefers it.
///
/// The fields are the meta file's own, version-scoped to Claude Code as of 2026-10-22:
///
/// - A plain `Agent` call writes `agentType`, `description`, `toolUseId` and, for some
///   background spawns, `finished: true`. It writes no `name`.
/// - An in-process teammate writes `name`, `description` and `agentType`, which is **its
///   name again**; the type it was spawned as is `spawnedAgentType` or `customAgentType`.
///   It writes no `toolUseId` and no `finished`.
public struct SubagentSummary: Identifiable, Hashable, Sendable {
  /// The `agentId` in the file's name, `agent-<agentId>.jsonl`.
  public let id: String
  /// The name a teammate was spawned under. `nil` for a plain `Agent` call.
  public let name: String?
  public let description: String?
  /// What kind of agent it is (`Explore`, `executor`), never a teammate's name.
  public let agentType: String?
  /// The spawn's `tool_use` id, which only a plain `Agent` call's meta carries.
  public let toolUseID: String?
  /// The meta file's `finished`. Written `true` by some background spawns and never `false`,
  /// so its absence says nothing.
  public let isFinished: Bool
  /// When the agent was spawned: the `timestamp` of the first record in its own file, which
  /// nothing later rewrites. Not the meta file's mtime, which Claude Code rewrites when a
  /// background agent finishes and when a teammate is woken. Phone clock, by the host's
  /// subtraction. See `TranscriptCommands.subagentListCommand` for the fallbacks.
  public let spawnedAt: Date?
  /// When the agent's own `.jsonl` was last written. Phone clock, from the host's age. `nil`
  /// while the file does not exist yet.
  public let writtenAt: Date?

  public init(
    id: String,
    name: String? = nil,
    description: String? = nil,
    agentType: String? = nil,
    toolUseID: String? = nil,
    isFinished: Bool = false,
    spawnedAt: Date? = nil,
    writtenAt: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.agentType = agentType
    self.toolUseID = toolUseID
    self.isFinished = isFinished
    self.spawnedAt = spawnedAt
    self.writtenAt = writtenAt
  }

  /// What a row and the back bar call it: the name, else the type, else the description.
  public var title: String {
    name ?? agentType ?? description ?? id
  }

  /// Which file a tap opens: this agent's own, by its `agentId`. A teammate respawned under
  /// one name has a file per spawn, and each row opens its own.
  public var link: SubagentLink { .agent(id: id) }

  /// The link a spawn line on the page carries for this agent, for a page whose spawn answer
  /// gave no `agentId` to join by: the `toolUseId` when there is one, a teammate's name
  /// otherwise. See `TranscriptParser.subagentLink`.
  public var pageLink: SubagentLink? {
    if let toolUseID { return .toolUse(id: toolUseID) }
    if let name { return .teammate(name: name) }
    return nil
  }
}

/// A session's sub-agents as the host listed them.
public struct SubagentList: Hashable, Sendable {
  /// How many meta files the session holds. At least `summaries.count`; more when the host
  /// capped the listing.
  public let total: Int
  /// Newest spawned first, by `SubagentSummary.spawnedAt`. A spawn time never changes, so a
  /// row moves only when a newer spawn arrives above it, not when an agent writes, finishes or
  /// is woken.
  public let summaries: [SubagentSummary]

  public init(total: Int, summaries: [SubagentSummary]) {
    self.total = max(total, summaries.count)
    self.summaries = summaries.sorted { ($0.spawnedAt ?? .distantPast) > ($1.spawnedAt ?? .distantPast) }
  }

  public static let empty = SubagentList(total: 0, summaries: [])

  public var isEmpty: Bool { total == 0 }

  /// How recently an agent's file must have been written for a row with nothing better to
  /// read as running. `TranscriptFile.isLive`'s window, for the same reason.
  public static let liveWindow: TimeInterval = 60

  /// One row per summary, with the state taken from the page where the page carries the
  /// spawn.
  ///
  /// In order: the row's own spawn line on the page; the meta's `finished`; a file written
  /// within `liveWindow`, as running. Otherwise **no state**: a quiet teammate may be idle or
  /// done, and the row says only when it was last written.
  ///
  /// **Each row takes its own spawn line.** A spawn line whose answer gave an `agentId` joins
  /// the row with that id. One without (an older Claude Code wrote a teammate's id as
  /// `name@team`) joins by `pageLink`, and when several rows share it, as a teammate
  /// respawned under one name does, the newest spawn line goes to the newest row, the next to
  /// the next, and a row left over takes nothing from the page.
  public func rows(merging turns: [TranscriptTurn], asOf now: Date) -> [SubagentRow] {
    let ids = Set(summaries.map(\.id))
    var byAgent: [String: TaskProgress] = [:]
    /// Newest spawn line first.
    var byLink: [SubagentLink: [TaskProgress]] = [:]
    for turn in turns.reversed() {
      guard let event = turn.agentEvent, event.kind == .spawned, let task = event.task
      else { continue }
      if let agentID = event.agentID, ids.contains(agentID) {
        if byAgent[agentID] == nil { byAgent[agentID] = task }
      } else if let link = event.link {
        byLink[link, default: []].append(task)
      }
    }
    return summaries.map { summary in
      var task = byAgent[summary.id]
      if task == nil, let link = summary.pageLink, var queue = byLink[link], !queue.isEmpty {
        task = queue.removeFirst()
        byLink[link] = queue
      }
      if let task {
        return SubagentRow(summary: summary, task: task, state: task.state)
      }
      if summary.isFinished {
        return SubagentRow(summary: summary, task: nil, state: .finished)
      }
      if let writtenAt = summary.writtenAt, now.timeIntervalSince(writtenAt) < Self.liveWindow {
        return SubagentRow(summary: summary, task: nil, state: .running)
      }
      return SubagentRow(summary: summary, task: nil, state: nil)
    }
  }
}

/// One line of the chat's sub-agent list.
public struct SubagentRow: Identifiable, Hashable, Sendable {
  public let summary: SubagentSummary
  /// The page's spawn line's progress, when the page carries the spawn.
  public let task: TaskProgress?
  /// `nil` when nothing says.
  public let state: TaskProgress.State?

  public init(summary: SubagentSummary, task: TaskProgress?, state: TaskProgress.State?) {
    self.summary = summary
    self.task = task
    self.state = state
  }

  public var id: String { summary.id }

  /// `Running · 3m` from the page; `Finished · 2h ago` or `Running` from the meta and the
  /// file; `Written 2h ago` when nothing says more.
  public func statusLine(asOf now: Date) -> String {
    if let task { return task.label(asOf: now) }
    let written = summary.writtenAt.map { TranscriptAge.elapsed(now.timeIntervalSince($0)) }
    switch state {
    case .finished:
      guard let written else { return TranscriptChatCopy.taskFinished }
      return
        "\(TranscriptChatCopy.taskFinished) \(TranscriptChatCopy.agentEventSeparator) \(Self.ago(written))"
    case .running:
      return TranscriptChatCopy.taskRunning
    default:
      guard let written else { return TranscriptChatCopy.subagentNotStarted }
      return "\(TranscriptChatCopy.subagentWritten) \(Self.ago(written))"
    }
  }

  /// `3h ago`, or `just now`, which takes no `ago`.
  private static func ago(_ elapsed: String) -> String {
    elapsed == TranscriptAge.justNow ? elapsed : "\(elapsed) ago"
  }

  /// The row read as one statement.
  public func accessibilityLabel(asOf now: Date) -> String {
    [summary.title, summary.description, statusLine(asOf: now)]
      .compactMap { $0 }.joined(separator: ", ")
  }
}

extension TranscriptChatCopy {
  /// A row whose agent has no file yet.
  public static let subagentNotStarted = "Starting"
  /// A row nothing says more about than when its file was written.
  public static let subagentWritten = "Written"
  /// The list's header button, for VoiceOver's hint.
  public static let subagentListHint = "Shows the agents this session started"

  /// The open list's foot when the host capped it: the rows are the newest spawns.
  public static func subagentListCapped(shown: Int, of total: Int) -> String {
    "The newest \(shown) of \(total)"
  }

  /// `3 sub-agents · 1 running`, or `1 sub-agent` when none is running.
  public static func subagentCount(total: Int, running: Int) -> String {
    let count = total == 1 ? "1 sub-agent" : "\(total) sub-agents"
    guard running > 0 else { return count }
    return "\(count) \(agentEventSeparator) \(running) running"
  }
}
