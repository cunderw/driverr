import DriverrCore
import Foundation
import Testing

@testable import DriverrTmux

@Suite("ClaudeSessionRecord")
struct ClaudeSessionRecordTests {
  private func parse(_ json: String) -> ClaudeSessionRecord? {
    ClaudeSessionRecord.parse(Data(json.utf8))
  }

  @Test("a record reads its pid, session, status and directory")
  func parses() throws {
    let record = try #require(
      parse(
        #"{"pid":4242,"sessionId":"abc-123","cwd":"/home/dev","status":"busy","version":"2.1.325","extra":{"a":1}}"#
      ))
    #expect(record.pid == 4242)
    #expect(record.sessionID == "abc-123")
    #expect(record.directory == "/home/dev")
    #expect(record.status == "busy")
    #expect(record.waitingFor == nil)
  }

  @Test(
    "the status words map to an agent status, and waiting is blocked",
    arguments: [
      ("idle", AgentStatus.idle), ("busy", .working), ("waiting", .blocked),
      ("starting", .unknown), ("", .unknown),
    ])
  func status(word: String, expected: AgentStatus) throws {
    let record = try #require(parse(#"{"sessionId":"s","status":"\#(word)"}"#))
    #expect(record.agentStatus == expected)
    #expect(record.agent.status == expected)
  }

  @Test("no status at all is unknown, not idle")
  func noStatus() throws {
    let record = try #require(parse(#"{"sessionId":"s"}"#))
    #expect(record.agentStatus == .unknown)
  }

  @Test("waitingFor is display text: blocked is decided by status alone")
  func waitingFor() throws {
    let permission = try #require(
      parse(#"{"sessionId":"s","status":"waiting","waitingFor":"permission prompt"}"#))
    let question = try #require(
      parse(#"{"sessionId":"s","status":"waiting","waitingFor":"input needed"}"#))
    let unseen = try #require(parse(#"{"sessionId":"s","status":"waiting","waitingFor":"dialog open"}"#))
    let silent = try #require(parse(#"{"sessionId":"s","status":"waiting"}"#))
    for record in [permission, question, unseen, silent] {
      #expect(record.agentStatus == .blocked)
    }
    #expect(permission.waitingFor == "permission prompt")
    #expect(question.waitingFor == "input needed")
    // A working record that carries a waitingFor is not blocked by it.
    let busy = try #require(parse(#"{"sessionId":"s","status":"busy","waitingFor":"permission prompt"}"#))
    #expect(busy.agentStatus == .working)
  }

  @Test(
    "a waiting record says what it waits for, in the two words Claude Code writes",
    arguments: [
      ("permission prompt", AgentBlockedKind?.some(.permission)), ("input needed", .question),
      ("dialog open", nil), ("something new", nil),
    ])
  func blockedKind(waitingFor: String, expected: AgentBlockedKind?) throws {
    let record = try #require(
      parse(#"{"sessionId":"s","status":"waiting","waitingFor":"\#(waitingFor)"}"#))
    #expect(record.agent.blockedKind == expected)
    // Blocked or not is the status alone, whatever the text says.
    #expect(record.agent.status == .blocked)
  }

  @Test("only a waiting record has a blocked kind, and a waiting one with no text has none")
  func blockedKindNeedsWaiting() throws {
    for word in ["busy", "idle", "starting"] {
      let record = try #require(
        parse(#"{"sessionId":"s","status":"\#(word)","waitingFor":"permission prompt"}"#))
      #expect(record.agent.blockedKind == nil, "\(word)")
    }
    let silent = try #require(parse(#"{"sessionId":"s","status":"waiting"}"#))
    #expect(silent.agent.blockedKind == nil)
    #expect(silent.agent.status == .blocked)
  }

  @Test("the agent is Claude, with the session the record names")
  func agent() throws {
    let record = try #require(parse(#"{"sessionId":"abc","status":"idle"}"#))
    let agent = record.agent
    #expect(agent.name == "Claude")
    #expect(agent.kind == TranscriptAgent.claude.rawValue)
    #expect(agent.session?.identifier == "abc")
    #expect(agent.session?.agent == TranscriptAgent.claude.rawValue)
    #expect(agent.session?.source == AgentSession.claudeRecordSource)
    #expect(agent.blockedKind == nil)
    #expect(agent.machine == nil)
  }

  @Test(
    "a file that is not a record reads as nothing, and never crashes",
    arguments: [
      "", "not json", "[]", "null", "{}", #"{"sessionId":""}"#, #"{"sessionId":"  "}"#,
      #"{"sessionId":"a/b"}"#, #"{"sessionId":" padded "}"#, #"{"sessionId":42}"#,
      #"{"sessionId":"s","pid":"nope"}"#, #"{"sessionId":"s""#,
    ])
  func malformed(json: String) {
    #expect(parse(json) == nil)
  }

  @Test("bytes that are not text read as nothing")
  func notText() {
    #expect(ClaudeSessionRecord.parse(Data([0xFF, 0xFE, 0x00, 0x7B])) == nil)
  }

  @Test("blank optional fields are absent, not empty")
  func blanks() throws {
    let record = try #require(
      parse(#"{"sessionId":"s","status":"  ","waitingFor":"","cwd":" "}"#))
    #expect(record.status == nil)
    #expect(record.waitingFor == nil)
    #expect(record.directory == nil)
  }
}
