#if DEBUG
import Foundation

/// A host's settings file, answering `HookInstallCommands`' read and write the way `sh` on
/// the host would. For tests and UI runs, where there is no shell.
///
/// The write is taken apart, not trusted: the fake undoes the login-shell quoting, checks the
/// compare-and-swap against the file it holds, reads the command's byte count from its
/// standard input as `head -c` would, and stores that. A write the host would refuse is
/// refused with the same exit status.
public actor FakeHookHost {
  public let integration: AgentIntegration
  /// The settings file, or `nil` when it does not exist.
  public private(set) var text: String?
  private let hasConfigDirectory: Bool
  /// Text the file changes to just before the next write arrives, as though the agent
  /// rewrote it between Driverr's read and its write. Used once.
  private var changeBeforeWrite: String?
  public private(set) var writeCount = 0

  public init(
    integration: AgentIntegration,
    text: String?,
    hasConfigDirectory: Bool = true,
    changeBeforeWrite: String? = nil
  ) {
    self.integration = integration
    self.text = text
    self.hasConfigDirectory = hasConfigDirectory
    self.changeBeforeWrite = changeBeforeWrite
  }

  /// The runner for `HookInstaller`'s read.
  public nonisolated var run: CommandRunner {
    { command in await self.answer(command) }
  }

  /// The runner for `HookInstaller`'s write.
  public nonisolated var write: InputCommandRunner {
    { command, input in await self.answer(command, standardInput: input) }
  }

  /// Both, as the app passes them around.
  public nonisolated var runners: HookInstallRunners {
    HookInstallRunners(run: run, write: write)
  }

  public func answer(_ command: String, standardInput: Data = Data()) -> CommandResult {
    guard hasConfigDirectory else {
      return exit(HookInstallCommands.noConfigDirectoryExitStatus)
    }
    if command == HookInstallCommands.read(for: integration) {
      guard let text else { return CommandResult(standardOutput: "missing\n", standardError: "", exitStatus: 0) }
      let checksum = POSIXChecksum(of: text.utf8)
      return CommandResult(standardOutput: "present \(checksum.text)\n" + text, standardError: "", exitStatus: 0)
    }
    guard let script = Self.script(of: command), let write = Self.write(in: script) else {
      return CommandResult(standardOutput: "", standardError: "sh: not found\n", exitStatus: 127)
    }
    if let change = changeBeforeWrite {
      text = change
      changeBeforeWrite = nil
    }
    let now = text.map { POSIXChecksum(of: $0.utf8).text } ?? HookInstallCommands.missingChecksum
    guard now == write.expected else { return exit(HookInstallCommands.changedSinceReadExitStatus) }
    // Input that ends early is a short copy, which the checksum refuses: it covers the size.
    let body = standardInput.prefix(write.byteCount)
    guard POSIXChecksum(of: body).text == write.written else {
      return exit(HookInstallCommands.writeDidNotMatchExitStatus)
    }
    text = String(decoding: body, as: UTF8.self)
    writeCount += 1
    return CommandResult(standardOutput: "", standardError: "", exitStatus: 0)
  }

  private func exit(_ status: Int) -> CommandResult {
    CommandResult(standardOutput: "", standardError: "", exitStatus: status)
  }

  /// The script inside `sh -c '…'`, with `HookInstallCommands.loginShellQuoted` undone.
  static func script(of command: String) -> String? {
    let prefix = "sh -c '"
    guard command.hasPrefix(prefix), command.hasSuffix("'") else { return nil }
    let quoted = command.dropFirst(prefix.count).dropLast()
    return quoted.replacingOccurrences(of: #"'\''"#, with: "'")
      .replacingOccurrences(of: #"'\\'"#, with: "\\")
  }

  /// The checksum the write expects, the one it writes, and how many bytes of its standard
  /// input are the file.
  static func write(in script: String) -> (expected: String, written: String, byteCount: Int)? {
    let lines = script.components(separatedBy: "\n")
    let expectedPrefix = "[ \"$now\" = \""
    let writtenPrefix = "set -- $c; [ \"$1 $2\" = \""
    let countPrefix = "head -c "
    guard let expectedLine = lines.first(where: { $0.hasPrefix(expectedPrefix) }),
      let writtenLine = lines.first(where: { $0.hasPrefix(writtenPrefix) }),
      let countLine = lines.first(where: { $0.hasPrefix(countPrefix) }),
      let byteCount = Int(countLine.dropFirst(countPrefix.count).prefix { $0 != " " }), byteCount >= 0
    else { return nil }
    func value(_ line: String, after prefix: String) -> String {
      String(line.dropFirst(prefix.count).prefix { $0 != "\"" })
    }
    return (value(expectedLine, after: expectedPrefix), value(writtenLine, after: writtenPrefix), byteCount)
  }
}
#endif
