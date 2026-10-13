import DriverrCore
import Foundation
import Observation
import UIKit

/// The one image a pane's composer holds, from Photos until the host has it.
///
/// One at a time, per pane. `PaneComposerModel` holds it and is cached per pane
/// (`PaneComposerCache`), so an attachment survives a switch to the Terminal surface, as a
/// half-typed reply does.
///
/// The pane is reached through one closure. The upload puts bytes in the host's inbox, and
/// `handOff` types the returned path into the pane with no newline, so a question can follow.
///
/// The downscale runs detached. This type is `@MainActor`, so a plain `Task` would decode a
/// 12 megapixel HEIC on the thread drawing the composer.
@MainActor
@Observable
final class PaneAttachmentModel {
  /// Where the pending attachment has got to, or `nil` when there is none. `nil` rather than
  /// a `.none` case, so "is there a row" is one optional check.
  private(set) var phase: PaneAttachmentPhase?

  /// What the row draws. Built from the prepared bytes, so it shows what is sent.
  private(set) var thumbnail: UIImage?

  /// The prepared PNG's size, which is what the row reports and what the host will receive.
  private(set) var byteCount = 0

  /// Whether there is anything to show.
  var isAttached: Bool { phase != nil }

  /// Builds the upload for a payload and a file name, or `nil` when the link is down.
  ///
  /// A closure, like `PaneComposerModel.control`, because the link can go while the composer
  /// is on screen and a captured coordinator would outlive it.
  @ObservationIgnored private let makeUpload: @MainActor (Data, String) -> (any ImageUploading)?

  /// Hands the finished host path to the pane.
  ///
  /// Takes only the path, so this type never learns what a pane is and tests need no herdr.
  /// A throw is a real outcome: the bytes are already on the host, so the failure says so.
  /// See `PaneAttachmentFailureCopy.handOffFailed`.
  @ObservationIgnored private let handOff: @MainActor (String) async throws -> Void

  /// The prepare-and-upload run, kept so Remove can cancel it.
  @ObservationIgnored private var work: Task<Void, Never>?

  /// Bumped on every attach and remove, so events from an abandoned run cannot overwrite a
  /// newer phase. `Task.cancel()` does not stop a continuation already resumed, so a
  /// progress event in flight at Remove still lands afterwards.
  @ObservationIgnored private var generation = 0

  /// The file's name on the host: a fresh UUID, because the inbox is shared and
  /// `IMG_0042.png` from two phones would be one file.
  @ObservationIgnored private let makeFileName: @Sendable () -> String

  init(
    makeUpload: @escaping @MainActor (Data, String) -> (any ImageUploading)?,
    handOff: @escaping @MainActor (String) async throws -> Void = { _ in },
    makeFileName: @escaping @Sendable () -> String = {
      UUID().uuidString.lowercased() + ".png"
    }
  ) {
    self.makeUpload = makeUpload
    self.handOff = handOff
    self.makeFileName = makeFileName
  }

  /// Takes the bytes Photos handed over, prepares them, and starts the upload.
  ///
  /// Replaces whatever was staged and cancels its upload. A second pick is a change of mind.
  func attach(_ picked: Data) {
    cancelWork()
    generation += 1
    let run = generation
    phase = .preparing
    thumbnail = nil
    byteCount = 0

    work = Task { [weak self] in
      // Detached, or the decode would run on the main actor.
      let prepared = await Task.detached(priority: .userInitiated) {
        ImageDownscale.png(from: picked)
      }.value
      guard let self, !Task.isCancelled else { return }
      guard let prepared else {
        self.settle(run, .failed(PaneAttachmentFailureCopy.unreadable))
        return
      }
      guard self.generation == run else { return }
      self.thumbnail = UIImage(data: prepared)
      self.byteCount = prepared.count
      // Prepared, and nothing on the wire yet. `send` still has to get an uploader, which is
      // `nil` when the link is down.
      self.phase = .ready
      await self.send(prepared, run: run)
    }
  }

  /// Discards the pending image, cancelling an upload in flight.
  ///
  /// Nothing is kept for an undo, because nothing on screen could offer one.
  func remove() {
    cancelWork()
    generation += 1
    phase = nil
    thumbnail = nil
    byteCount = 0
  }

  private func send(_ bytes: Data, run: Int) async {
    guard let uploader = makeUpload(bytes, makeFileName()) else {
      settle(run, .failed(PaneAttachmentFailureCopy.sentence(for: AppError.notConnected(host: "this host"))))
      return
    }

    phase = .uploading(ImageUploadProgress(bytesSent: 0, totalBytes: bytes.count))

    // Watched on its own task, because a `for await` after `upload()` would read a finished
    // stream. It ends when the uploader finishes the stream.
    let watch = Task { [weak self] in
      for await progress in uploader.progress {
        guard let self, !Task.isCancelled else { return }
        // Only while this run is still uploading. A late event must not redraw the row.
        guard self.generation == run, self.phase?.isUploading == true else { continue }
        self.phase = .uploading(progress)
      }
    }

    do {
      let outcome = try await uploader.upload()
      watch.cancel()
      settle(run, .uploaded(hostPath: outcome.hostPath))
      await handOver(outcome.hostPath, run: run)
    } catch is CancellationError {
      // A cancellation is Remove, not a failure, and gets no message. The generation guard
      // in `settle` would discard it anyway.
      watch.cancel()
    } catch {
      watch.cancel()
      settle(run, .failed(PaneAttachmentFailureCopy.sentence(for: error)))
    }
  }

  /// Types the path into the pane, and records which of the two things happened.
  ///
  /// Nothing is handed over for a stale run, so a path cannot appear in the prompt after
  /// Remove. `settle` guards the phase write too. A cancellation writes nothing.
  private func handOver(_ path: String, run: Int) async {
    guard generation == run else { return }
    do {
      try await handOff(path)
    } catch is CancellationError {
      return
    } catch {
      // Not the error's own text: what matters is that the image is already on the host, so
      // picking it again sends it twice.
      settle(run, .failed(PaneAttachmentFailureCopy.handOffFailed))
      return
    }
    settle(run, .handedOver)
  }

  /// Writes a terminal phase, but only if this run is still the current one.
  private func settle(_ run: Int, _ phase: PaneAttachmentPhase) {
    guard generation == run else { return }
    self.phase = phase
  }

  private func cancelWork() {
    work?.cancel()
    work = nil
  }
}
