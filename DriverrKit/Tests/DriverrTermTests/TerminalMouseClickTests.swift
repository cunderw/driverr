import DriverrCore
import Foundation
import SwiftTerm
import Testing

@testable import DriverrTerm

/// A tap's click on a PTY, against a headless `Terminal`.
@Suite("TerminalMouseClick")
struct TerminalMouseClickTests {
  private final class Recorder: TerminalDelegate {
    var sent: [UInt8] = []
    func send(source: Terminal, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
    var text: String { String(decoding: sent, as: UTF8.self) }
  }

  /// Returns the delegate so it outlives the terminal's weak reference.
  private func tap(
    after modes: String,
    at cell: TerminalCell,
    pixelX: Int = 0,
    pixelY: Int = 0
  ) -> (sent: Bool, text: String) {
    let recorder = Recorder()
    let terminal = Terminal(delegate: recorder, options: TerminalOptions(cols: 80, rows: 24))
    terminal.feed(text: modes)
    // Feeding can answer queries; only the tap's bytes are under test.
    recorder.sent.removeAll()
    let sent = TerminalMouseClick.send(at: cell, pixelX: pixelX, pixelY: pixelY, to: terminal)
    return (sent, withExtendedLifetime(recorder) { recorder.text })
  }

  @Test("no mouse mode sends nothing")
  func noModeSendsNothing() {
    let result = tap(after: "", at: TerminalCell(column: 3, row: 4))
    #expect(!result.sent)
    #expect(result.text.isEmpty)
  }

  @Test("X10 mode sends nothing, as SwiftTerm's own tap does")
  func x10SendsNothing() {
    let result = tap(after: "\u{1b}[?9h", at: TerminalCell(column: 3, row: 4))
    #expect(!result.sent)
    #expect(result.text.isEmpty)
  }

  /// The cell is 0-based and the report 1-based.
  @Test("SGR mode sends a left press and release, counted from 1")
  func sgrPressAndRelease() {
    let result = tap(after: "\u{1b}[?1000h\u{1b}[?1006h", at: TerminalCell(column: 3, row: 4))
    #expect(result.sent)
    #expect(result.text == "\u{1b}[<0;4;5M\u{1b}[<0;4;5m")
  }

  @Test("the modes Claude Code sets send an SGR click")
  func claudeCodeModes() {
    let result = tap(
      after: "\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1006h",
      at: TerminalCell(column: 0, row: 0)
    )
    #expect(result.text == "\u{1b}[<0;1;1M\u{1b}[<0;1;1m")
  }

  @Test("SGR pixel mode sends the pixel position")
  func sgrPixels() {
    let result = tap(
      after: "\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?1016h",
      at: TerminalCell(column: 3, row: 4),
      pixelX: 75,
      pixelY: 150
    )
    #expect(result.text == "\u{1b}[<0;75;150M\u{1b}[<0;75;150m")
  }

  @Test("the default encoding sends X10 bytes, counted from 1")
  func defaultEncoding() {
    let result = tap(after: "\u{1b}[?1000h", at: TerminalCell(column: 3, row: 4))
    // CSI M, then button, column and row, each plus 32; a release is button 3.
    let press: [UInt8] = [0x1b, 0x5b, 0x4d, 32, 36, 37]
    let release: [UInt8] = [0x1b, 0x5b, 0x4d, 35, 36, 37]
    #expect(result.sent)
    #expect(Array(result.text.utf8) == press + release)
  }

  @Test("a mode turned off again sends nothing")
  func modeTurnedOff() {
    let result = tap(
      after: "\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?1000l",
      at: TerminalCell(column: 1, row: 1)
    )
    #expect(!result.sent)
    #expect(result.text.isEmpty)
  }
}
