import Testing

@testable import DriverrCore

/// The fitted form sheet's height rule. `HostedProbe` cannot reach a live presentation and
/// XCUITest cannot read `preferredContentSize`, so every branch is here. The numbers are
/// from an iPad: a 660 pt natural card and a trust prompt whose content reports 365.
@Suite("Sheet content height")
struct SheetContentHeightTests {
  /// A `List`'s scroll view reports no geometry until it has laid out.
  @Test("nothing measured yet asks for nothing")
  func nothingMeasuredAsksForNothing() {
    #expect(SheetContentHeight.fitted(content: nil, natural: nil) == nil)
    #expect(SheetContentHeight.fitted(content: 365, natural: nil) == nil)
    #expect(SheetContentHeight.fitted(content: nil, natural: 660) == nil)
  }

  /// The same first frame, with `contentSize.height` at `0` rather than absent.
  @Test("a zero or negative content height asks for nothing")
  func zeroContentAsksForNothing() {
    #expect(SheetContentHeight.fitted(content: 0, natural: 660) == nil)
    #expect(SheetContentHeight.fitted(content: -12, natural: 660) == nil)
  }

  /// Read as "not laid out yet" rather than as a two-row sheet.
  @Test("content under the minimum asks for nothing")
  func underTheMinimumAsksForNothing() {
    #expect(SheetContentHeight.fitted(content: 239, natural: 660) == nil)
    #expect(SheetContentHeight.fitted(content: SheetContentHeight.minimum, natural: 660) == nil)
  }

  /// A nonsense natural height cannot be the comparison, or a 0 pt sheet would look like one
  /// with no room to give back.
  @Test("a natural height under the minimum asks for nothing")
  func nonsenseNaturalAsksForNothing() {
    #expect(SheetContentHeight.fitted(content: 365, natural: 0) == nil)
    #expect(SheetContentHeight.fitted(content: 365, natural: 100) == nil)
  }

  @Test("content shorter than the sheet asks for the content height")
  func shorterContentFits() {
    #expect(SheetContentHeight.fitted(content: 365, natural: 660) == 365)
    #expect(SheetContentHeight.fitted(content: 241, natural: 660) == 241)
  }

  /// Shrink-only: a form taller than the platform's sheet keeps it and scrolls rather than
  /// growing into the keyboard.
  @Test("content at or over the natural height asks for nothing")
  func tallerContentAsksForNothing() {
    #expect(SheetContentHeight.fitted(content: 660, natural: 660) == nil)
    #expect(SheetContentHeight.fitted(content: 1200, natural: 660) == nil)
  }

  /// Applying a height shrinks the sheet, so the next measurement finds content and room
  /// nearly equal. Without the slack the height is handed back and the sheet oscillates.
  @Test("a saving smaller than the slack is not worth taking")
  func tinySavingsAreLeftAlone() {
    #expect(SheetContentHeight.fitted(content: 655, natural: 660) == nil)
    #expect(SheetContentHeight.fitted(content: 660 - SheetContentHeight.slack, natural: 660) == 652)
  }

  @Test("the minimum is the caller's to choose")
  func minimumIsAParameter() {
    #expect(SheetContentHeight.fitted(content: 300, natural: 660, minimum: 400) == nil)
    #expect(SheetContentHeight.fitted(content: 300, natural: 660, minimum: 100) == 300)
  }
}
