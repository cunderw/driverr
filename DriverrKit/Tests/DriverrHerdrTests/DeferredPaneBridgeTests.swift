import DriverrCore
import Foundation
import Testing

@testable import DriverrHerdr

/// What the far side of a deferred attach saw, in order.
private final class FarSide: PaneBridge, RawTerminalStream, @unchecked Sendable {
  let output: AsyncThrowingStream<Data, any Error>
  let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let lock = NSLock()
  private var heard: [String] = []
  private var consumedBytes = 0

  init() {
    (output, continuation) = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self
    )
  }

  var log: [String] { lock.withLock { heard } }
  var consumedByteCount: Int { lock.withLock { consumedBytes } }

  private func note(_ line: String) { lock.withLock { heard.append(line) } }

  func send(text: String) async throws { note("text \(text)") }
  func send(bytes: Data) async throws { note("bytes \(String(decoding: bytes, as: UTF8.self))") }
  func resize(to size: TerminalSize) async throws { note("resize \(size.columns)x\(size.rows)") }
  func scroll(_ direction: ScrollDirection, lines: Int) async throws {}
  func click(_ cell: TerminalCell) async throws {}
  func focus(_ gained: Bool) async throws { note("focus \(gained)") }
  func consumed(_ bytes: Int) { lock.withLock { consumedBytes += bytes } }
  func release() async {
    note("release")
    continuation.finish()
  }
}

/// Hands out one `FarSide`, or refuses, and records the size each attach asked for.
private final class Attacher: @unchecked Sendable {
  let far = FarSide()
  private let lock = NSLock()
  private var sizes: [TerminalSize] = []
  private let gate: AsyncStream<Void>?
  private let refusal: AppError?

  init(refusal: AppError? = nil, gate: AsyncStream<Void>? = nil) {
    self.refusal = refusal
    self.gate = gate
  }

  var attached: [TerminalSize] { lock.withLock { sizes } }

  func attach(_ size: TerminalSize) async throws -> any PaneBridge {
    lock.withLock { sizes.append(size) }
    if let gate { for await _ in gate { break } }
    if let refusal { throw refusal }
    return far
  }
}

@Suite("Deferred pane bridge", .timeLimit(.minutes(1)))
struct DeferredPaneBridgeTests {
  private let measured = TerminalSize(columns: 52, rows: 48)

  private func bridge(_ attacher: Attacher, deadline: Duration = .seconds(30)) -> DeferredPaneBridge {
    DeferredPaneBridge(sizeDeadline: deadline) { try await attacher.attach($0) }
  }

  private func ending(of bridge: DeferredPaneBridge) async -> (any Error)? {
    do {
      for try await _ in bridge.output {}
      return nil
    } catch {
      return error
    }
  }

  @Test("nothing attaches until a size comes, and the first one is the attach")
  func firstResizeAttaches() async throws {
    let attacher = Attacher()
    let bridge = bridge(attacher)

    #expect(attacher.attached.isEmpty)
    try await bridge.resize(to: measured)

    #expect(attacher.attached == [measured])
    #expect(attacher.far.log.isEmpty, "the attach already carried the size")
  }

  @Test("a later size is a resize, not a second attach")
  func laterResizes() async throws {
    let attacher = Attacher()
    let bridge = bridge(attacher)

    try await bridge.resize(to: measured)
    try await bridge.resize(to: TerminalSize(columns: 52, rows: 22))

    #expect(attacher.attached == [measured])
    #expect(attacher.far.log == ["resize 52x22"])
  }

  @Test("what was typed and the focus go out behind the attach, in order, once")
  func heldInput() async throws {
    let attacher = Attacher()
    let bridge = bridge(attacher)

    try await bridge.send(bytes: Data("a".utf8))
    try await bridge.send(text: "b")
    try await bridge.focus(false)
    try await bridge.focus(true)
    try await bridge.resize(to: measured)
    try await bridge.send(bytes: Data("c".utf8))

    #expect(attacher.far.log == ["bytes ab", "focus true", "bytes c"])
  }

  @Test("nothing is held once the bridge is over", arguments: [true, false])
  func nothingHeldOnceOver(released: Bool) async throws {
    let attacher = Attacher()
    let bridge = bridge(attacher, deadline: .milliseconds(1))
    if released {
      await bridge.release()
    } else {
      #expect(await ending(of: bridge) as? TerminalCloseReason == .neverAttached)
    }

    try await bridge.send(bytes: Data("late".utf8))

    #expect(bridge.heldByteCount == 0)
  }

  @Test("held input stops at the cap, at a write's edge, and what was kept still goes out")
  func heldInputCap() async throws {
    let attacher = Attacher()
    let bridge = bridge(attacher)
    let kept = Data(repeating: 0x61, count: DeferredPaneBridge.heldInputLimit - 1)

    try await bridge.send(bytes: kept)
    try await bridge.send(bytes: Data("bc".utf8))
    #expect(bridge.heldByteCount == kept.count)

    try await bridge.send(bytes: Data("d".utf8))
    try await bridge.resize(to: measured)

    #expect(attacher.far.log == ["bytes " + String(decoding: kept, as: UTF8.self) + "d"])
  }

  @Test("output, its end and credit pass through")
  func passesThrough() async throws {
    let attacher = Attacher()
    let bridge = bridge(attacher)
    try await bridge.resize(to: measured)

    attacher.far.continuation.yield(Data("paint".utf8))
    attacher.far.continuation.finish(throwing: TerminalCloseReason.lost)

    var iterator = bridge.output.makeAsyncIterator()
    #expect(try await iterator.next() == Data("paint".utf8))
    await #expect(throws: TerminalCloseReason.lost) { _ = try await iterator.next() }
    bridge.consumed(5)
    #expect(attacher.far.consumedByteCount == 5)
  }

  @Test("a clean end stays clean")
  func cleanEnd() async throws {
    let attacher = Attacher()
    let bridge = bridge(attacher)
    try await bridge.resize(to: measured)

    attacher.far.continuation.finish()

    #expect(await ending(of: bridge) == nil)
  }

  /// Without this the scene's pump waits forever, and the pane never says anything.
  @Test("no size in time ends the stream, and a size after that attaches nothing")
  func deadline() async throws {
    let attacher = Attacher()
    let bridge = bridge(attacher, deadline: .milliseconds(10))

    #expect(await ending(of: bridge) as? TerminalCloseReason == .neverAttached)

    try await bridge.resize(to: measured)
    #expect(attacher.attached.isEmpty)
  }

  @Test("a size in time stops the deadline")
  func deadlineCancelled() async throws {
    let attacher = Attacher()
    // Far longer than init to resize can take, however busy the machine.
    let bridge = bridge(attacher, deadline: .seconds(1))
    try await bridge.resize(to: measured)

    try await Task.sleep(for: .milliseconds(1100))
    attacher.far.continuation.finish()

    #expect(await ending(of: bridge) == nil)
  }

  @Test("a refused attach ends the stream the same way")
  func refused() async throws {
    let attacher = Attacher(refusal: .herdrCommandFailed(reason: "no terminal t9"))
    let bridge = bridge(attacher)

    try await bridge.resize(to: measured)

    #expect(await ending(of: bridge) as? TerminalCloseReason == .neverAttached)
  }

  @Test("released while waiting, it attaches nothing and ends quietly")
  func releasedWhileWaiting() async throws {
    let attacher = Attacher()
    let bridge = bridge(attacher)

    await bridge.release()
    try await bridge.resize(to: measured)

    #expect(attacher.attached.isEmpty)
    #expect(await ending(of: bridge) == nil)
  }

  /// The viewer exists on the far side by then, and one left open would hold the size.
  @Test("released while the attach is on its way, the new viewer is released too")
  func releasedWhileAttaching() async throws {
    let (gate, opening) = AsyncStream<Void>.makeStream()
    let attacher = Attacher(gate: gate)
    let bridge = bridge(attacher)

    async let resized: Void = bridge.resize(to: measured)
    try await waitForAttach(attacher)
    await bridge.release()
    opening.yield()
    try await resized

    #expect(attacher.far.log == ["release"])
    #expect(await ending(of: bridge) == nil)
  }

  private func waitForAttach(_ attacher: Attacher) async throws {
    while attacher.attached.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
  }

  @Test("released once attached, the viewer goes with it")
  func releasedAttached() async throws {
    let attacher = Attacher()
    let bridge = bridge(attacher)
    try await bridge.resize(to: measured)

    await bridge.release()

    #expect(attacher.far.log == ["release"])
  }
}
