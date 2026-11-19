import DriverrCore
import DriverrHerdr
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

  /// Starts a long-lived `/bin/sh -c`, as an SSH exec stream does: stdin, stdout and stderr are
  /// pipes and there is no terminal. The environment is the runner's, so no `TERM` either.
  static let streamRunner: StreamRunner = { command in try LocalShellStream(command: command) }

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

/// One `/bin/sh -c` with its pipes, as a `HerdrStream`. Reads arrive on the file handle's own
/// queue and writes go out on a dispatch queue, so no cooperative thread ever blocks.
final class LocalShellStream: HerdrStream, @unchecked Sendable {
  let output: AsyncThrowingStream<Data, any Error>
  private let process = Process()
  private let input = Pipe()
  private let writes = DispatchQueue(label: "LocalShellStream.writes")

  init(command: String) throws {
    let (output, continuation) = AsyncThrowingStream.makeStream(
      of: Data.self, throwing: (any Error).self)
    self.output = output
    let out = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    process.standardInput = input
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    out.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        continuation.finish()
      } else {
        continuation.yield(data)
      }
    }
    try process.run()
  }

  var end: ProcessEnd? {
    get async {
      guard !process.isRunning else { return nil }
      return ProcessEnd(exitStatus: Int(process.terminationStatus), standardErrorTail: "")
    }
  }

  func send(_ data: Data) async throws {
    let handle = input.fileHandleForWriting
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
      writes.async {
        do {
          try handle.write(contentsOf: data)
          done.resume()
        } catch {
          done.resume(throwing: error)
        }
      }
    }
  }

  /// Closing stdin is how a control client is told to leave.
  func close() async {
    writes.async { [input] in try? input.fileHandleForWriting.close() }
  }
}
