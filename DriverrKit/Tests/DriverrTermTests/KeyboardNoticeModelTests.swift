import Testing

@testable import DriverrTerm

/// Everything about the hardware-keyboard notice short of rendering and a real device.
@MainActor
@Suite("KeyboardNoticeModel")
struct KeyboardNoticeModelTests {
  private func makeModel(
    hardwareKeyboardConnected: Bool = false,
    source: FakeHardwareKeyboardSource,
    idiom: KeyboardNoticeIdiom = .phone,
    keepsAccessoryRowWithHardwareKeyboard: Bool = false
  ) -> KeyboardNoticeModel {
    KeyboardNoticeModel(
      hardwareKeyboardConnected: hardwareKeyboardConnected,
      hardwareKeyboardSubscription: source.subscribe,
      idiom: idiom,
      keepsAccessoryRowWithHardwareKeyboard: keepsAccessoryRowWithHardwareKeyboard
    )
  }

  // MARK: - Closing the notice

  /// First-responder changes are constant and each recomputes the state, so a close stored
  /// as `state = .normal` would be overwritten. It is a separate flag `recompute` leaves alone.
  @Test("a closed notice stays closed across a focus change that would re-raise it")
  func closingTheNoticeSurvivesRecomputation() {
    let model = makeModel(hardwareKeyboardConnected: true, source: FakeHardwareKeyboardSource())
    model.firstResponderChanged(true)
    model.keyboardFrameChanged(height: 44)
    #expect(model.showsHardwareKeyboardNotice)

    model.dismissNotice()
    #expect(!model.showsHardwareKeyboardNotice)

    // The fact is still true; the reader has read it.
    #expect(model.state == .suppressedByHardwareKeyboard)

    model.firstResponderChanged(false)
    model.firstResponderChanged(true)

    #expect(!model.showsHardwareKeyboardNotice, "the close did not survive a focus change")
  }

  /// An iPad never raises it.
  @Test("an iPad shows no hardware-keyboard notice on the facts that raise one on a phone")
  func iPadShowsNoNotice() {
    let model = makeModel(
      hardwareKeyboardConnected: true,
      source: FakeHardwareKeyboardSource(),
      idiom: .pad
    )
    model.firstResponderChanged(true)
    model.keyboardFrameChanged(height: 44)

    #expect(!model.showsHardwareKeyboardNotice)
    #expect(model.state == .normal)
  }

  /// The iPad's sentence, if anything ever shows it.
  @Test("the model's copy follows its idiom")
  func copyFollowsTheIdiom() {
    let phone = makeModel(source: FakeHardwareKeyboardSource(), idiom: .phone)
    let pad = makeModel(source: FakeHardwareKeyboardSource(), idiom: .pad)

    #expect(phone.noticeText.contains("iPhone Mirroring"))
    #expect(!pad.noticeText.contains("Mirroring"))
  }

  @Test("no hardware keyboard, first responder: normal")
  func normalWhenNoHardwareKeyboard() {
    let model = makeModel(source: FakeHardwareKeyboardSource())
    model.firstResponderChanged(true)
    #expect(model.state == .normal)
  }

  @Test("never asked for focus: dismissed, even with a hardware keyboard already attached")
  func dismissedBeforeAnyFocus() {
    let model = makeModel(hardwareKeyboardConnected: true, source: FakeHardwareKeyboardSource())
    #expect(model.state == .dismissed)
  }

  @Test("GCKeyboardDidConnect while the terminal holds focus shows the notice at once")
  func connectingWhileFocusedSuppresses() {
    let source = FakeHardwareKeyboardSource()
    let model = makeModel(source: source)
    model.firstResponderChanged(true)
    #expect(model.state == .normal)

    source.connect()

    #expect(model.state == .suppressedByHardwareKeyboard)
  }

  @Test("a real full-height keyboard frame overrides a stale suppressed read")
  func fullHeightFrameClearsSuppression() {
    let source = FakeHardwareKeyboardSource()
    let model = makeModel(hardwareKeyboardConnected: true, source: source)
    model.firstResponderChanged(true)
    #expect(model.state == .suppressedByHardwareKeyboard)

    model.keyboardFrameChanged(height: 362)

    #expect(model.state == .normal)
  }

  @Test("GCKeyboardDidDisconnect clears the notice without the terminal being reopened")
  func disconnectingClearsTheNotice() {
    let source = FakeHardwareKeyboardSource()
    let model = makeModel(hardwareKeyboardConnected: true, source: source)
    model.firstResponderChanged(true)
    #expect(model.state == .suppressedByHardwareKeyboard)

    source.disconnect()

    #expect(model.state == .normal)
  }

  @Test("the hide key dismisses the notice rather than leaving it suppressed")
  func hideKeyDismissesRatherThanLeavingSuppressed() {
    let source = FakeHardwareKeyboardSource()
    let model = makeModel(hardwareKeyboardConnected: true, source: source)
    model.firstResponderChanged(true)
    #expect(model.state == .suppressedByHardwareKeyboard)

    model.firstResponderChanged(false)

    #expect(model.state == .dismissed)
  }

  // MARK: - What the keyboard covers that the safe area does not

  @Test("the row above the region's end covers nothing")
  func nothingOwedWhenTheRegionStopsAboveTheRow() {
    let model = makeModel(source: FakeHardwareKeyboardSource())

    // iPhone portrait, keyboard shown first time: the safe area ends where the accessory row
    // starts.
    model.accessoryRowTopChanged(522)

    #expect(model.obstruction(forRegionEndingAt: 522) == 0)
  }

  @Test("a region running past the row owes the difference")
  func obstructionIsTheUncoveredAccessoryRow() {
    let model = makeModel(source: FakeHardwareKeyboardSource())

    // Landscape: the safe area ends 44 pt below the row, which covers the grid's last lines.
    // The same 44 pt is owed in portrait after rotating back, so this is not an orientation
    // rule.
    model.accessoryRowTopChanged(198)

    #expect(model.obstruction(forRegionEndingAt: 242) == 44)
  }

  @Test("a keyboard that has gone covers nothing")
  func hidingTheKeyboardGivesTheRowsBack() {
    let model = makeModel(source: FakeHardwareKeyboardSource())
    model.accessoryRowTopChanged(198)
    #expect(model.obstruction(forRegionEndingAt: 242) == 44)

    model.accessoryRowTopChanged(nil)

    #expect(model.obstruction(forRegionEndingAt: 242) == 0)
  }

  @Test("a row below the region's end never adds height")
  func aRowBelowTheRegionClampsToZero() {
    let model = makeModel(source: FakeHardwareKeyboardSource())

    // Defensive: an inset larger than the obstruction throws rows away.
    model.accessoryRowTopChanged(700)

    #expect(model.obstruction(forRegionEndingAt: 522) == 0)
  }

  @Test("a report that does not move the row is not a change")
  func repeatedReportsAreDropped() {
    // Every warm pane shares one model and lays out on its own schedule, so an unconditional
    // write would relayout once per pane.
    let model = makeModel(source: FakeHardwareKeyboardSource())
    model.accessoryRowTopChanged(198)

    model.accessoryRowTopChanged(198)

    #expect(model.accessoryRowTop == 198)
  }

  // MARK: - The key row, with a hardware keyboard attached

  @Test("the key row is carried while there is no hardware keyboard")
  func rowIsCarriedWithoutAHardwareKeyboard() {
    let model = makeModel(source: FakeHardwareKeyboardSource())

    #expect(model.showsAccessoryRow)
  }

  @Test("a hardware keyboard takes the key row away")
  func aHardwareKeyboardHidesTheRow() {
    let model = makeModel(hardwareKeyboardConnected: true, source: FakeHardwareKeyboardSource())

    #expect(!model.showsAccessoryRow)
  }

  /// `HardwareKeyboardMonitor` publishes the change, and the row reads it live.
  @Test("plugging a keyboard in takes the row away, and unplugging it brings the row back")
  func theRowFollowsConnectAndDisconnect() {
    let source = FakeHardwareKeyboardSource()
    let model = makeModel(source: source)
    #expect(model.showsAccessoryRow)

    source.connect()
    #expect(!model.showsAccessoryRow)

    source.disconnect()
    #expect(model.showsAccessoryRow)
  }

  /// A simulator's hardware keyboard is the Mac's and cannot be unplugged, so without the
  /// override every UI run would take the hidden branch and `TerminalKeyboardUITests` would
  /// fail.
  @Test("the testing override keeps the row on screen with a keyboard attached")
  func theOverrideKeepsTheRow() {
    let source = FakeHardwareKeyboardSource()
    let model = makeModel(
      hardwareKeyboardConnected: true,
      source: source,
      keepsAccessoryRowWithHardwareKeyboard: true
    )
    #expect(model.showsAccessoryRow)

    source.disconnect()
    source.connect()
    #expect(model.showsAccessoryRow)
  }

  /// The notice also needs focus and a zero-height software keyboard. Tying the row to it
  /// would make the row come and go when the reader taps away from the terminal.
  @Test("the row does not wait for the notice's other two conditions")
  func theRowIsNotTheNotice() {
    let model = makeModel(hardwareKeyboardConnected: true, source: FakeHardwareKeyboardSource())

    // Nothing focused, so no notice.
    #expect(!model.showsHardwareKeyboardNotice)
    #expect(!model.showsAccessoryRow)
  }
}
