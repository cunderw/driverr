import DriverrCore
import Foundation

/// A viewer that attaches once it knows the size to attach at.
///
/// A core attach takes the terminal's size at once, and paints its history at that width, so
/// attaching at a guess reflows the desk twice and leaves the history at the wrong width. Only
/// a laid-out terminal view knows the size, a view needs a session and a session needs a feed,
/// so the feed is built over this, and **the first `resize(to:)` is the attach**. That is
/// `TerminalSession`'s first flush, after the keyboard has settled, so one open is one size.
///
/// Input and focus that arrive first are held and go out behind the attach, up to
/// `heldInputLimit`.
///
/// **Bounded.** A view that reports no size, or an attach that fails, ends `output` with
/// `.neverAttached`, because nothing else would ever say so.
public final class DeferredPaneBridge: PaneBridge, RawTerminalStream, @unchecked Sendable {
  public typealias Attach = @Sendable (TerminalSize) async throws -> any PaneBridge

  private enum State {
    case waitingForSize
    case attaching
    case attached(any PaneBridge)
    case over
  }

  /// Long enough for a view's first layout and `TerminalSession`'s settling window on a busy
  /// main thread, and short of `TerminalSceneModel.defaultStepDeadline`.
  public static let defaultSizeDeadline: Duration = .seconds(8)
  /// How much typed input is held for an attach that has not happened.
  ///
  /// Typing fits many times over, and so does an ordinary paste. Past it a write is dropped
  /// whole, not split, so what the program gets never ends partway through a keystroke.
  static let heldInputLimit = 64 * 1024

  public let output: AsyncThrowingStream<Data, any Error>

  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let attach: Attach
  private let lock = NSLock()
  private var state = State.waitingForSize
  private var heldInput = Data()
  private var heldFocus: Bool?
  private var deadline: Task<Void, Never>?

  public init(
    sizeDeadline: Duration = DeferredPaneBridge.defaultSizeDeadline,
    attach: @escaping Attach
  ) {
    self.attach = attach
    (output, continuation) = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self
    )
    deadline = Task { [weak self] in
      try? await Task.sleep(for: sizeDeadline)
      guard !Task.isCancelled else { return }
      self?.sizeNeverCame()
    }
  }

  public func resize(to size: TerminalSize) async throws {
    let (isFirst, bridge): (Bool, (any PaneBridge)?) = lock.withLock {
      guard case .waitingForSize = state else { return (false, attached) }
      state = .attaching
      return (true, nil)
    }
    if isFirst {
      deadline?.cancel()
      await open(at: size)
    } else {
      try await bridge?.resize(to: size)
    }
  }

  private func open(at size: TerminalSize) async {
    let bridge: any PaneBridge
    do {
      bridge = try await attach(size)
    } catch {
      lock.withLock { state = .over }
      finishUnattached()
      return
    }

    // Taken with the state change, so a keystroke is held or sent, never both.
    let held: (input: Data, focus: Bool?)? = lock.withLock {
      guard case .attaching = state else { return nil }
      state = .attached(bridge)
      defer {
        heldInput = Data()
        heldFocus = nil
      }
      return (heldInput, heldFocus)
    }
    guard let held else {
      // Released while the attach was on its way.
      await bridge.release()
      return
    }

    forward(bridge.output)
    if !held.input.isEmpty { try? await bridge.send(bytes: held.input) }
    if let focus = held.focus { try? await (bridge as? any RawTerminalStream)?.focus(focus) }
  }

  private func forward(_ source: AsyncThrowingStream<Data, any Error>) {
    Task { [continuation] in
      do {
        for try await chunk in source { continuation.yield(chunk) }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
  }

  private func sizeNeverCame() {
    let expired: Bool = lock.withLock {
      guard case .waitingForSize = state else { return false }
      state = .over
      return true
    }
    if expired { finishUnattached() }
  }

  private func finishUnattached() {
    continuation.finish(throwing: TerminalCloseReason.neverAttached)
  }

  /// How much input is waiting, so a test can see what was kept.
  var heldByteCount: Int { lock.withLock { heldInput.count } }

  private var isHolding: Bool {
    switch state {
    case .waitingForSize, .attaching: true
    case .attached, .over: false
    }
  }

  private var attached: (any PaneBridge)? {
    guard case .attached(let bridge) = state else { return nil }
    return bridge
  }

  public func send(text: String) async throws {
    try await send(bytes: Data(text.utf8))
  }

  public func send(bytes: Data) async throws {
    let bridge: (any PaneBridge)? = lock.withLock {
      if isHolding, heldInput.count + bytes.count <= Self.heldInputLimit {
        heldInput.append(bytes)
      }
      return attached
    }
    try await bridge?.send(bytes: bytes)
  }

  public func focus(_ gained: Bool) async throws {
    let bridge: (any PaneBridge)? = lock.withLock {
      if isHolding { heldFocus = gained }
      return attached
    }
    try await (bridge as? any RawTerminalStream)?.focus(gained)
  }

  public func consumed(_ bytes: Int) {
    let bridge = lock.withLock { attached }
    (bridge as? any RawTerminalStream)?.consumed(bytes)
  }

  public func leftAlternateScreen() {
    let bridge = lock.withLock { attached }
    (bridge as? any RawTerminalStream)?.leftAlternateScreen()
  }

  /// A deferred pane is a raw stream, whose scrollback and clicks are local.
  public func scroll(_ direction: ScrollDirection, lines: Int) async throws {}
  public func click(_ cell: TerminalCell) async throws {}

  public func release() async {
    let bridge: (any PaneBridge)? = lock.withLock {
      defer { state = .over }
      return attached
    }
    deadline?.cancel()
    await bridge?.release()
    continuation.finish()
  }
}
