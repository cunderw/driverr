import DriverrCore
import Foundation

/// Streams one file's bytes to a connected host over a single exec channel, and reports
/// where they landed.
///
/// It sends raw bytes, not base64. `execStream` has no pty, so the channel is binary
/// clean. Base64 would add a third to the wire size and need a `base64 -d` whose flags
/// differ between GNU and BSD.
///
/// One upload per instance. The progress stream is created in `init`, so a caller can
/// take ``progress`` before ``upload()`` and miss no event.
public final class ImageUploader: Sendable {
  /// 32 KB, the SSH channel's maximum packet size.
  ///
  /// One write of a whole photo would give one progress event at the end. A returned `send`
  /// means this device's socket took the chunk, not that the host has it. The channel
  /// throttles to the remote window, so progress follows the host once the window is full.
  public static let chunkSize = 32 * 1024

  /// Bytes sent over bytes to send. It finishes when the upload ends, even on failure, so
  /// a consumer's `for await` always ends.
  public let progress: AsyncStream<ImageUploadProgress>

  private let coordinator: ConnectionCoordinator
  private let bytes: Data
  private let command: InboxUploadCommand
  private let progressSignal: AsyncStream<ImageUploadProgress>.Continuation
  /// How long the upload may go with no byte moving. See `withIdleDeadline`.
  private let idleDeadline: Duration

  /// - Parameter command: normally `InboxUploadCommand.forUpload(…)`. Injected so a test
  ///   can drive failure branches the wire cannot reach.
  /// - Parameter idleDeadline: overridable so a test can assert the stall in milliseconds.
  public init(
    coordinator: ConnectionCoordinator,
    bytes: Data,
    command: InboxUploadCommand,
    idleDeadline: Duration = ConnectionCoordinator.defaultUploadIdleDeadline
  ) {
    self.coordinator = coordinator
    self.bytes = bytes
    self.command = command
    self.idleDeadline = idleDeadline
    let (stream, continuation) = AsyncStream.makeStream(of: ImageUploadProgress.self)
    progress = stream
    progressSignal = continuation
  }

  public convenience init(
    coordinator: ConnectionCoordinator,
    bytes: Data,
    fileName: String,
    inboxDirectory: String = InboxUploadCommand.defaultInboxDirectory,
    idleDeadline: Duration = ConnectionCoordinator.defaultUploadIdleDeadline
  ) {
    self.init(
      coordinator: coordinator,
      bytes: bytes,
      command: InboxUploadCommand.forUpload(
        fileName: fileName,
        byteCount: bytes.count,
        inboxDirectory: inboxDirectory
      ),
      idleDeadline: idleDeadline
    )
  }

  /// Runs the upload and returns the host's path for the finished file.
  ///
  /// It gives up when the channel has not opened, or no byte has moved in either direction,
  /// for the idle deadline, and throws ``ImageUploadFailure/stalled``.
  ///
  /// - Throws: ``ImageUploadFailure``, the `AppError` from `openStream` if no channel
  ///   opened, or `CancellationError`.
  @discardableResult
  public func upload() async throws -> ImageUploadOutcome {
    // The open has the deadline too. See `openingStream`. Its own `catch`, because there is
    // no stream to close yet and `progress` still has to finish.
    let stream: any ExecStream
    do {
      stream = try await openingStream(within: idleDeadline, stalled: ImageUploadFailure.stalled) {
        [coordinator, command] in
        try await coordinator.openStream(command: command.script)
      }
    } catch {
      progressSignal.finish()
      throw error
    }
    do {
      let outcome = try await send(over: stream)
      progressSignal.finish()
      await stream.close()
      return outcome
    } catch {
      progressSignal.finish()
      await stream.close()
      throw error
    }
  }

  private func send(over stream: any ExecStream) async throws -> ImageUploadOutcome {
    try await withIdleDeadline(idleDeadline, over: stream, stalled: ImageUploadFailure.stalled) {
      [self] activity in
      try await transfer(over: stream, marking: activity)
    }
  }

  /// The transfer itself. It may be abandoned part way: see `withIdleDeadline`.
  private func transfer(
    over stream: any ExecStream,
    marking activity: StreamActivity
  ) async throws -> ImageUploadOutcome {
    let total = bytes.count
    // Drained from the start, because the stderr buffer is small and the command may
    // write to it while still reading.
    async let standardError = Self.collect(stream.standardError, marking: activity)

    progressSignal.yield(ImageUploadProgress(bytesSent: 0, totalBytes: total))
    var sent = 0
    var index = bytes.startIndex
    while index < bytes.endIndex {
      // **Check cancellation here, because nothing below does.** Without it a cancelled
      // upload sends every chunk and the file lands on the host. Throwing closes the
      // stream short, so `head -c` stops early, the size check fails and `mv` never runs.
      // A bare `CancellationError` is thrown on purpose, so a cancel does not show a
      // "connection dropped" message.
      try Task.checkCancellation()
      let end =
        bytes.index(index, offsetBy: Self.chunkSize, limitedBy: bytes.endIndex) ?? bytes.endIndex
      do {
        try await stream.send(bytes[index..<end])
      } catch {
        throw ImageUploadFailure.channelDropped(reason: Self.reason(for: error))
      }
      activity.moved()
      sent += bytes.distance(from: index, to: end)
      progressSignal.yield(ImageUploadProgress(bytesSent: sent, totalBytes: total))
      index = end
    }

    // Read stdout to its end before asking for the status. The status arrives as a
    // separate channel request, and is certain to have landed only once output finishes.
    var printed = Data()
    do {
      for try await chunk in stream.output {
        activity.moved()
        printed.append(chunk)
      }
    } catch {
      throw ImageUploadFailure.channelDropped(reason: Self.reason(for: error))
    }

    // No status means the channel went, not that the command exited.
    guard let status = await stream.exitStatus else {
      throw ImageUploadFailure.channelDropped(reason: "The command ended without an exit status.")
    }

    switch status {
    case 0:
      let path = String(decoding: printed, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !path.isEmpty else { throw ImageUploadFailure.noHostPath }
      return ImageUploadOutcome(hostPath: path, bytesSent: sent)
    case InboxUploadCommand.sizeMismatchExitStatus:
      throw ImageUploadFailure.sizeMismatch(expectedBytes: total)
    default:
      throw ImageUploadFailure.commandFailed(
        exitStatus: status,
        standardError: (try? await standardError) ?? ""
      )
    }
  }

  private static func collect(
    _ stream: AsyncThrowingStream<Data, any Error>,
    marking activity: StreamActivity
  ) async throws -> String {
    var data = Data()
    for try await chunk in stream {
      activity.moved()
      data.append(chunk)
    }
    return String(decoding: data, as: UTF8.self)
  }

  private static func reason(for error: any Error) -> String {
    if let appError = error as? AppError, case .channelFailed(let reason) = appError {
      return reason
    }
    return "The connection to the host went away mid-upload."
  }
}

/// The protocol lives in `DriverrCore`, so the app's composer can hold
/// `any ImageUploading` without importing `DriverrSSH`, and tests can substitute a fake.
extension ImageUploader: ImageUploading {}
