import DriverrCore
import DriverrHerdr
import Foundation
import Testing

@testable import DriverrTmux

/// The fake's own contract: tmux answers commands in the order they were written, and
/// `TmuxSessionClient` pairs every reply with its command by that order (#143).
@Suite("FakeTmuxControlStream", .timeLimit(.minutes(1)))
struct FakeTmuxControlStreamTests {
  /// A line written while `resumeHeld()` runs the held lines is answered after all of them, as
  /// tmux answers it. Answered in between, a client's next reply goes to the wrong command.
  @Test("a line written while held lines run is answered after them")
  func lineDuringResumeIsAnsweredLast() async throws {
    var state = TmuxPaneState()
    state.height = 2
    let stream = FakeTmuxControlStream(panes: [
      "%3": FakeTmuxControlStream.Pane(window: "@1", state: state, screen: ["$ "])
    ])
    let heldCount = 1_000
    stream.hold(linesContaining: "refresh-client -C @1:")
    for index in 1...heldCount {
      try await stream.send(Data("refresh-client -C @1:\(index)x10\n".utf8))
    }
    let resuming = Task.detached { stream.resumeHeld() }
    // The fake writes each answer as one chunk.
    var answers = stream.output.makeAsyncIterator()
    var answeredFirst = 0
    // The first held answer is out, so `resumeHeld()` is running. Write the next line now.
    while let chunk = try await answers.next() {
      if String(decoding: chunk, as: UTF8.self).contains("%end 9 ") {
        answeredFirst += 1
        break
      }
    }
    // A pane the fake does not have, so its answer is the only `%error`.
    try await stream.send(Data("copy-mode -q -t %4\n".utf8))
    await resuming.value
    while let chunk = try await answers.next() {
      let text = String(decoding: chunk, as: UTF8.self)
      if text.contains("%error 9 ") { break }
      if text.contains("%end 9 ") { answeredFirst += 1 }
    }
    #expect(answeredFirst == heldCount, "every held line is answered before the line after them")
  }

  /// A `hold(linesContaining:)` made while `resumeHeld()` runs the held lines still holds once
  /// they are done. Cleared at the end of the drain, it would be lost.
  @Test("a hold made while held lines run still holds after them")
  func holdDuringResumeSurvives() async throws {
    var state = TmuxPaneState()
    state.height = 2
    let stream = FakeTmuxControlStream(panes: [
      "%3": FakeTmuxControlStream.Pane(window: "@1", state: state, screen: ["$ "])
    ])
    stream.hold(linesContaining: "refresh-client -C @1:")
    for index in 1...1_000 {
      try await stream.send(Data("refresh-client -C @1:\(index)x10\n".utf8))
    }
    let resuming = Task.detached { stream.resumeHeld() }
    var answers = stream.output.makeAsyncIterator()
    // The first held answer is out, so `resumeHeld()` is running. Hold the keys now.
    while let chunk = try await answers.next() {
      if String(decoding: chunk, as: UTF8.self).contains("%end 9 ") { break }
    }
    stream.hold(linesContaining: "send-keys")
    await resuming.value
    try await stream.send(Data("send-keys -t %3 -H 61\n".utf8))
    #expect(stream.keys(for: "%3").isEmpty, "the keys wait for the next resume")
    stream.resumeHeld()
    #expect(stream.keys(for: "%3") == Data([0x61]))
  }
}
