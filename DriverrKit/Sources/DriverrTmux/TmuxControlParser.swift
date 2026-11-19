import Foundation

/// One thing a tmux control client (`tmux -C`) wrote, in Driverr's terms.
///
/// Only what `TmuxAttachment` acts on has a case. Every other notification is skipped.
enum TmuxControlEvent: Equatable, Sendable {
  /// A command's answer: its body lines, raw, and whether it was `%error`.
  ///
  /// `fromClient` is the `%begin` flags field. It is `1` for a command this client wrote on its
  /// input, and `0` for one from the attach command line, which nothing is waiting for.
  case reply(number: Int, fromClient: Bool, lines: [Data], failed: Bool)
  /// A pane's output, decoded, for raw pane id `pane` (`%3`).
  case output(pane: String, bytes: Data)
  /// Window `window` (`@2`) has a new layout, which holds these raw pane ids.
  case layoutChange(window: String, panes: [String])
  /// Window `window` closed, or left the attached session.
  case windowClosed(window: String)
  /// The client is leaving. tmux writes this last.
  case exit(reason: String?)
}

/// Turns a control client's bytes into events.
///
/// - Works on bytes, not strings. A chunk can end inside a UTF-8 character, and a pane's text
///   inside a block is the program's own bytes.
/// - **A line inside a `%begin` block is body, whatever it starts with.** `capture-pane` prints a
///   pane's text, and a screen can show `%output` or `%end`. The block ends only on an
///   `%end` or `%error` whose time and number are the `%begin`'s, as tmux writes them.
struct TmuxControlParser {
  private var pending = Data()
  private var block: Block?

  private struct Block {
    let time: Data
    let number: Data
    let fromClient: Bool
    var lines: [Data] = []
  }

  mutating func consume(_ chunk: Data) -> [TmuxControlEvent] {
    pending.append(chunk)
    var events: [TmuxControlEvent] = []
    while let newline = pending.firstIndex(of: 0x0A) {
      let line = Data(pending[pending.startIndex..<newline])
      pending = Data(pending[pending.index(after: newline)...])
      if let event = take(line) { events.append(event) }
    }
    return events
  }

  private mutating func take(_ line: Data) -> TmuxControlEvent? {
    if var open = block {
      if let end = Self.guardLine(line, matching: open) {
        block = nil
        return .reply(
          number: Int(String(decoding: open.number, as: UTF8.self)) ?? 0,
          fromClient: open.fromClient, lines: open.lines, failed: end == .error)
      }
      open.lines.append(line)
      block = open
      return nil
    }

    let words = line.split(separator: 0x20, maxSplits: 2, omittingEmptySubsequences: false)
    guard let name = words.first.map({ String(decoding: $0, as: UTF8.self) }) else { return nil }
    switch name {
    case "%begin":
      let fields = line.split(separator: 0x20)
      guard fields.count >= 4 else { return nil }
      block = Block(time: Data(fields[1]), number: Data(fields[2]), fromClient: fields[3] == Data("1".utf8))
      return nil
    case "%output":
      guard words.count == 3 else { return nil }
      return .output(pane: String(decoding: words[1], as: UTF8.self), bytes: Self.unescaped(words[2]))
    case "%layout-change":
      guard words.count >= 3 else { return nil }
      let layout = words[2].split(separator: 0x20).first.map { Data($0) } ?? Data()
      return .layoutChange(
        window: String(decoding: words[1], as: UTF8.self), panes: Self.panes(inLayout: layout))
    case "%window-close", "%unlinked-window-close":
      guard words.count >= 2 else { return nil }
      return .windowClosed(window: String(decoding: words[1], as: UTF8.self))
    case "%exit":
      let reason = line.dropFirst("%exit".utf8.count).drop { $0 == 0x20 }
      return .exit(reason: reason.isEmpty ? nil : String(decoding: reason, as: UTF8.self))
    default:
      return nil
    }
  }

  private enum Guard { case end, error }

  /// `%end` or `%error` with this block's time and number, which is how tmux closes it.
  private static func guardLine(_ line: Data, matching open: Block) -> Guard? {
    let fields = line.split(separator: 0x20)
    guard fields.count >= 3, Data(fields[1]) == open.time, Data(fields[2]) == open.number else {
      return nil
    }
    switch fields[0] {
    case Data("%end".utf8): return .end
    case Data("%error".utf8): return .error
    default: return nil
    }
  }

  /// tmux writes a byte below a space, and a backslash, as a backslash and three octal digits.
  /// Everything else, UTF-8 included, is the byte itself.
  static func unescaped(_ escaped: Data) -> Data {
    var bytes = Data(capacity: escaped.count)
    var index = escaped.startIndex
    while index < escaped.endIndex {
      let byte = escaped[index]
      if byte == 0x5C, escaped.distance(from: index, to: escaped.endIndex) >= 4 {
        let digits = escaped[escaped.index(after: index)..<escaped.index(index, offsetBy: 4)]
        if digits.allSatisfy({ (0x30...0x37).contains($0) }) {
          bytes.append(digits.reduce(UInt8(0)) { $0 &* 8 &+ ($1 - 0x30) })
          index = escaped.index(index, offsetBy: 4)
          continue
        }
      }
      bytes.append(byte)
      index = escaped.index(after: index)
    }
    return bytes
  }

  /// The pane ids in a layout string, in order.
  ///
  /// A pane is a cell with five numbers, `WxH,X,Y,ID`. A split has four and then `{` or `[`, so
  /// it names no pane. The checksum in front holds hex letters and is never counted.
  static func panes(inLayout layout: Data) -> [String] {
    var panes: [String] = []
    var numbers: [String] = []
    var digits = ""
    var inCell = false
    func endCell() {
      if inCell, numbers.count == 5 { panes.append("%" + numbers[4]) }
      numbers = []
      inCell = false
    }
    for byte in layout + [0x20] {
      if (0x30...0x39).contains(byte) {
        digits.append(Character(UnicodeScalar(byte)))
        continue
      }
      let number = digits
      digits = ""
      switch byte {
      case UInt8(ascii: "x"):
        endCell()
        inCell = !number.isEmpty
        numbers = [number]
      case UInt8(ascii: ","):
        if inCell { numbers.append(number) }
      default:
        if inCell, !number.isEmpty { numbers.append(number) }
        endCell()
      }
    }
    return panes
  }
}
