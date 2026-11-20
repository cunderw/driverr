import DriverrCore
import Foundation
import Testing

/// A pane row's second line, shared by the host screen's tree and the iPad sidebar.
struct PaneRowSubtitleTests {
  private static func pane(title: String, agent: Agent?, directory: String? = "~/src/app") -> Pane {
    Pane(
      id: "w1:p1", tabID: "w1:t1", workspaceID: "w1", title: title, agent: agent,
      directory: directory)
  }

  @Test("an agent pane names its agent and status in words")
  func agent() {
    let pane = Self.pane(title: "fix the build", agent: Agent(name: "claude", status: .working))
    #expect(pane.rowSubtitle(stop: nil) == "claude · Working")
  }

  /// The title already names the agent, so repeating it would waste the line.
  @Test("a pane titled after its agent shows status and directory")
  func titledAfterAgent() {
    let pane = Self.pane(title: "Claude", agent: Agent(name: "claude", status: .idle))
    #expect(pane.rowSubtitle(stop: nil) == "Idle · ~/src/app")
    let bare = Self.pane(title: "claude", agent: Agent(name: "claude", status: .idle), directory: nil)
    #expect(bare.rowSubtitle(stop: nil) == "Idle")
  }

  @Test("a stopped agent says Stopped, not herdr's Blocked")
  func stopped() {
    let pane = Self.pane(title: "fix the build", agent: Agent(name: "claude", status: .blocked))
    let stop = PaneStopBadge(
      notice: AgentStopNotice(stop: AgentStop(kind: .rateLimit, resetsAt: nil, message: "limit"),
        asOf: Date()))
    #expect(pane.rowSubtitle(stop: stop) == "claude · \(stop.label)")
  }

  @Test("a shell shows its directory, or nothing")
  func shell() {
    #expect(Self.pane(title: "zsh", agent: nil).rowSubtitle(stop: nil) == "~/src/app")
    #expect(Self.pane(title: "zsh", agent: nil, directory: nil).rowSubtitle(stop: nil) == nil)
  }
}
