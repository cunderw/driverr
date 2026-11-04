import Foundation

/// One image upload, as everything above `DriverrSSH` sees it.
///
/// `DriverrSSH.ImageUploader` puts an image in the SSH host's inbox. A pane on a machine a
/// herdr-core added gets the core's `terminal.put` instead, through
/// `HerdrControl.imageUploader(forPane:bytes:fileName:)`. The protocol also lets the composer
/// take a paced fake under `-uiTestingSlowUpload`: an instant upload cannot show progress or
/// be captured mid-flight.
///
/// `progress` is a property, so it is subscribed before `upload()` runs. An `AsyncStream`
/// created inside the call that feeds it would lose its first events.
public protocol ImageUploading: Sendable {
  /// Bytes sent over bytes to send. Finishes when the upload does, including on failure, so
  /// a `for await` always ends.
  var progress: AsyncStream<ImageUploadProgress> { get }

  /// Runs the upload and returns where the bytes landed on the host.
  ///
  /// - Throws: ``ImageUploadFailure`` for anything with a sentence to say about it, and an
  ///   `AppError` if the channel could not be opened at all.
  @discardableResult
  func upload() async throws -> ImageUploadOutcome
}

/// An upload that fails as soon as it is run, with `error`.
///
/// For a refusal known before anything is sent. A `nil` uploader reads as a link that is
/// down, so a refusal has to be an upload that throws.
public struct RefusedImageUpload: ImageUploading {
  public let progress: AsyncStream<ImageUploadProgress>
  private let error: any Error & Sendable

  public init(_ error: any Error & Sendable) {
    self.error = error
    // Finished at once, so a watcher's `for await` ends.
    progress = AsyncStream { $0.finish() }
  }

  public func upload() async throws -> ImageUploadOutcome {
    throw error
  }
}
