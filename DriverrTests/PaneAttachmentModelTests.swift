import DriverrCore
import Foundation
import Testing
import UIKit

@testable import Driverr

/// The composer's pending attachment, driven against a fake uploader. The type is `@MainActor`
/// and lives in the app target, so it is tested here rather than in `DriverrKit`.
///
/// The bytes are a real PNG built in-process. `PaneAttachmentModel` runs its payload through
/// `ImageDownscale`, so arbitrary bytes would take the unreadable branch every time.
@MainActor
@Suite struct PaneAttachmentModelTests {
  /// An uploader the test drives by hand: it reports the progress it is told to, then either
  /// finishes or throws, and it can be held open until the test releases it.
  private final class StubUpload: ImageUploading, @unchecked Sendable {
    let progress: AsyncStream<ImageUploadProgress>
    private let signal: AsyncStream<ImageUploadProgress>.Continuation
    private let outcome: Result<ImageUploadOutcome, any Error>
    /// Held open so a test can cancel while the upload is still in flight.
    private let holdsOpen: Bool
    /// Set by `upload()` when it is cancelled, proving the cancel reached it and not only the
    /// model.
    private(set) var wasCancelled = false

    init(outcome: Result<ImageUploadOutcome, any Error>, holdsOpen: Bool = false) {
      self.outcome = outcome
      self.holdsOpen = holdsOpen
      let (stream, continuation) = AsyncStream.makeStream(of: ImageUploadProgress.self)
      progress = stream
      signal = continuation
    }

    func upload() async throws -> ImageUploadOutcome {
      signal.yield(ImageUploadProgress(bytesSent: 10, totalBytes: 100))
      if holdsOpen {
        do {
          // Long enough that nothing finishes on its own; every test that uses this cancels.
          try await Task.sleep(for: .seconds(30))
        } catch {
          wasCancelled = true
          signal.finish()
          throw CancellationError()
        }
      }
      signal.finish()
      return try outcome.get()
    }
  }

  /// A real PNG, small, so the downscale succeeds and leaves the pixel size alone.
  ///
  /// Rendered rather than committed, because a file in the bundle is a change to
  /// `project.pbxproj`, which parallel branches collide on.
  private func pngBytes() throws -> Data {
    let size = CGSize(width: 40, height: 30)
    let image = UIGraphicsImageRenderer(size: size).image { context in
      UIColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1).setFill()
      context.fill(CGRect(origin: .zero, size: size))
    }
    return try #require(image.pngData())
  }

  /// A hand-off held open until the test lets it go.
  ///
  /// `.uploaded` is a phase in passing: the hand-off runs the moment the bytes land, so the row
  /// is `.handedOver` before a poll sees anything else. Holding the hand-off keeps the upload's
  /// own outcome on the row long enough to read.
  ///
  /// A gate rather than a long sleep, so cleanup is `release()`, not a side effect of
  /// `remove()`. It suspends rather than blocking; see `CLAUDE.md` on the cooperative pool.
  private final class HandOffGate: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let open: AsyncStream<Void>.Continuation

    init() {
      (stream, open) = AsyncStream.makeStream(of: Void.self)
    }

    func hold() async {
      for await _ in stream { break }
    }

    func release() {
      open.yield(())
      open.finish()
    }
  }

  /// Waits for `condition` on the main actor, so a test never sleeps a fixed interval for an
  /// asynchronous phase change.
  private func waitFor(
    _ description: String,
    until condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    for _ in 0..<600 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for \(description).", sourceLocation: sourceLocation)
  }

  @Test func anAttachedImageIsPreparedAndThenUploaded() async throws {
    let landed = ImageUploadOutcome(hostPath: "/home/c/.driverr/inbox/a.png", bytesSent: 100)
    let gate = HandOffGate()
    let model = PaneAttachmentModel(
      makeUpload: { _, _ in StubUpload(outcome: .success(landed)) },
      handOff: { _ in await gate.hold() }
    )

    #expect(model.phase == nil)
    #expect(!model.isAttached)

    model.attach(try pngBytes())
    await waitFor("the upload to land") { model.phase?.hostPath != nil }

    #expect(model.phase == .uploaded(hostPath: "/home/c/.driverr/inbox/a.png"))
    #expect(model.isAttached)
    #expect(model.byteCount > 0)
    #expect(model.thumbnail != nil)

    gate.release()
  }

  /// The host path is on the phase, and it drives the hand-off.
  ///
  /// Read with the hand-off held, because on the ordinary path that phase is gone in the turn
  /// it arrives. `theFinishedPathIsHandedOverOnceAndUnchanged` is the other end.
  @Test func theFinishedHostPathIsReadableFromThePhase() async throws {
    let landed = ImageUploadOutcome(hostPath: "/var/tmp/x.png", bytesSent: 1)
    let gate = HandOffGate()
    let model = PaneAttachmentModel(
      makeUpload: { _, _ in StubUpload(outcome: .success(landed)) },
      handOff: { _ in await gate.hold() }
    )

    model.attach(try pngBytes())
    await waitFor("the upload to land") { model.phase?.hostPath != nil }

    #expect(model.phase?.hostPath == "/var/tmp/x.png")

    gate.release()
  }

  /// A failure from the uploader becomes the sentence for that case, not a debugger's
  /// description of an error value.
  @Test func anUploadFailureBecomesItsOwnSentence() async throws {
    let refused = ImageUploadFailure.commandFailed(exitStatus: 1, standardError: "No space")
    let model = PaneAttachmentModel(
      makeUpload: { _, _ in StubUpload(outcome: .failure(refused)) })

    model.attach(try pngBytes())
    await waitFor("the failure") {
      if case .failed = model.phase { return true }
      return false
    }

    #expect(model.phase == .failed(PaneAttachmentFailureCopy.sentence(for: refused)))
    // Still staged, so Remove is still the way out.
    #expect(model.isAttached)
  }

  /// No uploader means the link went while the picker was up, which gets a sentence.
  @Test func noLinkIsReportedRatherThanIgnored() async throws {
    let model = PaneAttachmentModel(makeUpload: { _, _ in nil })

    model.attach(try pngBytes())
    await waitFor("the failure") {
      if case .failed = model.phase { return true }
      return false
    }

    if case .failed(let sentence) = model.phase {
      #expect(!sentence.isEmpty)
    } else {
      Issue.record("Expected a failure phase.")
    }
  }

  /// Bytes that are not an image never reach an uploader at all.
  @Test func unreadableBytesFailBeforeAnythingIsSent() async {
    let built = Mutex(false)
    let model = PaneAttachmentModel(makeUpload: { _, _ in
      built.set(true)
      return StubUpload(outcome: .failure(ImageUploadFailure.noHostPath))
    })

    model.attach(Data("not a photograph".utf8))
    await waitFor("the failure") {
      if case .failed = model.phase { return true }
      return false
    }

    #expect(model.phase == .failed(PaneAttachmentFailureCopy.unreadable))
    #expect(!built.get())
  }

  /// Remove cancels the upload in flight. The row clearing and the transfer stopping are two
  /// things, and the generation guard delivers the first either way.
  @Test func removeCancelsAnUploadInFlight() async throws {
    let upload = StubUpload(
      outcome: .success(ImageUploadOutcome(hostPath: "/x.png", bytesSent: 1)),
      holdsOpen: true
    )
    let model = PaneAttachmentModel(makeUpload: { _, _ in upload })

    model.attach(try pngBytes())
    await waitFor("the upload to start") { model.phase?.isUploading == true }

    model.remove()

    #expect(model.phase == nil)
    #expect(!model.isAttached)
    #expect(model.thumbnail == nil)
    #expect(model.byteCount == 0)
    await waitFor("the uploader to see the cancel") { upload.wasCancelled }
    #expect(upload.wasCancelled)
  }

  /// A cancelled upload writes no failure onto the row, through the generation guard and the
  /// `catch is CancellationError` beside it.
  @Test func removingLeavesNoFailureBehind() async throws {
    let upload = StubUpload(
      outcome: .failure(ImageUploadFailure.noHostPath), holdsOpen: true)
    let model = PaneAttachmentModel(makeUpload: { _, _ in upload })

    model.attach(try pngBytes())
    await waitFor("the upload to start") { model.phase?.isUploading == true }
    model.remove()
    await waitFor("the uploader to see the cancel") { upload.wasCancelled }

    // Given time for a late write to land, the row is still empty.
    try? await Task.sleep(for: .milliseconds(100))
    #expect(model.phase == nil)
  }

  /// A second pick replaces the first, and the abandoned run cannot write over the new one's
  /// phase afterwards.
  @Test func asecondPickReplacesTheFirstAndTheAbandonedRunGoesQuiet() async throws {
    let first = StubUpload(
      outcome: .success(ImageUploadOutcome(hostPath: "/first.png", bytesSent: 1)),
      holdsOpen: true
    )
    let second = ImageUploadOutcome(hostPath: "/second.png", bytesSent: 1)
    let uploads = Mutex(0)
    let handed = Mutex<[String]>([])
    let model = PaneAttachmentModel(
      makeUpload: { _, _ in
        let count = uploads.increment()
        return count == 1 ? first : StubUpload(outcome: .success(second))
      },
      handOff: { handed.append($0) }
    )

    model.attach(try pngBytes())
    await waitFor("the first upload to start") { model.phase?.isUploading == true }

    model.attach(try pngBytes())
    await waitFor("the second upload to finish") { model.phase == .handedOver }
    await waitFor("the first uploader to see the cancel") { first.wasCancelled }

    // The abandoned run has written nothing, and the pane was told about the second image
    // only. Read off what was handed over, because `.uploaded` does not stay on the row.
    try? await Task.sleep(for: .milliseconds(100))
    #expect(model.phase == .handedOver)
    #expect(handed.get() == ["/second.png"])
  }

  // MARK: - The hand-off

  /// The path reaches the seam once, exactly as the host reported it.
  ///
  /// Once, because it is driven off a phase transition, not an observed property; a second call
  /// would type the path twice. Exactly, because a path with anything appended is not on the
  /// host, which is why this is `sendText` rather than `submitText`.
  @Test func theFinishedPathIsHandedOverOnceAndUnchanged() async throws {
    let path = "/home/c/.driverr/inbox/8f1c.png"
    let handed = Mutex<[String]>([])
    let model = PaneAttachmentModel(
      makeUpload: { _, _ in
        StubUpload(outcome: .success(ImageUploadOutcome(hostPath: path, bytesSent: 100)))
      },
      handOff: { handed.append($0) }
    )

    model.attach(try pngBytes())
    await waitFor("the hand-off") { model.phase == .handedOver }

    #expect(handed.get() == [path])
    // Given time for a second call, there is still one.
    try? await Task.sleep(for: .milliseconds(100))
    #expect(handed.get().count == 1)
    // The row stays, saying what happened. Only a reply or Remove takes it away.
    #expect(model.isAttached)
  }

  /// Remove means nothing is typed into the pane, a stronger claim than the row clearing. The
  /// generation check in `handOver` stops a late path.
  @Test func removingBeforeTheUploadLandsHandsNothingOver() async throws {
    let upload = StubUpload(
      outcome: .success(ImageUploadOutcome(hostPath: "/x.png", bytesSent: 1)),
      holdsOpen: true
    )
    let handed = Mutex<[String]>([])
    let model = PaneAttachmentModel(
      makeUpload: { _, _ in upload },
      handOff: { handed.append($0) }
    )

    model.attach(try pngBytes())
    await waitFor("the upload to start") { model.phase?.isUploading == true }
    model.remove()
    await waitFor("the uploader to see the cancel") { upload.wasCancelled }

    // Given time for a late hand-off to land, nothing was sent and the row is still empty.
    try? await Task.sleep(for: .milliseconds(100))
    #expect(handed.get().isEmpty)
    #expect(model.phase == nil)
  }

  /// A hand-off that throws says the host kept the image. Every other failure on this row means
  /// the upload did not land, and a reader told that would pick the photograph again.
  @Test func aHandOffThatThrowsSaysTheImageIsAlreadyThere() async throws {
    struct NoLink: Error {}
    let model = PaneAttachmentModel(
      makeUpload: { _, _ in
        StubUpload(outcome: .success(ImageUploadOutcome(hostPath: "/x.png", bytesSent: 1)))
      },
      handOff: { _ in throw NoLink() }
    )

    model.attach(try pngBytes())
    await waitFor("the failure") {
      if case .failed = model.phase { return true }
      return false
    }

    #expect(model.phase == .failed(PaneAttachmentFailureCopy.handOffFailed))
    // Still staged, so Remove is still the way out.
    #expect(model.isAttached)
  }

  /// An upload that fails never reaches the seam. There is no path to hand over.
  @Test func anUploadThatFailsHandsNothingOver() async throws {
    let handed = Mutex<[String]>([])
    let model = PaneAttachmentModel(
      makeUpload: { _, _ in
        StubUpload(outcome: .failure(ImageUploadFailure.noHostPath))
      },
      handOff: { handed.append($0) }
    )

    model.attach(try pngBytes())
    await waitFor("the failure") {
      if case .failed = model.phase { return true }
      return false
    }

    try? await Task.sleep(for: .milliseconds(100))
    #expect(handed.get().isEmpty)
  }
}

/// A tiny lock, because the `makeUpload` closure is `@MainActor` but the counters it touches
/// are read from the test body between awaits.
private final class Mutex<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) { self.value = value }

  func get() -> Value { lock.withLock { value } }
  func set(_ new: Value) { lock.withLock { value = new } }
}

extension Mutex where Value == [String] {
  func append(_ new: String) {
    lock.withLock { value.append(new) }
  }
}

extension Mutex where Value == Int {
  func increment() -> Int {
    lock.withLock {
      value += 1
      return value
    }
  }
}
