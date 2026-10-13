import DriverrCore
import Foundation
import Testing

@testable import DriverrHerdr

/// A snapshot shaped like herdr 0.8.0's, hand-built so no one's workspace names or paths
/// enter the repository. `LiveHerdrSnapshotTests` checks the shape against a real herdr.
enum Fixture {
  static func snapshot(
    workspaces: String = workspacesJSON,
    tabs: String = tabsJSON,
    panes: String = panesJSON,
    agents: String = agentsJSON,
    focusedPane: String = "\"w1:p1\""
  ) -> String {
    """
    {"id":"cli:api:snapshot","result":{"snapshot":{
      "version":"0.8.0","protocol":19,
      "focused_pane_id":\(focusedPane),
      "focused_tab_id":"w1:t1","focused_workspace_id":"w1",
      "layouts":[],
      "workspaces":\(workspaces),
      "tabs":\(tabs),
      "panes":\(panes),
      "agents":\(agents)
    }}}
    """
  }

  static let workspacesJSON = """
    [{"workspace_id":"w1","number":1,"label":"driverr","focused":true,
      "pane_count":2,"tab_count":2,"active_tab_id":"w1:t1","agent_status":"working"},
     {"workspace_id":"w2","number":2,"label":"tower","focused":false,
      "pane_count":1,"tab_count":1,"active_tab_id":"w2:t1","agent_status":"idle"}]
    """

  static let tabsJSON = """
    [{"tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"main","focused":true,
      "pane_count":1,"agent_status":"blocked"},
     {"tab_id":"w1:t2","workspace_id":"w1","number":2,"label":"tests","focused":false,
      "pane_count":1,"agent_status":"idle"},
     {"tab_id":"w2:t1","workspace_id":"w2","number":1,"label":"main","focused":false,
      "pane_count":1,"agent_status":"idle"}]
    """

  /// `w1:p1` has an agent; the other two are plain shells, the majority case.
  static let panesJSON = """
    [{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","terminal_id":"term_a",
      "focused":true,"agent_status":"blocked","revision":3,"cwd":"~/dev/driverr",
      "terminal_title":"✳ build","terminal_title_stripped":"build",
      "scroll":{"offset_from_bottom":0,"max_offset_from_bottom":0,"viewport_rows":58}},
     {"pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1","terminal_id":"term_b",
      "focused":false,"agent_status":"unknown","revision":1,"label":"unit tests",
      "cwd":"~/dev/driverr/DriverrKit"},
     {"pane_id":"w2:p1","tab_id":"w2:t1","workspace_id":"w2","terminal_id":"term_c",
      "focused":false,"agent_status":"unknown","revision":2,"cwd":"~/dev/tower"}]
    """

  /// herdr sends `agent_session` on both the agent record and the pane, as it does `agent`
  /// and `display_agent`.
  static let agentsJSON = """
    [{"pane_id":"w1:p1","terminal_id":"term_a","workspace_id":"w1","tab_id":"w1:t1",
      "focused":true,"revision":3,"agent_status":"blocked","agent":"claude",
      "display_agent":"Claude",
      "agent_session":{"agent":"claude","kind":"id","source":"herdr:claude",
        "value":"3f8c1d20-0000-4000-8000-000000000001"}}]
    """
}

@Suite("SnapshotMapper")
struct SnapshotMapperTests {
  private func tree(_ json: String) throws -> SessionTree {
    let response = try JSONDecoder().decode(
      HerdrResponse<HerdrSnapshotResult>.self,
      from: Data(json.utf8)
    )
    return SnapshotMapper.tree(from: response.result.snapshot)
  }

  @Test("four flat arrays become a workspace/tab/pane tree")
  func buildsTheTree() throws {
    let tree = try tree(Fixture.snapshot())

    #expect(tree.workspaces.map(\.id) == ["w1", "w2"])
    #expect(tree.workspaces[0].tabs.map(\.id) == ["w1:t1", "w1:t2"])
    #expect(tree.workspaces[0].tabs[0].panes.map(\.id) == ["w1:p1"])
    #expect(tree.workspaces[1].tabs[0].panes.map(\.id) == ["w2:p1"])
    #expect(tree.focusedPaneID == "w1:p1")
  }

  /// The bound on a `pane read`: over-asking costs about 420 ms against 30 ms for identical
  /// bytes. Absent means the read passes no `--lines` rather than inventing a number.
  @Test("a pane's viewport rows come through, and an absent scroll block stays absent")
  func mapsViewportRows() throws {
    let tree = try tree(Fixture.snapshot())

    #expect(tree.pane(id: "w1:p1")?.viewportRows == 58)
    #expect(tree.pane(id: "w1:p2")?.viewportRows == nil)
  }

  @Test("an agent is joined to its pane by id, and a shell pane gets none")
  func joinsAgentsToPanes() throws {
    let tree = try tree(Fixture.snapshot())

    #expect(tree.pane(id: "w1:p1")?.agent?.name == "Claude")
    #expect(tree.pane(id: "w1:p1")?.agent?.status == .blocked)
    // Dropping an empty shell would make the sidebar disagree with herdr.
    #expect(tree.pane(id: "w1:p2")?.agent == nil)
    #expect(tree.pane(id: "w2:p1") != nil)
  }

  @Test("herdr's own agent token survives the mapping, alongside the readable name")
  func keepsTheAgentToken() throws {
    let tree = try tree(Fixture.snapshot())
    let agent = try #require(tree.pane(id: "w1:p1")?.agent)
    // `name` is made presentable and cannot be reversed; `kind` decides whether a transcript
    // reader exists.
    #expect(agent.name == "Claude")
    #expect(agent.kind == "claude")
  }

  @Test("agent_session decodes onto the agent, with every field herdr sends")
  func decodesTheSession() throws {
    let tree = try tree(Fixture.snapshot())
    let session = try #require(tree.pane(id: "w1:p1")?.agent?.session)
    #expect(session.agent == "claude")
    #expect(session.kind == "id")
    #expect(session.value == "3f8c1d20-0000-4000-8000-000000000001")
    #expect(session.source == "herdr:claude")
    #expect(session.identifier == "3f8c1d20-0000-4000-8000-000000000001")
  }

  /// For Claude Code herdr's integration only populates this field, so Driverr cannot
  /// require it.
  @Test("an agent with no integration installed decodes fine, without a session")
  func absentSessionIsNormal() throws {
    let tree = try tree(
      Fixture.snapshot(
        agentsJSON: """
          [{"pane_id":"w1:p1","agent_status":"blocked","agent":"claude","display_agent":"Claude"}]
          """
      )
    )
    let agent = try #require(tree.pane(id: "w1:p1")?.agent)
    #expect(agent.kind == "claude")
    #expect(agent.session == nil)
  }

  @Test("a session with no value is not a session")
  func emptySessionValue() throws {
    let tree = try tree(
      Fixture.snapshot(
        agentsJSON: """
          [{"pane_id":"w1:p1","agent_status":"blocked","agent":"claude","display_agent":"Claude",
            "agent_session":{"agent":"claude","kind":"id","value":""}}]
          """
      )
    )
    // herdr reports the field before the first prompt resolves it. An empty identifier must not
    // become a filename.
    #expect(tree.pane(id: "w1:p1")?.agent?.session == nil)
  }

  @Test("a session kind this build does not understand is carried, not interpreted")
  func unknownSessionKind() throws {
    let tree = try tree(
      Fixture.snapshot(
        agentsJSON: """
          [{"pane_id":"w1:p1","agent_status":"blocked","agent":"claude","display_agent":"Claude",
            "agent_session":{"agent":"claude","kind":"path","value":"/tmp/somewhere"}}]
          """
      )
    )
    let session = try #require(tree.pane(id: "w1:p1")?.agent?.session)
    #expect(session.kind == "path")
    #expect(session.value == "/tmp/somewhere")
    // A token this build cannot read must not be mistaken for one it can.
    #expect(session.identifier == nil)
  }

  @Test("a pane-level agent_session is read when the agent record has none")
  func sessionFromThePane() throws {
    let panes = """
      [{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","terminal_id":"term_a",
        "focused":true,"agent_status":"blocked","cwd":"~/dev/driverr","agent":"claude",
        "agent_session":{"agent":"claude","kind":"id","value":"from-the-pane"}}]
      """
    let tree = try tree(
      Fixture.snapshot(
        panes: panes,
        agents: """
          [{"pane_id":"w1:p1","agent_status":"blocked","agent":"claude","display_agent":"Claude"}]
          """
      )
    )
    #expect(tree.pane(id: "w1:p1")?.agent?.session?.value == "from-the-pane")
  }

  @Test("a shell pane never gets a session, whatever else is in the snapshot")
  func shellPanesHaveNoSession() throws {
    let tree = try tree(Fixture.snapshot())
    #expect(tree.pane(id: "w1:p2")?.agent == nil)
    #expect(tree.pane(id: "w2:p1")?.agent == nil)
  }

  @Test("a shell pane's agent_status is not turned into an agent")
  func shellStatusDoesNotInventAnAgent() throws {
    // herdr reports `agent_status` on every pane, `unknown` for a plain shell. It only means
    // something once an agent is there.
    let panes = """
      [{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","terminal_id":"term_a",
        "focused":true,"agent_status":"blocked","revision":1,"label":"has an agent"},
       {"pane_id":"w2:p1","tab_id":"w2:t1","workspace_id":"w2","terminal_id":"term_c",
        "focused":false,"agent_status":"blocked","revision":1,"label":"just a shell"}]
      """
    let tree = try tree(Fixture.snapshot(panes: panes))

    #expect(tree.pane(id: "w2:p1")?.agent == nil)
    #expect(tree.blockedPanes.map(\.id) == ["w1:p1"], "a shell cannot reach Needs you")
  }

  @Test("an agent with no name is still an agent, so its pane keeps its badge")
  func unnamedAgentIsNotDropped() throws {
    // Dropping a nameless agent would take a blocked pane out of "Needs you".
    let tree = try tree(
      Fixture.snapshot(
        agentsJSON: """
          [{"pane_id":"w1:p1","terminal_id":"term_a","workspace_id":"w1","tab_id":"w1:t1",
            "focused":true,"revision":1,"agent_status":"blocked"}]
          """
      )
    )
    #expect(tree.pane(id: "w1:p1")?.agent?.status == .blocked)
    #expect(tree.pane(id: "w1:p1")?.agent?.name == "Agent")
  }

  @Test("a status herdr adds later degrades to unknown rather than failing the snapshot")
  func unknownStatusDoesNotBreakDecoding() throws {
    let panes = Fixture.panesJSON.replacingOccurrences(
      of: "\"agent_status\":\"blocked\"",
      with: "\"agent_status\":\"contemplating\""
    )
    let tree = try tree(Fixture.snapshot(panes: panes))

    #expect(tree.pane(id: "w1:p1")?.agent?.status == .unknown)
    #expect(tree.allPanes.count == 3, "one odd status must not drop the whole tree")
  }

  @Test("done arrives as done rather than collapsing into unknown")
  func doneSurvivesTheMapping() throws {
    let panes = Fixture.panesJSON.replacingOccurrences(
      of: "\"agent_status\":\"blocked\"",
      with: "\"agent_status\":\"done\""
    )
    let tree = try tree(Fixture.snapshot(panes: panes))
    #expect(tree.pane(id: "w1:p1")?.agent?.status == .done)
  }

  @Test("the terminal id and working directory come across")
  func decodesTerminalIDAndDirectory() throws {
    // `terminal_id` is what `herdr terminal attach` takes, for shells and agents alike.
    let tree = try tree(Fixture.snapshot())

    #expect(tree.pane(id: "w1:p1")?.terminalID == "term_a")
    #expect(tree.pane(id: "w2:p1")?.terminalID == "term_c")
    #expect(tree.pane(id: "w1:p2")?.directory == "~/dev/driverr/DriverrKit")
  }

  @Test("a pane from a herdr too old to send a terminal id still maps")
  func missingTerminalIDIsTolerated() throws {
    // `terminal_id` is optional below protocol 19; Driverr's floor is 17.
    let panes = """
      [{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1",
        "focused":true,"agent_status":"idle","revision":1,"label":"a pane"}]
      """
    let tree = try tree(Fixture.snapshot(panes: panes))

    #expect(tree.pane(id: "w1:p1")?.terminalID == nil)
    #expect(tree.pane(id: "w1:p1")?.directory == nil)
  }

  @Test("a tab and a workspace show herdr's roll-up rather than one of Driverr's own")
  func rollUpsComeFromHerdr() throws {
    let tree = try tree(Fixture.snapshot())

    // herdr says `working` for the workspace over a blocked pane. A derived roll-up would say
    // `blocked` and disagree with the desk.
    #expect(tree.workspaces[0].tabs[0].status == .blocked)
    #expect(tree.workspaces[0].status == .working)
  }

  @Test("a container with no agent under it carries no status at all")
  func rollUpIsNilWithoutAgents() throws {
    // herdr sends `agent_status:"idle"` here anyway; a badge would claim a state with no agent.
    let tree = try tree(Fixture.snapshot())

    #expect(tree.workspaces[0].tabs[1].status == nil, "w1:t2 holds one shell")
    #expect(tree.workspaces[1].status == nil, "w2 holds one shell")
  }

  @Test("a pane's title prefers what the user chose over what the program said")
  func titlePreference() throws {
    let tree = try tree(Fixture.snapshot())

    // A typed label wins.
    #expect(tree.pane(id: "w1:p2")?.title == "unit tests")
    // With no label, the terminal title, without herdr's status glyph.
    #expect(tree.pane(id: "w1:p1")?.title == "build")
  }

  @Test("the title chain ends at a readable name, never at a pane id")
  func titleNeverFallsBackToAPaneID() throws {
    // `w7:p6` is herdr's internal handle and means nothing to a reader.
    let panes = """
      [{"pane_id":"w9:p1","tab_id":"w9:t1","workspace_id":"w9",
        "focused":false,"agent_status":"unknown","revision":1},
       {"pane_id":"w9:p2","tab_id":"w9:t1","workspace_id":"w9",
        "focused":false,"agent_status":"unknown","revision":1,"label":"   ",
        "terminal_title":"  ","terminal_title_stripped":""},
       {"pane_id":"w9:p3","tab_id":"w9:t1","workspace_id":"w9",
        "focused":false,"agent_status":"unknown","revision":1,"terminal_title":"◐"}]
      """
    let tabs = """
      [{"tab_id":"w9:t1","workspace_id":"w9","number":1,"label":"main","focused":true,
        "pane_count":3,"agent_status":"unknown"}]
      """
    let workspaces = """
      [{"workspace_id":"w9","number":9,"label":"nine","focused":true,
        "pane_count":3,"tab_count":1,"active_tab_id":"w9:t1","agent_status":"unknown"}]
      """
    let tree = try tree(
      Fixture.snapshot(workspaces: workspaces, tabs: tabs, panes: panes, agents: "[]")
    )

    #expect(tree.allPanes.map(\.title) == ["Pane 1", "Pane 2", "Pane 3"])
    for pane in tree.allPanes {
      #expect(pane.title != pane.id, "a pane id reached the screen as a title")
    }
  }

  @Test("a blank title is treated as no title, not as a blank row")
  func blankTitlesFallThrough() throws {
    let panes = """
      [{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","terminal_id":"a",
        "focused":true,"agent_status":"idle","revision":1,
        "label":"   ","terminal_title_stripped":"real title"}]
      """
    let tree = try tree(Fixture.snapshot(panes: panes))
    #expect(tree.pane(id: "w1:p1")?.title == "real title")
  }

  @Test("a spinner frame is stripped from a terminal title but never from a label")
  func stripsSpinnersFromTerminalTitlesOnly() throws {
    // herdr's own stripper is a fixed list, and spinner frames like `◐` are not on it.
    let panes = """
      [{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","terminal_id":"a",
        "focused":true,"agent_status":"idle","revision":1,"terminal_title":"◐ driverr"},
       {"pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1","terminal_id":"b",
        "focused":false,"agent_status":"idle","revision":1,"label":"★ favourites"}]
      """
    let tree = try tree(Fixture.snapshot(panes: panes))

    #expect(tree.pane(id: "w1:p1")?.title == "driverr")
    // A label is the user's own words; a leading symbol there is a choice.
    #expect(tree.pane(id: "w1:p2")?.title == "★ favourites")
  }

  @Test("a terminal title whose symbols run into the text keeps every character")
  func doesNotStripPathsAndPrompts() {
    // The space after the run is what makes stripping safe: a spinner stands alone.
    #expect(SnapshotMapper.strippingLeadingSymbolRun("~/dev/driverr") == "~/dev/driverr")
    #expect(SnapshotMapper.strippingLeadingSymbolRun("#3 build") == "#3 build")
    #expect(SnapshotMapper.strippingLeadingSymbolRun("build") == "build")
    #expect(SnapshotMapper.strippingLeadingSymbolRun("◐ driverr") == "driverr")
    #expect(SnapshotMapper.strippingLeadingSymbolRun("··· thinking") == "thinking")
    // A title that is only a spinner frame strips to nothing, so the chain falls through.
    #expect(SnapshotMapper.strippingLeadingSymbolRun("◐") == "")
  }

  @Test("an agent named only by its wire slug is capitalised for display")
  func capitalisesTheAgentSlug() throws {
    // `display_agent` is herdr's own presentation and is left as sent.
    let tree = try tree(
      Fixture.snapshot(
        agentsJSON: """
          [{"pane_id":"w1:p1","terminal_id":"term_a","workspace_id":"w1","tab_id":"w1:t1",
            "focused":true,"revision":1,"agent_status":"working","agent":"codex"}]
          """
      )
    )
    #expect(tree.pane(id: "w1:p1")?.agent?.name == "Codex")
  }

  @Test("display_agent wins over the slug wherever it appears")
  func displayAgentWins() throws {
    let tree = try tree(
      Fixture.snapshot(
        agentsJSON: """
          [{"pane_id":"w1:p1","terminal_id":"term_a","workspace_id":"w1","tab_id":"w1:t1",
            "focused":true,"revision":1,"agent_status":"working","agent":"codex",
            "display_agent":"openai codex"}]
          """
      )
    )
    #expect(tree.pane(id: "w1:p1")?.agent?.name == "openai codex")
  }

  @Test("a tab herdr named by its own number becomes 'Tab 2', not '2'")
  func autoNamedTabsAreReadable() throws {
    // herdr labels an unnamed tab with its number, which reads as nothing on its own.
    let tabs = """
      [{"tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"main","focused":true,
        "pane_count":1,"agent_status":"blocked"},
       {"tab_id":"w1:t2","workspace_id":"w1","number":2,"label":"2","focused":false,
        "pane_count":1,"agent_status":"idle"},
       {"tab_id":"w2:t1","workspace_id":"w2","number":1,"label":"","focused":false,
        "pane_count":1,"agent_status":"idle"}]
      """
    let tree = try tree(Fixture.snapshot(tabs: tabs))

    #expect(tree.workspaces[0].tabs[0].label == "main")
    #expect(tree.workspaces[0].tabs[0].isAutoNamed == false)
    #expect(tree.workspaces[0].tabs[1].label == "Tab 2")
    #expect(tree.workspaces[0].tabs[1].isAutoNamed)
    // A blank label is also unnamed.
    #expect(tree.workspaces[1].tabs[0].label == "Tab 1")
    #expect(tree.workspaces[1].tabs[0].isAutoNamed)
  }

  @Test("herdr's own ordering is preserved rather than re-sorted by number")
  func keepsHerdrOrdering() throws {
    // `number` is a label, not a sequence; array order is the user's arrangement.
    let workspaces = """
      [{"workspace_id":"w2","number":9,"label":"second","focused":false,
        "pane_count":1,"tab_count":1,"active_tab_id":"w2:t1","agent_status":"idle"},
       {"workspace_id":"w1","number":1,"label":"first","focused":true,
        "pane_count":1,"tab_count":2,"active_tab_id":"w1:t1","agent_status":"idle"}]
      """
    // The tree groups panes by tab, so sorting tabs would reorder panes too.
    let tabs = """
      [{"tab_id":"w1:t2","workspace_id":"w1","number":2,"label":"tests","focused":false,
        "pane_count":1,"agent_status":"idle"},
       {"tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"main","focused":true,
        "pane_count":1,"agent_status":"blocked"},
       {"tab_id":"w2:t1","workspace_id":"w2","number":1,"label":"main","focused":false,
        "pane_count":1,"agent_status":"idle"}]
      """
    let tree = try tree(Fixture.snapshot(workspaces: workspaces, tabs: tabs))
    #expect(tree.workspaces.map(\.id) == ["w2", "w1"])
    #expect(tree.workspaces[1].tabs.map(\.id) == ["w1:t2", "w1:t1"])
    #expect(tree.workspaces[1].tabs.map(\.number) == [2, 1], "number is a label, not a sort key")
    // The panes moved with their tabs.
    #expect(tree.workspaces[1].tabs.flatMap(\.panes).map(\.id) == ["w1:p2", "w1:p1"])
  }

  @Test("a tab whose panes are missing is still shown, empty")
  func tabWithoutPanes() throws {
    let tree = try tree(Fixture.snapshot(panes: "[]"))

    #expect(tree.workspaces[0].tabs.count == 2)
    #expect(tree.allPanes.isEmpty)
    // An empty tab has nothing to report.
    #expect(tree.workspaces[0].tabs[0].status == nil)
  }

  @Test("a snapshot with nothing in it maps to an empty tree, not an error")
  func emptySnapshot() throws {
    let tree = try tree(
      Fixture.snapshot(workspaces: "[]", tabs: "[]", panes: "[]", agents: "[]", focusedPane: "null")
    )
    #expect(tree.isEmpty)
    #expect(tree.focusedPaneID == nil)
  }

  @Test("a field herdr adds later does not stop the snapshot decoding")
  func toleratesNewFields() throws {
    let panes = Fixture.panesJSON.replacingOccurrences(
      of: "\"revision\":3",
      with: "\"revision\":3,\"something_new_in_0_9\":{\"nested\":true}"
    )
    let tree = try tree(Fixture.snapshot(panes: panes))
    #expect(tree.allPanes.count == 3)
  }

  @Test("blocked-first ordering survives the mapping, with shells behind")
  func urgencyAfterMapping() throws {
    let tree = try tree(Fixture.snapshot())
    #expect(tree.panesByUrgency.map(\.id) == ["w1:p1", "w1:p2", "w2:p1"])
  }
}

extension Fixture {
  static func snapshot(agentsJSON: String) -> String {
    snapshot(agents: agentsJSON)
  }
}
