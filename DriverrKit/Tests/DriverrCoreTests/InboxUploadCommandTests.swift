import Foundation
import Testing

@testable import DriverrCore

/// The command is a string run by `/bin/sh` on the user's host, so a hostile file name
/// must not become syntax, and the steps must run in the order atomicity depends on.
@Suite("Inbox upload command")
struct InboxUploadCommandTests {
  /// Unquoted, the apostrophe would close the quoting and the space would split the word.
  @Test("a file name with a quote and a space is quoted, not interpolated raw")
  func quotesAHostileFileName() {
    let command = InboxUploadCommand.forUpload(fileName: "it's a photo.png", byteCount: 10)

    // POSIX: end the quote, escape the apostrophe, start a new quote.
    #expect(command.script.contains(#"'it'\''s a photo.png'"#))
    // The bare form is what a naive builder emits.
    #expect(!command.script.contains("/it's a photo.png"))
  }

  /// A sweep after the write could delete the upload or run while the `.part` exists.
  /// `-mmin +1440` rather than `-mtime +1`, because `find` truncates `-mtime` to whole days
  /// and `+1` keeps everything under 48 hours.
  @Test("the sweep runs before the write")
  func sweepsBeforeWriting() throws {
    let command = InboxUploadCommand.forUpload(fileName: "a.png", byteCount: 10)
    let script = command.script

    let sweep = try #require(script.range(of: "-mmin +1440 -delete"))
    let write = try #require(script.range(of: "head -c"))
    #expect(sweep.lowerBound < write.lowerBound)
  }

  /// This order is why an agent on the host never reads a half-written image.
  @Test("bytes land on .part and are renamed only after the size check")
  func writesToPartThenRenames() throws {
    let command = InboxUploadCommand.forUpload(fileName: "a.png", byteCount: 4096)
    let script = command.script

    let write = try #require(script.range(of: #"head -c 4096 > "$p".part"#))
    let check = try #require(script.range(of: #"[ "$(wc -c < "$p".part)" -eq 4096 ]"#))
    let rename = try #require(script.range(of: #"mv "$p".part "$p""#))

    #expect(write.lowerBound < check.lowerBound)
    #expect(check.lowerBound < rename.lowerBound)
  }

  /// Its own status lets the client tell "the bytes arrived short" from "the disk is full".
  @Test("the size check exits with its own status")
  func sizeMismatchHasItsOwnExitStatus() {
    let command = InboxUploadCommand.forUpload(fileName: "a.png", byteCount: 10)
    #expect(command.script.contains("|| exit \(InboxUploadCommand.sizeMismatchExitStatus)"))
    #expect(InboxUploadCommand.sizeMismatchExitStatus != 0)
    #expect(InboxUploadCommand.sizeMismatchExitStatus != 1)
    // 126 and 127 are the shell's "cannot execute" and "not found".
    #expect(InboxUploadCommand.sizeMismatchExitStatus != 126)
    #expect(InboxUploadCommand.sizeMismatchExitStatus != 127)
  }

  /// A quoted tilde makes a directory literally named `~`.
  @Test("the default inbox expands $HOME rather than quoting a tilde")
  func defaultInboxExpandsHome() {
    let command = InboxUploadCommand.forUpload(fileName: "a.png", byteCount: 10)
    #expect(command.script.contains(#""$HOME/.driverr/inbox""#))
    #expect(!command.script.contains("'~"))
    #expect(!command.script.contains("~/.driverr"))
  }

  /// Created 0700 by `umask`, never widened and narrowed afterwards.
  @Test("umask precedes mkdir")
  func umaskPrecedesMkdir() throws {
    let script = InboxUploadCommand.forUpload(fileName: "a.png", byteCount: 10).script
    let umask = try #require(script.range(of: "umask 077"))
    let mkdir = try #require(script.range(of: "mkdir -p"))
    #expect(umask.lowerBound < mkdir.lowerBound)
  }

  /// If the sweep ignored the explicit path, an upload to a temp inbox would sweep the user's.
  @Test("an explicit inbox directory is used by the sweep and the write alike")
  func honoursAnExplicitInbox() {
    let command = InboxUploadCommand.forUpload(
      fileName: "a.png",
      byteCount: 10,
      inboxDirectory: shellQuoted("/tmp/an inbox")
    )
    #expect(command.script.contains("mkdir -p '/tmp/an inbox'"))
    #expect(command.script.contains("find '/tmp/an inbox' -type f -mmin +1440 -delete"))
    #expect(command.script.contains("p='/tmp/an inbox'/a.png"))
    #expect(!command.script.contains("$HOME"))
  }

  /// A mismatch would hang the upload.
  @Test("the reported byte count is the one in the command")
  func byteCountMatchesTheCommand() {
    let command = InboxUploadCommand.forUpload(fileName: "a.png", byteCount: 32_768)
    #expect(command.byteCount == 32_768)
    #expect(command.script.contains("head -c 32768"))
  }

  /// It must not reach `head -c` as an unparseable option.
  @Test("a negative byte count is clamped rather than passed through")
  func clampsANegativeCount() {
    let command = InboxUploadCommand.forUpload(fileName: "a.png", byteCount: -5)
    #expect(command.byteCount == 0)
    #expect(!command.script.contains("-c -5"))
  }

  /// The client cannot expand `$HOME`.
  @Test("the resolved path is printed on stdout")
  func printsTheResolvedPath() throws {
    let script = InboxUploadCommand.forUpload(fileName: "a.png", byteCount: 10).script
    let rename = try #require(script.range(of: #"mv "$p".part "$p""#))
    let printed = try #require(script.range(of: #"printf '%s\n' "$p""#))
    #expect(rename.lowerBound < printed.lowerBound)
  }
}
