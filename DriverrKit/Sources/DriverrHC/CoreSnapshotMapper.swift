import DriverrCore
import DriverrHerdr
import Foundation

/// Turns `terminal.list` into the tree the app draws.
///
/// Flat and read-only for now: one workspace, one tab, no agents. Terminals on machines this
/// core added are listed like its own. The real mapping, from labels and status, is #17.
enum CoreSnapshotMapper {
  static let workspaceID = CorePaneID.prefix + "workspace"
  static let tabID = CorePaneID.prefix + "tab"

  static func tree(from list: CoreListResult) -> SessionTree {
    // No workspace at all when empty, so a core with nothing running adds no row to a host.
    guard !list.terminals.isEmpty else { return .empty }

    let panes = list.terminals.map { terminal in
      Pane(
        id: CorePaneID.id(forAddress: terminal.address),
        tabID: tabID,
        workspaceID: workspaceID,
        title: title(of: terminal),
        terminalID: terminal.address,
        directory: directory(of: terminal),
        viewportRows: terminal.rows
      )
    }
    let tab = Tab(
      id: tabID,
      workspaceID: workspaceID,
      number: 1,
      label: "Terminals",
      isAutoNamed: true,
      panes: panes
    )
    return SessionTree(
      workspaces: [Workspace(id: workspaceID, number: 1, label: "herdr-core", tabs: [tab])]
    )
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
