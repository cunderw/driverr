import Foundation

/// What one session file looks like from the outside: has it been written to.
///
/// Two fields from the host's `stat` and `wc`, under thirty bytes on the wire against 1 KB
/// to 100 KB for a page, so it is cheap to ask every few seconds.
///
/// Both fields: an append grows the size, and an in-place rewrite at the same length still
/// moves the mtime. `modified` is only compared with another reading of itself, never the
/// device clock, so clock skew cannot hide a live file.
public struct TranscriptStamp: Hashable, Sendable {
  /// The file's mtime, in seconds since the epoch, on the host's clock.
  public let modified: TimeInterval
  public let sizeInBytes: Int

  public init(modified: TimeInterval, sizeInBytes: Int) {
    self.modified = modified
    self.sizeInBytes = sizeInBytes
  }
}
