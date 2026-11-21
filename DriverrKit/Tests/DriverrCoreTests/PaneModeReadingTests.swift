import Testing

@testable import DriverrCore

/// When the chat believes a screen about Claude Code's mode (#166). The first read after a
/// Shift-Tab often still shows the old mode, because Claude redraws about 70 ms later.
@Suite("Pane mode reading")
struct PaneModeReadingTests {
  private static let rule = String(repeating: "─", count: 30)

  private func screen(_ footer: String?) -> PaneScreen {
    var rows = [Self.rule, "❯\u{A0}", Self.rule]
    if let footer { rows.append(footer) }
    return PaneScreen.sanitised(rows.joined(separator: "\n"), lines: PaneScreen.maximumLines)
  }

  /// `#expect` cannot take a mutating call, so this lifts it out. With no ticket, the read
  /// started after the latest Shift-Tab, here and in `failed`.
  private func read(
    _ reading: inout PaneModeReading, _ screen: PaneScreen, ticket: Int? = nil
  ) -> Bool {
    reading.read(screen, ticket: ticket ?? reading.ticket)
  }

  private func failed(_ reading: PaneModeReading, ticket: Int? = nil) -> Bool {
    reading.failed(ticket: ticket ?? reading.ticket)
  }

  private var manual: PaneScreen { screen("  ⏸ manual mode on · ← 1 agent") }
  private var edits: PaneScreen { screen("  ⏵⏵ accept edits on · ← 1 agent") }
  private var plan: PaneScreen { screen("  ⏸ plan mode on (shift+tab to cycle)") }

  @Test("a read replaces the mode")
  func readReplaces() {
    var reading = PaneModeReading()
    #expect(reading.mode == nil)
    #expect(!read(&reading, edits))
    #expect(reading.mode == .acceptEdits)
    #expect(!read(&reading, plan))
    #expect(reading.mode == .plan)
  }

  /// A permission prompt replaces the composer, so its screen names no mode. The mode has not
  /// changed, and dropping it shrank the button to the glyph for the length of the block.
  @Test("a screen with no composer keeps the last known mode")
  func noComposerKeepsTheMode() {
    var reading = PaneModeReading(mode: .acceptEdits)
    let prompt = PaneScreen.sanitised(
      [Self.rule, " Do you want to proceed?", " ❯ 1. Yes", "   2. No", " Esc to cancel"]
        .joined(separator: "\n"),
      lines: PaneScreen.maximumLines)
    #expect(ClaudeMode(screen: prompt) == nil)
    #expect(!read(&reading, prompt))
    #expect(reading.mode == .acceptEdits)
    #expect(!read(&reading, .blank))
    #expect(reading.mode == .acceptEdits)
    #expect(!read(&reading, plan))
    #expect(reading.mode == .plan)
  }

  @Test("a Shift-Tab marks the mode stale and keeps it on show")
  func toggleMarksStale() {
    var reading = PaneModeReading(mode: .manual)
    reading.toggled()
    #expect(reading.isStale)
    #expect(reading.mode == .manual)
  }

  @Test("a read showing the new mode is believed at once")
  func newModeBelieved() {
    var reading = PaneModeReading(mode: .manual)
    reading.toggled()
    #expect(!read(&reading, edits))
    #expect(reading.mode == .acceptEdits)
    #expect(!reading.isStale)
  }

  @Test("a read still showing the old mode asks again, twice at most, then believes it")
  func oldModeRereadTwice() {
    var reading = PaneModeReading(mode: .manual)
    reading.toggled()
    #expect(read(&reading, manual))
    #expect(reading.isStale)
    #expect(read(&reading, manual))
    #expect(!read(&reading, manual))
    #expect(reading.mode == .manual)
    #expect(!reading.isStale)
  }

  @Test("the second read can be the one that shows the change")
  func changeOnReread() {
    var reading = PaneModeReading(mode: .manual)
    reading.toggled()
    #expect(read(&reading, manual))
    #expect(!read(&reading, edits))
    #expect(reading.mode == .acceptEdits)
  }

  /// `refresh()` does nothing while a read is in flight, so the read that lands may have
  /// started before the key went.
  @Test("a read that started before the Shift-Tab asks again and spends nothing")
  func readFromBeforeTheToggle() {
    var reading = PaneModeReading(mode: .manual)
    let before = reading.ticket
    reading.toggled()
    #expect(read(&reading, manual, ticket: before))
    #expect(read(&reading, manual, ticket: before))
    #expect(reading.isStale)
    // The full allowance is still there.
    #expect(read(&reading, manual))
    #expect(read(&reading, manual))
    #expect(!read(&reading, manual))
  }

  @Test("with no mode known before the Shift-Tab, one more read decides")
  func unknownBefore() {
    var reading = PaneModeReading()
    reading.toggled()
    #expect(read(&reading, edits))
    #expect(!read(&reading, edits))
    #expect(reading.mode == .acceptEdits)

    var changed = PaneModeReading()
    changed.toggled()
    #expect(read(&changed, manual))
    #expect(!read(&changed, edits))
    #expect(changed.mode == .acceptEdits)
  }

  @Test("two Shift-Tabs wait for two changes, within the same allowance")
  func twoToggles() {
    var reading = PaneModeReading(mode: .manual)
    reading.toggled()
    reading.toggled()
    #expect(read(&reading, edits), "only the first key has landed")
    #expect(!read(&reading, plan))
    #expect(reading.mode == .plan)

    // A read that skips a step: the allowance runs out and the screen is believed.
    var skipped = PaneModeReading(mode: .manual)
    skipped.toggled()
    skipped.toggled()
    #expect(read(&skipped, plan))
    #expect(read(&skipped, plan))
    #expect(!read(&skipped, plan))
    #expect(skipped.mode == .plan)
  }

  @Test("a screen with no answer after a Shift-Tab is not a change")
  func noAnswerIsNotAChange() {
    var reading = PaneModeReading(mode: .manual)
    reading.toggled()
    #expect(read(&reading, .blank))
    #expect(reading.mode == .manual)
    #expect(!read(&reading, edits))
    #expect(reading.mode == .acceptEdits)
  }

  @Test("a failed read keeps the last known mode")
  func failureKeeps() {
    var reading = PaneModeReading(mode: .plan)
    #expect(!failed(reading))
    #expect(reading.mode == .plan)
    reading.toggled()
    #expect(!failed(reading), "a refusal is not retried")
    #expect(reading.mode == .plan)
    #expect(reading.isStale)
  }

  @Test("a failed read from before the Shift-Tab asks for the read the key never got")
  func failureFromBeforeTheToggle() {
    var reading = PaneModeReading(mode: .plan)
    let before = reading.ticket
    reading.toggled()
    #expect(failed(reading, ticket: before))
    #expect(reading.mode == .plan)
  }

  @Test("nothing predicts the next mode")
  func noPrediction() {
    var reading = PaneModeReading(mode: .plan)
    reading.toggled()
    #expect(reading.mode == .plan, "the cycle is the user's, so the old mode stays on show")
  }
}
