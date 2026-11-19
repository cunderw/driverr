import Foundation
import Testing

@testable import DriverrTmux

/// What a tmux control client writes, as tmux 3.7c wrote it in a throwaway session.
@Suite("TmuxControlParser")
struct TmuxControlParserTests {
  private func events(_ text: String, chunkSize: Int? = nil) -> [TmuxControlEvent] {
    events(Data(text.utf8), chunkSize: chunkSize)
  }

  private func events(_ bytes: Data, chunkSize: Int? = nil) -> [TmuxControlEvent] {
    var parser = TmuxControlParser()
    guard let chunkSize else { return parser.consume(bytes) }
    var all: [TmuxControlEvent] = []
    var index = bytes.startIndex
    while index < bytes.endIndex {
      let end = bytes.index(index, offsetBy: chunkSize, limitedBy: bytes.endIndex) ?? bytes.endIndex
      all += parser.consume(bytes[index..<end])
      index = end
    }
    return all
  }

  @Test("%output decodes tmux's octal escapes and keeps UTF-8 as sent")
  func output() {
    let line = "%output %0 echo \u{E9}\\134\\015\\012\n"
    #expect(
      events(line) == [.output(pane: "%0", bytes: Data("echo \u{E9}\\\r\n".utf8))])
    // The same bytes one at a time, so the é is split across two chunks.
    #expect(events(line, chunkSize: 1) == events(line))
  }

  @Test("an escape is exactly three octal digits; anything else is kept as written")
  func octalEdges() {
    #expect(
      events("%output %3 a\\033[0mb\\1c\n")
        == [.output(pane: "%3", bytes: Data("a\u{1B}[0mb\\1c".utf8))])
  }

  @Test("a reply carries its lines, its number and whether this client asked")
  func reply() {
    let text = """
      %begin 1795049563 310 0
      %end 1795049563 310 0
      %begin 1795049563 318 1
      line one
      %output %9 inside a block is body
      %end 1 1 1
      %end 1795049563 318 1

      """
    #expect(
      events(text) == [
        .reply(number: 310, fromClient: false, lines: [], failed: false),
        .reply(
          number: 318, fromClient: true,
          lines: [
            Data("line one".utf8), Data("%output %9 inside a block is body".utf8),
            Data("%end 1 1 1".utf8),
          ], failed: false),
      ])
  }

  @Test("%error ends a block as a failure")
  func error() {
    let text = "%begin 5 321 1\nno alternate screen\n%error 5 321 1\n"
    #expect(
      events(text) == [
        .reply(number: 321, fromClient: true, lines: [Data("no alternate screen".utf8)], failed: true)
      ])
  }

  @Test("a body line keeps its raw bytes, escapes and all")
  func rawBody() {
    let body = Data([0x1B, 0x5B, 0x31, 0x6D, 0xC3, 0xA9])
    var text = Data("%begin 7 8 1\n".utf8)
    text.append(body)
    text.append(Data("\n%end 7 8 1\n".utf8))
    #expect(events(text, chunkSize: 2) == [.reply(number: 8, fromClient: true, lines: [body], failed: false)])
  }

  @Test("%layout-change names its window and the panes in its layout")
  func layout() {
    #expect(
      events("%layout-change @0 f25d,40x6,0,0,0 f25d,40x6,0,0,0 *\n")
        == [.layoutChange(window: "@0", panes: ["%0"])])
    #expect(
      events(
        "%layout-change @2 bb62,159x48,0,0{79x48,0,0,79,79x48,80,0[79x24,80,0,80,79x23,80,25,81]} x *-\n"
      ) == [.layoutChange(window: "@2", panes: ["%79", "%80", "%81"])])
  }

  @Test("a window closing, linked or not, is one event")
  func windowClose() {
    #expect(
      events("%window-close @4\n%unlinked-window-close @5\n")
        == [.windowClosed(window: "@4"), .windowClosed(window: "@5")])
  }

  @Test("%exit, with and without a reason")
  func exit() {
    #expect(events("%exit\n") == [.exit(reason: nil)])
    #expect(events("%exit server exited\n") == [.exit(reason: "server exited")])
  }

  @Test("other notifications are skipped")
  func skipped() {
    #expect(
      events("%session-changed $0 main\n%window-pane-changed @0 %1\n%sessions-changed\n").isEmpty)
  }

  @Test("a line waits for its newline")
  func partial() {
    var parser = TmuxControlParser()
    #expect(parser.consume(Data("%output %1 ab".utf8)).isEmpty)
    #expect(parser.consume(Data("c\n".utf8)) == [.output(pane: "%1", bytes: Data("abc".utf8))])
  }
}
