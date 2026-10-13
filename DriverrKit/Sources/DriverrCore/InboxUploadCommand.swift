import Foundation

/// The `/bin/sh` command that receives one file's bytes on stdin and lands them in the
/// host's Driverr inbox, atomically.
///
/// Length-bounded because there is no half-close of stdin on Driverr's SSH exec channel:
/// `ExecStream.close()` closes the whole channel. A receiver reading to EOF would never
/// finish and the exit status would never arrive. `head -c <bytes>` stops at an exact count,
/// so the command exits while the channel is still open.
///
/// Written to `.part` and then `mv`, which is atomic within one directory, so the agent
/// given the path never reads a half-written file.
///
/// Each upload first deletes inbox files older than 24 hours. `~/.driverr/inbox` is ours and
/// nothing else clears it, and this needs no daemon or setting. The sweep runs before the
/// write, so the new file is never swept. It uses `-mmin +1440`, not `-mtime +1`: `find`
/// truncates `-mtime` to whole days, so `+1` keeps files up to 48 hours old.
public struct InboxUploadCommand: Sendable, Hashable {
  /// The exact text to run, as one `/bin/sh` command.
  public let script: String
  /// How many bytes the caller must write to stdin, exactly. The command reads this many
  /// and exits.
  public let byteCount: Int

  public init(script: String, byteCount: Int) {
    self.script = script
    self.byteCount = byteCount
  }

  /// The exit status of the size check, distinct from other failures, so "arrived short" is
  /// not reported as "disk full". 65 is `EX_DATAERR` from `sysexits.h`, clear of the shell's
  /// own 1–2, 126 and 127.
  public static let sizeMismatchExitStatus = 65

  /// The inbox as a shell word, not a path. `shellQuoted("~/.driverr/inbox")` would quote
  /// the tilde and create a directory literally named `~`. `$HOME` in double quotes expands
  /// and survives a space in the home path.
  public static let defaultInboxDirectory = "\"$HOME/.driverr/inbox\""

  /// Builds the command for one file.
  ///
  /// - Parameters:
  ///   - fileName: the name to create inside the inbox, quoted here so it is an argument and
  ///     never syntax. Driverr passes a UUID plus `.png`, but this does not assume it.
  ///   - byteCount: the exact size of the payload the caller will write to stdin.
  ///   - inboxDirectory: an already-quoted shell word for the directory, defaulting to
  ///     ``defaultInboxDirectory``. A shell word, so the default can expand `$HOME` on the
  ///     host. Pass `shellQuoted(path)` for a literal path.
  public static func forUpload(
    fileName: String,
    byteCount: Int,
    inboxDirectory: String = InboxUploadCommand.defaultInboxDirectory
  ) -> InboxUploadCommand {
    let directory = inboxDirectory
    let destination = directory + "/" + shellQuoted(fileName)
    // Clamped: `head -c -1` is an error, not a zero-byte read.
    let byteCount = max(0, byteCount)
    // `umask 077` before `mkdir -p`, so the directory is created 0700 with no readable
    // window. The sweep's errors are ignored, so one unreadable entry cannot fail the
    // upload. `p` holds the destination once, avoiding nested quotes in `"$( … )"`.
    let lines = [
      "umask 077",
      "mkdir -p \(directory) || exit 1",
      "find \(directory) -type f -mmin +1440 -delete 2>/dev/null",
      "p=\(destination)",
      "head -c \(byteCount) > \"$p\".part || exit 1",
      "[ \"$(wc -c < \"$p\".part)\" -eq \(byteCount) ] || exit \(sizeMismatchExitStatus)",
      "mv \"$p\".part \"$p\" || exit 1",
      // The host prints the resolved path, since only it can expand `$HOME`. This is what
      // the agent is given.
      "printf '%s\\n' \"$p\"",
    ]
    return InboxUploadCommand(script: lines.joined(separator: "; "), byteCount: byteCount)
  }
}
