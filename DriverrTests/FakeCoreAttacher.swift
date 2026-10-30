import DriverrCore
import DriverrHerdr
import Foundation

/// A herdr-core behind `PaneAttacher`, so a scene test can hold a viewer's far end.
///
/// `CoreControl` needs a framed stream to get this far, and what that stream does is
/// `DriverrHCTests`' subject. Here the subject is what the scene does with a viewer.
final class FakeCoreAttacher: PaneAttacher, @unchecked Sendable {
  private let lock = NSLock()
  private var refusals: Int
  private var opened: [FakeCoreViewer] = []
  private var requests: [String] = []

  /// - Parameter refusals: how many attaches are refused, as a core refuses one while a kept
  ///   terminal waits for its new shell.
  init(refusals: Int = 0) {
    self.refusals = refusals
  }

  /// Every attach asked for, refused ones included: `open t7`, `observe t7`.
  var log: [String] { lock.withLock { requests } }
  var viewers: [FakeCoreViewer] { lock.withLock { opened } }
  var latest: FakeCoreViewer? { viewers.last }

  func refuseNext(_ count: Int) {
    lock.withLock { refusals = count }
  }

  func open(terminalID: String, size: TerminalSize) async throws -> any PaneBridge {
    try attach("open \(terminalID)")
  }

  func observe(terminalID: String, size: TerminalSize) async throws -> any PaneObserver {
    try attach("observe \(terminalID)")
  }

  private func attach(_ request: String) throws -> FakeCoreViewer {
    defer { Waker.signalShared() }
    return try lock.withLock {
      requests.append(request)
      if refusals > 0 {
        refusals -= 1
        throw AppError.herdrCommandFailed(reason: "lost, waiting for its new shell")
      }
      let viewer = FakeCoreViewer()
      opened.append(viewer)
      return viewer
    }
  }
}

/// The far end of one attach.
final class FakeCoreViewer: PaneBridge, PaneObserver, RawTerminalStream, @unchecked Sendable {
  let output: AsyncThrowingStream<Data, any Error>
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let lock = NSLock()
  private var written = Data()
  private var sizes: [TerminalSize] = []
  private var focuses: [Bool] = []
  private var consumedBytes = 0
  private var releases = 0

  init() {
    (output, continuation) = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self
    )
  }

  var sent: Data { lock.withLock { written } }
  var resizes: [TerminalSize] { lock.withLock { sizes } }
  var focusChanges: [Bool] { lock.withLock { focuses } }
  var consumedByteCount: Int { lock.withLock { consumedBytes } }
  var releaseCount: Int { lock.withLock { releases } }

  func paint(_ text: String) {
    continuation.yield(Data(text.utf8))
  }

  /// The stream ends: cleanly for a program that finished, or with why.
  func end(_ reason: TerminalCloseReason? = nil) {
    if let reason {
      continuation.finish(throwing: reason)
    } else {
      continuation.finish()
    }
  }

  func send(text: String) async throws { try await send(bytes: Data(text.utf8)) }
  func send(bytes: Data) async throws { record { written.append(bytes) } }
  func resize(to size: TerminalSize) async throws { record { sizes.append(size) } }
  func scroll(_ direction: ScrollDirection, lines: Int) async throws {}
  func click(_ cell: TerminalCell) async throws {}
  func focus(_ gained: Bool) async throws { record { focuses.append(gained) } }
  func consumed(_ bytes: Int) { record { consumedBytes += bytes } }

  func release() async {
    record { releases += 1 }
    continuation.finish()
  }

  private func record(_ change: () -> Void) {
    lock.withLock(change)
    Waker.signalShared()
  }
}
