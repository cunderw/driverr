import Foundation

/// One image upload, as everything above `DriverrSSH` sees it.
///
/// `DriverrSSH.ImageUploader` is the only production conformance. The protocol lets the
/// composer take a paced fake under `-uiTestingSlowUpload`: an instant upload cannot show
/// progress or be captured mid-flight.
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
