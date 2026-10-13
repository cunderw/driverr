/// One place or control in the pane switcher, in the order it is drawn. `PaneSheetView`
/// renders these and the toolbar button's badge counts from them. The "strip" and "chip"
/// names outlived the strip.
public enum PaneStripChip: Hashable, Sendable {
  /// How many panes other than the current one are blocked. Absent rather than zero.
  case needsYou(count: Int)
  case shell(isCurrent: Bool)
  case pane(Pane, isCurrent: Bool)
  /// Opens the sheet. Always last.
  case grid
}

/// One ordering of a session, as a pure function of the tree, the current target, and
/// whether the scene was opened as a plain shell.
///
/// Order: an optional Needs-you count (only when another pane is blocked), an optional
/// Shell place, one entry per pane in `SessionTree.allPanes` order, then the grid. This is
/// the single opinion about which panes a session has and in what order.
public struct PaneStripModel: Sendable {
  public let chips: [PaneStripChip]
  /// The first blocked pane that is not the one on screen, in tree order.
  ///
  /// Uses the same filter as `blockedElsewhereCount`, so the badge's number always has
  /// somewhere to go. Nothing in the app reads it now, but `PaneStripModelTests` asserts it.
  public let needsYouTarget: Pane?
  /// How many panes other than the current one are blocked: the toolbar button's badge.
  /// Stored, because the chip is absent at zero and the badge must still say "none".
  public let blockedElsewhereCount: Int
  /// Each workspace's label, by id. A `Pane` carries only `workspaceID`, and `groups` cannot
  /// ask the tree after construction.
  private let workspaceLabels: [String: String]

  public init(tree: SessionTree, current: TerminalTarget, openedAsShell: Bool) {
    var chips: [PaneStripChip] = []

    self.workspaceLabels = Dictionary(
      tree.workspaces.map { ($0.id, $0.label) },
      uniquingKeysWith: { first, _ in first }
    )

    let blockedElsewhere = tree.blockedPanes.filter { current != .pane(id: $0.id) }
    if !blockedElsewhere.isEmpty {
      chips.append(.needsYou(count: blockedElsewhere.count))
    }
    self.needsYouTarget = blockedElsewhere.first
    self.blockedElsewhereCount = blockedElsewhere.count

    if openedAsShell {
      chips.append(.shell(isCurrent: current == .shell))
    }

    chips.append(
      contentsOf: tree.allPanes.map { .pane($0, isCurrent: current == .pane(id: $0.id)) }
    )

    chips.append(.grid)

    self.chips = chips
  }

  /// Everywhere the switcher can send you, in its own order: the Shell if the scene opened
  /// as one, then each pane. The sheet's tiles and thumbnails are both built from this.
  public var targets: [TerminalTarget] {
    chips.compactMap { chip in
      switch chip {
      case .needsYou, .grid: nil
      case .shell: .shell
      case .pane(let pane, _): .pane(id: pane.id)
      }
    }
  }

  /// The places, cut into sections at workspace boundaries, so the sheet can name each
  /// workspace.
  ///
  /// Runs of consecutive chips, not a `Dictionary(grouping:)`. `SessionTree.allPanes` is
  /// depth-first, so a workspace's panes are contiguous, and grouping by key would silently
  /// reorder a tree that ever stopped being so.
  ///
  /// The shell is its own untitled group, because Driverr's own pty belongs to no workspace.
  public var groups: [PaneGroup] {
    var groups: [PaneGroup] = []
    for chip in chips {
      switch chip {
      // Needs you and the grid are not places, so they belong to no workspace.
      case .needsYou, .grid:
        continue
      case .shell:
        groups.append(PaneGroup(id: PaneGroup.shellID, title: nil, chips: [chip]))
      case .pane(let pane, _):
        // Namespaced with `PaneGroup.workspaceGroupID(_:)`. herdr's `workspace_id` could be
        // `"shell"`, which would collide with `PaneGroup.shellID` and give `ForEach` a
        // duplicate id. With the prefix, comparing ids below is safe.
        let groupID = PaneGroup.workspaceGroupID(pane.workspaceID)
        if let last = groups.last, last.id == groupID {
          groups[groups.count - 1] = PaneGroup(
            id: last.id,
            title: last.title,
            chips: last.chips + [chip]
          )
        } else {
          groups.append(
            PaneGroup(id: groupID, title: workspaceLabels[pane.workspaceID], chips: [chip])
          )
        }
      }
    }
    return groups
  }

  /// Whether naming the workspaces is worth the rows. A header over the only group
  /// separates nothing, as with `Workspace.showsTabHeaders`.
  public var showsWorkspaceHeaders: Bool {
    groups.filter { $0.title != nil }.count > 1
  }

  /// Whether there is a session worth switching between.
  ///
  /// False with no panes: a plain shell on a host without herdr would otherwise get a Panes
  /// button whose sheet shows only the terminal already on screen. With no panes there is
  /// nowhere to go and nothing to split.
  public var showsSwitcher: Bool {
    chips.contains { chip in
      if case .pane = chip { return true }
      return false
    }
  }
}

/// One run of the switcher's places that belongs together: one workspace's panes, or the
/// scene's own shell. See `PaneStripModel.groups`.
public struct PaneGroup: Identifiable, Hashable, Sendable {
  /// The shell group's id. Not a workspace id, because herdr never sees this terminal.
  public static let shellID = "shell"

  /// A workspace's group id, namespaced so it can never equal `shellID`. herdr's
  /// `workspace_id` is opaque and could be `"shell"`, and `ForEach(_:)` needs unique ids.
  public static func workspaceGroupID(_ workspaceID: String) -> String {
    "workspace:\(workspaceID)"
  }

  /// The workspace's namespaced id (see `workspaceGroupID(_:)`), or `shellID`.
  public let id: String
  /// The workspace's label, or `nil` for the shell group.
  public let title: String?
  public let chips: [PaneStripChip]

  public init(id: String, title: String?, chips: [PaneStripChip]) {
    self.id = id
    self.title = title
    self.chips = chips
  }
}
