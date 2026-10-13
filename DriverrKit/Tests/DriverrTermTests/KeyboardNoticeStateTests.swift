import DriverrCore
import Testing

@testable import DriverrTerm

/// Suppressed, dismissed or normal as a function of three facts. In a UI-test launch
/// `GCKeyboard.coalesced` is nil, so only this tier can drive a hardware keyboard connecting
/// and going away.
@Suite("KeyboardNoticeState")
struct KeyboardNoticeStateTests {
  @Test("not first responder is always dismissed, whatever the hardware keyboard is doing")
  func notFirstResponderIsDismissed() {
    #expect(
      KeyboardNoticeState.decide(
        isFirstResponder: false, hardwareKeyboardConnected: true, keyboardFrameHeight: 44
      ) == .dismissed
    )
    #expect(
      KeyboardNoticeState.decide(
        isFirstResponder: false, hardwareKeyboardConnected: false, keyboardFrameHeight: 362
      ) == .dismissed
    )
  }

  @Test("first responder, no hardware keyboard, is normal at any frame height")
  func noHardwareKeyboardIsNormal() {
    #expect(
      KeyboardNoticeState.decide(
        isFirstResponder: true, hardwareKeyboardConnected: false, keyboardFrameHeight: 0
      ) == .normal
    )
    #expect(
      KeyboardNoticeState.decide(
        isFirstResponder: true, hardwareKeyboardConnected: false, keyboardFrameHeight: 362
      ) == .normal
    )
  }

  @Test("first responder, hardware keyboard connected, accessory-sized frame is suppressed")
  func accessorySizedFrameIsSuppressed() {
    #expect(
      KeyboardNoticeState.decide(
        isFirstResponder: true, hardwareKeyboardConnected: true, keyboardFrameHeight: 44
      ) == .suppressedByHardwareKeyboard
    )
  }

  /// The threshold is the row's own height. With the row at 48 pt and the threshold at 44,
  /// a frame holding only the row read as a software keyboard.
  @Test("a frame the height of the terminal's key row is suppressed")
  func keyRowSizedFrameIsSuppressed() {
    #expect(
      KeyboardNoticeState.decide(
        isFirstResponder: true,
        hardwareKeyboardConnected: true,
        keyboardFrameHeight: PaneKey.AccessoryRowMetrics.rowHeight
      ) == .suppressedByHardwareKeyboard
    )
  }

  @Test(
    """
    before the first keyboard notification arrives, a zero frame with a hardware keyboard \
    already connected reads as suppressed rather than waiting
    """
  )
  func zeroFrameWithHardwareKeyboardIsSuppressed() {
    #expect(
      KeyboardNoticeState.decide(
        isFirstResponder: true, hardwareKeyboardConnected: true, keyboardFrameHeight: 0
      ) == .suppressedByHardwareKeyboard
    )
  }

  @Test(
    "a full-size frame is normal even with a hardware keyboard connected — the two facts must agree"
  )
  func fullSizeFrameOverridesHardwareKeyboardFlag() {
    #expect(
      KeyboardNoticeState.decide(
        isFirstResponder: true, hardwareKeyboardConnected: true, keyboardFrameHeight: 362
      ) == .normal
    )
  }

  // MARK: - The idiom

  /// On iPad the suppression is the feature. Every suppressing fact is present; only the
  /// idiom differs.
  @Test("the same suppressing facts are normal on an iPad")
  func iPadNeverReportsSuppression() {
    #expect(
      KeyboardNoticeState.decide(
        isFirstResponder: true,
        hardwareKeyboardConnected: true,
        keyboardFrameHeight: 44,
        idiom: .pad
      ) == .normal
    )
    #expect(
      KeyboardNoticeState.decide(
        isFirstResponder: true,
        hardwareKeyboardConnected: true,
        keyboardFrameHeight: 0,
        idiom: .pad
      ) == .normal
    )
  }

  /// Stated explicitly, because a changed default would take every other test here with it.
  @Test("the phone still reports suppression on the same facts")
  func phoneStillReportsSuppression() {
    #expect(
      KeyboardNoticeState.decide(
        isFirstResponder: true,
        hardwareKeyboardConnected: true,
        keyboardFrameHeight: 44,
        idiom: .phone
      ) == .suppressedByHardwareKeyboard
    )
  }

  /// The idiom guard sits after the first-responder one; swapping them would lose this.
  @Test("the idiom does not override the dismissed case")
  func idiomDoesNotOverrideDismissed() {
    #expect(
      KeyboardNoticeState.decide(
        isFirstResponder: false,
        hardwareKeyboardConnected: true,
        keyboardFrameHeight: 44,
        idiom: .pad
      ) == .dismissed
    )
  }

  // MARK: - What it says

  /// Only a Mac can attach a keyboard to a phone this way, and it is the case with no
  /// physical keyboard in the room to explain it.
  @Test("only the phone's copy mentions iPhone Mirroring")
  func copyMentionsMirroringOnlyOnThePhone() {
    #expect(KeyboardNoticeState.copy(for: .phone).contains("iPhone Mirroring"))
    #expect(!KeyboardNoticeState.copy(for: .pad).contains("Mirroring"))
  }

  @Test("both idioms say what happened and how to get the keyboard back")
  func copyAlwaysSaysWhatToDo() {
    for idiom: KeyboardNoticeIdiom in [.phone, .pad] {
      let copy = KeyboardNoticeState.copy(for: idiom)
      #expect(copy.contains("Software keyboard hidden"))
      #expect(copy.contains("Globe"))
    }
  }
}
