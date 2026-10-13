import Testing

@testable import Driverr

/// What Escape does on the pane screen: it never leaves the scene, and closes an open prompt
/// bar or sheet only when no terminal holds focus.
///
/// XCUITest delivers Escape to nothing in this app, neither to a focused field nor to a
/// `.keyboardShortcut(.escape)` button, so this is the only automated check. The rule is a
/// named value rather than a branch in a body for that reason.
///
/// The Escape button is in the view tree only when this answers something. A wrong `nil` leaves
/// a closable thing open; a wrong answer takes the Escape key from the far side.
///
/// `@MainActor` because `TerminalScreen`'s static members are main-actor isolated.
@MainActor
@Suite("TerminalScreen.escapeAction")
struct TerminalScreenEscapeTests {
  @Test("with nothing open, Escape belongs to the terminal")
  func nothingOpenLeavesEscapeAlone() {
    #expect(
      TerminalScreen.escapeAction(
        isShowingPaneSheet: false,
        isShowingSettings: false,
        hasPrompt: false,
        terminalHoldsKeyboard: true
      ) == nil
    )
  }

  /// The chat is on screen, so no terminal has the keyboard, and there is nothing to close.
  /// Escape does nothing rather than leaving the scene.
  @Test("with nothing open, Escape does not leave the scene even from the chat")
  func nothingOpenDoesNotDismissTheScene() {
    #expect(
      TerminalScreen.escapeAction(
        isShowingPaneSheet: false,
        isShowingSettings: false,
        hasPrompt: false,
        terminalHoldsKeyboard: false
      ) == nil
    )
  }

  /// A sheet is a presentation, so the terminal behind it is not first responder whatever
  /// the surface underneath says. Both sheets therefore ignore the focus argument.
  @Test("the pane sheet closes, whatever the surface behind it is")
  func paneSheetClosesRegardlessOfFocus() {
    #expect(
      TerminalScreen.escapeAction(
        isShowingPaneSheet: true,
        isShowingSettings: false,
        hasPrompt: false,
        terminalHoldsKeyboard: true
      ) == .closePaneSheet
    )
  }

  @Test("Settings closes, whatever the surface behind it is")
  func settingsClosesRegardlessOfFocus() {
    #expect(
      TerminalScreen.escapeAction(
        isShowingPaneSheet: false,
        isShowingSettings: true,
        hasPrompt: true,
        terminalHoldsKeyboard: true
      ) == .closeSettings
    )
  }

  /// The prompt bar is inline beside the terminal, so the terminal may still be typing, and
  /// Escape stays with the far side.
  @Test("an inline prompt over a focused terminal leaves Escape to the terminal")
  func promptOverAFocusedTerminalLeavesEscapeAlone() {
    #expect(
      TerminalScreen.escapeAction(
        isShowingPaneSheet: false,
        isShowingSettings: false,
        hasPrompt: true,
        terminalHoldsKeyboard: false
      ) == .dismissPrompt
    )
    #expect(
      TerminalScreen.escapeAction(
        isShowingPaneSheet: false,
        isShowingSettings: false,
        hasPrompt: true,
        terminalHoldsKeyboard: true
      ) == nil
    )
  }

  /// Both sheets up at once does not happen, but the pane sheet is raised over Settings, so it
  /// is the one Escape takes down.
  @Test("the pane sheet is answered before Settings")
  func paneSheetWinsOverSettings() {
    #expect(
      TerminalScreen.escapeAction(
        isShowingPaneSheet: true,
        isShowingSettings: true,
        hasPrompt: true,
        terminalHoldsKeyboard: false
      ) == .closePaneSheet
    )
  }
}

/// The `Chat | Terminal` key.
@MainActor
@Suite("PaneSurface.toggled")
struct PaneSurfaceToggleTests {
  @Test("each surface toggles to the other, and back again")
  func toggleIsItsOwnInverse() {
    #expect(PaneSurface.chat.toggled == .terminal)
    #expect(PaneSurface.terminal.toggled == .chat)
    #expect(PaneSurface.chat.toggled.toggled == .chat)
  }
}
