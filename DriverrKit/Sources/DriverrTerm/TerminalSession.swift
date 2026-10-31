import DriverrCore
import Foundation
import Observation

/// One live terminal: pumps a `TerminalFeed`'s output at a renderer and sends typed
/// input back the other way.
///
/// Behaviour lives here rather than in the view, so tests can drive it against a headless
/// SwiftTerm `Terminal`. Nothing is shared, so sessions can run side by side.
@MainActor
@Observable
public final class TerminalSession {
  public enum State: Equatable, Sendable {
    case idle
    case running
    /// The far side closed cleanly, such as a shell that exited.
    case closed
    case failed(AppError)
  }

  public private(set) var state: State = .idle
  /// The last title the remote side set via OSC, such as a shell's `\e]0;…\a`.
  public private(set) var title: String?

  private let feed: TerminalFeed
  private var pump: Task<Void, Never>?
  /// Every write to the far side, in order. One task drains it and awaits each write.
  ///
  /// A `Task` per write does not keep order, because the cooperative pool starts them in
  /// any order. Keystrokes, paste chunks, scrolls and clicks all go through here. A slow
  /// write holds up the rest, which is acceptable on one byte stream.
  private let outbox: AsyncStream<@Sendable () async -> Void>.Continuation
  /// The task that drains `outbox`. It ends once the queue is finished and empty.
  private let drain: Task<Void, Never>
  private var sink: (@MainActor (ArraySlice<UInt8>) -> Void)?
  /// Reads what the attached renderer shows. Set and cleared with the sink.
  private var readVisibleText: (@MainActor () -> String)?
  /// Output that arrived before a renderer attached. The shell writes its prompt before
  /// SwiftUI makes the view, and without this the terminal starts blank.
  private var pending: [UInt8] = []
  /// How much output is waiting for a renderer, so a test can tell "not read yet" from
  /// "buffered".
  var bufferedByteCount: Int { pending.count }
  /// The last focus sent to the far side, so a repeat grant costs nothing. A grant counts as
  /// activity on a core, so a repeat would not be free.
  private var lastSentFocus: Bool?
  /// The last size actually sent to the far side, so an identical repeat costs nothing.
  private var lastSentSize: TerminalSize?
  /// The newest size the renderer has reported but that has not been sent yet.
  private var pendingSize: TerminalSize?
  private var resizeFlush: Task<Void, Never>?
  private let resizeCoalescingWindow: Duration
  private let openSettlingWindow: Duration
  /// Rows the user has dragged past that have not been asked for yet, signed: positive is
  /// up, into older output. Signed so reversing mid-drag cancels instead of sending both.
  private var unsentScrollRows = 0
  /// True from sending a scroll until its frame comes back. Keeps one scroll in flight.
  private var scrollAwaitingFrame = false
  /// Which scheduled pacing timeout is the live one. See `FocusRetryPolicy.generation`.
  private var scrollGateGeneration = 0
  private let scrollPacingTimeout: Duration
  private let scrollPacingScheduler: ScrollPacingScheduler
  /// The rows the in-flight scroll asked for, signed like `unsentScrollRows`. Kept apart
  /// so a sent request is not banked again.
  private var inFlightScrollRows = 0
  /// Net rows scrolled up, counting only scrolls herdr answered with a frame. Clamped at
  /// zero.
  ///
  /// On an alt-screen pane with alternate scroll (mode 1007) or a mouse-reporting pane,
  /// herdr ignores the row count and sends one wheel event or arrow key per command.
  public private(set) var scrolledRows = 0

  /// How long to let sizes settle before telling the far side.
  ///
  /// A Split View drag or a rotation emits many sizes, and each would be a `SIGWINCH`
  /// and a full redraw. Short enough that a rotation still feels instant.
  public static let defaultResizeCoalescingWindow = Duration.milliseconds(60)

  /// How long the first size is held, longer because an open takes two layout passes.
  ///
  /// The grid lays out, then the keyboard and accessory row rise and iOS revises the
  /// keyboard frame. Without the wait an open sends two sizes, for example `50x18` then
  /// `50x22`, and a herdr pane reflows the user's desk twice. 400 ms was too short.
  ///
  /// A bridge stream already opened at `TerminalSceneModel.viewportSize`, and `reportedSize`
  /// reads `pendingSize`, so nothing waits on this delay. A held core attach does: this first
  /// size is what it attaches at. See `DeferredPaneBridge`.
  public static let defaultOpenSettlingWindow = Duration.milliseconds(1000)

  /// How long to wait for a scroll's frame before assuming none is coming.
  ///
  /// At either end of the scrollback herdr sends no frame, because nothing changed.
  /// Without a timeout the gate would stay shut. Long enough for a slow link, short
  /// enough that hitting the top does not feel stuck.
  public static let defaultScrollPacingTimeout = Duration.milliseconds(250)

  /// How long `close()`'s caller waits for the write queue to drain before it hands the
  /// far side back anyway. See `pendingWritesSent(within:)`.
  public static let defaultWriteDrainLimit = Duration.seconds(1)

  /// Runs `work` once a scroll's pacing timeout elapses. See
  /// `FocusRetryPolicy.Scheduler`.
  public typealias ScrollPacingScheduler = @MainActor (Duration, @escaping @MainActor () -> Void) -> Void

  public static let liveScrollPacingScheduler: ScrollPacingScheduler = { delay, work in
    Task {
      try? await Task.sleep(for: delay)
      work()
    }
  }

  public init(
    feed: TerminalFeed,
    resizeCoalescingWindow: Duration = TerminalSession.defaultResizeCoalescingWindow,
    openSettlingWindow: Duration = TerminalSession.defaultOpenSettlingWindow,
    scrollPacingTimeout: Duration = TerminalSession.defaultScrollPacingTimeout,
    scrollPacingScheduler: @escaping ScrollPacingScheduler = TerminalSession.liveScrollPacingScheduler
  ) {
    self.feed = feed
    self.resizeCoalescingWindow = resizeCoalescingWindow
    self.openSettlingWindow = openSettlingWindow
    self.scrollPacingTimeout = scrollPacingTimeout
    self.scrollPacingScheduler = scrollPacingScheduler
    let (writes, outbox) = AsyncStream<@Sendable () async -> Void>.makeStream()
    self.outbox = outbox
    // Holds the stream and nothing else, so the queue does not keep the session alive.
    drain = Task {
      for await write in writes { await write() }
    }
  }

  deinit {
    outbox.finish()
  }

  /// Begins reading the feed. Only the first call does anything, so a re-run `.task`
  /// cannot open a second pump.
  public func start() {
    guard pump == nil else { return }
    state = .running
    pump = Task { [weak self, feed] in
      do {
        for try await chunk in feed.output {
          guard let self else { return }
          self.deliver(chunk)
        }
        self?.finish(with: nil)
      } catch {
        self?.finish(with: error)
      }
    }
  }

  /// Points the session at a renderer and flushes anything that arrived before it existed.
  ///
  /// - Parameter visibleText: reads back what the renderer shows, for the pane sheet's
  ///   thumbnails. The emulator belongs to the view, so this is the only way to reach it.
  public func attach(
    _ sink: @escaping @MainActor (ArraySlice<UInt8>) -> Void,
    visibleText: (@MainActor () -> String)? = nil
  ) {
    self.sink = sink
    readVisibleText = visibleText
    guard !pending.isEmpty else { return }
    let buffered = pending
    pending.removeAll()
    sink(buffered[...])
    feed.consumed?(buffered.count)
  }

  /// Stops rendering without touching the connection. Later bytes are buffered for the
  /// next `attach`.
  public func detach() {
    sink = nil
    // Dropped with the sink, or it would keep reporting a dismantled view's last screen.
    readVisibleText = nil
  }

  /// The last `count` rows the renderer is showing, or `nil` when nothing is rendering.
  ///
  /// `nil` means "ask elsewhere", and the caller falls back to `pane read`. `[]` means the
  /// pane shows nothing.
  public func visibleLines(last count: Int) -> [String]? {
    guard let text = readVisibleText?() else { return nil }
    // Splitting "" yields one empty line, not none.
    guard !text.isEmpty else { return [] }
    return Array(text.split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
      .suffix(count))
  }

  public func send(_ bytes: ArraySlice<UInt8>) {
    // Rejected only once the channel is gone, not before `start()`. The pump governs
    // output only, and an attach command can be sent before the view exists.
    switch state {
    case .closed, .failed: return
    case .idle, .running: break
    }
    // Told through `focus(_:)` when the feed takes that. SwiftTerm's report on top would say
    // it twice, and as typed bytes a focus-out would count as activity and take the size.
    if feed.focus != nil, Self.isFocusReport(bytes) { return }
    let data = Data(bytes)
    outbox.yield { [feed] in
      // A failed write means the channel is gone, and the pump reports that.
      try? await feed.send(data)
    }
  }

  public func send(text: String) {
    send(ArraySlice(Array(text.utf8)))
  }

  /// SwiftTerm's two focus reports, whole. Anything else a program asked for goes out.
  private static func isFocusReport(_ bytes: ArraySlice<UInt8>) -> Bool {
    bytes.elementsEqual([0x1B, 0x5B, 0x49]) || bytes.elementsEqual([0x1B, 0x5B, 0x4F])
  }

  /// Tells the far side whether this terminal has the keyboard, if it wants to know.
  public func focus(_ gained: Bool) {
    guard let focus = feed.focus, gained != lastSentFocus else { return }
    switch state {
    case .closed, .failed: return
    case .idle, .running: break
    }
    lastSentFocus = gained
    outbox.yield { try? await focus(gained) }
  }

  /// Tells the far side the window changed, once the sizes stop moving.
  ///
  /// An identical repeat is dropped. A burst collapses to its last size after
  /// `resizeCoalescingWindow`. The first size waits `openSettlingWindow` instead.
  public func resize(to size: TerminalSize) {
    guard size != lastSentSize else { return }
    switch state {
    case .closed, .failed: return
    case .idle, .running: break
    }
    pendingSize = size
    guard resizeFlush == nil else { return }
    // An open is the case where nothing has reached the far side yet.
    let window = lastSentSize == nil ? openSettlingWindow : resizeCoalescingWindow
    resizeFlush = Task { [weak self, window] in
      try? await Task.sleep(for: window)
      self?.flushResize()
    }
  }

  /// The renderer's first layout, at this grid.
  ///
  /// SwiftTerm reports a size only when it differs from its own default grid, so a view that
  /// lands on exactly 80x25 reports nothing, and a feed holding an attach for a size would
  /// wait out its deadline. A feed that is not waiting ignores this.
  public func firstGridMeasured(_ size: TerminalSize) {
    guard feed.awaitsFirstSize, reportedSize == nil else { return }
    resize(to: size)
  }

  /// The newest size the renderer reported, whether or not it has reached the far side.
  ///
  /// A reattach can restate it without waiting for a layout pass.
  public var reportedSize: TerminalSize? { pendingSize ?? lastSentSize }

  private func flushResize() {
    resizeFlush = nil
    if case .closed = state { pendingSize = nil; return }
    if case .failed = state { pendingSize = nil; return }
    guard let size = pendingSize, size != lastSentSize else {
      pendingSize = nil
      return
    }
    pendingSize = nil
    lastSentSize = size
    outbox.yield { [feed] in
      try? await feed.resize(size)
    }
  }

  /// Whether every write queued before `close()` has reached the far side, waiting at most
  /// `limit` for it.
  ///
  /// The scene writes `terminal.release` itself after `close()`. Without this wait, a
  /// write still queued here lands after the release and is dropped. Bounded, so a write
  /// stuck on a dead link cannot hold herdr's attach token and lock the user's pane.
  ///
  /// Returns `false` at once unless the session is closed or failed. Only `close()`
  /// finishes the queue, so an unclosed failed session waits the full `limit`.
  @discardableResult
  public func pendingWritesSent(
    within limit: Duration = TerminalSession.defaultWriteDrainLimit
  ) async -> Bool {
    guard state == .closed || isFailed else { return false }
    let drain = drain
    return await withCheckedContinuation { continuation in
      let race = WriteDrainRace(continuation)
      Task { @MainActor in
        await drain.value
        race.settle(true)
      }
      race.deadline = Task { @MainActor in
        try? await Task.sleep(for: limit)
        guard !Task.isCancelled else { return }
        race.settle(false)
      }
    }
  }

  private var isFailed: Bool {
    if case .failed = state { return true }
    return false
  }

  /// Ends the session from this side.
  public func close() {
    pump?.cancel()
    pump = nil
    resizeFlush?.cancel()
    resizeFlush = nil
    pendingSize = nil
    scrollGateGeneration += 1
    unsentScrollRows = 0
    inFlightScrollRows = 0
    scrollAwaitingFrame = false
    sink = nil
    if case .failed = state {} else { state = .closed }
    // Queued behind any input already sent, so that input still goes out.
    outbox.yield { [feed] in await feed.close() }
    outbox.finish()
  }

  /// Records a title the emulator parsed out of the stream.
  public func setTitle(_ title: String) {
    self.title = title
  }

  private func deliver(_ chunk: Data) {
    let bytes = [UInt8](chunk)
    guard !bytes.isEmpty else { return }
    if let sink {
      sink(bytes[...])
      feed.consumed?(bytes.count)
    } else {
      pending.append(contentsOf: bytes)
    }
    // Any chunk answers the scroll in flight. See `scroll(_:lines:)`.
    if scrollAwaitingFrame { openScrollGate(answered: true) }
  }

  private func finish(with error: (any Error)?) {
    switch error {
    case nil:
      state = .closed
    case let appError as AppError:
      state = .failed(appError)
    case .some(let other) where other is CancellationError:
      // `close()` cancelled the pump; it has already set the state.
      break
    case .some:
      state = .failed(.channelFailed(reason: "The terminal session ended unexpectedly."))
    }
  }
  /// Whether this session's history lives somewhere else.
  ///
  /// True for a herdr pane, false for a pty. See `TerminalFeed.scroll`.
  public var scrollsRemotely: Bool { feed.scroll != nil }

  /// Asks the far side to scroll, if that is where the history is.
  ///
  /// A no-op for a pty, whose scroll view has already scrolled.
  ///
  /// **Paced.** Every herdr scroll frame is a full-screen repaint of about 2.6 KB, however
  /// many rows it moved, so one-row commands overdrive the link and the drag stutters.
  /// One scroll is in flight at a time. Rows the finger covers meanwhile are banked and
  /// sent as one command when the frame lands. Rows are merged, never dropped.
  public func scroll(_ direction: ScrollDirection, lines: Int) {
    guard feed.scroll != nil, lines > 0 else { return }
    switch state {
    case .closed, .failed: return
    case .idle, .running: break
    }
    unsentScrollRows += direction == .up ? lines : -lines
    flushScroll()
  }

  private func flushScroll() {
    guard !scrollAwaitingFrame, unsentScrollRows != 0, let scroll = feed.scroll else {
      return
    }
    let rows = unsentScrollRows
    unsentScrollRows = 0
    scrollAwaitingFrame = true
    inFlightScrollRows = rows

    scrollGateGeneration += 1
    let generation = scrollGateGeneration
    scrollPacingScheduler(scrollPacingTimeout) { [weak self] in
      self?.scrollPacingTimedOut(generation: generation)
    }

    let direction: ScrollDirection = rows > 0 ? .up : .down
    let magnitude = abs(rows)
    outbox.yield { try? await scroll(direction, magnitude) }
  }

  /// A pacing timeout firing. Acts only if nothing reopened the gate since. See
  /// `scrollGateGeneration`.
  private func scrollPacingTimedOut(generation: Int) {
    guard generation == scrollGateGeneration else { return }
    openScrollGate(answered: false)
  }

  /// Lets the next scroll through, and sends it if the finger banked any rows meanwhile.
  ///
  /// - Parameter answered: whether a frame arrived, rather than the timeout. Only an
  ///   answered scroll counts toward `scrolledRows`, because an unanswered one moved
  ///   nothing.
  private func openScrollGate(answered: Bool) {
    scrollGateGeneration += 1
    scrollAwaitingFrame = false
    if answered {
      scrolledRows = max(0, scrolledRows + inFlightScrollRows)
    }
    inFlightScrollRows = 0
    flushScroll()
  }

  /// Whether a tap's click goes to the far side as a cell. True for a herdr pane. See
  /// `TerminalFeed.click`.
  public var clicksRemotely: Bool { feed.click != nil }

  /// Sends a left click at a 0-based cell to the far side, if it takes one.
  ///
  /// A no-op after the session ends, and for a pty, whose click the view encodes with
  /// `TerminalMouseClick`.
  public func click(column: Int, row: Int) {
    guard let click = feed.click else { return }
    switch state {
    case .closed, .failed: return
    case .idle, .running: break
    }
    let cell = TerminalCell(column: column, row: row)
    outbox.yield { try? await click(cell) }
  }

  /// Leaves the pane as the desk found it: one scroll down of the rows the phone scrolled
  /// up, then forgets them. A no-op at zero and for a pty. The scene calls it before
  /// switching away.
  ///
  /// **`async`, unlike the other sends.** The caller releases the controller right after,
  /// and a scroll that lands after the release reaches nobody, leaving the desk scrolled.
  /// It still goes through `outbox`, so a queued scroll-up cannot land after it. It can
  /// wait behind a slow write, and the scene's step deadline bounds that.
  public func scrollToBottom() async {
    switch state {
    case .closed, .failed: return
    case .idle, .running: break
    }
    guard scrolledRows > 0, let scroll = feed.scroll else { return }
    let rows = scrolledRows
    scrolledRows = 0
    await withCheckedContinuation { (sent: CheckedContinuation<Void, Never>) in
      let queued = outbox.yield {
        try? await scroll(.down, rows)
        sent.resume()
      }
      // A finished queue drops the write without running it, and nobody else would resume.
      if case .terminated = queued { sent.resume() }
    }
  }

  /// Puts the phone back near where it left off with one scroll up of `rows`, from
  /// `WarmPaneSet.scrolledRows(for:)`. A no-op at zero and for a pty.
  public func restoreScroll(rows: Int) {
    switch state {
    case .closed, .failed: return
    case .idle, .running: break
    }
    guard rows > 0, let scroll = feed.scroll else { return }
    scrolledRows = rows
    outbox.yield { try? await scroll(.up, rows) }
  }
}

/// Whichever of the write queue draining and its limit comes first, resolved exactly once.
///
/// The same shape as `TerminalSceneModel`'s `StepRace`.
@MainActor
private final class WriteDrainRace {
  private var continuation: CheckedContinuation<Bool, Never>?
  var deadline: Task<Void, Never>?

  init(_ continuation: CheckedContinuation<Bool, Never>) {
    self.continuation = continuation
  }

  func settle(_ drained: Bool) {
    guard let continuation else { return }
    self.continuation = nil
    deadline?.cancel()
    continuation.resume(returning: drained)
  }
}
