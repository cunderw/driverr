import DriverrCore
import Foundation

/// One line of `tmux list-panes -a -F`.
struct TmuxPaneRow: Equatable, Sendable {
  let paneID: String
  let windowID: String
  let sessionID: String
  let sessionName: String
  /// How many clients are attached to the session. A detached session is `0`.
  let sessionAttached: Int
  /// When anything last happened in the session, in epoch seconds.
  let sessionActivity: Int
  let windowIndex: Int
  let windowName: String
  /// Whether tmux names the window from what runs in it. `rename-window` turns it off.
  let windowAutoNamed: Bool
  let windowActive: Bool
  let paneActive: Bool
  let tty: String
  let width: Int?
  let height: Int?
  let title: String
  let host: String
  let hostShort: String
  let command: String
  let path: String
}

/// The `-F` format of the one call that lists everything, and its reader.
///
/// One call returns every pane on the server, with its window and session. tmux has no
/// separate listing worth a second round trip.
enum TmuxPaneFormat {
  /// ASCII unit separator. tmux refuses a tab in a name and prints a control character as it
  /// is, so this one cannot appear in a session or window name, and a title tmux accepted
  /// cannot hold it either.
  static let delimiter = "\u{1F}"

  /// In the order they are printed. The free text that could most plausibly hold anything, a
  /// path, is last, so a stray delimiter in it is read as part of it.
  static let fields = [
    "pane_id", "window_id", "session_id", "session_name", "session_attached",
    "session_activity", "window_index", "window_name", "automatic-rename", "window_active",
    "pane_active", "pane_tty", "pane_width", "pane_height", "pane_title", "host", "host_short",
    "pane_current_command", "pane_current_path",
  ]

  static var format: String {
    fields.map { "#{\($0)}" }.joined(separator: delimiter)
  }

  /// The row on `line`, or `nil` for a line that is not one.
  ///
  /// A line whose field count is wrong, or whose ids are not tmux's, is skipped rather than
  /// guessed at. It never crashes, and one bad line does not cost the rest.
  static func row(from line: Substring) -> TmuxPaneRow? {
    let parts = line.split(
      separator: Character(delimiter), maxSplits: fields.count - 1, omittingEmptySubsequences: false
    ).map(String.init)
    guard parts.count == fields.count,
      let paneID = TmuxID.validRaw(parts[0], kind: .pane),
      let windowID = TmuxID.validRaw(parts[1], kind: .window),
      let sessionID = TmuxID.validRaw(parts[2], kind: .session)
    else { return nil }
    return TmuxPaneRow(
      paneID: paneID,
      windowID: windowID,
      sessionID: sessionID,
      sessionName: parts[3],
      sessionAttached: Int(parts[4]) ?? 0,
      sessionActivity: Int(parts[5]) ?? 0,
      windowIndex: Int(parts[6]) ?? 0,
      windowName: parts[7],
      windowAutoNamed: parts[8] == "1",
      windowActive: parts[9] == "1",
      paneActive: parts[10] == "1",
      tty: parts[11],
      width: Int(parts[12]),
      height: Int(parts[13]),
      title: parts[14],
      host: parts[15],
      hostShort: parts[16],
      command: parts[17],
      path: parts[18]
    )
  }

  static func rows(from output: String) -> [TmuxPaneRow] {
    output.split(separator: "\n").compactMap(row(from:))
  }
}

/// Turns tmux's flat list into the tree the sidebar renders.
///
/// A session is a workspace, a window is a tab, and a pane is a pane. tmux's order is kept,
/// because it is the user's arrangement.
enum TmuxSnapshotMapper {
  /// `agents` is by raw pane id, from the process join. A pane not in it is a shell.
  static func tree(from rows: [TmuxPaneRow], agents: [String: Agent] = [:]) -> SessionTree {
    let focusedSession = focusedSessionID(in: rows)
    var focusedPaneID: String?

    var sessionOrder: [String] = []
    var windowOrder: [String: [String]] = [:]
    var rowsByWindow: [String: [TmuxPaneRow]] = [:]
    var firstRowOfSession: [String: TmuxPaneRow] = [:]
    var firstRowOfWindow: [String: TmuxPaneRow] = [:]
    for row in rows {
      if firstRowOfSession[row.sessionID] == nil {
        firstRowOfSession[row.sessionID] = row
        sessionOrder.append(row.sessionID)
      }
      if firstRowOfWindow[row.windowID] == nil {
        firstRowOfWindow[row.windowID] = row
        windowOrder[row.sessionID, default: []].append(row.windowID)
      }
      rowsByWindow[row.windowID, default: []].append(row)
    }

    let workspaces = sessionOrder.enumerated().map { sessionPosition, sessionID in
      let sessionRow = firstRowOfSession[sessionID]!
      let isFocusedSession = sessionID == focusedSession
      let workspaceID = TmuxID.session(sessionID)
      let tabs = (windowOrder[sessionID] ?? []).map { windowID in
        let windowRows = rowsByWindow[windowID] ?? []
        let windowRow = firstRowOfWindow[windowID]!
        let tabID = TmuxID.window(windowID)
        let isFocusedWindow = isFocusedSession && windowRow.windowActive
        let panes = windowRows.enumerated().map { index, row in
          let isFocused = isFocusedWindow && row.paneActive
          if isFocused { focusedPaneID = TmuxID.pane(row.paneID) }
          return pane(
            row, index: index, tabID: tabID, workspaceID: workspaceID,
            agent: agents[row.paneID], isFocused: isFocused)
        }
        return Tab(
          id: tabID,
          workspaceID: workspaceID,
          number: windowRow.windowIndex,
          label: windowRow.windowName.isEmpty ? "Tab \(windowRow.windowIndex)" : windowRow.windowName,
          isFocused: isFocusedWindow,
          status: rollUp(panes),
          isAutoNamed: windowRow.windowAutoNamed,
          panes: panes
        )
      }
      return Workspace(
        id: workspaceID,
        number: sessionPosition + 1,
        label: sessionRow.sessionName,
        isFocused: isFocusedSession,
        status: rollUp(tabs.flatMap(\.panes)),
        tabs: tabs
      )
    }
    return SessionTree(workspaces: workspaces, focusedPaneID: focusedPaneID)
  }

  /// The session someone is looking at: the attached one with the latest activity. `nil` when
  /// none is attached, as a host nobody is sitting at has no focus.
  private static func focusedSessionID(in rows: [TmuxPaneRow]) -> String? {
    // The first of the most recently active, so a tie is not decided by luck.
    rows.filter { $0.sessionAttached > 0 }
      .reduce(nil as TmuxPaneRow?) { best, row in
        guard let best else { return row }
        return row.sessionActivity > best.sessionActivity ? row : best
      }?.sessionID
  }

  private static func pane(
    _ row: TmuxPaneRow,
    index: Int,
    tabID: String,
    workspaceID: String,
    agent: Agent?,
    isFocused: Bool
  ) -> Pane {
    Pane(
      id: TmuxID.pane(row.paneID),
      tabID: tabID,
      workspaceID: workspaceID,
      title: title(of: row, agent: agent, index: index),
      agent: agent,
      // The pane's own id, which is what `TmuxAttacher` opens. `Pane.sessionWitness` passes over
      // a terminal id equal to the pane's, because tmux reuses `%3` after a server restart and a
      // pane that witnessed itself by it would read as resumed. The directory tells more.
      terminalID: TmuxID.pane(row.paneID),
      directory: nonEmpty(row.path),
      isFocused: isFocused,
      viewportRows: row.height
    )
  }

  /// The program's title, then the agent's name, then what runs in the pane, then its number.
  ///
  /// tmux's default pane title is the host's name, which says nothing, so a title that equals
  /// it is passed over. A command that is a version string is passed over too: Claude Code's
  /// process is named `2.1.325`.
  private static func title(of row: TmuxPaneRow, agent: Agent?, index: Int) -> String {
    if let title = nonEmpty(row.title), title != row.host, title != row.hostShort,
      let stripped = nonEmpty(strippingLeadingSymbolRun(title))
    {
      return stripped
    }
    if let name = nonEmpty(agent?.name) { return name }
    if let command = nonEmpty(row.command), !looksLikeVersion(command) { return command }
    return "Pane \(index + 1)"
  }

  /// Drops a spinner frame and the space after it, such as `✳ ` in front of Claude Code's title.
  /// The required space keeps `~/driverr` and `#3 build` as they are.
  static func strippingLeadingSymbolRun(_ text: String) -> String {
    var rest = Substring(text)
    var sawSymbol = false
    while let first = rest.first, first.isSymbol || first.isPunctuation {
      sawSymbol = true
      rest = rest.dropFirst()
    }
    guard sawSymbol else { return text }
    guard let boundary = rest.first else { return "" }
    guard boundary.isWhitespace else { return text }
    return String(rest.drop(while: \.isWhitespace))
  }

  /// `2.1.325` or `3.7c`: digits and dots, and at most one trailing letter.
  private static func looksLikeVersion(_ command: String) -> Bool {
    let body = command.last?.isLetter == true ? command.dropLast() : Substring(command)
    return body.first?.isNumber == true && body.allSatisfy { $0.isNumber || $0 == "." }
  }

  /// The most urgent agent under these panes, or `nil` with none. tmux rolls nothing up.
  private static func rollUp(_ panes: [Pane]) -> AgentStatus? {
    panes.compactMap { $0.agent?.status }.min { $0.sortPriority < $1.sortPriority }
  }

  private static func nonEmpty(_ text: String?) -> String? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}
