import Foundation

/// How far one image upload has got, as bytes written over bytes to write.
///
/// Known client-side, because the host says nothing until it exits. An awaited write on an
/// SSH exec channel returns only when the far side's window had room, so this is real
/// progress.
public struct ImageUploadProgress: Sendable, Hashable {
  public let bytesSent: Int
  public let totalBytes: Int

  public init(bytesSent: Int, totalBytes: Int) {
    self.bytesSent = bytesSent
    self.totalBytes = totalBytes
  }

  /// 0…1, and 1 for an empty payload rather than a division by zero.
  public var fraction: Double {
    guard totalBytes > 0 else { return 1 }
    return min(1, Double(bytesSent) / Double(totalBytes))
  }
}

/// Where the bytes landed, once the host has said so.
public struct ImageUploadOutcome: Sendable, Hashable {
  /// The absolute path on the host, as the host printed it.
  ///
  /// Read back rather than built here, because only the host can expand `$HOME`. This is
  /// the string typed into the agent.
  public let hostPath: String
  public let bytesSent: Int

  public init(hostPath: String, bytesSent: Int) {
    self.hostPath = hostPath
    self.bytesSent = bytesSent
  }
}

/// The ways an upload ends badly, kept apart because each needs different advice.
///
/// A dropped channel is worth retrying. A non-zero exit is the host refusing (space,
/// permission), which retrying will not fix. A size mismatch means the bytes arrived short,
/// and the `.part` is left for the next sweep rather than renamed into place. A stall means
/// the host stopped answering and nothing reported a drop, so Driverr stopped waiting.
public enum ImageUploadFailure: Error, Sendable, Hashable {
  /// The command ran and exited non-zero. `standardError` is whatever it printed, which
  /// may be empty.
  case commandFailed(exitStatus: Int, standardError: String)
  /// The channel went away before the command could report anything.
  case channelDropped(reason: String)
  /// The host counted the bytes it received and got a different number.
  case sizeMismatch(expectedBytes: Int)
  /// The command exited zero but printed no path, so there is nothing to hand an agent.
  case noHostPath
  /// The channel did not open, or no byte moved in either direction, for the upload's idle
  /// deadline, so Driverr stopped the upload. Every byte may have been sent: the host may
  /// only have failed to print the path.
  case stalled
}
