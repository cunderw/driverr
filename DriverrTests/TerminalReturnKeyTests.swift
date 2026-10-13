import Foundation
import SwiftTerm
import SwiftUI
import Testing
import UIKit

@testable import DriverrTerm

/// Return sends CR, and armed Ctrl then Return sends LF.
///
/// Claude Code reads LF as a new line and CR as submit, so armed Ctrl then Return adds a line.
/// SwiftTerm applying Control to "\n" gives no byte. `ReturnKeyBytesTests` pins the mapping;
/// this pins that the view uses it.
///
/// Hosted, because `DriverrTerminalUIView` is a UIKit view and the Kit
/// tier does not build it. `insertText` is what both the software keyboard and a hardware
/// Return reach. A hardware Shift-Return goes through `pressesBegan` first, and no in-process
/// API creates a `UIPress`, so that half is checked on a device.
@MainActor
@Suite("DriverrTerminalUIView Return key")
struct TerminalReturnKeyTests {
  /// Records what the view hands its delegate, synchronously.
  ///
  /// In place of the session's own delegate, whose writes go out through a `Task` and would
  /// need a wait.
  private final class RecordingDelegate: TerminalViewDelegate {
    var sent: [[UInt8]] = []

    func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(Array(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
  }

  @MainActor
  private struct Hosted {
    let window: UIWindow
    let view: DriverrTerminalUIView
    let delegate: RecordingDelegate
    let finish: () -> Void
  }

  private func hosted() throws -> Hosted {
    let (output, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    let feed = TerminalFeed(output: output, send: { _ in }, resize: { _ in }, close: {})
    let window = HostedProbe.window(
      DriverrTerminalView(session: TerminalSession(feed: feed), wantsKeyboardFocus: false)
    )
    let view = try #require(Self.terminal(in: window))
    let delegate = RecordingDelegate()
    view.terminalDelegate = delegate
    return Hosted(window: window, view: view, delegate: delegate) {
      continuation.finish()
    }
  }

  private static func terminal(in view: UIView) -> DriverrTerminalUIView? {
    if let terminal = view as? DriverrTerminalUIView { return terminal }
    for subview in view.subviews {
      if let terminal = terminal(in: subview) { return terminal }
    }
    return nil
  }

  @Test("plain Return sends a carriage return")
  func plainReturnSendsCR() throws {
    let hosted = try hosted()
    defer { hosted.finish() }

    hosted.view.insertText("\n")

    #expect(hosted.delegate.sent == [[0x0d]])
    withExtendedLifetime(hosted.window) {}
  }

  @Test("armed Ctrl then Return sends a line feed and disarms Ctrl")
  func controlReturnSendsLF() throws {
    let hosted = try hosted()
    defer { hosted.finish() }

    hosted.view.controlModifier = true
    hosted.view.insertText("\n")

    #expect(hosted.delegate.sent == [[0x0a]])
    #expect(!hosted.view.controlModifier)

    // The line feed is for that one Return: the next plain Return must still submit.
    hosted.view.insertText("\n")
    #expect(hosted.delegate.sent == [[0x0a], [0x0d]])
    withExtendedLifetime(hosted.window) {}
  }

  /// A held hardware Shift-Return keeps adding lines. A repeat can reach `insertText` with
  /// no new `pressesBegan`, so the flag set by the press must survive the first Return.
  /// `internal`, and set here directly, because no in-process API creates a `UIPress`.
  @Test("a repeated Shift-Return keeps sending line feeds")
  func repeatedShiftReturnSendsLF() throws {
    let hosted = try hosted()
    defer { hosted.finish() }

    hosted.view.isHardwareKeyboardConnected = { true }
    hosted.view.shiftReturnPending = true
    hosted.view.insertText("\n")
    hosted.view.insertText("\n")

    #expect(hosted.delegate.sent == [[0x0a], [0x0a]])
    withExtendedLifetime(hosted.window) {}
  }

  /// Software-keyboard taps never reach `pressesBegan`, so a flag left by the last hardware
  /// Shift-Return must not outlive the keyboard. With none attached, Return submits.
  @Test("a Shift-Return flag left with no hardware keyboard still sends a carriage return")
  func staleShiftReturnWithoutKeyboardSendsCR() throws {
    let hosted = try hosted()
    defer { hosted.finish() }

    hosted.view.isHardwareKeyboardConnected = { false }
    hosted.view.shiftReturnPending = true
    hosted.view.insertText("\n")

    #expect(hosted.delegate.sent == [[0x0d]])
    withExtendedLifetime(hosted.window) {}
  }
}
