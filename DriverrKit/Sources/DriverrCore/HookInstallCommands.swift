import Foundation

/// Why an install did not happen, or did not finish. Each one leaves the settings file as
/// it was: the edit is written to a separate file and moved into place only at the end.
public enum HookInstallFailure: Error, Hashable, Sendable {
  /// The agent's configuration directory, e.g. `~/.claude`, does not exist: the agent has
  /// never run on this host. Driverr does not create it.
  case noConfigDirectory(path: String)
  /// The settings file is a symlink or not a regular file. Driverr refuses it, because a
  /// move into place would replace the link with a plain file and cut it from wherever
  /// the user keeps the real one.
  case notARegularFile(path: String)
  /// The file's JSON is invalid or has a shape Driverr cannot edit.
  case settings(HookSettingsError)
  /// The bytes that arrived do not match the host's checksum of the file: it changed while
  /// it was read, or it is not UTF-8 text. Nothing was written.
  case readDidNotMatch
  /// The file changed between the read and the write. Nothing was written; reading again
  /// and repeating the install is safe.
  case changedSinceRead
  /// The copy written on the host did not match what Driverr sent, so it was not moved into
  /// place. The settings file is unchanged.
  case writeDidNotMatch
  /// `cksum` failed on the host, so the file could not be compared. Nothing was written.
  case checksumFailed(message: String)
  /// The settings file is larger than an install writes.
  case settingsTooLarge(bytes: Int)
  /// Any other failure: the host's exit status and what it wrote to stderr.
  case commandFailed(exitStatus: Int, message: String)
}

/// What the read found on the host.
public enum HookSettingsRead: Hashable, Sendable {
  /// The directory exists and the settings file does not. An install creates it.
  case missing
  case present(text: String, checksum: POSIXChecksum)
}

/// One install, ready to send: the write command, and the file text for its standard input.
public struct HookInstallPlan: Hashable, Sendable {
  public let integration: AgentIntegration
  /// The whole command for the exec channel. It holds the file's byte count and two
  /// checksums, and none of the file. "View Full Command" shows ``display``, which has a
  /// description in place of each of those values.
  public let command: String
  /// The file the command writes. It goes to the command's standard input and never into
  /// ``command``, because any account on the host can read a command with `ps`.
  public let settingsText: String

  /// The command view for this install. Built from the integration alone, so nothing the
  /// read returned can reach the screen.
  public var display: HookCommandDisplay { HookInstallCommands.display(for: integration) }
}

/// What "View Full Command" shows: the two shell commands and the JSON added, with every
/// value that would come from the user's file replaced by a description of it.
public struct HookCommandDisplay: Hashable, Sendable {
  public let readCommand: String
  /// Each hook's group, as it is added, under the key path it goes into.
  public let addedJSON: String
  public let writeCommand: String
  /// Says that the rest of the file is kept and that the file itself is not shown.
  public let note: String
  /// Says where the write command gets the file from, since the command does not hold it.
  public let writeNote: String

  /// The whole view as one text, in the order it runs.
  public var text: String {
    [
      "1. Read the settings file and its checksum:", readCommand,
      "2. Add this to it, on this device:", addedJSON, note,
      "3. Write it back:", writeCommand, writeNote,
    ].joined(separator: "\n\n")
  }
}

/// The shell commands that read and write an agent's settings file on the host.
///
/// The merge runs on the phone. The host needs only `sh`, `cat`, `cksum`, `cp`, `head` and
/// `mv`, because it may have no `jq` or `python`.
///
/// The finished file goes to the write command on its standard input, and no part of it is
/// in the command. The command is an argument to the login shell, and `ps` shows every
/// argument to every account on the host. A settings file can hold tokens in its `env`
/// values. The command holds the file's byte count and reads that many bytes with
/// `head -c`. It cannot read to end of input: Driverr has no half-close (see
/// `InboxUploadCommand`), so end of input never comes while the channel is open. That is
/// also why the script itself is not sent to `sh -s`.
///
/// The write is a compare-and-swap: it recomputes the `cksum` the read reported and exits
/// ``changedSinceReadExitStatus`` on a mismatch, before touching anything. Claude Code
/// rewrites `settings.json` itself, and a racing install would restore the old file.
///
/// Then `cp -p` to a backup, the new text into `.driverr-part`, and `mv`. The part file
/// starts as a `cp -p` of the original so it keeps its mode; a umask-created file could make
/// a 0600 settings file world-readable. The part file is checked against the phone's
/// checksum before the `mv`, which is atomic within one directory. `cksum` prints the size
/// with the CRC, so input that ended early fails the same check. A part file that does not
/// match, or that `cksum` fails on, is removed with `rm -f`. On a host with no `rm` it stays,
/// and the exit status is the same. The three exits with status 1 (the `cp -p` into the part
/// file, the `head` and the `mv`) leave it, and their message says only that nothing was
/// replaced.
///
/// Both commands run under `sh -c`, quoted for any login shell, because the exec channel
/// hands the command to the login shell, which may be fish. fish reads `\\` and `\'` inside
/// single quotes as escapes, so each `'` and `\` is written outside the quotes as `'\''` and
/// `'\\'`, which bash, zsh, dash and fish all read as one character. csh and tcsh reject a
/// multi-line single-quoted string, so those hosts cannot install.
///
/// ``maximumSettingsBytes`` is a limit Driverr sets, not one the host has. A settings file
/// is a few kilobytes, and one far past that is refused, not edited.
///
/// The directory is `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`, as Claude Code resolves it. The
/// variable only helps if it reaches a non-interactive SSH shell. Failures name `~/.claude`.
///
/// Exit statuses come from `sysexits.h`, clear of the shell's own 1–2, 126 and 127.
public enum HookInstallCommands {
  /// `EX_TEMPFAIL`: the file changed since it was read.
  public static let changedSinceReadExitStatus = 75
  /// `EX_IOERR`: the written copy's checksum is not the one sent.
  public static let writeDidNotMatchExitStatus = 74
  /// `EX_NOPERM`: the settings file is a symlink or not a regular file.
  public static let notARegularFileExitStatus = 77
  /// `EX_CONFIG`: the configuration directory does not exist.
  public static let noConfigDirectoryExitStatus = 78
  /// `EX_OSERR`: `cksum` itself failed, so there is nothing to compare.
  public static let checksumFailedExitStatus = 71

  /// The largest settings file an install writes.
  public static let maximumSettingsBytes = 96 * 1024

  /// What the write compares against when the read found no file.
  static let missingChecksum = "missing"
  static let backupSuffix = ".driverr-backup"
  static let partSuffix = ".driverr-part"

  /// Reads the file and its checksum. Prints `missing` when the file does not exist, and
  /// otherwise `present <crc> <bytes>` on the first line followed by the file.
  ///
  /// The checksum is taken before the `cat`. If the file changes in between, the phone's
  /// checksum of what arrived will not match and the read is refused. The other order would
  /// pair a new checksum with old text and let the write's check pass.
  public static func read(for integration: AgentIntegration) -> String {
    let lines = prelude(for: integration) + [
      "if [ ! -e \"$f\" ]; then echo \(missingChecksum); exit 0; fi",
      "c=$(cksum < \"$f\") || exit \(checksumFailedExitStatus)",
      "echo present $c",
      "cat \"$f\" || exit 1",
    ]
    return "sh -c " + loginShellQuoted(lines.joined(separator: "\n"))
  }

  /// Maps the read command's result to what it found, or to why it failed.
  public static func parseRead(_ result: CommandResult, for integration: AgentIntegration) throws(HookInstallFailure)
    -> HookSettingsRead
  {
    if let failure = failure(forExitStatus: result, integration: integration) { throw failure }
    let output = result.standardOutput
    if output.trimmingCharacters(in: .whitespacesAndNewlines) == missingChecksum { return .missing }
    guard let newline = output.firstIndex(of: "\n") else { throw .readDidNotMatch }
    let header = output[..<newline].split(separator: " ")
    guard header.count == 3, header[0] == "present", let crc = UInt32(header[1]), let size = Int(header[2])
    else { throw .readDidNotMatch }
    let text = String(output[output.index(after: newline)...])
    let expected = POSIXChecksum(crc: crc, byteCount: size)
    guard POSIXChecksum(of: text.utf8) == expected else { throw .readDidNotMatch }
    return .present(text: text, checksum: expected)
  }

  /// The install for what the read found, or `nil` when every hook is already there.
  public static func plan(for integration: AgentIntegration, read: HookSettingsRead) throws(HookInstallFailure)
    -> HookInstallPlan?
  {
    let original: String?
    let expected: String
    switch read {
    case .missing:
      original = nil
      expected = missingChecksum
    case .present(let text, let checksum):
      original = text
      expected = checksum.text
    }
    let edited: String?
    do {
      edited = try integration.installing(into: original)
    } catch {
      throw .settings(error)
    }
    guard let edited else { return nil }
    // The file is written with a final newline, so one without gains it. Compared as
    // bytes: `"\r\n"` is one `Character`, so `hasSuffix("\n")` misses it.
    let text = edited.utf8.last == 0x0A ? edited : edited + "\n"
    guard text.utf8.count <= maximumSettingsBytes else { throw .settingsTooLarge(bytes: text.utf8.count) }
    // The count and the checksum come from the text the plan carries, which is the text
    // the installer sends.
    let command = write(
      for: integration,
      expected: expected,
      written: POSIXChecksum(of: text.utf8).text,
      byteCount: String(text.utf8.count)
    )
    return HookInstallPlan(integration: integration, command: command, settingsText: text)
  }

  /// `nil` when the write succeeded, otherwise why it did not.
  public static func outcome(of result: CommandResult, for integration: AgentIntegration) -> HookInstallFailure? {
    failure(forExitStatus: result, integration: integration)
  }

  /// The command view. It takes no file: every value that would come from one is written as
  /// a description in angle brackets.
  public static func display(for integration: AgentIntegration) -> HookCommandDisplay {
    let added: [String]
    switch integration.format {
    case .claudeCodeJSON:
      added = integration.hooks.map { hook in
        "\"hooks\" → \"\(hook.event)\", added at the end:\n"
          + ClaudeSettingsEditor.group(for: hook).rendered(indent: "", unit: "  ")
      }
    }
    return HookCommandDisplay(
      readCommand: read(for: integration),
      addedJSON: added.joined(separator: "\n\n"),
      writeCommand: write(
        for: integration,
        expected: "<checksum from step 1>",
        written: "<checksum of the new file>",
        byteCount: "<size of the new file in bytes>"
      ),
      note:
        "The rest of \(integration.displayPath) is kept unchanged and in its order. An older Driverr entry is replaced where it stands. The file’s contents are not shown here. If the file exists, the version before this install is saved as \(integration.displayPath)\(backupSuffix).",
      writeNote:
        "The new file is \(integration.settingsFileName) from step 1 with the JSON above added. Driverr sends it to this command’s standard input. It is not part of the command, so other accounts on the host cannot read it in the process list."
    )
  }

  // MARK: - Building

  /// `d` and `f`, then the two refusals both commands share.
  private static func prelude(for integration: AgentIntegration) -> [String] {
    [
      "d=\(integration.configDirectory)",
      "f=\"$d\"/\(shellQuoted(integration.settingsFileName))",
      "[ -d \"$d\" ] || exit \(noConfigDirectoryExitStatus)",
      "if [ -L \"$f\" ]; then exit \(notARegularFileExitStatus); fi",
      "if [ -e \"$f\" ] && [ ! -f \"$f\" ]; then exit \(notARegularFileExitStatus); fi",
    ]
  }

  /// The write, which reads the new file from its standard input.
  ///
  /// - Parameter byteCount: how many bytes of standard input are the file. `head -c` reads
  ///   that many and stops. Nothing before it reads standard input, so a refusal exits with
  ///   the file unread. Text, like the two checksums, so the command view can pass a
  ///   description.
  static func write(for integration: AgentIntegration, expected: String, written: String, byteCount: String) -> String {
    let part = "\"$f\(partSuffix)\""
    let lines = prelude(for: integration) + [
      "now=\(missingChecksum)",
      "if [ -e \"$f\" ]; then c=$(cksum < \"$f\") || exit \(checksumFailedExitStatus); set -- $c; now=\"$1 $2\"; fi",
      "[ \"$now\" = \"\(expected)\" ] || exit \(changedSinceReadExitStatus)",
      "if [ -e \"$f\" ]; then cp -p \"$f\" \"$f\(backupSuffix)\" || exit 1; cp -p \"$f\" \(part) || exit 1; fi",
      "head -c \(byteCount) > \(part) || exit 1",
      "c=$(cksum < \(part)) || { rm -f \(part) 2>/dev/null; exit \(checksumFailedExitStatus); }",
      "set -- $c; [ \"$1 $2\" = \"\(written)\" ] || { rm -f \(part) 2>/dev/null; exit \(writeDidNotMatchExitStatus); }",
      "mv \(part) \"$f\" || exit 1",
    ]
    return "sh -c " + loginShellQuoted(lines.joined(separator: "\n"))
  }

  /// One single-quoted word that bash, zsh, dash and fish all read back as `script`: each
  /// `'` and `\` goes outside the quotes, escaped, because fish treats both as escapes
  /// inside single quotes. See the type's comment.
  static func loginShellQuoted(_ script: String) -> String {
    var out = "'"
    for scalar in script.unicodeScalars {
      switch scalar {
      case "'": out += #"'\''"#
      case "\\": out += #"'\\'"#
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out + "'"
  }

  private static func failure(forExitStatus result: CommandResult, integration: AgentIntegration) -> HookInstallFailure? {
    switch result.exitStatus {
    case 0:
      return nil
    case changedSinceReadExitStatus:
      return .changedSinceRead
    case writeDidNotMatchExitStatus:
      return .writeDidNotMatch
    case notARegularFileExitStatus:
      return .notARegularFile(path: integration.displayPath)
    case checksumFailedExitStatus:
      return .checksumFailed(message: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
    case noConfigDirectoryExitStatus:
      return .noConfigDirectory(path: (integration.displayPath as NSString).deletingLastPathComponent)
    default:
      return .commandFailed(
        exitStatus: result.exitStatus,
        message: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }
  }
}
