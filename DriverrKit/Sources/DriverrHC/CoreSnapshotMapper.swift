import DriverrCore
import DriverrHerdr
import Foundation

/// Turns `terminal.list` into the tree the app draws.
///
/// **Labels build the groups.** A core is flat terminals. The desktop app labels the ones it
/// opens with `herdr.space` and `herdr.tab`, and those are the workspaces and tabs. Anything
/// else is one flat group. Machines the core added follow its own terminals, each its own
/// groups, because the desktop app's document describes only this core.
///
/// **The document only orders and names.** It is the app's private format, so a tree built
/// without it holds the same terminals in the same groups. See `CoreAppDocument`.
///
/// **A status makes an agent.** Status comes only from OSC 7501, so a terminal with none is a
/// plain shell, whatever it is running. `reported` is not read: a program that reported once
/// and has since cleared its status is no agent now.
enum CoreSnapshotMapper {
  private typealias Group<Key: Hashable> = (key: Key, terminals: [CoreTerminal])
  private typealias Index = CoreAppDocument.Index

  /// What herdr-app's `programs.json` calls the agents Driverr has a reason to tell apart,
  /// by every name a program reports itself under. `kind` is the token `TranscriptReader`
  /// looks up.
  private static let programs: [String: (kind: String, name: String)] = [
    "claude": ("claude", "Claude"),
    "claude-code": ("claude", "Claude"),
    "codex": ("codex", "Codex"),
    "cursor": ("cursor", "Cursor"),
    "cursor-agent": ("cursor", "Cursor"),
    "copilot": ("copilot", "Copilot"),
    "github-copilot": ("copilot", "Copilot"),
    "antigravity": ("antigravity", "Antigravity"),
    "agy": ("antigravity", "Antigravity"),
  ]

  /// `sessions` holds each Claude terminal's session id, by address. See `CoreSessionFiles`.
  static func tree(
    from list: CoreListResult,
    document: CoreAppDocument? = nil,
    sessions: [String: String] = [:]
  ) -> SessionTree {
    let index = Index(document)
    let machines = ordered(grouped(list.terminals, by: machine)) { $0.key == nil ? 0 : nil }
    return SessionTree(
      workspaces: machines.flatMap { machine in
        let index = machine.key == nil ? index : Index(nil)
        return workspaces(machine.terminals, on: machine.key, index: index, sessions: sessions)
      }
    )
  }

  /// One machine's groups: spaces the document lists in its order, then the rest as seen.
  private static func workspaces(
    _ terminals: [CoreTerminal],
    on machine: String?,
    index: Index,
    sessions: [String: String]
  ) -> [Workspace] {
    let prefix = CorePaneID.prefix + (machine.map { $0 + "/" } ?? "")
    let spaces = ordered(grouped(terminals) { label("herdr.space", of: $0) }) { space in
      space.key.flatMap { index.spaceRanks[$0] }
    }
    return spaces.enumerated().map { offset, space in
      guard let key = space.key else {
        return flatWorkspace(
          space.terminals, on: machine, prefix: prefix, number: offset + 1, sessions: sessions)
      }
      let id = prefix + key
      let tabs = ordered(grouped(space.terminals) { label("herdr.tab", of: $0) }) { tab in
        tab.key.flatMap { index.tabRanks[$0] }
      }
      .enumerated().map { offset, tab in
        self.tab(
          tab, inSpace: key, id: id, prefix: prefix, number: offset + 1, index: index,
          sessions: sessions)
      }
      let name =
        index.names[key] ?? place(among: space.terminals, \.space) ?? "Space \(offset + 1)"
      return Workspace(
        id: id,
        number: offset + 1,
        label: [machine, name].compactMap { $0 }.joined(separator: " · "),
        status: rollUp(tabs.flatMap(\.panes)),
        tabs: tabs
      )
    }
  }

  /// A terminal with no space label. No tab level, because there is nothing to say at one.
  private static func flatWorkspace(
    _ terminals: [CoreTerminal],
    on machine: String?,
    prefix: String,
    number: Int,
    sessions: [String: String]
  ) -> Workspace {
    let workspaceID = prefix + "workspace"
    let tabID = prefix + "tab"
    let panes = terminals.map {
      pane(of: $0, tabID: tabID, workspaceID: workspaceID, sessions: sessions)
    }
    return Workspace(
      id: workspaceID,
      number: number,
      label: machine ?? "herdr-core",
      status: rollUp(panes),
      tabs: [
        Tab(
          id: tabID,
          workspaceID: workspaceID,
          number: 1,
          label: "Terminals",
          status: rollUp(panes),
          isAutoNamed: true,
          panes: panes
        )
      ]
    )
  }

  private static func tab(
    _ tab: Group<String?>,
    inSpace space: String,
    id workspaceID: String,
    prefix: String,
    number: Int,
    index: Index,
    sessions: [String: String]
  ) -> Tab {
    let id = prefix + (tab.key ?? space + ".tab")
    let panes = ordered(tab.terminals) { index.terminalRanks[$0.address] }
      .map { pane(of: $0, tabID: id, workspaceID: workspaceID, sessions: sessions) }
    let name = tab.key.flatMap { index.names[$0] } ?? place(among: tab.terminals, \.tab)
    // The app numbers an unnamed tab, as herdr does.
    let isAutoNamed = name?.allSatisfy(\.isWholeNumber) ?? true
    return Tab(
      id: id,
      workspaceID: workspaceID,
      number: number,
      label: isAutoNamed ? "Tab \(name ?? String(number))" : name ?? "",
      status: rollUp(panes),
      isAutoNamed: isAutoNamed,
      panes: panes
    )
  }

  private static func pane(
    of terminal: CoreTerminal,
    tabID: String,
    workspaceID: String,
    sessions: [String: String]
  ) -> Pane {
    Pane(
      id: CorePaneID.id(forAddress: terminal.address),
      tabID: tabID,
      workspaceID: workspaceID,
      title: title(of: terminal),
      agent: agent(of: terminal, sessions: sessions),
      terminalID: terminal.address,
      directory: directory(of: terminal),
      viewportRows: terminal.rows
    )
  }

  /// Whether this terminal's pane is Claude on this core. Asks `agent(of:sessions:)`, so a
  /// shell or an added machine is never read for.
  static func isLocalClaude(_ terminal: CoreTerminal) -> Bool {
    agent(of: terminal, sessions: [:])?.kind == TranscriptAgent.claude.rawValue
  }

  /// The agent a status says is there.
  ///
  /// `kind` is never `nil` or empty, because `TranscriptReader` then matches on the name and
  /// `claude-helper` would be handed Claude's files. No app is `unknown`, which is herdr-app's
  /// word too, unless what is in the foreground is a program Driverr knows. A status is still
  /// what makes an agent, so `claude` running with none stays a shell.
  ///
  /// `sessions` only ever holds Claude's. Codex keeps no file that names a process's session,
  /// so its panes take the reader's directory match.
  ///
  /// A terminal on a machine the core added is `unknown` whatever it runs, keeps its name, and
  /// says which machine. The reader lists the SSH host's files, so a real `kind` there would
  /// show this host's conversation for the same directory on the other machine.
  private static func agent(of terminal: CoreTerminal, sessions: [String: String]) -> Agent? {
    guard let report = terminal.status else { return nil }
    let status = AgentStatus(wireValue: report.state ?? "")
    let app = report.app?.trimmingCharacters(in: .whitespacesAndNewlines)
    let reported = app?.isEmpty == false ? app : nil
    let foreground = terminal.foreground?.argv?.first.map(commandName)
    let program = (reported ?? foreground).flatMap { programs[$0.lowercased()] }
    let machine = machine(of: terminal)
    let kind = machine == nil ? program?.kind ?? reported?.lowercased() : nil
    return Agent(
      name: program?.name ?? reported ?? "Agent",
      kind: kind ?? "unknown",
      status: status,
      session: sessions[terminal.address].map(session),
      blockedKind:
        status == .blocked ? report.kind.flatMap(AgentBlockedKind.init(rawValue:)) : nil,
      machine: machine
    )
  }

  private static func session(_ id: String) -> AgentSession {
    AgentSession(
      agent: TranscriptAgent.claude.rawValue, kind: "id", value: id, source: "claude:sessions")
  }

  /// The most urgent agent under these panes, or `nil` when none has one. herdr-core rolls
  /// nothing up, so this is the only place it happens.
  private static func rollUp(_ panes: [Pane]) -> AgentStatus? {
    panes.compactMap { $0.agent?.status }.min { $0.sortPriority < $1.sortPriority }
  }

  /// The machine in `machine/t7`, or `nil` for a terminal on this core.
  private static func machine(of terminal: CoreTerminal) -> String? {
    guard let slash = terminal.address.firstIndex(of: "/") else { return nil }
    return String(terminal.address[..<slash])
  }

  private static func label(_ name: String, of terminal: CoreTerminal) -> String? {
    terminal.labels?[name].flatMap { $0.isEmpty ? nil : $0 }
  }

  /// The app's own `where` label, `space / tab`, split at the first separator because a
  /// name can hold another.
  private struct Place {
    let space: String?
    let tab: String?

    init(_ text: String) {
      let parts = text.components(separatedBy: " / ")
      space = parts.first.flatMap { $0.isEmpty ? nil : $0 }
      let rest = parts.dropFirst().joined(separator: " / ")
      tab = rest.isEmpty ? nil : rest
    }
  }

  /// The first thing any of these terminals' `where` says about `part`.
  private static func place(
    among terminals: [CoreTerminal],
    _ part: KeyPath<Place, String?>
  ) -> String? {
    terminals.lazy.compactMap { label("where", of: $0).flatMap { Place($0)[keyPath: part] } }.first
  }

  /// `terminals` by `key`, each group where its first member was seen.
  private static func grouped<Key: Hashable>(
    _ terminals: [CoreTerminal],
    by key: (CoreTerminal) -> Key
  ) -> [Group<Key>] {
    var positions: [Key: Int] = [:]
    var groups: [Group<Key>] = []
    for terminal in terminals {
      let key = key(terminal)
      if let position = positions[key] {
        groups[position].terminals.append(terminal)
      } else {
        positions[key] = groups.count
        groups.append((key, [terminal]))
      }
    }
    return groups
  }

  /// Everything with a rank, by rank, then the rest as it came.
  private static func ordered<Element>(
    _ elements: [Element],
    by rank: (Element) -> Int?
  ) -> [Element] {
    elements.enumerated()
      .sorted { (rank($0.element) ?? .max, $0.offset) < (rank($1.element) ?? .max, $1.offset) }
      .map(\.element)
  }

  /// A name the user gave, the terminal's own title, then what is running in it. `title` is
  /// usually `""`, so an empty string falls through like an absent one.
  private static func title(of terminal: CoreTerminal) -> String {
    let candidates = [
      terminal.name,
      terminal.title,
      terminal.foreground?.argv?.first.map(commandName),
      terminal.foreground?.name,
      terminal.argv?.first.map(commandName),
    ]
    return candidates.compactMap { $0 }.first { !$0.isEmpty } ?? terminal.address
  }

  private static func commandName(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
  }

  /// Where it is now, then where it started.
  private static func directory(of terminal: CoreTerminal) -> String? {
    [terminal.foreground?.cwd, terminal.cwd].compactMap { $0 }.first { !$0.isEmpty }
  }
}
