import DriverrCore
import Foundation
import Testing

@testable import DriverrHerdr

/// `CLIControl` against the herdr running on this machine.
///
/// Off unless `DRIVERR_LIVE_HERDR=1`, because it needs a herdr server with panes. Run it by
/// hand:
///
/// ```sh
/// DRIVERR_LIVE_HERDR=1 swift test --package-path DriverrKit --filter LiveHerdrProbe
/// ```
///
/// `CLIControlTests` checks command strings against a fake that answers whatever it was
/// told, so a well-formed but wrong flag passes there. A wrong `--source` once returned
/// nothing for half the panes on a real session. This suite is read-only (`api snapshot`
/// and `pane read`), so it is safe against the herdr you are using.
@Suite(
  "LiveHerdrProbe",
  .enabled(if: ProcessInfo.processInfo.environment["DRIVERR_LIVE_HERDR"] == "1")
)
struct LiveHerdrProbeTests {
  /// Runs a command as an SSH exec channel does: `/bin/sh -c`, no rc file, stdout and stderr
  /// captured separately, no terminal. An interactive shell would test a `PATH` and `HERDR_*`
  /// environment the device never gets.
  private static let localRunner: CommandRunner = { command in
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        // No `HERDR_SOCKET_PATH`: the phone never has it, so herdr must find its own socket.
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
          // Read before waiting: a full pipe buffer deadlocks the child, and a session of panes is
          // more than 64 KB.
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

  /// An absolute path, as discovery hands `CLIControl` on a real host. The probe's `PATH`
  /// has neither Homebrew nor `~/.local/bin`.
  private static var binaryPath: String? {
    let candidates =
      [ProcessInfo.processInfo.environment["HERDR_BIN_PATH"]].compactMap { $0 }
      + [
        "\(NSHomeDirectory())/.local/bin/herdr",
        "/opt/homebrew/bin/herdr",
        "/usr/local/bin/herdr",
      ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  private func liveControl() throws -> CLIControl {
    let path = try #require(Self.binaryPath, "no herdr binary found on this machine")
    return CLIControl(binaryPath: path, run: Self.localRunner)
  }

  @Test("the live herdr answers a snapshot, and it maps to a tree with panes in it")
  func snapshotMaps() async throws {
    let tree = try await liveControl().snapshot()

    #expect(!tree.allPanes.isEmpty, "the herdr on this machine has no panes to probe")
    #expect(tree.allPanes.allSatisfy { !$0.id.isEmpty })
  }

  /// Every pane in one batch, as the pane sheet asks. A cleared pane with no prompt would
  /// fail honestly; the regression this guards blanked half the session.
  @Test("every pane on a real session comes back with something to draw")
  func everyLivePaneHasAThumbnail() async throws {
    let control = try liveControl()
    let ids = try await control.snapshot().allPanes.map(\.id)
    try #require(!ids.isEmpty)

    let read = try await control.readPanes(ids: ids, lines: 6)

    let blank = ids.filter { read[$0]?.isEmpty != false }.sorted()
    #expect(
      blank.isEmpty,
      """
      \(blank.count) of \(ids.count) panes read back with no lines at all: \
      \(blank.joined(separator: ", ")). The read is well-formed and exits 0, \
      but it returns nothing for those panes.
      """
    )
  }

  /// `--format ansi` and `pane read` rather than `agent read` only take effect on the far
  /// side. An unstyled read here would lose the message marker.
  @Test("a real agent pane reads back as a styled screen")
  func readsARealAgentPaneScreen() async throws {
    let control = try liveControl()
    let panes = try await control.snapshot().allPanes
    let pane = try #require(
      panes.first { $0.agent != nil },
      "the herdr on this machine has no agent pane to probe"
    )

    let screen = try await control.readScreen(of: pane, lines: 30)

    #expect(!screen.isEmpty)
    #expect(screen.lines.count <= 30)
    #expect(!screen.text.unicodeScalars.contains { $0.value == 0x1B })
    #expect(
      screen.lines.contains { line in line.spans.contains { $0.style.foreground != nil } },
      """
      the screen came back with no styling anywhere in it, which is exactly what \
      `--format text` looks like from this side
      """
    )
  }

  /// Without a viewport the read passes no `--lines`, and the bound would go untested.
  @Test("a real agent pane reports the viewport that bounds the read")
  func realAgentPanesReportAViewport() async throws {
    let control = try liveControl()
    let panes = try await control.snapshot().allPanes.filter { $0.agent != nil }
    try #require(!panes.isEmpty)

    let unbounded = panes.filter { $0.viewportRows == nil }.map(\.id).sorted()
    #expect(
      unbounded.isEmpty,
      "\(unbounded.count) agent panes reported no scroll.viewport_rows: \(unbounded.joined(separator: ", "))"
    )
  }

  /// Six is what the sheet draws; sixty would cost ten times the budget.
  @Test("a read is bounded by the line count it asked for")
  func readsAreBounded() async throws {
    let control = try liveControl()
    let ids = try await control.snapshot().allPanes.map(\.id)
    try #require(!ids.isEmpty)

    let read = try await control.readPanes(ids: ids, lines: 6)

    #expect(read.values.allSatisfy { $0.count <= 6 })
  }
}
