import Testing

@testable import DriverrTerm

/// The bytes the row's Tab key sends, pinned by value so a mistaken constant fails here.
@Suite("TabKeyBytes")
struct TabKeyBytesTests {
  @Test("a tap on Tab sends a horizontal tab")
  func plainTabSendsHT() {
    #expect(TabKeyBytes.bytes(shift: false) == [0x09])
  }

  @Test("a hold on Tab sends back-tab, ESC [ Z")
  func shiftTabSendsBackTab() {
    #expect(TabKeyBytes.bytes(shift: true) == [0x1B, 0x5B, 0x5A])
  }
}
