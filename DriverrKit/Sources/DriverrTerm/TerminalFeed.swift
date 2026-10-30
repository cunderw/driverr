import DriverrCore
import Foundation

/// Everything a terminal needs from whatever is on the other end: bytes arriving, bytes
/// leaving, and a way to say how big the window is.
///
/// A struct of closures, not `DriverrSSH`'s `PTYChannel`, so a PTY, a herdr pane or a test
/// transcript can drive it. See the `DriverrTerm` import rule in `CLAUDE.md`.
public struct TerminalFeed: Sendable {
  /// Everything the far side has written. Finishing means a clean close, and throwing
  /// means the channel died.
  public var output: AsyncThrowingStream<Data, any Error>
  public var send: @Sendable (Data) async throws -> Void
  public var resize: @Sendable (TerminalSize) async throws -> Void
  public var close: @Sendable () async -> Void
  /// How to scroll, when scrolling is **not** this side's job.
  ///
  /// `nil` for a pty, whose scrollback lives in the local emulator. A herdr pane's history
  /// lives in herdr, so a drag becomes a message sent through this.
  public var scroll: (@Sendable (ScrollDirection, Int) async throws -> Void)?
  /// Where a tap's click goes, when the far side decides whether it is one.
  ///
  /// `nil` for a pty, where `TerminalMouseClick` encodes the click locally. A herdr pane's
  /// emulator never sees the mouse mode, so the tap goes to herdr as a cell.
  public var click: (@Sendable (TerminalCell) async throws -> Void)?
  /// Whether this terminal has the keyboard, when the far side wants to be told directly.
  ///
  /// `nil` for a pty and a herdr pane. When set, SwiftTerm's own `CSI I` and `CSI O` reports
  /// are dropped. See `TerminalSession.send(_:)`.
  public var focus: (@Sendable (Bool) async throws -> Void)?
  /// Takes how many bytes just reached the renderer, when the far side paces itself on that.
  ///
  /// `nil` for a pty and a herdr pane. Never waits: the session calls it as it renders.
  public var consumed: (@Sendable (Int) -> Void)?

  public init(
    output: AsyncThrowingStream<Data, any Error>,
    send: @escaping @Sendable (Data) async throws -> Void,
    resize: @escaping @Sendable (TerminalSize) async throws -> Void,
    close: @escaping @Sendable () async -> Void,
    scroll: (@Sendable (ScrollDirection, Int) async throws -> Void)? = nil,
    click: (@Sendable (TerminalCell) async throws -> Void)? = nil,
    focus: (@Sendable (Bool) async throws -> Void)? = nil,
    consumed: (@Sendable (Int) -> Void)? = nil
  ) {
    self.output = output
    self.send = send
    self.resize = resize
    self.close = close
    self.scroll = scroll
    self.click = click
    self.focus = focus
    self.consumed = consumed
  }

  /// A feed for an `observe` stream: everything but reading is inert.
  ///
  /// herdr ignores an observer's input and never resizes for it, so `send` and `resize`
  /// are no-ops rather than errors. `scroll` and `click` are `nil`, because nobody looks
  /// at an observer.
  public static func readOnly(
    output: AsyncThrowingStream<Data, any Error>,
    close: @escaping @Sendable () async -> Void
  ) -> TerminalFeed {
    TerminalFeed(
      output: output,
      send: { _ in },
      resize: { _ in },
      close: close,
      scroll: nil,
      click: nil
    )
  }
}
