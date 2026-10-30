import DriverrCore
import DriverrHerdr
import Foundation
import Testing

@testable import DriverrHC

@Suite("Core snapshot mapping")
struct CoreSnapshotMapperTests {
  /// `terminal.list` as a real core 0.1.14 answered, cut down to three terminals: a local one
  /// with a title, one whose title is `""`, and one on a machine the core added. The fields
  /// Driverr does not read stay, so this proves they do not disturb the decode.
  private static let captured = #"""
    {"hidden_finished":22,"machines":[{"host":"nas","id":"5b37","name":"10.1.0.254",
    "session":null,"state":"connected","target":"root@10.1.0.254","temporary":false,
    "version":"0.1.14","via":false}],"terminals":[
    {"address":"t1","argv":["/bin/zsh"],"cols":257,"created_ms":1793377161500,
    "cwd":"/home/me","die_with_parent":false,"exit_code":null,"finished_ms":null,
    "foreground":{"argv":["claude","--model","opus"],"cwd":"/home/me","name":"2.1.314","pid":18640},
    "identity":"ghostty","keep":true,"labels":{"where":"main / vault"},"name":null,"notify":true,
    "parent":null,"pid":17916,"reason":null,"reported":true,"rm":false,"rows":48,"screen":"exact",
    "signal":null,"state":"live","status":{"app":"claude-code","msg":"done","state":"done"},
    "status_ms":1793379211630,"template":null,"title":"cunderw","turn":9},
    {"address":"t6","argv":["/bin/zsh"],"cols":126,"created_ms":1793377805603,"cwd":"/home/me",
    "die_with_parent":false,"exit_code":null,"finished_ms":null,
    "foreground":{"argv":["/usr/local/bin/nvim"],"cwd":"/home/me/project","name":"nvim","pid":75627},
    "identity":"ghostty","keep":true,"labels":{},"name":null,"notify":true,"parent":null,
    "pid":24653,"reason":null,"reported":false,"rm":false,"rows":36,"screen":"exact",
    "signal":null,"state":"live","status":null,"template":null,"title":"","turn":0},
    {"address":"10.1.0.254/t1","argv":["/bin/bash"],"cols":80,"created_ms":1,"cwd":"/root",
    "foreground":null,"labels":{},"name":null,"rows":24,"screen":"exact","state":"live",
    "title":""}]}
    """#

  private func mapped() throws -> SessionTree {
    let list = try JSONDecoder().decode(CoreListResult.self, from: Data(Self.captured.utf8))
    return CoreSnapshotMapper.tree(from: list)
  }

  private func terminal(_ fields: String) throws -> Pane {
    let json = #"{"terminals":[{"address":"t1",\#(fields)}]}"#
    let list = try JSONDecoder().decode(CoreListResult.self, from: Data(json.utf8))
    return try #require(CoreSnapshotMapper.tree(from: list).allPanes.first)
  }

  @Test("one workspace, one tab, machine terminals included")
  func flatTree() throws {
    let tree = try mapped()
    let workspace = try #require(tree.workspaces.only)
    let tab = try #require(workspace.tabs.only)
    #expect(workspace.label == "herdr-core")
    #expect(workspace.tabHeaderStyle == .none)
    #expect(tab.panes.map(\.terminalID) == ["t1", "t6", "10.1.0.254/t1"])
  }

  @Test("every id routes to the core side of a combined host")
  func idsAreCoreIDs() throws {
    let tree = try mapped()
    let workspace = try #require(tree.workspaces.only)
    let tab = try #require(workspace.tabs.only)
    #expect(CorePaneID.isCore(workspace.id))
    #expect(CorePaneID.isCore(tab.id))
    #expect(tree.allPanes.allSatisfy { CorePaneID.isCore($0.id) })
    #expect(tree.allPanes.map(\.id) == ["core:t1", "core:t6", "core:10.1.0.254/t1"])
    #expect(tree.allPanes.allSatisfy { $0.tabID == tab.id && $0.workspaceID == workspace.id })
  }

  @Test("no agent, because that is #17's mapping")
  func noAgents() throws {
    #expect(try mapped().allPanes.allSatisfy { $0.agent == nil })
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
