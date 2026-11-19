import Testing

@testable import DriverrCore

/// The chat's Shift-Tab control: for Claude Code panes Shift-Tab reaches, and off while
/// Claude is asking something, because its permission prompt binds Shift-Tab to "Yes, and
/// switch to accept edits".
@Suite("Pane mode control")
struct PaneModeControlTests {
  private func pane(_ agent: Agent?) -> Pane {
    Pane(id: "w1:p1", tabID: "w1:t1", workspaceID: "w1", title: "claude", agent: agent)
  }

  @Test("a Claude pane gets it, ready unless blocked")
  func claudePane() {
    for status in [AgentStatus.idle, .working, .done, .error, .unknown] {
      let claude = pane(Agent(name: "Claude", kind: "claude", status: status))
      #expect(PaneModeControl(pane: claude, deliversShiftTab: true) == .ready, "\(status)")
    }
    let blocked = pane(Agent(name: "Claude", kind: "claude", status: .blocked))
    #expect(PaneModeControl(pane: blocked, deliversShiftTab: true) == .blocked)
  }

  @Test("hidden where Shift would not survive the trip")
  func hiddenWithoutShift() {
    let claude = pane(Agent(name: "Claude", kind: "claude", status: .idle))
    #expect(PaneModeControl(pane: claude, deliversShiftTab: false) == .hidden)
  }

  /// Shift-Tab means something else to every other program, or nothing.
  @Test("hidden for a shell and for any other agent")
  func hiddenForOthers() {
    #expect(PaneModeControl(pane: pane(nil), deliversShiftTab: true) == .hidden)
    let codex = pane(Agent(name: "Codex", kind: "codex", status: .idle))
    #expect(PaneModeControl(pane: codex, deliversShiftTab: true) == .hidden)
    let unnamed = pane(Agent(name: "Agent", kind: nil, status: .idle))
    #expect(PaneModeControl(pane: unnamed, deliversShiftTab: true) == .hidden)
  }

  /// The same token rule as the transcript reader: the session's agent outranks the slug.
  @Test("the reported session's agent outranks the pane's slug")
  func sessionAgentWins() {
    let session = AgentSession(agent: "Claude", kind: "id", value: "abc")
    let claude = pane(Agent(name: "Claude", kind: nil, status: .idle, session: session))
    #expect(PaneModeControl(pane: claude, deliversShiftTab: true) == .ready)
    let codexSession = AgentSession(agent: "codex", kind: "id", value: "abc")
    let notClaude = pane(
      Agent(name: "Claude", kind: "claude", status: .idle, session: codexSession))
    #expect(PaneModeControl(pane: notClaude, deliversShiftTab: true) == .hidden)
  }

  @Test("it is named for what it does, and spoken the same way")
  func words() {
    #expect(PaneModeControl.label == "Change mode")
    #expect(!PaneModeControl.hint.isEmpty)
    #expect(PaneModeControl.blockedHint != PaneModeControl.hint)
  }
}
