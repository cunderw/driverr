import Foundation
import Testing

@testable import DriverrCore

/// `LoginShell.posix` is how every command Driverr writes reaches the user's login shell.
/// These tests read the command back the way fish does, and run it through each POSIX shell
/// the exec channel can land in. No test needs fish installed.
@Suite("LoginShell")
struct LoginShellTests {
  /// Values that end a POSIX single-quoted word early under fish: a backslash before a
  /// quote, and a backslash before a backslash.
  static let hostileValues = [#"a\\b"#, #"it\'s"#, #"/srv/a\'; touch p; #"#, #"\"#]

  /// The one word after `sh -c `, read with fish's rules: inside single quotes, `\'` is a
  /// quote and `\\` is a backslash, and any other `\` is literal. Outside quotes, `\` escapes
  /// the next character. `nil` when the command is not `sh -c` and exactly one word.
  ///
  /// Copied from `DirectoryListingTests`. A quoting that only bash, zsh and dash read back
  /// correctly fails here.
  private static func fishWord(afterShC command: String) -> String? {
    guard command.hasPrefix("sh -c ") else { return nil }
    var word = ""
    var quoted = false
    var scalars = command.dropFirst("sh -c ".count).unicodeScalars.makeIterator()
    while let scalar = scalars.next() {
      if scalar == "'" {
        quoted.toggle()
      } else if scalar == "\\" {
        guard let next = scalars.next() else { return nil }
        if quoted, next != "'", next != "\\" { word.unicodeScalars.append(scalar) }
        word.unicodeScalars.append(next)
      } else {
        guard quoted else { return nil }
        word.unicodeScalars.append(scalar)
      }
    }
    return quoted ? nil : word
  }

  /// A script that prints `value` exactly, with POSIX quoting inside it.
  private static func printing(_ value: String) -> String {
    "printf '%s' " + shellQuoted(value)
  }

  @Test("a script goes to the login shell as one sh -c word")
  func prefix() {
    #expect(LoginShell.posix("herdr --version") == "sh -c 'herdr --version'")
  }

  @Test("a value with a backslash and a quote reaches sh as one literal word, even through fish", arguments: hostileValues)
  func fishSafeWord(value: String) {
    let script = Self.printing(value)
    #expect(Self.fishWord(afterShC: LoginShell.posix(script)) == script)
  }

  /// Runs the wrapped command as the exec channel hands it to a login shell, and checks
  /// that `sh` printed the value unchanged.
  @Test(
    "each POSIX login shell runs the wrapped script unchanged",
    arguments: ["/bin/zsh", "/bin/sh", "/bin/bash", "/bin/dash"], hostileValues)
  func posixShellsRunTheScript(shell: String, value: String) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-c", LoginShell.posix(Self.printing(value))]
    process.environment = ["PATH": "/usr/bin:/bin"]
    let output = Pipe()
    process.standardOutput = output
    // Waits on the termination handler rather than `waitUntilExit()`, so no cooperative
    // thread blocks (CLAUDE.md, "Never block a cooperative thread in a Kit test").
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do { try process.run() } catch { continuation.resume(throwing: error) }
    }
    let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(status == 0)
    #expect(printed == value)
  }
}
