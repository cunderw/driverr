#if os(macOS)
  import DriverrCore
  import DriverrHerdr
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

        // Names that tmux would expand, or read as a flag, are stored as typed. `#(echo hi)` would
        // run a command on the host if it were not escaped.
        let session = split.workspaces[0].id
        let window = split.workspaces[0].tabs[0].id
        for (label, stored) in [
          ("#S", "#S"), ("-x", "-x"), ("a#{pane_id}b", "a#{pane_id}b"), ("#(echo hi)", "#(echo hi)"),
          ("issue #3", "issue #3"), ("two\nlines", "two lines"), ("tab\tseparated", "tab separated"),
          ("bell\u{7}esc\u{1B}del\u{7F}x", "bell esc del x"),
        ] {
          try await control.rename(.workspace(id: session), to: label)
          try await control.rename(.tab(id: window), to: label)
          try await control.perform(.rename(label), on: first)
          let named = try await control.snapshot()
          #expect(named.workspaces[0].label == stored, "session \(label.debugDescription)")
          #expect(named.workspaces[0].tabs[0].label == stored, "window \(label.debugDescription)")
          #expect(named.pane(id: first)?.title == stored, "pane \(label.debugDescription)")
        }

        try await control.perform(.close, on: split.allPanes[1].id)
        #expect(try await control.snapshot().allPanes.count == 1)
      }
    }

    // MARK: The live terminal (#102 S3)

    /// A throwaway server with a session `probe`, 150x44, holding two windows: `@0` current with
    /// `%0`, and `@1` with `%1`. No desk is attached.
    private func withLiveServer(
      resizes: Bool = true,
      _ body: (TmuxControl, _ tmux: @escaping (String) async throws -> String) async throws -> Void
    ) async throws {
      try await withThrowaway { plain in
        let control = TmuxControl(
          binaryPath: plain.binaryPath, run: LocalShell.runner, open: LocalShell.streamRunner,
          resizesWindow: { resizes })
        let tmux: (String) async throws -> String = { arguments in
          let result = try await LocalShell.runner(
            "\(shellQuoted(plain.binaryPath)) -u \(arguments)")
          #expect(result.exitStatus == 0, "tmux \(arguments): \(result.standardError)")
          return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await tmux("new-session -d -s probe -x 150 -y 44")
        _ = try await tmux("new-window -d -t probe")
        let panes = try await tmux("list-panes -a -F '#{pane_id}'")
        #expect(panes == "%0\n%1")
        try await body(control, tmux)
      }
    }

    private func sizes(_ tmux: (String) async throws -> String) async throws -> String {
      try await tmux("list-windows -a -F '#{window_id}:#{window_width}x#{window_height}'")
        .replacingOccurrences(of: "\n", with: " ")
    }

    /// Everything a viewer's output has said, and how it ended.
    private final class Collector: @unchecked Sendable {
      private let lock = NSLock()
      private var bytes = Data()
      private var ending: String?

      init(_ stream: AsyncThrowingStream<Data, any Error>) {
        Task {
          do {
            for try await chunk in stream { lock.withLock { bytes.append(chunk) } }
            lock.withLock { ending = "finished" }
          } catch {
            lock.withLock { ending = "\(error)" }
          }
        }
      }

      var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
      var end: String? { lock.withLock { ending } }

      /// Whether `condition` came true within `seconds`. Callers `#expect` it, so a timeout fails.
      func eventually(_ seconds: Double = 5, _ condition: (Collector) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
          if condition(self) { return true }
          try? await Task.sleep(for: .milliseconds(20))
        }
        return condition(self)
      }
    }

    private static let phone = TerminalSize(columns: 60, rows: 20, pixelWidth: 0, pixelHeight: 0)

    private func attacher(_ control: TmuxControl) throws -> any PaneAttacher {
      try #require(control.paneAttacher(for: "tmux:%0"))
    }

    /// Measured on 3.7c with no desk attached. The attach line sets the client's own size to the
    /// current window's, so the attach changes nothing; `@W:` then sizes only the pane's window,
    /// and `@W:` with no size hands it back to the client's own size. With a desk attached, a
    /// window the desk is not viewing keeps the phone's size instead, until the desk views it
    /// (measured by hand; a desk needs a terminal, which this suite does not start).
    @Test("a controller sizes only its pane's window, and hands it back on release")
    func sizing() async throws {
      try await withLiveServer { control, tmux in
        let attacher = try attacher(control)
        let before = try await sizes(tmux)
        #expect(before == "@0:150x44 @1:150x44")

        let other = try await attacher.open(terminalID: "tmux:%1", size: Self.phone)
        let otherOpen = try await sizes(tmux)
        #expect(otherOpen == "@0:150x44 @1:60x20", "the current window is left alone")
        await other.release()
        let otherReleased = try await sizes(tmux)
        #expect(otherReleased == "@0:150x44 @1:150x44")

        let current = try await attacher.open(terminalID: "tmux:%0", size: Self.phone)
        let currentOpen = try await sizes(tmux)
        #expect(currentOpen == "@0:60x20 @1:150x44")
        try await current.resize(to: TerminalSize(columns: 50, rows: 18, pixelWidth: 0, pixelHeight: 0))
        let resized = try await sizes(tmux)
        #expect(resized == "@0:50x18 @1:150x44")
        await current.release()
        let released = try await sizes(tmux)
        #expect(released == "@0:150x44 @1:150x44", "the current window comes back")
      }
    }

    @Test("with resizing off no window changes size")
    func resizingOff() async throws {
      try await withLiveServer(resizes: false) { control, tmux in
        let attacher = try attacher(control)
        let current = try await attacher.open(terminalID: "tmux:%0", size: Self.phone)
        let other = try await attacher.open(terminalID: "tmux:%1", size: Self.phone)
        try await current.send(text: "true\r")
        try await current.resize(to: TerminalSize(columns: 50, rows: 18, pixelWidth: 0, pixelHeight: 0))
        let open = try await sizes(tmux)
        #expect(open == "@0:150x44 @1:150x44")
        await current.release()
        await other.release()
        let released = try await sizes(tmux)
        #expect(released == "@0:150x44 @1:150x44")
      }
    }

    /// The rule `TmuxAttachment` stands on: output before the paint's last `%end` is already in
    /// the capture, and output after it is not. A pane counting as fast as it can shows a gap
    /// or a repeat at the cut if the rule is wrong.
    @Test("a counting pane's numbers arrive once each and in order, across the paint")
    func ordering() async throws {
      try await withLiveServer { control, tmux in
        _ = try await tmux(
          "respawn-pane -k -t %0 'i=0; while [ $i -lt 200000 ]; do i=$((i+1)); echo n$i; done; sleep 30'")
        try await Task.sleep(for: .milliseconds(100))
        let bridge = try await attacher(control).open(terminalID: "tmux:%0", size: Self.phone)
        let collected = Collector(bridge.output)
        #expect(await collected.eventually(20) { $0.text.contains("n200000") })
        await bridge.release()

        let plain = collected.text.replacingOccurrences(
          of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "\n", options: .regularExpression)
        let numbers = plain.split(whereSeparator: \.isNewline).compactMap { line -> Int? in
          guard line.hasPrefix("n") else { return nil }
          return Int(line.dropFirst())
        }
        let first = try #require(numbers.first)
        #expect(numbers.count > 1000, "the paint and the stream both carried numbers")
        #expect(numbers == Array(first..<(first + numbers.count)), "no repeat and no gap")
        #expect(numbers.last == 200000)
      }
    }

    @Test("typed bytes reach the pane as typed: UTF-8, quotes, a backslash, a semicolon")
    func typing() async throws {
      try await withLiveServer { control, tmux in
        _ = try await tmux("respawn-pane -k -t %0 cat")
        let bridge = try await attacher(control).open(terminalID: "tmux:%0", size: Self.phone)
        let collected = Collector(bridge.output)
        let text = #"é ✓ "it's" \ ; $HOME 😀"#
        try await bridge.send(text: text + "\r")
        #expect(await collected.eventually { $0.text.contains(text) })
        let screen = try await tmux("capture-pane -p -t %0")
        #expect(screen.contains(text), "screen: \(screen)")
        await bridge.release()
      }
    }

    @Test("a pane closed at the desk ends cleanly, as does the session's last one")
    func paneClosed() async throws {
      try await withLiveServer { control, tmux in
        let attacher = try attacher(control)
        let first = Collector(try await attacher.open(terminalID: "tmux:%0", size: Self.phone).output)
        let second = Collector(try await attacher.observe(terminalID: "tmux:%1", size: Self.phone).output)
        _ = try await tmux("kill-pane -t %1")
        #expect(await second.eventually { $0.end != nil })
        #expect(second.end == "finished")
        #expect(first.end == nil)
        _ = try await tmux("kill-session -t probe")
        #expect(await first.eventually { $0.end != nil })
        #expect(first.end == "finished")
      }
    }

    @Test("a client detached at the desk, with its pane still there, is .streamEnded")
    func clientDetached() async throws {
      try await withLiveServer { control, tmux in
        let collected = Collector(
          try await attacher(control).open(terminalID: "tmux:%0", size: Self.phone).output)
        _ = try await tmux("detach-client -s probe")
        #expect(await collected.eventually { $0.end != nil })
        #expect(collected.end == "\(TerminalCloseReason.streamEnded)")
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

    // MARK: Needs You (#102 S4)

    /// A pane running `sleep`, with Claude Code's record for that pid written by hand. S0
    /// measured what Claude writes; this measures that a real `sh`, `ps` and tmux carry it to the
    /// pane. `HOME` is a scratch directory in both cases, so the real `~/.claude` is never read
    /// or written, and the unset case proves the `:-` default.
    @Test(
      "a waiting record for a pane's own pid blocks it on permission, and busy makes it work",
      arguments: [true, false])
    func needsYou(configDirectorySet: Bool) async throws {
      try await withThrowaway { plain in
        let scratch = try LocalShell.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let home = scratch.appendingPathComponent("home")
        let config = scratch.appendingPathComponent("config")
        let sessions =
          configDirectorySet
          ? config.appendingPathComponent("sessions")
          : home.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        var environment = "HOME=\(shellQuoted(home.path)); export HOME; "
        if configDirectorySet {
          environment += "CLAUDE_CONFIG_DIR=\(shellQuoted(config.path)); export CLAUDE_CONFIG_DIR; "
        }
        let run: CommandRunner = { try await LocalShell.runner(environment + $0) }
        let control = TmuxControl(binaryPath: plain.binaryPath, run: run)
        let tmux = shellQuoted(plain.binaryPath)

        let pane = try await control.startTerminal()
        let raw = try #require(TmuxID.raw(of: pane))
        let respawned = try await run(
          "\(tmux) respawn-pane -k -t \(shellQuoted(raw)) 'exec sleep 600'")
        #expect(respawned.exitStatus == 0, "\(respawned.standardError)")
        let shown = try await run("\(tmux) -u display-message -p -t \(shellQuoted(raw)) '#{pane_pid}'")
        let pid = try #require(
          Int(shown.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)),
          "pane_pid: \(shown.standardOutput) \(shown.standardError)")

        let session = UUID().uuidString.lowercased()
        let file = sessions.appendingPathComponent("\(pid).json")
        func write(_ status: String, waitingFor: String? = nil) throws {
          try FakeTmuxHost.claudeRecord(
            pid: pid, sessionID: session, status: status, waitingFor: waitingFor,
            directory: scratch.path
          ).write(to: file, atomically: true, encoding: .utf8)
        }
        /// `respawn-pane` returns before `ps` shows the new process, so poll, then assert.
        func settled(_ status: AgentStatus) async throws -> SessionTree {
          var tree = try await control.snapshot()
          for _ in 0..<40 where tree.pane(id: pane)?.agent?.status != status {
            try await Task.sleep(for: .milliseconds(100))
            tree = try await control.snapshot()
          }
          return tree
        }

        try write("waiting", waitingFor: "permission prompt")
        let waiting = try await settled(.blocked)
        let agent = waiting.pane(id: pane)?.agent
        #expect(agent?.status == .blocked)
        #expect(agent?.blockedKind == .permission)
        #expect(agent?.session?.identifier == session)
        #expect(waiting.blockedPanes.map(\.id) == [pane])

        try write("busy")
        let working = try await settled(.working)
        #expect(working.pane(id: pane)?.agent?.status == .working)
        #expect(working.pane(id: pane)?.agent?.blockedKind == nil)
        #expect(working.blockedPanes.isEmpty)
      }
    }
  }
#endif
