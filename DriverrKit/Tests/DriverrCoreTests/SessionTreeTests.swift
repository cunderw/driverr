import Testing

@testable import DriverrCore

private func pane(
  _ id: String,
  status: AgentStatus,
  tab: String = "t1",
  workspace: String = "w1"
) -> Pane {
  Pane(
    id: id,
    tabID: tab,
    workspaceID: workspace,
    title: id,
    agent: Agent(name: "Claude", status: status)
  )
}

/// A pane with no agent: a plain shell, most panes in a real session.
private func shell(
  _ id: String,
  tab: String = "t1",
  workspace: String = "w1"
) -> Pane {
  Pane(id: id, tabID: tab, workspaceID: workspace, title: id, directory: "~/dev")
}

@Suite("SessionTree")
struct SessionTreeTests {
  @Test("an empty tree has no panes and reports itself empty")
  func emptyTree() {
    #expect(SessionTree.empty.isEmpty)
    #expect(SessionTree.empty.allPanes.isEmpty)
    #expect(SessionTree.empty.pane(id: "anything") == nil)
  }

  @Test("panes are reachable depth-first through the tree")
  func allPanesWalksTheTree() {
    let tree = SessionTree(workspaces: [
      Workspace(
        id: "w1", number: 1, label: "one",
        tabs: [
          Tab(id: "t1", workspaceID: "w1", number: 1, label: "a", panes: [
            pane("p1", status: .idle), pane("p2", status: .working),
          ]),
          Tab(id: "t2", workspaceID: "w1", number: 2, label: "b", panes: [
            pane("p3", status: .blocked, tab: "t2")
          ]),
        ]
      )
    ])

    #expect(tree.allPanes.map(\.id) == ["p1", "p2", "p3"])
    #expect(tree.pane(id: "p3")?.agent?.status == .blocked)
    #expect(tree.pane(id: "nope") == nil)
  }

  @Test("a pane with no agent has no status to have")
  func shellPaneHasNoAgent() {
    // The status lives inside the agent, so "a blocked shell pane" cannot be written down.
    let pane = shell("p1")
    #expect(pane.agent == nil)
    #expect(pane.directory == "~/dev")
  }

  @Test("blocked sorts first, then done, then working, then idle, then unknown")
  func urgencySorting() {
    // `done` above `working` is where Driverr deliberately differs from herdr: a finished agent
    // is news the user has not seen.
    let tree = SessionTree(workspaces: [
      Workspace(
        id: "w1", number: 1, label: "one",
        tabs: [
          Tab(id: "t1", workspaceID: "w1", number: 1, label: "a", panes: [
            pane("idle", status: .idle),
            pane("unknown", status: .unknown),
            pane("blocked", status: .blocked),
            pane("working", status: .working),
            pane("done", status: .done),
          ])
        ]
      )
    ])

    #expect(
      tree.panesByUrgency.map(\.id) == ["blocked", "done", "working", "idle", "unknown"]
    )
  }

  @Test("a pane with no agent sorts behind every pane that has one")
  func shellPanesSortLast() {
    // Even behind `unknown`. A shell is nobody waiting on anything.
    let tree = SessionTree(workspaces: [
      Workspace(
        id: "w1", number: 1, label: "one",
        tabs: [
          Tab(id: "t1", workspaceID: "w1", number: 1, label: "a", panes: [
            shell("shell"),
            pane("unknown", status: .unknown),
            pane("blocked", status: .blocked),
          ])
        ]
      )
    ])

    #expect(tree.panesByUrgency.map(\.id) == ["blocked", "unknown", "shell"])
    #expect(shell("s").sortPriority > AgentStatus.unknown.sortPriority)
  }

  @Test("panes of equal urgency keep herdr's own order")
  func sortingIsStable() {
    // A list that reshuffles when an unrelated agent changes state is worse than a stale one.
    let tree = SessionTree(workspaces: [
      Workspace(
        id: "w1", number: 1, label: "one",
        tabs: [
          Tab(id: "t1", workspaceID: "w1", number: 1, label: "a", panes: [
            pane("first", status: .idle),
            pane("second", status: .idle),
            pane("third", status: .idle),
          ])
        ]
      )
    ])

    #expect(tree.panesByUrgency.map(\.id) == ["first", "second", "third"])
  }

  @Test("a tab sorts its own panes blocked-first, stably")
  func tabSortsItsPanes() {
    // A pane never leaves its tab.
    let tab = Tab(
      id: "t1", workspaceID: "w1", number: 1, label: "a",
      panes: [
        pane("idle-first", status: .idle),
        pane("blocked", status: .blocked),
        pane("idle-second", status: .idle),
        pane("working", status: .working),
      ]
    )

    #expect(
      tab.panesByUrgency.map(\.id) == ["blocked", "working", "idle-first", "idle-second"]
    )
  }

  @Test("blocked panes are collected across the whole session")
  func blockedPanesAcrossTheTree() {
    let tree = SessionTree(workspaces: [
      Workspace(
        id: "w1", number: 1, label: "one",
        tabs: [
          Tab(id: "t1", workspaceID: "w1", number: 1, label: "a", panes: [
            pane("calm", status: .idle), pane("waiting", status: .blocked),
          ])
        ]
      ),
      Workspace(
        id: "w2", number: 2, label: "two",
        tabs: [
          Tab(id: "t2", workspaceID: "w2", number: 1, label: "b", panes: [
            pane("also-waiting", status: .blocked, tab: "t2", workspace: "w2"),
            pane("busy", status: .working, tab: "t2", workspace: "w2"),
            shell("empty-shell", tab: "t2", workspace: "w2"),
          ])
        ]
      ),
    ])

    #expect(tree.blockedPanes.map(\.id) == ["waiting", "also-waiting"])
    #expect(SessionTree.empty.blockedPanes.isEmpty)
  }

  /// With two blocked panes, a tap that guesses is worse than no tap, so the row is a label.
  @Test("exactly one blocked pane is the only case that has a lone one")
  func loneBlockedPaneNeedsExactlyOne() {
    func tree(_ panes: [Pane]) -> SessionTree {
      SessionTree(workspaces: [
        Workspace(
          id: "w1", number: 1, label: "one",
          tabs: [Tab(id: "t1", workspaceID: "w1", number: 1, label: "a", panes: panes)]
        )
      ])
    }

    #expect(tree([pane("calm", status: .idle), shell("sh")]).loneBlockedPane == nil)
    #expect(SessionTree.empty.loneBlockedPane == nil)

    // That one, not merely non-nil: picking the first of several would pass a nil check.
    let one = tree([
      pane("busy", status: .working), pane("waiting", status: .blocked), shell("sh"),
    ])
    #expect(one.loneBlockedPane?.id == "waiting")

    let two = tree([
      pane("waiting", status: .blocked), pane("also-waiting", status: .blocked),
    ])
    #expect(two.blockedPanes.count == 2)
    #expect(two.loneBlockedPane == nil)
  }

  @Test("agent status counts cover every state and shells, across the whole tree")
  func agentStatusCountsCoverEveryState() {
    // `HostStatus.calmSummary` turns this into a sentence; this proves the counting.
    let tree = SessionTree(workspaces: [
      Workspace(
        id: "w1", number: 1, label: "one",
        tabs: [
          Tab(id: "t1", workspaceID: "w1", number: 1, label: "a", panes: [
            pane("blocked", status: .blocked),
            pane("done-1", status: .done),
            pane("done-2", status: .done),
            pane("working", status: .working),
            pane("idle-1", status: .idle),
            pane("idle-2", status: .idle),
            pane("idle-3", status: .idle),
            pane("unknown", status: .unknown),
            shell("shell-1"),
            shell("shell-2"),
          ])
        ]
      )
    ])

    let counts = tree.agentStatusCounts
    #expect(counts.blocked == 1)
    #expect(counts.done == 2)
    #expect(counts.working == 1)
    #expect(counts.idle == 3)
    #expect(counts.unknown == 1)
    #expect(counts.shells == 2)
  }

  /// `error` is the one state that sorts above `done` and asks for nothing.
  @Test("a failed agent sorts second and is not waiting on anyone")
  func aFailedAgentIsNotBlocked() {
    let tree = SessionTree(workspaces: [
      Workspace(
        id: "w1", number: 1, label: "a",
        tabs: [
          Tab(
            id: "t1", workspaceID: "w1", number: 1, label: "x",
            panes: [
              pane("done", status: .done), pane("failed", status: .error),
              pane("blocked", status: .blocked),
            ])
        ])
    ])
    #expect(tree.panesByUrgency.map(\.id) == ["blocked", "failed", "done"])
    #expect(tree.blockedPanes.map(\.id) == ["blocked"])
    #expect(tree.loneBlockedPane?.id == "blocked")
    #expect(tree.agentStatusCounts.errors == 1)
  }

  @Test("an empty tree counts nothing in any state")
  func agentStatusCountsOfAnEmptyTree() {
    #expect(SessionTree.empty.agentStatusCounts == AgentStatusCounts())
  }

  @Test("a pane's location resolves to labels, not ids")
  func locationResolvesLabels() {
    // A row shown outside the tree has to say where it came from, and a pane carries ids only.
    let tree = SessionTree(workspaces: [
      Workspace(
        id: "w1", number: 1, label: "myproject",
        tabs: [
          Tab(id: "t1", workspaceID: "w1", number: 2, label: "2: tests", panes: [
            pane("p1", status: .blocked)
          ])
        ]
      )
    ])

    #expect(tree.location(of: tree.allPanes[0]) == "myproject › 2: tests")
    #expect(tree.location(of: pane("stray", status: .idle, tab: "tX", workspace: "wX")) == nil)
  }

  @Test("a tab's status is herdr's own, carried rather than recomputed")
  func tabStatusIsNotDerived() {
    // Deliberately inconsistent with its panes. A derived roll-up could make the phone and the
    // desk disagree about the same tab.
    let tab = Tab(
      id: "t1", workspaceID: "w1", number: 1, label: "a",
      status: .blocked,
      panes: [pane("a", status: .idle), pane("b", status: .idle)]
    )
    #expect(tab.status == .blocked)
  }

  @Test("a workspace's status is herdr's own too")
  func workspaceStatusIsNotDerived() {
    let workspace = Workspace(
      id: "w1", number: 1, label: "one",
      status: .done,
      tabs: [
        Tab(id: "t1", workspaceID: "w1", number: 1, label: "a", panes: [
          pane("a", status: .idle)
        ])
      ]
    )
    #expect(workspace.status == .done)
  }

  @Test("a freshly-loaded tree opens the focused workspace and only it")
  func expansionDefaultsToTheFocusedWorkspace() {
    // Opening workspaces with blocked or done panes as well buried everything under one
    // large workspace. A blocked pane is already in "Needs you".
    let tree = SessionTree(
      workspaces: [
        Workspace(id: "w1", number: 1, label: "one", tabs: [
          Tab(id: "t1", workspaceID: "w1", number: 1, label: "a", panes: [
            pane("blocked-here", status: .blocked)
          ])
        ]),
        Workspace(id: "w2", number: 2, label: "two", isFocused: true, tabs: [
          Tab(id: "t2", workspaceID: "w2", number: 1, label: "b", panes: [
            pane("calm", status: .idle, tab: "t2", workspace: "w2")
          ])
        ]),
        Workspace(id: "w3", number: 3, label: "three"),
      ]
    )

    #expect(tree.defaultExpandedWorkspaceIDs == ["w2"])
  }

  @Test("with no focused workspace, the one holding the focused pane opens")
  func expansionFallsBackToTheFocusedPane() {
    let tree = SessionTree(
      workspaces: [
        Workspace(id: "w1", number: 1, label: "one"),
        Workspace(id: "w2", number: 2, label: "two", tabs: [
          Tab(id: "t2", workspaceID: "w2", number: 1, label: "b", panes: [
            pane("here", status: .idle, tab: "t2", workspace: "w2")
          ])
        ]),
      ],
      focusedPaneID: "here"
    )

    #expect(tree.defaultExpandedWorkspaceIDs == ["w2"])
  }

  @Test("with nothing focused at all, the first workspace opens rather than none")
  func expansionNeverOpensNothing() {
    // A tree with every workspace shut reads as an empty session, which has its own screen.
    let tree = SessionTree(workspaces: [
      Workspace(id: "w1", number: 1, label: "one"),
      Workspace(id: "w2", number: 2, label: "two"),
    ])

    #expect(tree.defaultExpandedWorkspaceIDs == ["w1"])
    #expect(SessionTree.empty.defaultExpandedWorkspaceIDs.isEmpty, "nothing to open")
  }

  @Test("a workspace with one auto-named tab hides its tab level")
  func tabHeadersAreElidedWhenTheySayNothing() {
    // "Tab 1" under a workspace tells a reader nothing and costs a line per workspace.
    let single = Workspace(
      id: "w1", number: 1, label: "one",
      tabs: [Tab(id: "t1", workspaceID: "w1", number: 1, label: "Tab 1", isAutoNamed: true)]
    )
    #expect(!single.showsTabHeaders)

    let two = Workspace(
      id: "w2", number: 2, label: "two",
      tabs: [
        Tab(id: "t1", workspaceID: "w2", number: 1, label: "Tab 1", isAutoNamed: true),
        Tab(id: "t2", workspaceID: "w2", number: 2, label: "Tab 2", isAutoNamed: true),
      ]
    )
    #expect(two.showsTabHeaders)

    let named = Workspace(
      id: "w3", number: 3, label: "three",
      tabs: [Tab(id: "t1", workspaceID: "w3", number: 1, label: "tests")]
    )
    #expect(named.showsTabHeaders)

    #expect(!Workspace(id: "w4", number: 4, label: "four").showsTabHeaders, "no tabs")
  }

  @Test("the tab level is drawn three ways, and one tab is not one answer")
  func tabHeaderStyleNamesTheThreeCases() {
    // Folding any single tab onto the workspace row drew "driverr · Tab 1", the row
    // `showsTabHeaders` exists to suppress.
    let auto = Workspace(
      id: "w1", number: 1, label: "one",
      tabs: [Tab(id: "t1", workspaceID: "w1", number: 1, label: "Tab 1", isAutoNamed: true)]
    )
    #expect(auto.tabHeaderStyle == .none, "an auto-named tab on its own says nothing")

    // A typed name is carried on the workspace row but gets no row of its own, which a boolean
    // cannot express.
    let named = Workspace(
      id: "w2", number: 2, label: "two",
      tabs: [Tab(id: "t1", workspaceID: "w2", number: 1, label: "tests")]
    )
    #expect(named.tabHeaderStyle == .inline)

    let two = Workspace(
      id: "w3", number: 3, label: "three",
      tabs: [
        Tab(id: "t1", workspaceID: "w3", number: 1, label: "Tab 1", isAutoNamed: true),
        Tab(id: "t2", workspaceID: "w3", number: 2, label: "Tab 2", isAutoNamed: true),
      ]
    )
    #expect(two.tabHeaderStyle == .headers)

    #expect(Workspace(id: "w4", number: 4, label: "four").tabHeaderStyle == .none, "no tabs")
  }

  @Test("a tab or workspace with no agent under it has no status at all")
  func containersWithoutAgentsHaveNoStatus() {
    // `nil`, not `.unknown`: a workspace of plain shells has nothing to badge.
    #expect(Tab(id: "t", workspaceID: "w", number: 1, label: "x").status == nil)
    #expect(Workspace(id: "w", number: 1, label: "x").status == nil)
    #expect(
      Tab(id: "t", workspaceID: "w", number: 1, label: "x", panes: [shell("s")]).status == nil
    )
  }
}
