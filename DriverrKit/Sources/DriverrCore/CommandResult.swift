import Foundation

/// The outcome of a one-shot remote command run over an SSH exec channel.
///
/// Output is decoded to `String` here, because every consumer wants text, and one decode
/// keeps callers from inventing their own.
public struct CommandResult: Hashable, Sendable {
  public let standardOutput: String
  public let standardError: String
  public let exitStatus: Int

  public init(standardOutput: String, standardError: String, exitStatus: Int) {
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.exitStatus = exitStatus
  }

  public var succeeded: Bool { exitStatus == 0 }

  /// `standardOutput` without the shell's trailing newline, for comparing against literals.
  public var trimmedOutput: String {
    standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
