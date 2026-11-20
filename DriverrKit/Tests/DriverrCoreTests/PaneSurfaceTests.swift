import Testing

@testable import DriverrCore

/// The first-open rule: which surface a pane shows when it opens.
@Suite("PaneSurface.opening")
struct PaneSurfaceOpeningTests {
  @Test("a pane with a chat and no remembered surface opens where the setting says",
    arguments: PaneSurface.allCases)
  func theSettingDecidesANewPane(setting: PaneSurface) {
    #expect(
      PaneSurface.opening(hasChatSurface: true, remembered: nil, setting: setting) == setting)
  }

  /// Memory is the reader's own choice for one pane, so it outranks the global default.
  @Test("a remembered surface wins over either setting", arguments: [
    (PaneSurface.chat, PaneSurface.terminal), (.terminal, .chat), (.chat, .chat),
    (.terminal, .terminal),
  ])
  func memoryWins(remembered: PaneSurface, setting: PaneSurface) {
    #expect(
      PaneSurface.opening(hasChatSurface: true, remembered: remembered, setting: setting)
        == remembered)
  }

  @Test("a pane with no chat surface opens on the terminal under either setting",
    arguments: PaneSurface.allCases)
  func aShellIsAlwaysATerminal(setting: PaneSurface) {
    #expect(
      PaneSurface.opening(hasChatSurface: false, remembered: nil, setting: setting) == .terminal)
    // A stale entry for a pane whose agent quit does not bring back a chat it no longer has.
    #expect(
      PaneSurface.opening(hasChatSurface: false, remembered: .chat, setting: setting)
        == .terminal)
  }

  @Test("toggling goes to the other surface and back")
  func toggled() {
    #expect(PaneSurface.chat.toggled == .terminal)
    #expect(PaneSurface.terminal.toggled == .chat)
  }

  @Test("the setting's copy names both surfaces")
  func copy() {
    #expect(PanesOpenOnCopy.header == "Open Panes In")
    #expect(PanesOpenOnCopy.title(for: .chat) == "Chat")
    #expect(PanesOpenOnCopy.title(for: .terminal) == "Terminal")
    #expect(
      PanesOpenOnCopy.footer
        == "A pane you change between chat and terminal opens where you left it. A pane "
        + "without an agent always opens in the terminal.")
  }
}
