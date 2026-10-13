import DriverrCore
import Foundation

/// Turns herdr's four flat arrays into the tree the sidebar renders.
///
/// The module boundary: wire types in, `DriverrCore` values out. Every ordering, join and
/// fallback the UI depends on is made here, and all of it is testable without a host.
enum SnapshotMapper {
  static func tree(from snapshot: HerdrSessionSnapshot) -> SessionTree {
    // Agents are joined to panes by id. A pane with no agent is kept, as herdr shows it.
    let agentsByPane = Dictionary(
      snapshot.agents.map { ($0.paneID, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    let panesByTab = Dictionary(grouping: snapshot.panes, by: \.tabID)
    let tabsByWorkspace = Dictionary(grouping: snapshot.tabs, by: \.workspaceID)

    // herdr's order is kept, because it is the user's arrangement. `number` is only a
    // label.
    let workspaces = snapshot.workspaces.map { workspace in
      let tabs = (tabsByWorkspace[workspace.workspaceID] ?? []).map { tab in
        let wirePanes = panesByTab[tab.tabID] ?? []
        let panes = wirePanes.enumerated().map { index, pane in
          Pane(
            id: pane.paneID,
            tabID: pane.tabID,
            workspaceID: pane.workspaceID,
            title: title(for: pane, agent: agentsByPane[pane.paneID], index: index),
            agent: agent(for: pane, agent: agentsByPane[pane.paneID]),
            terminalID: pane.terminalID,
            directory: nonEmpty(pane.cwd),
            isFocused: pane.focused,
            viewportRows: pane.scroll?.viewportRows
          )
        }
        let autoNamed = isAutoNamed(tab)
        return Tab(
          id: tab.tabID,
          workspaceID: tab.workspaceID,
          number: tab.number,
          // Decided here, like a pane's title, so downstream reads one field.
          label: autoNamed ? "Tab \(tab.number)" : tab.label,
          isFocused: tab.focused,
          status: rollUp(tab.agentStatus, whenAgentIsPresentIn: panes),
          isAutoNamed: autoNamed,
          panes: panes
        )
      }
      return Workspace(
        id: workspace.workspaceID,
        number: workspace.number,
        label: workspace.label,
        isFocused: workspace.focused,
        status: rollUp(workspace.agentStatus, whenAgentIsPresentIn: tabs.flatMap(\.panes)),
        tabs: tabs
      )
    }

    return SessionTree(workspaces: workspaces, focusedPaneID: snapshot.focusedPaneID)
  }

  /// herdr's own roll-up for a tab or a workspace, or `nil` when nothing under it has an
  /// agent.
  ///
  /// Taken, not recomputed, so the phone and the desk agree. herdr sends `"unknown"` for
  /// a container of plain shells, so the presence check is Driverr's.
  private static func rollUp(
    _ reported: String?,
    whenAgentIsPresentIn panes: [Pane]
  ) -> AgentStatus? {
    guard panes.contains(where: { $0.agent != nil }), let reported else { return nil }
    return AgentStatus(wireValue: reported)
  }

  /// Whether herdr named this tab itself.
  ///
  /// herdr labels an unnamed tab with its number, such as `"2"`. A user who types `2`
  /// gets the same treatment, and `Tab 2` is what they meant either way.
  private static func isAutoNamed(_ tab: HerdrTab) -> Bool {
    guard let label = nonEmpty(tab.label) else { return true }
    return label == String(tab.number)
  }

  /// What to show for a pane, in the order of how much the user chose it.
  ///
  /// A label the user typed, then the program's terminal titles. The last resort is
  /// `Pane {n}`, numbered from 1 within its tab, never herdr's internal id.
  private static func title(for pane: HerdrPane, agent: HerdrAgent?, index: Int) -> String {
    // Only the label is the user's own words, so only it is left as typed.
    if let label = nonEmpty(pane.label) { return label }

    let fromTheProgram = [pane.title, pane.terminalTitleStripped, pane.terminalTitle]
    for candidate in fromTheProgram {
      guard let text = nonEmpty(candidate) else { continue }
      // Checked again after stripping: a title that is only a spinner strips to nothing.
      if let stripped = nonEmpty(strippingLeadingSymbolRun(text)) { return stripped }
    }
    if let name = nonEmpty(agent?.name) { return name }
    return "Pane \(index + 1)"
  }

  /// Drops a leading run of symbols followed by a space, such as a spinner frame.
  ///
  /// herdr strips only a fixed list, and frames such as `◐ driverr` get through and
  /// animate the row. The required space keeps `~/driverr` and `#3 build` intact. Applied
  /// to terminal titles only, never to a user's label.
  static func strippingLeadingSymbolRun(_ text: String) -> String {
    var rest = Substring(text)
    var sawSymbol = false
    while let first = rest.first, first.isSymbolOrPunctuation {
      sawSymbol = true
      rest = rest.dropFirst()
    }
    guard sawSymbol else { return text }
    // Only symbols: strip to nothing, and the caller tries the next candidate.
    guard let boundary = rest.first else { return "" }
    guard boundary.isWhitespace else { return text }
    return String(rest.drop(while: \.isWhitespace))
  }

  /// The agent running in a pane, if there is one.
  ///
  /// Present when herdr lists an agent record or names one on the pane. An agent without
  /// a name is called `Agent`, so its pane stays in "Needs you".
  ///
  /// The status comes from the pane, where it is a required field.
  private static func agent(for pane: HerdrPane, agent: HerdrAgent?) -> Agent? {
    let named = displayName(for: pane, agent: agent)
    guard agent != nil || named != nil else { return nil }
    return Agent(
      name: named ?? "Agent",
      kind: slug(for: pane, agent: agent),
      status: AgentStatus(wireValue: pane.agentStatus),
      session: session(for: pane, agent: agent)
    )
  }

  /// herdr's own token for the agent, untouched.
  ///
  /// Code that decides on an agent, such as which transcript to read, needs this token.
  /// `displayName` cannot be turned back into it.
  private static func slug(for pane: HerdrPane, agent: HerdrAgent?) -> String? {
    nonEmpty(agent?.agent) ?? nonEmpty(pane.agent)
  }

  /// The session reference, from whichever of the two records carries one.
  ///
  /// The agent record first, because the pane copy is herdr echoing it. A session with no
  /// `value`, as before the first prompt, is dropped, so no empty identifier becomes a
  /// filename.
  private static func session(for pane: HerdrPane, agent: HerdrAgent?) -> AgentSession? {
    guard let wire = agent?.agentSession ?? pane.agentSession,
      let value = nonEmpty(wire.value)
    else { return nil }
    return AgentSession(
      // Falls back to the pane's slug if herdr stops repeating the agent here.
      agent: nonEmpty(wire.agent) ?? slug(for: pane, agent: agent) ?? "",
      // Only `id` is read. An absent kind stays empty, so `AgentSession.identifier`
      // refuses it rather than treat an unknown token as a filename.
      kind: nonEmpty(wire.kind) ?? "",
      value: value,
      source: nonEmpty(wire.source)
    )
  }

  /// The agent's name the way a person would write it.
  ///
  /// `display_agent` wins where present. Otherwise the slug is capitalised, and only on
  /// that path, so a `display_agent` of `openai codex` is left alone.
  private static func displayName(for pane: HerdrPane, agent: HerdrAgent?) -> String? {
    if let display = nonEmpty(agent?.displayAgent) ?? nonEmpty(pane.displayAgent) {
      return display
    }
    if let slug = nonEmpty(agent?.agent) ?? nonEmpty(pane.agent) {
      return slug.prefix(1).uppercased() + slug.dropFirst()
    }
    return nil
  }

  /// Trimmed, or `nil` for a blank string. Every fallback chain here depends on it.
  private static func nonEmpty(_ text: String?) -> String? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}

extension Character {
  /// Neither a letter nor a number, the class spinner frames come from.
  fileprivate var isSymbolOrPunctuation: Bool {
    isSymbol || isPunctuation
  }
}
