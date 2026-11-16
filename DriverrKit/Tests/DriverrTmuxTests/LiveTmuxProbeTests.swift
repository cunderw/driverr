#if os(macOS)
  import DriverrCore
  import Foundation
  import Testing

  @testable import DriverrTmux

  /// `TmuxControl` against a real tmux, on a throwaway server of its own.
  ///
  /// Off unless `DRIVERR_LIVE_TMUX=1`, because it needs tmux installed:
  ///
  /// ```sh
  /// DRIVERR_LIVE_TMUX=1 swift test --package-path DriverrKit --filter LiveTmuxProbe
  /// ```
  ///
  /// The fake checks command strings against a model of tmux, so a flag tmux does not take, or a
  /// semicolon rule that changed, passes there. This runs the same commands through a real `/bin/sh`
  /// into a real server. A wrapper script stands in for `tmux` and adds `-L <socket> -f /dev/null`,
  /// so it never touches the tmux you are using, and the server is killed at the end.
  @Suite(
    "LiveTmuxProbe",
    .enabled(if: ProcessInfo.processInfo.environment["DRIVERR_LIVE_TMUX"] == "1"),
    .serialized
  )
  struct LiveTmuxProbeTests {
    private static let realTmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
      .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Runs `body` against a control on a server of its own, and kills the server after, whether
    /// or not `body` threw. Awaited, so no server outlives the test.
    private func withThrowaway(_ body: (TmuxControl) async throws -> Void) async throws {
      let real = try #require(Self.realTmux, "no tmux installed")
      let directory = try LocalShell.temporaryDirectory()
      let socket = "driverr-probe-\(UUID().uuidString.prefix(8))"
      let wrapper = directory.appendingPathComponent("tmux")
      try "#!/bin/sh\nexec \(real) -L \(socket) -f /dev/null \"$@\"\n"
        .write(to: wrapper, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
      let control = TmuxControl(binaryPath: wrapper.path, run: LocalShell.runner)
      do {
        try await body(control)
      } catch {
        _ = try? await LocalShell.runner("\(shellQuoted(wrapper.path)) kill-server")
        try? FileManager.default.removeItem(at: directory)
        throw error
      }
      _ = try? await LocalShell.runner("\(shellQuoted(wrapper.path)) kill-server")
      try? FileManager.default.removeItem(at: directory)
    }

    /// Waits for a pane to show `text`, because `send-keys` returns before the program echoes.
    private func waitForScreen(
      _ control: TmuxControl, pane: Pane, containing text: String
    ) async throws -> String {
      for _ in 0..<40 {
        let screen = try await control.readScreen(of: pane, lines: 20).text
        if screen.contains(text) { return screen }
        try await Task.sleep(for: .milliseconds(100))
      }
      return try await control.readScreen(of: pane, lines: 20).text
    }

    @Test("a real server lists, takes hostile text through send-keys, reads it back and splits")
    func roundTrip() async throws {
      try await withThrowaway { control in
        #expect(await control.tmuxAvailability().isReady)
        #expect(try await control.snapshot() == .empty, "no server yet is an empty tree")

        let first = try await control.startTerminal()
        let tree = try await control.snapshot()
        let pane = try #require(tree.pane(id: first))
        #expect(tree.workspaces.count == 1)
        #expect(pane.viewportRows != nil)

        // `cat` echoes what it is sent, so the screen shows exactly what arrived.
        let raw = try #require(TmuxID.raw(of: first))
        let started = try await LocalShell.runner(
          "\(shellQuoted(control.binaryPath)) respawn-pane -k -t \(shellQuoted(raw)) cat")
        #expect(started.exitStatus == 0, "\(started.standardError)")

        let texts = ["plain", #"it's "quoted""#, "dollar $HOME", "semi;colon", "ends with;", "héllo ✓"]
        for text in texts {
          try await control.submitText(paneID: first, text: text)
        }
        let screen = try await waitForScreen(control, pane: pane, containing: "héllo ✓")
        for text in texts { #expect(screen.contains(text), "screen: \(screen)") }

        // The title carries non-ASCII text, which tmux prints as `_` without `-u`.
        try await control.perform(.rename("✳ Claude Code"), on: first)
        #expect(try await control.snapshot().pane(id: first)?.title == "Claude Code")

        try await control.perform(.split(.right), on: first)
        let split = try await control.snapshot()
        #expect(split.allPanes.count == 2)

        try await control.rename(.workspace(id: split.workspaces[0].id), to: "probé;")
        #expect(try await control.snapshot().workspaces[0].label == "probé;")

        try await control.perform(.close, on: split.allPanes[1].id)
        #expect(try await control.snapshot().allPanes.count == 1)
      }
    }

    @Test("a refusal from a real tmux is an error a person can read")
    func refusal() async throws {
      try await withThrowaway { control in
        _ = try await control.startTerminal()
        await #expect(throws: AppError.self) {
          try await control.sendText(paneID: "tmux:%999", text: "x")
        }
      }
    }
  }
#endif
