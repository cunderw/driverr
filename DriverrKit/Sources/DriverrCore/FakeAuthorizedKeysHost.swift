#if DEBUG
import Foundation

/// A host's `~/.ssh/authorized_keys`, answering `AuthorizedKeyInstallCommands.install` the
/// way `sh` on the host would. For tests and UI runs, where there is no shell.
///
/// The command is taken apart, not trusted: the fake undoes the login-shell quoting and the
/// `sh` quoting of `b=` and `line=`, so it holds the line the command carried.
public actor FakeAuthorizedKeysHost {
  /// The file's lines, or `nil` when it does not exist.
  public private(set) var lines: [String]?
  /// When set, every install fails with this exit status and stderr.
  private let failure: (status: Int, message: String)?
  /// How long an answer takes, so a UI capture can catch the installing state.
  private let delay: Duration
  public private(set) var installCount = 0

  public init(lines: [String]? = nil, failure: (status: Int, message: String)? = nil, delay: Duration = .zero) {
    self.lines = lines
    self.failure = failure
    self.delay = delay
  }

  /// The runner to hand to `AuthorizedKeyInstaller`.
  public nonisolated var run: CommandRunner {
    { command in await self.answer(command) }
  }

  public func answer(_ command: String) async -> CommandResult {
    if delay > .zero { try? await Task.sleep(for: delay) }
    guard let script = FakeHookHost.script(of: command), let values = Self.values(in: script) else {
      return CommandResult(standardOutput: "", standardError: "sh: not found\n", exitStatus: 127)
    }
    if let failure {
      return CommandResult(standardOutput: "", standardError: failure.message, exitStatus: failure.status)
    }
    let present = (lines ?? []).contains { $0.split(separator: " ").contains { $0 == values.blob } }
    if present { return CommandResult(standardOutput: "present\n", standardError: "", exitStatus: 0) }
    lines = (lines ?? []) + [values.line]
    installCount += 1
    return CommandResult(standardOutput: "installed\n", standardError: "", exitStatus: 0)
  }

  /// The blob and the line from the script's second line, `b=…; line=…`.
  static func values(in script: String) -> (blob: String, line: String)? {
    guard let assignment = script.components(separatedBy: "\n").first(where: { $0.hasPrefix("b=") }),
      let split = assignment.range(of: "; line=")
    else { return nil }
    let blob = unquoted(String(assignment[assignment.index(assignment.startIndex, offsetBy: 2)..<split.lowerBound]))
    let line = unquoted(String(assignment[split.upperBound...]))
    return (blob, line)
  }

  /// `shellQuoted` undone: a bare word, or `'…'` with each `'` written as `'\''`.
  static func unquoted(_ word: String) -> String {
    guard word.hasPrefix("'"), word.hasSuffix("'"), word.count >= 2 else { return word }
    return String(word.dropFirst().dropLast()).replacingOccurrences(of: #"'\''"#, with: "'")
  }
}
#endif
