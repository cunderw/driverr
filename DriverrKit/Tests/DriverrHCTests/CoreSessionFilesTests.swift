import DriverrCore
import DriverrHerdr
import Foundation
import Testing

@testable import DriverrHC

/// Through `CoreControl.snapshot`, because what matters is the session on the pane.
@Suite("Core session files", .timeLimit(.minutes(1)))
struct CoreSessionFilesTests {
  private static let home = "/home/my user"

  private func control(
    _ stream: FakeCoreStream,
    home: String? = Self.home,
    deadline: Duration = .seconds(30)
  ) -> CoreControl {
    CoreControl(binaryPath: "hc", home: home, callDeadline: deadline, open: { _ in stream })
  }

  private func path(_ pid: Int) -> String {
    "\(Self.home)/.claude/sessions/\(pid).json"
  }

  private func record(pid: Int, id: String) -> FakeCoreStream.Reply {
    Self.file(#"{"pid":\#(pid),"sessionId":"\#(id)","cwd":"/elsewhere","kind":"interactive"}"#)
  }

  /// A `file.read` answer around `text`, as a real core 0.1.14 wrote one.
  private static func file(_ text: String) -> FakeCoreStream.Reply {
    let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
    return .result(#"{"first":1,"last":1,"lines":1,"text":"\#(escaped)\n"}"#)
  }

  private func claude(_ address: String, pid: Int) -> String {
    #"""
    {"address":"\#(address)","cwd":"/srv","foreground":{"argv":["claude"],"cwd":"/srv",
    "name":"2.1.314","pid":\#(pid)},"status":{"app":"claude-code","state":"working"}}
    """#
  }

  private func listing(_ terminals: [String]) -> FakeCoreStream.Reply {
    .result(#"{"terminals":[\#(terminals.joined(separator: ","))]}"#)
  }

  private func stream(_ terminals: String...) -> FakeCoreStream {
    let stream = FakeCoreStream()
    stream.replies["terminal.list"] = listing(terminals)
    return stream
  }

  private func sessions(_ tree: SessionTree) -> [String: String?] {
    Dictionary(
      uniqueKeysWithValues: tree.allPanes.map { ($0.id, $0.agent?.session?.identifier) })
  }

  @Test("two Claudes in one folder each get their own session")
  func twoInOneFolder() async throws {
    let stream = stream(claude("t1", pid: 101), claude("t2", pid: 102))
    stream.files = [
      path(101): record(pid: 101, id: "first"),
      path(102): record(pid: 102, id: "second"),
    ]
    let tree = try await control(stream).snapshot()

    #expect(tree.pane(id: "core:t1")?.directory == tree.pane(id: "core:t2")?.directory)
    #expect(sessions(tree) == ["core:t1": "first", "core:t2": "second"])
    #expect(
      tree.pane(id: "core:t1")?.agent?.session
        == AgentSession(agent: "claude", kind: "id", value: "first", source: "claude:sessions"))
  }

  /// `.key` files sit beside the records, so anything broader than one exact name would read
  /// a stranger's.
  @Test("only a local Claude is read for, and only its one exact file")
  func oneExactFile() async throws {
    let shell = #"{"address":"t3","foreground":{"argv":["zsh"],"pid":103}}"#
    let quietClaude = #"{"address":"t4","foreground":{"argv":["claude"],"pid":104}}"#
    let codex = #"""
      {"address":"t5","foreground":{"argv":["codex"],"pid":105},
      "status":{"app":"codex","state":"idle"}}
      """#
    let noPID = #"{"address":"t6","status":{"app":"claude-code","state":"idle"}}"#
    let elsewhere = #"""
      {"address":"box/t1","foreground":{"argv":["claude"],"pid":106},
      "status":{"app":"claude-code","state":"idle"}}
      """#
    let stream = stream(claude("t1", pid: 101), shell, quietClaude, codex, noPID, elsewhere)
    stream.files = [path(101): record(pid: 101, id: "first")]
    _ = try await control(stream).snapshot()
    #expect(stream.readPaths == [path(101)])
  }

  @Test("the record of a status with no app is read too")
  func noApp() async throws {
    let stream = stream(
      #"{"address":"t1","foreground":{"argv":["claude"],"pid":101},"status":{"state":"idle"}}"#)
    stream.files = [path(101): record(pid: 101, id: "first")]
    #expect(sessions(try await control(stream).snapshot()) == ["core:t1": "first"])
  }

  @Test("with no home nothing is read, and the terminal has no session")
  func noHome() async throws {
    let stream = stream(claude("t1", pid: 101))
    stream.files = [path(101): record(pid: 101, id: "first")]
    let tree = try await control(stream, home: nil).snapshot()
    #expect(sessions(tree) == ["core:t1": nil])
    #expect(!stream.methods.contains("file.read"))
  }

  /// Everything a record can be wrong in. Each leaves the pane to the reader's directory match.
  private static let failures: [FakeCoreStream.Reply] = [
    .error("no file"),
    file("not json"),
    file(#"{"pid":101}"#),
    file(#"{"pid":"101","sessionId":"x"}"#),
    file(#"{"pid":999,"sessionId":"someone-else"}"#),
    file(#"{"pid":101,"sessionId":""}"#),
    file(#"{"pid":101,"sessionId":"a/b"}"#),
    file(#"{"pid":101,"sessionId":" padded "}"#),
    .result(#"{"unexpected":true}"#),
  ]

  @Test("a record that cannot be used leaves no session", arguments: Self.failures)
  func unusableRecord(failure: FakeCoreStream.Reply) async throws {
    let stream = stream(claude("t1", pid: 101))
    stream.files = [path(101): failure]
    #expect(sessions(try await control(stream).snapshot()) == ["core:t1": nil])
  }

  @Test("no record at all leaves no session, and the snapshot stands")
  func missingRecord() async throws {
    let tree = try await control(stream(claude("t1", pid: 101))).snapshot()
    #expect(sessions(tree) == ["core:t1": nil])
  }

  @Test("a later failure keeps the id", arguments: Self.failures)
  func failureKeepsTheID(failure: FakeCoreStream.Reply) async throws {
    let stream = stream(claude("t1", pid: 101))
    stream.files = [path(101): record(pid: 101, id: "first")]
    let control = control(stream)
    #expect(sessions(try await control.snapshot()) == ["core:t1": "first"])

    stream.files = [path(101): failure]
    #expect(sessions(try await control.snapshot()) == ["core:t1": "first"])
  }

  /// Claude running something in the foreground: the pid is not Claude's and there is no
  /// record, for as long as that runs.
  @Test("a foreground child keeps the id")
  func foregroundChild() async throws {
    let stream = stream(claude("t1", pid: 101))
    stream.files = [path(101): record(pid: 101, id: "first")]
    let control = control(stream)
    _ = try await control.snapshot()

    stream.replies["terminal.list"] = listing([claude("t1", pid: 500)])
    #expect(sessions(try await control.snapshot()) == ["core:t1": "first"])
    #expect(stream.readPaths.last == path(500))
  }

  @Test("a call that never answers costs the deadline, not the snapshot or the id")
  func silentRecord() async throws {
    let stream = stream(claude("t1", pid: 101))
    stream.files = [path(101): record(pid: 101, id: "first")]
    let control = control(stream, deadline: .milliseconds(500))
    _ = try await control.snapshot()

    stream.files = [path(101): .silent]
    #expect(sessions(try await control.snapshot()) == ["core:t1": "first"])
  }

  @Test("/clear lands on the next poll")
  func newID() async throws {
    let stream = stream(claude("t1", pid: 101))
    stream.files = [path(101): record(pid: 101, id: "before")]
    let control = control(stream)
    _ = try await control.snapshot()

    stream.files = [path(101): record(pid: 101, id: "after")]
    #expect(sessions(try await control.snapshot()) == ["core:t1": "after"])
  }

  @Test("a terminal that stops being Claude forgets its id")
  func stopsBeingClaude() async throws {
    let stream = stream(claude("t1", pid: 101))
    stream.files = [path(101): record(pid: 101, id: "first")]
    let control = control(stream)
    _ = try await control.snapshot()

    stream.replies["terminal.list"] = listing([
      #"{"address":"t1","foreground":{"argv":["zsh"],"pid":200}}"#
    ])
    #expect(sessions(try await control.snapshot()) == ["core:t1": nil])

    // Back, with no record yet: the old id is another process's.
    stream.replies["terminal.list"] = listing([claude("t1", pid: 300)])
    #expect(sessions(try await control.snapshot()) == ["core:t1": nil])
  }

  @Test("a terminal that leaves forgets its id")
  func leaves() async throws {
    let stream = stream(claude("t1", pid: 101))
    stream.files = [path(101): record(pid: 101, id: "first")]
    let control = control(stream)
    _ = try await control.snapshot()

    stream.replies["terminal.list"] = listing([])
    _ = try await control.snapshot()

    stream.replies["terminal.list"] = listing([claude("t1", pid: 300)])
    #expect(sessions(try await control.snapshot()) == ["core:t1": nil])
  }
}
