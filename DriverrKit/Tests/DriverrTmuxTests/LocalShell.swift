import DriverrCore
import Foundation

/// A real `/bin/sh`, run as an SSH exec channel runs a command: `-c`, no rc file, no terminal,
/// stdout and stderr apart. Used where a test must see what a real shell makes of a command
/// string, which a fake that parses it itself cannot say.
///
/// A dispatch thread blocks here, never a cooperative one, which Swift Testing's pool cannot
/// spare.
enum LocalShell {
  static let runner: CommandRunner = { command in
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = [
          "HOME": NSHomeDirectory(),
          "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
          try process.run()
          // Read before waiting: a full pipe buffer deadlocks the child.
          let outData = out.fileHandleForReading.readDataToEndOfFile()
          let errData = err.fileHandleForReading.readDataToEndOfFile()
          process.waitUntilExit()
          continuation.resume(
            returning: CommandResult(
              standardOutput: String(decoding: outData, as: UTF8.self),
              standardError: String(decoding: errData, as: UTF8.self),
              exitStatus: Int(process.terminationStatus)
            )
          )
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// An executable that prints each of its arguments followed by a NUL, in place of `tmux`.
  /// The directory is the caller's to delete.
  static func argumentPrinter(in directory: URL) throws -> String {
    let url = directory.appendingPathComponent("tmux")
    let script = "#!/bin/sh\nfor argument in \"$@\"; do printf '%s\\0' \"$argument\"; done\n"
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
  }

  /// A fresh directory under the system temporary one.
  static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("driverr-tmux-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
