/// How a remote command finished: its exit status, and what it wrote to stderr.
///
/// A finished byte stream cannot tell a clean close from a bridge that died. A failed
/// `herdr terminal session control` writes to stderr and exits nonzero; a torn-down channel
/// sends neither. Here because `DriverrSSH` produces it and `DriverrHerdr` reads it, and
/// neither may use the other's types.
public struct ProcessEnd: Equatable, Sendable {
  /// The command's exit status, or `nil` if it never reported one. `nil` is not zero: a
  /// command that exits sends SSH's `exit-status`, and a channel that disappears sends
  /// nothing.
  public let exitStatus: Int?

  /// What the command wrote to stderr, bounded and raw. Only `DriverrHerdr` interprets herdr's
  /// wording. The producer keeps the tail, because a failing process explains itself last.
  public let standardErrorTail: String

  public init(exitStatus: Int?, standardErrorTail: String = "") {
    self.exitStatus = exitStatus
    self.standardErrorTail = standardErrorTail
  }

  /// Whether the process ran and refused. A `nil` status is neither; see `exitStatus`.
  public var isFailure: Bool {
    guard let exitStatus else { return false }
    return exitStatus != 0
  }
}
