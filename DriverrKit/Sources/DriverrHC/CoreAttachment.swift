import DriverrCore
import DriverrHerdr
import Foundation

/// One viewer on one terminal: a `terminal.attach` channel on the shared connection.
///
/// A `PaneBridge` and a `PaneObserver` both, so the scene's two kinds of hold stay as they
/// are. Unlike the TUI's, the bytes are the program's own and the scrollback is local, so a
/// feed built from this reads like a pty's, which is what `RawTerminalStream` says.
///
/// **Credit is returned for what was consumed, not what was read.** The reader yields into
/// an unbounded stream, so crediting there would let a burst run ahead of the main thread
/// with nothing to stop it. Whoever renders the bytes calls `consumed(_:)`.
final class CoreAttachment: PaneBridge, PaneObserver, RawTerminalStream, @unchecked Sendable {
  /// How many consumed bytes to gather before sending CREDIT.
  ///
  /// A fraction of the stream's 256 KiB starting credit, so what is still owed can never
  /// stall it. One frame per chunk of a burst would be a write per chunk on the shared link.
  static let creditBatch = 64 * 1024

  let output: AsyncThrowingStream<Data, any Error>

  private let connection: CoreConnection
  private let channel: UInt32
  private let isObserver: Bool
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  /// A lock, not an actor: `consumed` runs on the main actor for every chunk and must not wait.
  private let lock = NSLock()
  private var owedCredit = 0
  private var isReleased = false

  private init(
    output: AsyncThrowingStream<Data, any Error>,
    continuation: AsyncThrowingStream<Data, any Error>.Continuation,
    connection: CoreConnection,
    channel: UInt32,
    isObserver: Bool
  ) {
    self.output = output
    self.continuation = continuation
    self.connection = connection
    self.channel = channel
    self.isObserver = isObserver
  }

  static func open(
    on connection: CoreConnection,
    params: CoreAttachParams
  ) async throws -> CoreAttachment {
    let (output, continuation) = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self
    )
    do {
      let opened = try await connection.openChannel(
        "terminal.attach",
        params: params,
        as: CoreAttachResult.self,
        handler: receiver(continuation)
      )
      return CoreAttachment(
        output: output,
        continuation: continuation,
        connection: connection,
        channel: opened.channel,
        isObserver: params.observe
      )
    } catch {
      continuation.finish()
      throw error
    }
  }

  /// `PaneBridge.output`'s contract: a clean finish for a program that ended, a
  /// `TerminalCloseReason` for anything else, and `.streamEnded` for a connection that went
  /// with no CLOSE.
  private static func receiver(
    _ continuation: AsyncThrowingStream<Data, any Error>.Continuation
  ) -> CoreConnection.ChannelHandler {
    { event in
      switch event {
      case .connectionEnded:
        continuation.finish(throwing: TerminalCloseReason.streamEnded)
      case .frame(let frame) where frame.kind == .data:
        continuation.yield(frame.payload)
      case .frame(let frame) where frame.kind == .close:
        let reason = closeReason(from: frame.payload)
        if reason == .paneClosed {
          continuation.finish()
        } else {
          continuation.finish(throwing: reason)
        }
      case .frame:
        break
      }
    }
  }

  /// Maps a CLOSE's payload to `TerminalCloseReason`. The core's vocabulary matters only here.
  ///
  /// - nothing: the receipt for our own CLOSE, `.detached`
  /// - `finished_ms` present and `null`: a kept terminal's loss, `.lost`, whatever `reason`
  /// - `exited`, `killed`, or no reason → `.paneClosed`
  /// - `server_stop`, `host_shutdown`, `stopped_by_restart` → `.serverShuttingDown`
  /// - anything else → `.other`, kept verbatim
  static func closeReason(from payload: Data) -> TerminalCloseReason {
    guard !payload.isEmpty else { return .detached }
    guard let record = try? JSONDecoder().decode(CoreCloseRecord.self, from: payload) else {
      return .other(String(decoding: payload, as: UTF8.self))
    }
    if record.isLoss { return .lost }
    switch record.reason {
    case nil, "exited", "killed": return .paneClosed
    case "server_stop", "host_shutdown", "stopped_by_restart": return .serverShuttingDown
    case .some(let other): return .other(other)
    }
  }

  func send(text: String) async throws {
    try await send(bytes: Data(text.utf8))
  }

  func send(bytes: Data) async throws {
    try await connection.write(.data, bytes, toChannel: channel)
  }

  func resize(to size: TerminalSize) async throws {
    var payload = Data()
    for cells in [size.columns, size.rows] {
      withUnsafeBytes(of: UInt16(clamping: cells).littleEndian) { payload.append(contentsOf: $0) }
    }
    try await connection.write(.resize, payload, toChannel: channel)
  }

  /// Scrollback is local, and a tap goes through `TerminalMouseClick`, so a feed over this has
  /// neither closure and these are never reached. `PaneBridge` asks for them.
  func scroll(_ direction: ScrollDirection, lines: Int) async throws {}
  func click(_ cell: TerminalCell) async throws {}

  func focus(_ gained: Bool) async throws {
    // An observer's focus means nothing to the core.
    guard !isObserver else { return }
    try await connection.write(.focus, Data([gained ? 1 : 0]), toChannel: channel)
  }

  func consumed(_ bytes: Int) {
    let due: Int? = lock.withLock {
      guard !isReleased else { return nil }
      owedCredit += bytes
      guard owedCredit >= Self.creditBatch else { return nil }
      defer { owedCredit = 0 }
      return owedCredit
    }
    guard let due else { return }
    Task { [connection, channel] in await connection.credit(due, toChannel: channel) }
  }

  func release() async {
    lock.withLock { isReleased = true }
    await connection.closeChannel(channel)
    continuation.finish()
  }
}
