import Foundation

/// Why a key was not added to `~/.ssh/authorized_keys`, or not for certain.
public enum AuthorizedKeyInstallFailure: Error, Hashable, Sendable {
  /// `~/.ssh` or `authorized_keys` exists and is not a directory or a regular file, or the
  /// file is a symbolic link to nothing. Driverr does not replace it.
  case notARegularFile
  /// `~/.ssh` did not exist and could not be made.
  case couldNotCreateDirectory(message: String)
  /// `authorized_keys` exists and could not be read, so Driverr cannot tell whether the key
  /// is already there.
  case unreadable(message: String)
  /// The append failed on a read-only file system.
  case readOnlyFileSystem
  /// The append failed because the disk is full. A partial line may remain; sshd skips it,
  /// and the next install adds a newline before appending.
  case diskFull
  /// The append failed for another reason, or the key was not in the file after it.
  case writeFailed(message: String)
  /// The host's shell could not find or run a tool the install needs (126 or 127).
  case missingTool(message: String)
  /// Any other failure: the host's exit status and what it wrote to stderr.
  case commandFailed(exitStatus: Int, message: String)
}

/// The one shell command that adds a public key to `~/.ssh/authorized_keys`.
///
/// It runs only `sh`, `mkdir`, `tail` and `awk`, which any sshd host has, and checks for
/// them before touching anything (exit 127 naming the missing one). `restorecon`, when
/// present, labels only what the install created, never with `-F`, so existing SELinux
/// labels stay.
///
/// It matches on the key's base64 blob, not the line, so a renamed key or one with an
/// options prefix such as `restrict,from="…"` counts as present and a rerun changes nothing.
///
/// It changes no mode on anything that exists. `umask 077` makes a new `~/.ssh` 0700 and a
/// new file 0600, as sshd's `StrictModes` expects. A file without a final newline gets one
/// before the key, or the key would join the last line.
///
/// A symlink to a regular file is followed, because people keep this file in dotfiles. A
/// dangling symlink is refused, because the append would create a file wherever it points.
///
/// Quoted for the login shell as `HookInstallCommands` explains. Exit statuses are from
/// `sysexits.h`.
public enum AuthorizedKeyInstallCommands {
  /// `EX_NOPERM`: something that is not a regular file or directory is in the way.
  public static let notARegularFileExitStatus = 77
  /// `EX_CANTCREAT`: `~/.ssh` could not be made.
  public static let couldNotCreateDirectoryExitStatus = 73
  /// `EX_NOINPUT`: the file could not be read.
  public static let unreadableExitStatus = 66
  /// `EX_IOERR`: the append failed, or the key is not in the file after it.
  public static let writeFailedExitStatus = 74

  static let installedOutput = "installed"
  static let presentOutput = "present"

  /// The command that adds `identity`'s public key, or reports that it is already there.
  public static func install(_ identity: SSHIdentity) -> String {
    // Base64 has no `'`, so plain single quotes hold it.
    let blob = identity.publicKeyBlob.base64EncodedString()
    let lines = [
      "LC_ALL=C; export LC_ALL; umask 077",
      "for t in mkdir tail awk; do command -v $t >/dev/null 2>&1 || { echo \"$t: not found\" >&2; exit 127; }; done",
      "b='\(blob)'; line=\(shellQuoted(authorizedKeysLine(for: identity)))",
      "d=\"$HOME/.ssh\"; f=\"$d/authorized_keys\"",
      "md=; mf=",
      "if [ ! -d \"$d\" ]; then [ -e \"$d\" ] && exit \(notARegularFileExitStatus); mkdir \"$d\" || exit \(couldNotCreateDirectoryExitStatus); md=1; fi",
      "if [ -L \"$f\" ] && [ ! -e \"$f\" ]; then exit \(notARegularFileExitStatus); fi",
      "if [ -e \"$f\" ] && [ ! -f \"$f\" ]; then exit \(notARegularFileExitStatus); fi",
      "has() { awk -v b=\"$b\" '{for(i=1;i<=NF;i++)if($i==b){x=1;exit}}END{exit !x}' \"$f\"; }",
      "if [ -e \"$f\" ]; then has; s=$?; [ $s = 0 ] && { echo \(presentOutput); exit 0; }; [ $s = 1 ] || exit \(unreadableExitStatus); else mf=1; fi",
      "{ [ -z \"$(tail -c 1 \"$f\" 2>/dev/null)\" ] || printf '\\n'; printf '%s\\n' \"$line\"; } >> \"$f\" || exit \(writeFailedExitStatus)",
      "has || exit \(writeFailedExitStatus)",
      "if command -v restorecon >/dev/null 2>&1; then { [ -z \"$md\" ] || restorecon \"$d\"; [ -z \"$mf\" ] || restorecon \"$f\"; } 2>/dev/null; fi",
      "echo \(installedOutput)",
    ]
    return "sh -c " + HookInstallCommands.loginShellQuoted(lines.joined(separator: "\n"))
  }

  /// The line appended: algorithm, blob and the key's name as its comment.
  ///
  /// Every control character is removed from the comment, including inside it, or a newline
  /// in the key's name would start a second line. `SSHIdentity.authorizedKeysLine` trims only
  /// the ends, so it is not used.
  public static func authorizedKeysLine(for identity: SSHIdentity) -> String {
    let scalars = identity.name.unicodeScalars.filter { !$0.properties.generalCategory.isControl }
    let comment = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    let base = "\(identity.algorithm) \(identity.publicKeyBlob.base64EncodedString())"
    return comment.isEmpty ? base : "\(base) \(comment)"
  }

  /// What the command did, or why it did not.
  ///
  /// The last line of stdout is the answer, because a login shell's rc file can print first.
  public static func outcome(of result: CommandResult) throws(AuthorizedKeyInstallFailure) -> KeyInstallOutcome {
    let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
    switch result.exitStatus {
    case 0:
      let last = result.standardOutput.split(whereSeparator: \.isNewline).last.map(String.init)
      switch last?.trimmingCharacters(in: .whitespaces) {
      case installedOutput: return .installed
      case presentOutput: return .alreadyInstalled
      default: throw .commandFailed(exitStatus: 0, message: message)
      }
    case notARegularFileExitStatus:
      throw .notARegularFile
    case couldNotCreateDirectoryExitStatus:
      throw .couldNotCreateDirectory(message: message)
    case unreadableExitStatus:
      throw .unreadable(message: message)
    case writeFailedExitStatus:
      if message.localizedCaseInsensitiveContains("Read-only file system") { throw .readOnlyFileSystem }
      if message.localizedCaseInsensitiveContains("No space left on device") { throw .diskFull }
      throw .writeFailed(message: message)
    case 126, 127:
      throw .missingTool(message: message)
    default:
      throw .commandFailed(exitStatus: result.exitStatus, message: message)
    }
  }
}

private extension Unicode.GeneralCategory {
  var isControl: Bool {
    switch self {
    case .control, .format, .lineSeparator, .paragraphSeparator: true
    default: false
    }
  }
}
