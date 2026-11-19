import Foundation
import Testing

@testable import DriverrCore

/// What tells a pane from one that inherited its id. herdr's pane ids are positional, so a
/// rebuilt session reports the same string for a different pane.
@Suite("A pane's session witness")
struct PaneSessionWitnessTests {
  private func pane(terminalID: String? = nil, directory: String? = nil) -> Pane {
    Pane(
      id: "w1:p1", tabID: "w1:t1", workspaceID: "w1", title: "terminal wiring",
      terminalID: terminalID, directory: directory)
  }

  /// herdr allocates the terminal id from the clock and an atomic and forbids deriving it,
  /// so a rebuilt session cannot reproduce it.
  @Test("the terminal id is the witness when herdr reports one")
  func theTerminalIDIsPreferred() {
    #expect(pane(terminalID: "term_a1", directory: "~/dev/driverr").sessionWitness == "term_a1")
  }

  /// The cwd for snapshots older than protocol 19, where the terminal id is optional. It
  /// discriminates less, but covers the common case where the slot holds something else.
  @Test("the directory is the witness when no terminal id arrives")
  func theDirectoryIsTheFallback() {
    #expect(pane(directory: "~/dev/driverr").sessionWitness == "~/dev/driverr")
  }

  /// An empty string would match on a check that proves nothing.
  @Test("an empty terminal id falls through to the directory")
  func anEmptyTerminalIDFallsThrough() {
    #expect(pane(terminalID: "", directory: "~/dev/driverr").sessionWitness == "~/dev/driverr")
  }

  /// A tmux pane's terminal id is its own id, and tmux reuses `%3` after its server restarts, so
  /// a new pane in that slot would read as the old one resumed.
  @Test("a terminal id that is the pane's own id is no witness")
  func theOwnIDIsNoWitness() {
    let tmux = Pane(
      id: "tmux:%3", tabID: "tmux:@1", workspaceID: "tmux:$0", title: "zsh",
      terminalID: "tmux:%3", directory: "/home/dev/app")
    #expect(tmux.sessionWitness == "/home/dev/app")
    let bare = Pane(
      id: "tmux:%3", tabID: "tmux:@1", workspaceID: "tmux:$0", title: "zsh", terminalID: "tmux:%3")
    #expect(bare.sessionWitness == nil)
  }

  /// The rule above changes nothing for herdr or a core: neither's terminal id is its pane id.
  @Test("herdr and core panes keep their terminal ids as witnesses")
  func herdrAndCoreWitnessesAreUnchanged() {
    let herdr = Pane(
      id: "w1:p1", tabID: "w1:t1", workspaceID: "w1", title: "zsh", terminalID: "term_a1",
      directory: "~/dev/driverr")
    #expect(herdr.sessionWitness == "term_a1")
    let core = Pane(
      id: "core:t7", tabID: "core:tab", workspaceID: "core:workspace", title: "t7",
      terminalID: "t7", directory: "~/dev/driverr")
    #expect(core.sessionWitness == "t7")
    let machine = Pane(
      id: "core:box/t1", tabID: "core:tab", workspaceID: "core:workspace", title: "t1",
      terminalID: "box/t1")
    #expect(machine.sessionWitness == "box/t1")
  }

  /// `ConnectionModel.noteLastPane` then forgets rather than writing an unverifiable record.
  @Test("a pane with neither field has no witness")
  func neitherFieldIsNoWitness() {
    #expect(pane().sessionWitness == nil)
    #expect(pane(terminalID: "", directory: "").sessionWitness == nil)
  }

  /// Not the agent's session id: herdr keeps the terminal id when the agent restarts, so the
  /// reader returns to the pane they were in.
  @Test("restarting the agent in a pane does not change its witness")
  func anAgentRestartKeepsTheWitness() {
    let before = Pane(
      id: "w1:p2", tabID: "w1:t1", workspaceID: "w1", title: "needs a decision",
      agent: Agent(
        name: "Claude", kind: "claude", status: .blocked,
        session: AgentSession(agent: "claude", kind: "id", value: "session-one")),
      terminalID: "term_b2", directory: "~/dev/driverr")
    let after = Pane(
      id: "w1:p2", tabID: "w1:t1", workspaceID: "w1", title: "needs a decision",
      agent: Agent(
        name: "Claude", kind: "claude", status: .idle,
        session: AgentSession(agent: "claude", kind: "id", value: "session-two")),
      terminalID: "term_b2", directory: "~/dev/driverr")

    #expect(before.sessionWitness == after.sessionWitness)
    #expect(before.agent?.session?.identifier != after.agent?.session?.identifier)
  }
}
