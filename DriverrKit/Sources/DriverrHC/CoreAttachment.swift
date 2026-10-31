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

  var output: AsyncThrowingStream<Data, any Error> { delivery.output }

  private let connection: CoreConnection
  private let delivery: CoreViewerDelivery
  private let isObserver: Bool
  /// A lock, not an actor: `consumed` runs on the main actor for every chunk and must not wait.
  private let lock = NSLock()
  private var channel: UInt32
  /// What an attach for this viewer asks for now, kept for `repaint()`.
  private var params: CoreAttachParams
  private var generation = 0
  private var owedCredit = 0
  private var isReleased = false
  private var repainting: Task<Void, Never>?
  private var isRepainting = false

  private init(
    delivery: CoreViewerDelivery,
    connection: CoreConnection,
    channel: UInt32,
    params: CoreAttachParams
  ) {
    self.delivery = delivery
    self.connection = connection
    self.channel = channel
    self.params = params
    isObserver = params.observe
  }

  static func open(
    on connection: CoreConnection,
    params: CoreAttachParams
  ) async throws -> CoreAttachment {
    let delivery = CoreViewerDelivery()
    do {
      let opened = try await connection.openChannel(
        "terminal.attach",
        params: params,
        as: CoreAttachResult.self,
        handler: delivery.handler(generation: 0)
      )
      return CoreAttachment(
        delivery: delivery,
        connection: connection,
        channel: opened.channel,
        params: params
      )
    } catch {
      delivery.finish()
      throw error
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
    try await connection.write(.data, bytes, toChannel: currentChannel)
  }

  private var currentChannel: UInt32 { lock.withLock { channel } }

  func resize(to size: TerminalSize) async throws {
    var payload = Data()
    for cells in [size.columns, size.rows] {
      withUnsafeBytes(of: UInt16(clamping: cells).littleEndian) { payload.append(contentsOf: $0) }
    }
    lock.withLock {
      params.cols = size.columns
      params.rows = size.rows
    }
    try await connection.write(.resize, payload, toChannel: currentChannel)
  }

  /// A drag goes by `TerminalDragRoute` and a tap through `TerminalMouseClick`, so a feed over
  /// this has neither closure and these are never reached. `PaneBridge` asks for them.
  func scroll(_ direction: ScrollDirection, lines: Int) async throws {}
  func click(_ cell: TerminalCell) async throws {}

  func focus(_ gained: Bool) async throws {
    // An observer's focus means nothing to the core.
    guard !isObserver else { return }
    try await connection.write(.focus, Data([gained ? 1 : 0]), toChannel: currentChannel)
  }

  /// Attaches again if this stream's paint held nothing of the normal screen.
  ///
  /// The core skips a shell's screen and history in a paint on the alternate screen, so the
  /// emulator has nothing behind `top`. Only a paint brings them back, and only an attach
  /// brings a paint. A stream that saw the program start and kept up has it all already.
  func leftAlternateScreen() {
    guard !isObserver, delivery.takePaintedAlternateScreen() else { return }
    let running = Task { await repaint() }
    lock.withLock { repainting = running }
  }

  /// Returns once any repaint under way has finished, so a test can say that none happened.
  func repaintSettled() async {
    await lock.withLock { repainting }?.value
  }

  /// A second channel into the same output, so the emulator and its keyboard stay as they are.
  ///
  /// `resumed`, because the phone did nothing: a desk that typed since keeps the size. No
  /// history when the emulator already has it, which a repaint for falling behind leaves it
  /// holding, or it would print twice.
  ///
  /// The old channel delivers until the new one's first frame, whose paint covers anything cut
  /// off. If the attach is refused, the old channel stays and the screen stays blank until the
  /// next open.
  private func repaint() async {
    let next: (params: CoreAttachParams, generation: Int)? = lock.withLock {
      guard !isReleased else { return nil }
      generation += 1
      isRepainting = true
      var repaint = params
      repaint.resumed = true
      if delivery.holdsHistory { repaint.history = 0 }
      return (repaint, generation)
    }
    guard let next else { return }

    let opened = try? await connection.openChannel(
      "terminal.attach",
      params: next.params,
      as: CoreAttachResult.self,
      handler: delivery.handler(generation: next.generation)
    )
    // Credit held meanwhile goes out here whether or not the attach worked. It may be all
    // the window had, and then no later `consumed` would come to send it.
    let settled: (unused: UInt32?, credit: (bytes: Int, channel: UInt32)?) = lock.withLock {
      isRepainting = false
      guard !isReleased else { return (opened?.channel, nil) }
      let replaced = opened.map { _ in channel }
      if let opened { channel = opened.channel }
      return (replaced, takeDueCredit().map { ($0, channel) })
    }
    if let credit = settled.credit {
      await connection.credit(credit.bytes, toChannel: credit.channel)
    }
    if let unused = settled.unused { await connection.closeChannel(unused) }
  }

  func consumed(_ bytes: Int) {
    let due: (bytes: Int, channel: UInt32)? = lock.withLock {
      guard !isReleased else { return nil }
      owedCredit += bytes
      // Held while the channel is changing: the new paint's bytes are already being rendered,
      // and credit for them sent to the old channel would be lost to the new one's window.
      guard !isRepainting, let credit = takeDueCredit() else { return nil }
      return (credit, channel)
    }
    guard let due else { return }
    Task { [connection] in await connection.credit(due.bytes, toChannel: due.channel) }
  }

  /// A whole batch of what is owed, if there is one. Call with `lock` held.
  private func takeDueCredit() -> Int? {
    guard owedCredit >= Self.creditBatch else { return nil }
    defer { owedCredit = 0 }
    return owedCredit
  }

  func release() async {
    let channel: UInt32 = lock.withLock {
      isReleased = true
      return self.channel
    }
    await connection.closeChannel(channel)
    delivery.finish()
  }
}

/// Where a viewer's channels deliver.
///
/// Made ahead of the first channel, because a paint can arrive before the reply naming it.
/// `generation` tells a replacement channel from the one it replaces: the first frame of a
/// later generation ends the earlier one.
private final class CoreViewerDelivery: @unchecked Sendable {
  let output: AsyncThrowingStream<Data, any Error>

  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let lock = NSLock()
  private var generation = 0
  private var paintedAlternateScreen = false
  private var holdsHistoryNow = false
  /// The channel whose first paint has been seen, by generation.
  private var paintedGeneration = -1

  init() {
    (output, continuation) = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self
    )
  }

  func finish() {
    continuation.finish()
  }

  /// Whether the emulator has the history: a channel's first paint carried it.
  var holdsHistory: Bool { lock.withLock { holdsHistoryNow } }

  /// Answers once for each paint on the alternate screen.
  func takePaintedAlternateScreen() -> Bool {
    lock.withLock {
      defer { paintedAlternateScreen = false }
      return paintedAlternateScreen
    }
  }

  /// `PaneBridge.output`'s contract: a clean finish for a program that ended, a
  /// `TerminalCloseReason` for anything else, and `.streamEnded` for a connection that went
  /// with no CLOSE.
  func handler(generation: Int) -> CoreConnection.ChannelHandler {
    { [self] event in
      let isCurrent: Bool = lock.withLock {
        guard generation >= self.generation else { return false }
        self.generation = generation
        return true
      }
      guard isCurrent else { return }

      switch event {
      case .connectionEnded:
        continuation.finish(throwing: TerminalCloseReason.streamEnded)
      case .frame(let frame) where frame.kind == .data:
        continuation.yield(prepared(frame.payload, generation: generation))
      case .frame(let frame) where frame.kind == .close:
        let reason = CoreAttachment.closeReason(from: frame.payload)
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

  /// Only a channel's first paint can hold the history. A repaint for falling behind has none,
  /// so one of the normal screen is no answer to a stream that never had it.
  private func prepared(_ bytes: Data, generation: Int) -> Data {
    guard let paint = CorePaint(bytes) else { return bytes }
    lock.withLock {
      let isFirst = generation != paintedGeneration
      paintedGeneration = generation
      if paint.isOnAlternateScreen {
        paintedAlternateScreen = true
      } else if isFirst || holdsHistoryNow {
        holdsHistoryNow = true
        paintedAlternateScreen = false
      }
    }
    return paint.bytes
  }
}

/// A first paint, or the repaint a viewer gets for falling behind, which opens the same way.
/// The core's wording of one matters only here.
///
/// A paint starts a frame, because the core queues it onto an empty backlog, and its opening
/// reset fits in that frame.
struct CorePaint {
  private static let opening = Data("\u{1b}[!p".utf8)
  private static let endOfReset = Data("\u{1b}[?47l\u{1b}[H\u{1b}[2J".utf8)
  private static let leavingWithRestore = Data("\u{1b}[?1049l".utf8)
  private static let leaving = Data("\u{1b}[?1047l".utf8)
  private static let enteringAlternateScreen = Data("\u{1b}[?1049h".utf8)

  let bytes: Data
  /// Whether this paint is of a full-screen program, so it holds nothing of the normal screen.
  let isOnAlternateScreen: Bool

  /// `nil` for a frame that is not a paint.
  ///
  /// **`?1049l` becomes `?1047l`, the same length, so credit still adds up.** SwiftTerm's
  /// `?1049l` restores a cursor, and with it the saved autowrap. Nothing saved one, and the
  /// paint's own soft reset leaves the saved value off, so every line after a paint would
  /// clip at the last column. The cursor does not matter: the reset goes on to `CSI H`.
  init?(_ frame: Data) {
    guard frame.starts(with: Self.opening),
      let resetEnd = frame.range(of: Self.endOfReset),
      let leaving = frame.range(
        of: Self.leavingWithRestore, in: frame.startIndex..<resetEnd.lowerBound)
    else { return nil }

    var bytes = frame
    bytes.replaceSubrange(leaving, with: Self.leaving)
    self.bytes = bytes
    isOnAlternateScreen = frame[resetEnd.upperBound...].starts(with: Self.enteringAlternateScreen)
  }
}
