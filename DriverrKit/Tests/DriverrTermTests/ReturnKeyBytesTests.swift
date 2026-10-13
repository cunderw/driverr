import Testing

@testable import DriverrTerm

/// The bytes a Return sends, pinned by value so a mistaken constant fails here.
@Suite("ReturnKeyBytes")
struct ReturnKeyBytesTests {
  @Test("plain Return sends a carriage return")
  func plainReturnSendsCR() {
    #expect(ReturnKeyBytes.bytes(shift: false, control: false) == [0x0d])
  }

  @Test("Shift-Return sends a line feed")
  func shiftReturnSendsLF() {
    #expect(ReturnKeyBytes.bytes(shift: true, control: false) == [0x0a])
  }

  @Test("armed Ctrl then Return sends a line feed")
  func controlReturnSendsLF() {
    #expect(ReturnKeyBytes.bytes(shift: false, control: true) == [0x0a])
  }

  @Test("Shift with Ctrl still sends a line feed")
  func shiftControlReturnSendsLF() {
    #expect(ReturnKeyBytes.bytes(shift: true, control: true) == [0x0a])
  }
}
