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
  /// The file has landed, at this path as the computer the pane runs on sees it: the SSH
  /// host's, read off the inbox command's stdout, or a machine's, as its core answered.
  /// Next comes ``handedOver``.
  case uploaded(hostPath: String)
  /// The path has been typed into the pane, with no newline.
  ///
  /// Its own phase rather than clearing the row, because the path lands in the agent's input
  /// in the pane, where Driverr's field shows nothing. A vanishing row would look like one
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

  /// The finished path, as the pane's computer sees it, or `nil`. It drives the hand-off, so `.handedOver` returns `nil`
  /// and cannot drive a second one.
  public var hostPath: String? {
    if case .uploaded(let path) = self { return path }
    return nil
  }
}

/// Where a pane's attachment is sent: the SSH host's inbox, or a machine a herdr-core added,
/// by the name the core gives it. The row's sentences name the place.
public enum PaneAttachmentPlace: Equatable, Sendable {
  case host
  case machine(String)
}

/// What the pending attachment is: a photo, prepared down to PNG, or a file sent as it is.
/// The row and its sentences follow it.
public enum PaneAttachmentKind: Equatable, Sendable {
  case image
  /// `name` is the original, as the reader picked it, not the sanitised name it lands under.
  case file(name: String)

  /// The word the sentences use for it.
  var noun: String {
    switch self {
    case .image: "image"
    case .file: "file"
    }
  }
}

/// Which picker the composer's Attach menu asked for.
public enum AttachmentSource: Equatable, Sendable {
  case photos
  case files
}

/// The row's strings.
public enum PaneAttachmentCopy {
  /// The Attach control's accessibility label. The control itself is a glyph.
  public static let attachButton = "Attach a photo or file"
  /// The Attach menu's two items.
  public static let photosItem = "Photos"
  public static let filesItem = "Files"
  /// The Remove control's accessibility label, likewise.
  public static let removeButton = "Remove the attachment"
  /// What the row calls the thing it is showing, beside the thumbnail.
  public static let imageLabel = "Image"

  /// ``imageLabel`` for an image, and a file's own name for a file.
  public static func label(for kind: PaneAttachmentKind) -> String {
    switch kind {
    case .image: imageLabel
    case .file(let name): name
    }
  }
  /// While the picked bytes are being read down to PNG.
  public static let preparing = "Preparing…"
  /// Once the host has it, for a pane on the SSH host. Not the path, a UUID file name that
  /// tells a reader nothing. ``uploaded(at:)`` names the place.
  public static let uploaded = "Sent to the host"

  /// ``uploaded``, naming the machine for a pane on one.
  public static func uploaded(at place: PaneAttachmentPlace) -> String {
    switch place {
    case .host: uploaded
    case .machine(let name): "Sent to \(name)"
    }
  }

  /// Once the path is in the pane. "the prompt", because it went into the agent's input in
  /// the pane, not into Driverr's field.
  public static let handedOver = "Added to the pane’s prompt"

  /// While the bytes are on the wire. A host's upload reports `sent of total`. A machine's is
  /// one `terminal.put` that says nothing until it is done, so it has no count to show, and
  /// a `0 bytes of` would sit there for the whole put.
  public static func uploading(_ progress: ImageUploadProgress, at place: PaneAttachmentPlace)
    -> String
  {
    switch place {
    case .host: self.progress(progress)
    case .machine(let name): "Sending to \(name)…"
    }
  }

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

  /// ``unreadable`` for a kind. A file is unreadable when it is a folder or its read failed.
  public static func unreadable(_ kind: PaneAttachmentKind) -> String {
    "That \(kind.noun) could not be read."
  }

  /// A picked file over ``AttachmentLimit``'s number for its place, refused before it was
  /// read. A machine's sentence is the same one its core's refusal gets.
  public static func tooLarge(limit: Int, at place: PaneAttachmentPlace, kind: PaneAttachmentKind)
    -> String
  {
    switch place {
    case .host:
      "The \(kind.noun) is over the \(PaneAttachmentCopy.size(limit)) limit for the host."
    case .machine(let name):
      "The \(kind.noun) is over the \(PaneAttachmentCopy.size(limit)) limit for \(name)."
    }
  }

  /// The upload landed and the hand-off did not. It says the host has the file, so the
  /// reader does not upload it again and leave two copies.
  public static let handOffFailed =
    "The host has the image, but the pane could not be told where it is."

  /// ``handOffFailed``, naming the machine that has the image or file.
  public static func handOffFailed(
    at place: PaneAttachmentPlace, kind: PaneAttachmentKind = .image
  ) -> String {
    switch place {
    case .host:
      "The host has the \(kind.noun), but the pane could not be told where it is."
    case .machine(let name):
      "The \(kind.noun) is on \(name), but the pane could not be told where it is."
    }
  }

  /// One upload failure at a place. A dropped channel and a short write are the SSH inbox
  /// command's alone, so they keep the host's sentence wherever they come from.
  public static func sentence(
    for failure: ImageUploadFailure, at place: PaneAttachmentPlace,
    kind: PaneAttachmentKind = .image
  ) -> String {
    guard case .machine(let name) = place else { return sentence(for: failure, kind: kind) }
    let noun = kind.noun
    switch failure {
    case .channelDropped, .sizeMismatch:
      return sentence(for: failure, kind: kind)
    case .commandFailed:
      return "Driverr could not save the \(noun) on \(name). Check its disk space and permissions."
    case .noHostPath:
      return "The \(noun) was saved on \(name), but Driverr was not told where."
    case .stalled:
      return "Nothing came back from \(name), so the upload was stopped. Try again."
    }
  }

  /// Any error at a place. For a machine, anything but an upload failure or a refusal is the
  /// one fallback: the core's own words name its terminal, not what to do.
  public static func sentence(
    for error: any Error, at place: PaneAttachmentPlace, kind: PaneAttachmentKind = .image
  ) -> String {
    guard case .machine(let name) = place else { return sentence(for: error, kind: kind) }
    if let failure = error as? ImageUploadFailure {
      return sentence(for: failure, at: place, kind: kind)
    }
    switch error as? MachineImageRefusal {
    case .unsupported?:
      return "Driverr can't send \(kind.noun)s to \(name)."
    case .tooLarge(let limit)?:
      return tooLarge(limit: limit, at: place, kind: kind)
    case nil:
      return "The \(kind.noun) could not be sent to \(name)."
    }
  }

  public static func sentence(for failure: ImageUploadFailure, kind: PaneAttachmentKind = .image)
    -> String
  {
    let noun = kind.noun
    switch failure {
    case .channelDropped:
      return "The connection to the host dropped mid-upload. Try again."
    case .commandFailed:
      return "The host refused the upload. Check its disk space and permissions."
    case .sizeMismatch:
      return "The \(noun) arrived incomplete, so nothing was saved. Try again."
    case .noHostPath:
      return "The host saved the \(noun) but did not say where."
    case .stalled:
      return "The host stopped answering, so the upload was stopped. Try again."
    }
  }

  /// Any other error, most often an `AppError` from a channel that could not open, as one
  /// sentence.
  public static func sentence(for error: any Error, kind: PaneAttachmentKind = .image) -> String {
    if let failure = error as? ImageUploadFailure { return sentence(for: failure, kind: kind) }
    if let appError = error as? AppError, let described = appError.errorDescription {
      return described
    }
    return "The \(kind.noun) could not be sent to the host."
  }
}
