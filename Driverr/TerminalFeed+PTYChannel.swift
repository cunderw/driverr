import DriverrCore
import DriverrHerdr
import Foundation
import DriverrSSH
import DriverrTerm

/// The adapters that keep `DriverrTerm`, `DriverrSSH` and `DriverrHerdr` independent.
///
/// `DriverrTerm` renders a byte stream and `DriverrSSH` produces one. Neither imports the
/// other, so this file, the one place allowed to know both, joins them.
extension TerminalFeed {
  init(channel: any PTYChannel) {
    self.init(
      output: channel.output,
      send: { try await channel.send($0) },
      resize: { try await channel.resize(to: $0) },
      close: { await channel.close() }
    )
  }
}

/// A herdr pane as a feed.
///
/// A pane is not a pty. Its history lives in herdr, so this feed carries `scroll`, and
/// herdr knows the pane's mouse mode, so it carries `click`. That is why a drag on a pane
/// sends `terminal.scroll` while a drag on a shell goes by `TerminalDragRoute`; see
/// `TerminalFeed`.
extension TerminalFeed {
  init(bridge: any PaneBridge) {
    self.init(
      output: bridge.output,
      send: { try await bridge.send(bytes: $0) },
      resize: { try await bridge.resize(to: $0) },
      close: { await bridge.release() },
      scroll: { direction, lines in try await bridge.scroll(direction, lines: lines) },
      click: { try await bridge.click($0) }
    )
  }
}

/// A herdr-core terminal as a feed.
///
/// The other way round from a bridge pane: the bytes are the program's own, so the emulator
/// knows the program's modes, a drag goes by `TerminalDragRoute`, and `TerminalMouseClick`
/// encodes a tap locally. A feed with no `scroll` or `click` is what says so. What it adds is
/// the two things a core asks of a viewer.
extension TerminalFeed {
  init(
    raw: any RawTerminalStream,
    output: AsyncThrowingStream<Data, any Error>,
    send: @escaping @Sendable (Data) async throws -> Void,
    resize: @escaping @Sendable (TerminalSize) async throws -> Void
  ) {
    self.init(
      output: output,
      send: send,
      resize: resize,
      // The scene releases, in order; see `TerminalSceneModel.demote(_:)`.
      close: {},
      focus: { try await raw.focus($0) },
      consumed: { raw.consumed($0) },
      leftAlternateScreen: { raw.leftAlternateScreen() },
      awaitsFirstSize: true
    )
  }
}

/// `DriverrSSH`'s stream, as `DriverrHerdr` wants it.
///
/// **A class that owns a task, because of stderr.** `ExecStream` keeps stderr separate so
/// it cannot corrupt parsed frames. A `herdr terminal session control` that fails after
/// starting writes its reason there, so something must drain it for the tail to exist
/// when the bridge asks.
final class ExecStreamBridge: HerdrStream {
  let stream: any ExecStream

  private let tail: StandardErrorTail
  private let drain: Task<Void, Never>

  init(stream: any ExecStream) {
    let tail = StandardErrorTail()
    self.stream = stream
    self.tail = tail
    // Read out here, so the task never captures `self`. Capturing `self` would keep this
    // object alive until stderr finished, and `deinit` could not cancel the drain.
    let errors = stream.standardError
    drain = Task {
      do {
        for try await chunk in errors {
          tail.append(chunk)
        }
      } catch {
        // A failed stderr stream has said all it will. Keep what the tail already holds.
      }
      tail.finish()
    }
  }

  deinit { drain.cancel() }

  var output: AsyncThrowingStream<Data, any Error> { stream.output }

  /// How the command finished, after a short wait for whatever is still arriving.
  ///
  /// SSH's `exit-status` and the last of stderr are not ordered against `output`
  /// finishing, so this waits up to `endWait` for both. The bound lives here, not in
  /// `BridgeFramePump`, because only this conformer can race, and the fakes answer
  /// instantly. The wait only runs on a path that is already ending.
  var end: ProcessEnd? {
    get async {
      // **Keep `!Task.isCancelled`.** `try?` swallows `Task.sleep`'s cancellation error,
      // so without it a cancelled read spins this loop until the deadline.
      let deadline = ContinuousClock.now + Self.endWait
      while ContinuousClock.now < deadline, !Task.isCancelled {
        if tail.isFinished, await stream.exitStatus != nil { break }
        try? await Task.sleep(for: .milliseconds(10))
      }
      return ProcessEnd(exitStatus: await stream.exitStatus, standardErrorTail: tail.text)
    }
  }

  /// How long `end` will wait for the exit status and the last of stderr before answering
  /// with what it has.
  private static let endWait: Duration = .milliseconds(250)

  func send(_ data: Data) async throws { try await stream.send(data) }

  func close() async {
    await stream.close()
    drain.cancel()
  }
}

/// The last few kilobytes a command wrote to stderr.
///
/// Trimmed from the front, because a failing process explains itself last, and an
/// unbounded buffer would grow for the life of the bridge. 4 KB is far more than herdr's
/// longest error.
///
/// A lock, not an actor: the critical sections are tiny and `withLock` cannot suspend, so
/// it is legal from async code under strict concurrency. `@unchecked` because the lock,
/// not the type system, guards the state.
private final class StandardErrorTail: @unchecked Sendable {
  /// Never logged, persisted or sent. It is read once to build one notice, because remote
  /// stderr can hold anything the host printed.
  static let limit = 4096

  private let lock = NSLock()
  private var bytes = Data()
  private var finished = false

  func append(_ chunk: Data) {
    lock.withLock {
      bytes.append(chunk)
      if bytes.count > Self.limit {
        bytes.removeFirst(bytes.count - Self.limit)
      }
    }
  }

  func finish() {
    lock.withLock { finished = true }
  }

  /// Whether the stream behind this tail has ended, so there is nothing more to wait for.
  var isFinished: Bool { lock.withLock { finished } }

  /// The tail as text. Lossy, because trimming the front can split a UTF-8 sequence.
  var text: String { String(decoding: lock.withLock { bytes }, as: UTF8.self) }
}
