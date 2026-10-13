import Testing

@testable import Driverr

/// The surface memory on its own: what it hands back, one answer per pane, and letting go of a
/// pane that has left the session. The scene-level consequences are in
/// `TerminalSceneModelTests`.
@MainActor
@Suite("PaneSurfaceMemory")
struct PaneSurfaceMemoryTests {
  /// `nil` rather than a surface of its own, because "nobody has chosen" and "chose chat"
  /// are different facts and only the caller knows the first-open rule.
  @Test("a pane nobody has switched is not remembered at all")
  func nothingIsRememberedUntilSomethingIsChosen() {
    let memory = PaneSurfaceMemory()

    #expect(memory.surface(for: "w1:p1") == nil)
  }

  @Test("each pane keeps its own answer")
  func panesAreRememberedSeparately() {
    let memory = PaneSurfaceMemory()

    memory.remember(.terminal, for: "w1:p1")
    memory.remember(.chat, for: "w1:p2")

    #expect(memory.surface(for: "w1:p1") == .terminal)
    #expect(memory.surface(for: "w1:p2") == .chat)
  }

  @Test("the latest choice is the one kept")
  func rememberingAgainReplacesTheAnswer() {
    let memory = PaneSurfaceMemory()

    memory.remember(.terminal, for: "w1:p1")
    memory.remember(.chat, for: "w1:p1")

    #expect(memory.surface(for: "w1:p1") == .chat)
  }

  /// herdr reuses a pane id after a close, so a pane that has gone takes its choice with it
  /// rather than handing it to whatever is next called `w1:p1`.
  @Test("a pane that has left the session is forgotten")
  func aDepartedPaneIsForgotten() {
    let memory = PaneSurfaceMemory()
    memory.remember(.terminal, for: "w1:p1")
    memory.remember(.terminal, for: "w1:p2")

    memory.forgetEverythingExcept(["w1:p2"])

    #expect(memory.surface(for: "w1:p1") == nil)
    #expect(memory.surface(for: "w1:p2") == .terminal)
  }
}
