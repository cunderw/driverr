import DriverrCore
import DriverrHerdr
import Foundation

@testable import DriverrTmux

/// A scripted `tmux -C`: it answers the commands `TmuxAttacher` writes, in tmux's block format,
/// and writes whatever notification a test hands it.
///
/// Like tmux, it runs a line's commands in order and skips the rest after one fails.
final class FakeTmuxControlStream: HerdrStream, @unchecked Sendable {
  struct Pane {
    var window: String
    var state: TmuxPaneState
    var history: [String] = []
    var screen: [String]
    /// The normal screen, kept aside while a program holds the alternate one.
    var normal: [String]?
  }

  let output: AsyncThrowingStream<Data, any Error>
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let lock = NSLock()
  private var panes: [String: Pane]
  private var number = 100
  private var received: [String] = []
  private var typed: [String: Data] = [:]
  private var closes = 0
  private var refusesWindowSizes = false
  private var isSilent = false
  /// Pane output tmux had queued before a paint line ran, written ahead of its replies.
  private var staleOutput: [String: String] = [:]
  /// Pane output written right after a paint line's replies.
  private var freshOutput: [String: String] = [:]
  /// Pane output written ahead of a window size's reply.
  private var sizingOutput: (pane: String, text: String)?

  init(panes: [String: Pane]) {
    self.panes = panes
    (output, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
    // What tmux writes at attach: the attach line's own blocks, which nobody asked for.
    continuation.yield(Data("%begin 1 1 0\n%end 1 1 0\n%session-changed $0 main\n".utf8))
  }

  var end: ProcessEnd? { get async { nil } }

  /// Every command line, as written.
  var lines: [String] { lock.withLock { received } }
  var closeCount: Int { lock.withLock { closes } }
  func keys(for pane: String) -> Data { lock.withLock { typed[pane] ?? Data() } }

  func refuseWindowSizes() { lock.withLock { refusesWindowSizes = true } }
  /// From here on, lines are recorded and nothing is answered, as on a link that went quiet.
  func goSilent() { lock.withLock { isSilent = true } }
  func setPane(_ id: String, _ pane: Pane?) { lock.withLock { panes[id] = pane } }
  func around(paintOf pane: String, stale: String, fresh: String) {
    lock.withLock {
      staleOutput[pane] = stale
      freshOutput[pane] = fresh
    }
  }

  func after(sizing pane: String, writes text: String) {
    lock.withLock { sizingOutput = (pane, text) }
  }

  /// Writes raw control-mode text, a notification or several.
  func emit(_ text: String) { continuation.yield(Data(text.utf8)) }

  /// The stream ends, as an SSH channel's does.
  func finish() { continuation.finish() }

  func send(_ data: Data) async throws {
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
      run(String(line))
    }
  }

  func close() async {
    lock.withLock { closes += 1 }
    continuation.finish()
  }

  private func run(_ line: String) {
    let silent = lock.withLock {
      received.append(line)
      return isSilent
    }
    if silent { return }
    let commands = line.components(separatedBy: " ; ")
    let paintedPane = commands.count == 3 ? Self.target(of: commands[0]) : nil
    if let paintedPane, let stale = lock.withLock({ staleOutput[paintedPane] }) {
      emit(Self.output(paintedPane, stale))
    }
    for command in commands {
      let (body, failed) = answer(command)
      let number = lock.withLock {
        self.number += 1
        return self.number
      }
      var text = "%begin 9 \(number) 1\n"
      for row in body { text += row + "\n" }
      text += "%\(failed ? "error" : "end") 9 \(number) 1\n"
      // Output the pane wrote while the size was on its way, ahead of the reply, as tmux
      // writes it when a pane is busy.
      if command.hasPrefix("refresh-client -C @"), let sizing = lock.withLock({ sizingOutput }) {
        emit(Self.output(sizing.pane, sizing.text))
      }
      emit(text)
      if failed { return }
    }
    if let paintedPane, let fresh = lock.withLock({ freshOutput[paintedPane] }) {
      emit(Self.output(paintedPane, fresh))
    }
  }

  static func output(_ pane: String, _ text: String) -> String {
    var escaped = ""
    for byte in text.utf8 {
      if byte < 0x20 || byte == 0x5C {
        escaped += "\\" + String(format: "%03o", byte)
      } else {
        escaped += String(decoding: [byte], as: UTF8.self)
      }
    }
    return "%output \(pane) \(escaped)\n"
  }

  private static func target(of command: String) -> String? {
    let words = command.split(separator: " ")
    guard let index = words.firstIndex(of: "-t"), index + 1 < words.count else { return nil }
    return String(words[index + 1])
  }

  private func answer(_ command: String) -> (body: [String], failed: Bool) {
    let words = command.split(separator: " ").map(String.init)
    guard let name = words.first else { return (["parse error"], true) }
    switch name {
    case "refresh-client":
      let size = words.last ?? ""
      if size.hasPrefix("@"), lock.withLock({ refusesWindowSizes }) {
        return (["bad size argument"], true)
      }
      return ([], false)
    case "send-keys":
      guard let pane = Self.target(of: command), lock.withLock({ panes[pane] }) != nil else {
        return (["can't find pane"], true)
      }
      let hex = words.drop { $0 != "-H" }.dropFirst()
      let bytes = Data(hex.compactMap { UInt8($0, radix: 16) })
      lock.withLock { typed[pane, default: Data()].append(bytes) }
      return ([], false)
    case "display-message", "capture-pane":
      let id = Self.target(of: command) ?? ""
      guard let pane = lock.withLock({ panes[id] }) else {
        // `display-message`'s target may fail: tmux 3.7c answers a missing pane with an empty
        // line, not an error.
        if name == "display-message" { return ([""], false) }
        return (["can't find pane: \(id)"], true)
      }
      if name == "display-message" {
        if command.hasSuffix("'#{pane_id} #{window_id}'") { return (["\(id) \(pane.window)"], false) }
        return ([Self.stateLine(pane.state)], false)
      }
      if words.contains("-a") { return (pane.normal ?? [], false) }
      let history = words.firstIndex(of: "-S").flatMap { Int(words[$0 + 1].dropFirst()) } ?? 0
      return (pane.history.suffix(history) + pane.screen, false)
    default:
      return (["unknown command: \(name)"], true)
    }
  }

  /// The state line tmux prints for `TmuxPaneState.format`.
  static func stateLine(_ state: TmuxPaneState) -> String {
    func flag(_ value: Bool) -> String { value ? "1" : "0" }
    return [
      flag(state.alternateScreen), "\(state.cursorColumn)", "\(state.cursorRow)",
      flag(state.cursorVisible), flag(state.applicationCursorKeys), flag(state.applicationKeypad),
      flag(state.autowrap), flag(state.insert), flag(state.originMode), "\(state.scrollTop)",
      "\(state.scrollBottom)", flag(state.mouseStandard), flag(state.mouseButton),
      flag(state.mouseAny), flag(state.mouseSGR), flag(state.bracketedPaste), "\(state.height)",
    ].map { $0 + "." }.joined()
  }
}
