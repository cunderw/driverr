import Foundation

/// Where the composer's pending attachment is. The phases, sizes and failure sentences are
/// here so `swift test` asserts them.
public enum PaneAttachmentPhase: Equatable, Sendable {
  /// The bytes are being converted to PNG. Not instant for a large photo, so the row appears
  /// now and the tap on Attach is visibly acknowledged.
  case preparing
  /// Prepared and waiting. Nothing has been sent.
  case ready
  /// On the wire, with the count so far.
  case uploading(ImageUploadProgress)
  /// The host has the file, at this path read off its stdout. Next comes ``handedOver``.
  case uploaded(hostPath: String)
  /// The path has been typed into the pane, with no newline.
  ///
  /// Its own phase rather than clearing the row, because the path lands in the agent's input
  /// on the host, where Driverr's field shows nothing. A vanishing row would look like one
  /// that gave up. Carries no path, because nothing reads it. Cleared by the next successful
  /// reply from this composer, and by Remove.
  case handedOver
  /// It ended badly, with the sentence to show.
  case failed(String)

  /// Whether an upload is in flight, which Remove has to cancel rather than forget.
  public var isUploading: Bool {
    if case .uploading = self { return true }
    return false
  }

  /// Whether the row has finished moving on its own: `.handedOver` or `.failed`.
  ///
  /// `PaneComposerModel` clears the attachment after a successful reply, and clearing
  /// cancels anything in flight. Without this check, a reply sent mid-upload would silently
  /// throw the upload away.
  public var isSettled: Bool {
    switch self {
    case .handedOver, .failed: return true
    case .preparing, .ready, .uploading, .uploaded: return false
    }
  }

  /// The finished host path, or `nil`. It drives the hand-off, so `.handedOver` returns `nil`
  /// and cannot drive a second one.
  public var hostPath: String? {
    if case .uploaded(let path) = self { return path }
    return nil
  }
}

/// The row's strings.
public enum PaneAttachmentCopy {
  /// The Attach control's accessibility label. The control itself is a glyph.
  public static let attachButton = "Attach an image"
  /// The Remove control's accessibility label, likewise.
  public static let removeButton = "Remove the attachment"
  /// What the row calls the thing it is showing, beside the thumbnail.
  public static let imageLabel = "Image"
  /// While the picked bytes are being read down to PNG.
  public static let preparing = "Preparing…"
  /// Once the host has it. Not the path, a `~/.driverr/inbox/` UUID that tells a reader
  /// nothing.
  public static let uploaded = "Sent to the host"
  /// Once the path is in the pane. "the prompt", because it went into the agent's input on
  /// the host, not into Driverr's field.
  public static let handedOver = "Added to the pane’s prompt"

  /// `sent of total`. "of", because VoiceOver reads a slash as "slash" and this is also the
  /// row's accessibility value.
  public static func progress(_ progress: ImageUploadProgress) -> String {
    "\(size(progress.bytesSent)) of \(size(progress.totalBytes))"
  }

  /// A byte count as a short human string, in decimal units as iOS shows file sizes. Not
  /// `ByteCountFormatter`, whose output varies by locale and OS version.
  public static func size(_ bytes: Int) -> String {
    let bytes = max(0, bytes)
    if bytes < 1000 { return "\(bytes) bytes" }
    let units = ["KB", "MB", "GB", "TB"]
    var value = Double(bytes) / 1000
    var unit = 0
    while value >= 1000, unit < units.count - 1 {
      value /= 1000
      unit += 1
    }
    // One decimal under 100, none above, so the row fits a collapsed landscape bar.
    if value < 100 { return String(format: "%.1f %@", value, units[unit]) }
    return String(format: "%.0f %@", value, units[unit])
  }
}

/// The ways an upload ends badly, each with a sentence that says what to do next.
///
/// Each differs in advice: a dropped channel is worth retrying, a refusal is not until the
/// host changes, a short write saved nothing, a silent success means Driverr cannot say
/// where the file went, and a stall is one Driverr ended itself.
public enum PaneAttachmentFailureCopy {
  /// The bytes could not be read as an image at all, before anything was sent.
  public static let unreadable = "That image could not be read."

  /// The upload landed and the hand-off did not. It says the host has the file, so the
  /// reader does not upload it again and leave two copies.
  public static let handOffFailed =
    "The host has the image, but the pane could not be told where it is."

  public static func sentence(for failure: ImageUploadFailure) -> String {
    switch failure {
    case .channelDropped:
      return "The connection to the host dropped mid-upload. Try again."
    case .commandFailed:
      return "The host refused the upload. Check its disk space and permissions."
    case .sizeMismatch:
      return "The image arrived incomplete, so nothing was saved. Try again."
    case .noHostPath:
      return "The host saved the image but did not say where."
    case .stalled:
      return "The host stopped answering, so the upload was stopped. Try again."
    }
  }

  /// Any other error, most often an `AppError` from a channel that could not open, as one
  /// sentence.
  public static func sentence(for error: any Error) -> String {
    if let failure = error as? ImageUploadFailure { return sentence(for: failure) }
    if let appError = error as? AppError, let described = appError.errorDescription {
      return described
    }
    return "The image could not be sent to the host."
  }
}
