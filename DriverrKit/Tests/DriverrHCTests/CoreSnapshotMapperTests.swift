import DriverrCore
import DriverrHerdr
import Foundation
import Testing

@testable import DriverrHC

@Suite("Core snapshot mapping")
struct CoreSnapshotMapperTests {
  /// `terminal.list` as a real core 0.1.14 answered, cut down: a local labelled terminal with
  /// a status, its neighbour with none, a local one with no labels, and one on a machine the
  /// core added. The fields Driverr does not read stay, so this proves they do not disturb the
  /// decode.
  private static let captured = #"""
    {"hidden_finished":22,"machines":[{"host":"nas","id":"5b37","name":"box",
    "session":null,"state":"connected","target":"root@box","temporary":false,
    "version":"0.1.14","via":false}],"terminals":[
    {"address":"t1","argv":["/bin/zsh"],"cols":257,"created_ms":1793377161500,
    "cwd":"/home/me","die_with_parent":false,"exit_code":null,"finished_ms":null,
    "foreground":{"argv":["claude","--model","opus"],"cwd":"/home/me","name":"2.1.314","pid":18640},
    "identity":"ghostty","keep":true,"labels":{"herdr.space":"spA","herdr.tab":"tbA",
    "where":"main / vault"},"name":null,"notify":true,
    "parent":null,"pid":17916,"reason":null,"records":{"tpcv5":{"state":"working"}},
    "reported":true,"rm":false,"rows":48,"screen":"exact",
    "signal":null,"state":"live","status":{"app":"claude-code","msg":"done","state":"done"},
    "status_ms":1793379211630,"template":null,"title":"me","turn":9},
    {"address":"t6","argv":["/bin/zsh"],"cols":126,"created_ms":1793377805603,"cwd":"/home/me",
    "die_with_parent":false,"exit_code":null,"finished_ms":null,
    "foreground":{"argv":["/usr/local/bin/nvim"],"cwd":"/home/me/project","name":"nvim","pid":75627},
    "identity":"ghostty","keep":true,"labels":{"herdr.space":"spA","herdr.tab":"tbA",
    "where":"main / vault"},"name":null,"notify":true,"parent":null,
    "pid":24653,"reason":null,"reported":false,"rm":false,"rows":36,"screen":"exact",
    "signal":null,"state":"live","status":null,"template":null,"title":"","turn":0},
    {"address":"t9","argv":["/bin/zsh"],"cols":80,"created_ms":1793377805603,"cwd":"/home/me",
    "foreground":null,"labels":{},"name":null,"rows":24,"screen":"exact","state":"live",
    "title":""},
    {"address":"box/t1","argv":["/bin/bash"],"cols":80,"created_ms":1,"cwd":"/root",
    "foreground":null,"labels":{"herdr.space":"spB","herdr.tab":"tbB","where":"root / 1"},
    "name":null,"rows":24,"screen":"exact","state":"live","title":""}]}
    """#

  private func decoded(_ json: String) throws -> CoreListResult {
    try JSONDecoder().decode(CoreListResult.self, from: Data(json.utf8))
  }

  private func mapped() throws -> SessionTree {
    CoreSnapshotMapper.tree(from: try decoded(Self.captured))
  }

  private func terminal(_ fields: String) throws -> Pane {
    let json = #"{"terminals":[{"address":"t1",\#(fields)}]}"#
    return try #require(CoreSnapshotMapper.tree(from: try decoded(json)).allPanes.first)
  }

  /// One terminal, by address and labels, for the tests about order and names.
  private func listing(_ terminals: [(address: String, labels: String)]) throws -> CoreListResult {
    let records = terminals.map { #"{"address":"\#($0.address)","labels":{\#($0.labels)}}"# }
    return try decoded(#"{"terminals":[\#(records.joined(separator: ","))]}"#)
  }

  private func labels(space: String, tab: String, where place: String? = nil) -> String {
    let wherever = place.map { #","where":"\#($0)""# } ?? ""
    return #""herdr.space":"\#(space)","herdr.tab":"\#(tab)"\#(wherever)"#
  }

  private func document(_ json: String) throws -> CoreAppDocument {
    try JSONDecoder().decode(CoreAppDocument.self, from: Data(json.utf8))
  }

  private func leaf(_ terminal: String) -> String {
    #"{"type":"block","content":{"terminal":"\#(terminal)"}}"#
  }

  @Test("labels build the groups, unlabelled terminals are flat and machines come last")
  func groups() throws {
    let tree = try mapped()
    #expect(tree.workspaces.map(\.label) == ["main", "herdr-core", "box · root"])
    #expect(tree.workspaces[0].tabs.map(\.label) == ["vault"])
    #expect(tree.workspaces[0].tabs[0].panes.map(\.terminalID) == ["t1", "t6"])
    #expect(tree.workspaces[1].tabs.map(\.label) == ["Terminals"])
    #expect(tree.workspaces[1].tabs[0].panes.map(\.terminalID) == ["t9"])
    #expect(tree.workspaces[2].tabs[0].panes.map(\.terminalID) == ["box/t1"])
  }

  @Test("a machine's unlabelled terminals are a flat group named for the machine")
  func flatMachine() throws {
    let tree = CoreSnapshotMapper.tree(from: try listing([("t1", ""), ("box/t2", "")]))
    #expect(tree.workspaces.map(\.label) == ["herdr-core", "box"])
    #expect(tree.workspaces.map(\.id) == ["core:workspace", "core:box/workspace"])
    #expect(tree.workspaces.flatMap(\.tabs).map(\.id) == ["core:tab", "core:box/tab"])
    #expect(tree.workspaces.allSatisfy { $0.tabHeaderStyle == .none })
  }

  @Test("a machine's groups carry its core id, and this core's own groups carry none")
  func machineIdentity() throws {
    let tree = CoreSnapshotMapper.tree(from: try decoded(Self.captured), coreID: "f47b")
    #expect(tree.coreID == "f47b")
    let machines = tree.workspaces.filter { $0.id.hasPrefix("core:box/") }
    #expect(!machines.isEmpty)
    #expect(machines.allSatisfy { $0.machineCoreID == "5b37" })
    #expect(tree.workspaces.filter { $0.machineCoreID == nil }.count == tree.workspaces.count - 1)
  }

  @Test("a machine whose id has not been read yet is still drawn, and carries none")
  func machineNotReadYet() throws {
    var list = try decoded(Self.captured)
    list.machines = nil
    let tree = CoreSnapshotMapper.tree(from: list)
    #expect(tree.pane(id: "core:box/t1") != nil)
    #expect(tree.workspaces.allSatisfy { $0.machineCoreID == nil })
  }

  @Test("every id routes to the core side of a combined host, and says which machine")
  func idsAreCoreIDs() throws {
    let tree = try mapped()
    #expect(tree.workspaces.map(\.id) == ["core:spA", "core:workspace", "core:box/spB"])
    #expect(tree.workspaces.flatMap(\.tabs).map(\.id) == ["core:tbA", "core:tab", "core:box/tbB"])
    #expect(tree.allPanes.map(\.id) == ["core:t1", "core:t6", "core:t9", "core:box/t1"])
    #expect(tree.workspaces.allSatisfy { CorePaneID.isCore($0.id) })
    for workspace in tree.workspaces {
      for tab in workspace.tabs {
        #expect(tab.workspaceID == workspace.id)
        #expect(tab.panes.allSatisfy { $0.tabID == tab.id && $0.workspaceID == workspace.id })
      }
    }
  }

  /// `Pane.sessionWitness` is what `LastPaneStore` keeps, and an address never moves.
  @Test("a core terminal's witness is its address")
  func witness() throws {
    let tree = try mapped()
    #expect(tree.pane(id: "core:box/t1")?.sessionWitness == "box/t1")
    #expect(tree.pane(id: "core:t1")?.sessionWitness == "t1")
  }

  @Test("no status is a plain shell, whatever `reported` says")
  func noStatusIsAShell() throws {
    #expect(try terminal(#""status":null,"reported":true"#).agent == nil)
    #expect(try terminal("").agent == nil)
    #expect(try mapped().pane(id: "core:t6")?.agent == nil)
  }

  @Test("a status makes an agent, whatever `reported` says")
  func statusIsAnAgent() throws {
    let agent = try #require(
      try terminal(#""reported":false,"status":{"app":"claude-code","state":"working"}"#).agent)
    #expect(agent.status == .working)
    #expect(agent.session == nil)
  }

  @Test(
    "the status word is taken as it is, and one this build does not know is unknown",
    arguments: [
      ("idle", AgentStatus.idle), ("working", .working), ("done", .done),
      ("blocked", .blocked), ("error", .error), ("compacting", .unknown),
    ])
  func statuses(word: String, status: AgentStatus) throws {
    #expect(try terminal(#""status":{"state":"\#(word)"}"#).agent?.status == status)
  }

  @Test(
    "the app is herdr's own token, so the transcript reader can trust it",
    arguments: [
      ("claude-code", "claude", "Claude"), ("Claude-Code", "claude", "Claude"),
      ("claude", "claude", "Claude"), ("codex", "codex", "Codex"),
      ("cursor-agent", "cursor", "Cursor"), ("github-copilot", "copilot", "Copilot"),
      ("agy", "antigravity", "Antigravity"), ("My-Agent", "my-agent", "My-Agent"),
    ])
  func apps(app: String, kind: String, name: String) throws {
    let agent = try terminal(#""status":{"app":"\#(app)","state":"idle"}"#).agent
    #expect(agent?.kind == kind)
    #expect(agent?.name == name)
  }

  /// A `nil` or empty `kind` sends `TranscriptReader` to its name match, so a program called
  /// `claude-helper` would be handed Claude's files.
  @Test("an app with no name keeps a token, so nothing is matched by name")
  func noApp() throws {
    for status in [#"{"state":"idle"}"#, #"{"state":"idle","app":" "}"#] {
      let agent = try terminal(#""status":\#(status)"#).agent
      #expect(agent?.name == "Agent")
      #expect(agent?.kind == "unknown")
    }
    #expect(
      try terminal(#""status":{"app":"claude-helper","state":"idle"}"#).agent?.kind
        == "claude-helper")
  }

  /// `TranscriptReader` lists the SSH host's files, so a real `kind` here would show the
  /// host's conversation for the same directory on the other machine.
  @Test("an agent on an added machine keeps its name and picks no reader")
  func machineAgent() throws {
    let json = #"""
      {"terminals":[{"address":"box/t1","cwd":"/srv",
      "status":{"app":"claude-code","state":"working"}}]}
      """#
    let tree = CoreSnapshotMapper.tree(from: try decoded(json))
    let agent = try #require(tree.allPanes.only?.agent)
    #expect(agent.name == "Claude")
    #expect(agent.kind == "unknown")
    #expect(agent.status == .working)
  }

  @Test("an agent says which added machine it is on, and a local one says none")
  func agentMachine() throws {
    let json = #"""
      {"terminals":[{"address":"box/t1","status":{"app":"claude-code","state":"idle"}},
      {"address":"t2","status":{"app":"claude-code","state":"idle"}}]}
      """#
    let panes = CoreSnapshotMapper.tree(from: try decoded(json)).allPanes
    #expect(panes.first { $0.id == "core:box/t1" }?.agent?.machine == "box")
    #expect(panes.first { $0.id == "core:t2" }?.agent?.machine == nil)
  }

  @Test(
    "a status with no app takes the foreground's program, if Driverr knows it",
    arguments: [
      (["/opt/homebrew/bin/claude", "--model", "opus"], "Claude", "claude"),
      (["codex"], "Codex", "codex"),
      (["/bin/zsh"], "Agent", "unknown"),
    ])
  func foregroundProgram(argv: [String], name: String, kind: String) throws {
    let quoted = argv.map { "\"\($0)\"" }.joined(separator: ",")
    let agent = try terminal(
      #""status":{"state":"idle"},"foreground":{"argv":[\#(quoted)],"pid":7}"#
    ).agent
    #expect(agent?.name == name)
    #expect(agent?.kind == kind)
  }

  @Test("the app a status names beats what is in the foreground")
  func appBeatsForeground() throws {
    let agent = try terminal(
      #""status":{"app":"codex","state":"idle"},"foreground":{"argv":["claude"],"pid":7}"#
    ).agent
    #expect(agent?.kind == "codex")
  }

  @Test("claude running with no status is a shell")
  func claudeWithNoStatus() throws {
    #expect(try terminal(#""foreground":{"argv":["claude"],"pid":7}"#).agent == nil)
  }

  @Test("a session id becomes the agent's session, with where it came from")
  func sessionFromFile() throws {
    let json = #"""
      {"terminals":[{"address":"t1","status":{"app":"claude-code","state":"idle"}}]}
      """#
    let tree = CoreSnapshotMapper.tree(from: try decoded(json), sessions: ["t1": "abc"])
    #expect(
      tree.allPanes.only?.agent?.session
        == AgentSession(agent: "claude", kind: "id", value: "abc", source: "claude:sessions"))
  }

  @Test(
    "what a blocked agent waits for is carried, and only for a blocked agent",
    arguments: [
      ("blocked", "permission", AgentBlockedKind?.some(.permission)),
      ("blocked", "question", .question), ("blocked", "auth", .auth),
      ("blocked", "payment", nil), ("working", "permission", nil),
    ])
  func blockedKinds(state: String, kind: String, expected: AgentBlockedKind?) throws {
    let status = #""status":{"state":"\#(state)","kind":"\#(kind)"}"#
    #expect(try terminal(status).agent?.blockedKind == expected)
  }

  @Test("tabs and workspaces wear their most urgent agent, and shells wear nothing")
  func rollUps() throws {
    let json = #"""
      {"terminals":[
      {"address":"t1","labels":{"herdr.space":"s","herdr.tab":"a"},"status":{"state":"idle"}},
      {"address":"t2","labels":{"herdr.space":"s","herdr.tab":"a"},"status":{"state":"error"}},
      {"address":"t3","labels":{"herdr.space":"s","herdr.tab":"b"},"status":{"state":"blocked"}},
      {"address":"t4","labels":{"herdr.space":"s","herdr.tab":"c"}}]}
      """#
    let workspace = try #require(CoreSnapshotMapper.tree(from: try decoded(json)).workspaces.only)
    #expect(workspace.status == .blocked)
    #expect(workspace.tabs.map(\.status) == [.error, .blocked, nil])
  }

  @Test("with no document, names come from `where`, split at the first separator")
  func namesFromWhere() throws {
    let tree = CoreSnapshotMapper.tree(
      from: try listing([("t1", labels(space: "a", tab: "b", where: "my / project / tests"))]))
    #expect(tree.workspaces.map(\.label) == ["my"])
    #expect(tree.workspaces[0].tabs.map(\.label) == ["project / tests"])
    #expect(tree.workspaces[0].tabs[0].isAutoNamed == false)
  }

  @Test("with neither, names are positions")
  func namesFromPosition() throws {
    let tree = CoreSnapshotMapper.tree(
      from: try listing([
        ("t1", labels(space: "a", tab: "x")), ("t2", labels(space: "a", tab: "y")),
        ("t3", labels(space: "b", tab: "z")),
      ]))
    #expect(tree.workspaces.map(\.label) == ["Space 1", "Space 2"])
    #expect(tree.workspaces[0].tabs.map(\.label) == ["Tab 1", "Tab 2"])
    #expect(tree.workspaces[0].tabs.allSatisfy { $0.isAutoNamed })
  }

  /// herdr-app names an unnamed tab by its number, as herdr does.
  @Test("a tab called only a number is auto-named and keeps its number")
  func digitTab() throws {
    let tree = CoreSnapshotMapper.tree(
      from: try listing([("box/t1", labels(space: "a", tab: "b", where: "root / 3"))]))
    let tab = try #require(tree.workspaces.only?.tabs.only)
    #expect(tab.isAutoNamed)
    #expect(tab.label == "Tab 3")
    #expect(tree.workspaces.only?.tabHeaderStyle == TabHeaderStyle.none)
  }

  @Test("a labelled terminal with no tab label still has a tab of its own")
  func spaceWithoutTab() throws {
    let tree = CoreSnapshotMapper.tree(
      from: try listing([("t1", #""herdr.space":"a","where":"only""#)]))
    let workspace = try #require(tree.workspaces.only)
    #expect(workspace.label == "only")
    #expect(workspace.tabs.only?.id == "core:a.tab")
    #expect(workspace.tabs.only?.label == "Tab 1")
  }

  @Test("the document's names win, and an empty one falls through to `where`")
  func documentNames() throws {
    let doc = try document(
      #"""
      {"spaces":[{"id":"a","name":"","tabs":[{"id":"b","name":"","root":null}]},
      {"id":"c","name":"Mine","tabs":[{"id":"d","name":"Logs"}]}]}
      """#)
    let tree = CoreSnapshotMapper.tree(
      from: try listing([
        ("t1", labels(space: "a", tab: "b", where: "from / where")),
        ("t2", labels(space: "c", tab: "d", where: "not / this")),
      ]),
      document: doc)
    #expect(tree.workspaces.map(\.label) == ["from", "Mine"])
    #expect(tree.workspaces.flatMap(\.tabs).map(\.label) == ["where", "Logs"])
  }

  @Test("the document orders spaces, tabs and leaves, and everything else follows as seen")
  func documentOrder() throws {
    let doc = try document(
      #"""
      {"spaces":[{"id":"second","tabs":[
      {"id":"y","root":{"children":[{"children":[\#(leaf("t4")),\#(leaf("t3"))]},\#(leaf("t2"))]}},
      {"id":"x"}]},
      {"id":"gone"},{"id":"first"}]}
      """#)
    let tree = CoreSnapshotMapper.tree(
      from: try listing([
        ("t9", ""),
        ("t0", labels(space: "unlisted", tab: "u")),
        ("t1", labels(space: "first", tab: "f")),
        ("t5", labels(space: "second", tab: "z")),
        ("t6", labels(space: "second", tab: "x")),
        ("t7", labels(space: "second", tab: "y")),
        ("t2", labels(space: "second", tab: "y")),
        ("t3", labels(space: "second", tab: "y")),
        ("t4", labels(space: "second", tab: "y")),
        ("box/t1", labels(space: "elsewhere", tab: "e")),
      ]),
      document: doc)
    #expect(
      tree.workspaces.map(\.id) == [
        "core:second", "core:first", "core:workspace", "core:unlisted", "core:box/elsewhere",
      ])
    #expect(tree.workspaces[0].tabs.map(\.id) == ["core:y", "core:x", "core:z"])
    #expect(tree.workspaces[0].tabs[0].panes.map(\.terminalID) == ["t4", "t3", "t2", "t7"])
  }

  @Test("the document adds no group and removes none")
  func documentOnlyOrders() throws {
    let doc = try document(#"{"spaces":[{"id":"a","tabs":[{"id":"b","root":\#(leaf("t1"))}]}]}"#)
    let list = try listing([("t2", labels(space: "c", tab: "d"))])
    let tree = CoreSnapshotMapper.tree(from: list, document: doc)
    #expect(tree.workspaces.map(\.id) == ["core:c"])
    #expect(tree.allPanes.map(\.id) == ["core:t2"])
  }

  /// The app's format is private, so a document of another shape is not an error.
  @Test("a document with nothing recognisable changes nothing")
  func strangeDocument() throws {
    let list = try decoded(Self.captured)
    let strange = try document(#"{"layout":{"v":2},"spaces":[{"tabs":[{"root":{"x":1}}]}]}"#)
    #expect(
      CoreSnapshotMapper.tree(from: list, document: strange) == CoreSnapshotMapper.tree(from: list)
    )
  }

  @Test("nothing running is no workspace at all")
  func emptyList() {
    #expect(CoreSnapshotMapper.tree(from: CoreListResult(terminals: [])).isEmpty)
  }

  @Test("the title is the name, then the title, then what runs in it")
  func titles() throws {
    #expect(try terminal(#""name":"build","title":"x""#).title == "build")
    #expect(try terminal(#""name":"","title":"x""#).title == "x")
    let running = #""title":"","foreground":{"argv":["/usr/bin/vim"],"name":"vi"}"#
    #expect(try terminal(running).title == "vim")
    let unnamed = #""title":"","foreground":{"argv":[],"name":"vi"}"#
    #expect(try terminal(unnamed).title == "vi")
    #expect(try terminal(#""title":"","argv":["/bin/zsh"]"#).title == "zsh")
    #expect(try terminal(#""title":"""#).title == "t1")
  }

  @Test("the directory is where it is now, then where it started")
  func directories() throws {
    let moved = #""cwd":"/a","foreground":{"cwd":"/b"}"#
    #expect(try terminal(moved).directory == "/b")
    #expect(try terminal(#""cwd":"/a","foreground":null"#).directory == "/a")
    #expect(try terminal(#""cwd":"""#).directory == nil)
  }

  @Test("its rows bound a read")
  func rows() throws {
    #expect(try terminal(#""rows":48"#).viewportRows == 48)
  }
}

extension Collection {
  /// The element of a one-element collection, so a test can state the count and use it at once.
  fileprivate var only: Element? { count == 1 ? first : nil }
}
