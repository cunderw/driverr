import Foundation
import Testing

@testable import DriverrCore

/// Claude Code's mode, read off the footer under its composer (#166), against real captures
/// from three transports and two Claude Code versions.
@Suite("Claude mode from the screen")
struct ClaudeModeTests {
  private func mode(_ ansi: String) -> ClaudeMode? {
    ClaudeMode(screen: PaneScreen.sanitised(ansi, lines: PaneScreen.maximumLines))
  }

  @Test("each mode of the cycle, on the herdr TUI")
  func herdrTUI() {
    #expect(mode(PaneScreenFixture.claudeCodeManualOnTUI) == .manual)
    #expect(mode(PaneScreenFixture.claudeCodeAcceptEditsOnTUI) == .acceptEdits)
    #expect(mode(PaneScreenFixture.claudeCodePlanOnTUI) == .plan)
    #expect(mode(PaneScreenFixture.claudeCodeAutoOnTUI) == .auto)
  }

  @Test("a herdr-core terminal, which carries no styling")
  func core() {
    #expect(mode(PaneScreenFixture.claudeCodeManualOnCore) == .manual)
    #expect(mode(PaneScreenFixture.claudeCodePlanOnCore) == .plan)
  }

  @Test("tmux, whose colours are the 30s and 90s")
  func tmux() {
    #expect(mode(PaneScreenFixture.claudeCodeAcceptEditsOnTmux) == .acceptEdits)
    #expect(mode(PaneScreenFixture.claudeCodeAutoOnTmux) == .auto)
  }

  /// The status-change trigger reads as work starts, so the row must be there while Claude
  /// works, or every working pane would read as manual.
  @Test("the mode row stays while Claude works")
  func whileWorking() {
    #expect(mode(PaneScreenFixture.claudeCodeManualWhileWorking) == .manual)
    let edits = PaneScreenFixture.claudeCodeManualWhileWorking.replacingOccurrences(
      of: "⏸ manual mode on", with: "⏵⏵ accept edits on")
    #expect(mode(edits) == .acceptEdits)
  }

  /// 2.1.241 at the phone's width cut the hint to `(shift+tab to  · `, and a wide pane had a
  /// `/rc` row under the mode row. Both still name the mode.
  @Test("an older Claude Code, with a cut hint and a row under the mode")
  func olderVersion() {
    #expect(mode(PaneScreenFixture.claudeCodeAssistantMessage) == .auto)
    #expect(mode(PaneScreenFixture.claudeCodeSentUserTurns) == .auto)
    #expect(mode(PaneScreenFixture.claudeCodeComposerText) == .auto)
    #expect(mode(PaneScreenFixture.claudeCodeFreshSession) == .auto)
  }

  /// At 18 columns the row loses its `on`. A whole name still counts and a cut one does not.
  @Test("a row cut by a narrow pane names a mode only while its name is whole")
  func cutRow() {
    #expect(mode(PaneScreenFixture.claudeCodeManualAt18) == .manual)
    #expect(mode(PaneScreenFixture.claudeCodeAcceptEditsAt18) == nil)
  }

  private static let rule = String(repeating: "─", count: 30)

  /// A conversation can quote the footer. Only rows under the composer count.
  @Test("the words above the composer are not the footer")
  func conversationIsNotTheFooter() {
    let screen = [
      "⏺ The footer now says",
      "  ⏸ plan mode on (shift+tab to cycle)",
      Self.rule,
      "❯\u{A0}",
      Self.rule,
      "  ⏸ manual mode on · ← 1 agent",
    ].joined(separator: "\n")
    #expect(mode(screen) == .manual)

    // The same quote over a footer with no mode row: the older manual mode, not plan.
    let older = [
      "  ⏸ plan mode on (shift+tab to cycle)",
      Self.rule,
      "❯\u{A0}",
      Self.rule,
      "  ? for shortcuts",
    ].joined(separator: "\n")
    #expect(mode(older) == .manual)
  }

  /// Manual is an answer, so it needs the composer. A permission prompt or a blank screen
  /// says nothing.
  @Test("no composer is no answer, whatever the footer says")
  func noComposer() {
    #expect(mode("") == nil)
    let prompt = [
      Self.rule,
      " Bash command",
      "   rm -rf build",
      " Do you want to proceed?",
      " ❯ 1. Yes",
      "   2. No",
      "",
      " Esc to cancel",
    ].joined(separator: "\n")
    #expect(mode(prompt) == nil)
    // A rule pair with something other than the composer between them.
    let box = [Self.rule, "  ⏸ plan mode on", Self.rule, "  ⏸ plan mode on"]
      .joined(separator: "\n")
    #expect(mode(box) == nil)
  }

  @Test("a multi-line draft is still the composer")
  func multiLineDraft() {
    let screen = [
      Self.rule, "❯\u{A0}first line", "  second line", Self.rule, "  ⏵⏵ auto mode on",
    ].joined(separator: "\n")
    #expect(mode(screen) == .auto)
  }

  /// The cycle is the user's, so a mode this build has never seen is named in its own words.
  @Test("an unknown mode keeps the footer's name")
  func unknownMode() {
    let screen = [Self.rule, "❯\u{A0}", Self.rule, "  ⏵⏵ focus mode on (shift+tab to cycle)"]
      .joined(separator: "\n")
    #expect(mode(screen) == .other("focus mode"))
    #expect(ClaudeMode.other("focus mode").label == "Focus mode")
    #expect(ClaudeMode.other("focus mode").spokenName == "Focus mode")
    let bypass = [Self.rule, "❯\u{A0}", Self.rule, "  ⏵⏵ bypass permissions on"]
      .joined(separator: "\n")
    #expect(mode(bypass) == .bypassPermissions)
  }

  /// Other footer rows open with a symbol too.
  @Test("a notice under the composer is not a mode row")
  func noticeIsNotAMode() {
    let screen = [Self.rule, "❯\u{A0}", Self.rule, "  ✔ Update installed · Restart to update"]
      .joined(separator: "\n")
    #expect(mode(screen) == .manual)
  }

  @Test("every mode has words and a spoken name, manual included")
  func words() {
    #expect(ClaudeMode.manual.label == "Manual")
    #expect(ClaudeMode.manual.spokenName == "Manual mode")
    #expect(ClaudeMode.acceptEdits.label == "Edits")
    #expect(ClaudeMode.acceptEdits.spokenName == "Accept edits")
    #expect(ClaudeMode.plan.spokenName == "Plan mode")
  }
}
