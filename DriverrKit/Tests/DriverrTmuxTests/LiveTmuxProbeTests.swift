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
  ///
  /// `DRIVERR_LIVE_TMUX_BINARY` names another tmux to run it against. tmux 3.2a, built from its
  /// release tarball, is how the pre-3.3 cases below were measured:
  ///
  /// ```sh
  /// DRIVERR_LIVE_TMUX=1 DRIVERR_LIVE_TMUX_BINARY=/path/to/tmux-3.2a/tmux \
  ///   swift test --package-path DriverrKit --filter LiveTmuxProbe
  /// ```
  @Suite(
    "LiveTmuxProbe",
    .enabled(if: ProcessInfo.processInfo.environment["DRIVERR_LIVE_TMUX"] == "1"),
    .serialized
  )
  struct LiveTmuxProbeTests {
    /// `DRIVERR_LIVE_TMUX_BINARY` runs the suite against another tmux, such as a 3.2a built from
    /// its release tarball.
    private static let realTmux =
      ([ProcessInfo.processInfo.environment["DRIVERR_LIVE_TMUX_BINARY"]].compactMap { $0 }
      + ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"])
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
    ///
    /// tmux 3.2a leaves a detached session's first window at 80x23 whatever `-x` and `-y` say,
    /// so `newSession` sizes it by hand, and unsets the `manual` that `resize-window` leaves.
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
        try await newSession("probe", tmux)
        _ = try await tmux("new-window -d -t probe")
        let panes = try await tmux("list-panes -a -F '#{pane_id}'")
        #expect(panes == "%0\n%1")
        try await body(control, tmux)
      }
    }

    private func newSession(_ name: String, _ tmux: (String) async throws -> String) async throws {
      _ = try await tmux("new-session -d -s \(name) -x 150 -y 44")
      let window = try await tmux("display-message -p -t \(name): '#{window_id}'")
      _ = try await tmux("resize-window -t \(window) -x 150 -y 44")
      _ = try await tmux("set-option -w -u -t \(window) window-size")
    }

    /// Whether this tmux sizes one window for a control client, which 3.3 and later do.
    private func sizesOneWindow(_ tmux: (String) async throws -> String) async throws -> Bool {
      let version = try await tmux("-V")
      let number = version.split(separator: " ").last.map { $0.prefix { $0.isNumber || $0 == "." } }
      let parts = (number ?? "").split(separator: ".").compactMap { Int($0) }
      let found = try #require(parts.count >= 2 ? (parts[0], parts[1]) : nil, "version: \(version)")
      return found >= (3, 3)
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
    ///
    /// On 3.2a nothing changes size: the first window size answers `bad size argument`.
    @Test("a controller sizes only its pane's window, and hands it back on release")
    func sizing() async throws {
      try await withLiveServer { control, tmux in
        let sized = try await sizesOneWindow(tmux)
        let attacher = try attacher(control)
        let before = try await sizes(tmux)
        #expect(before == "@0:150x44 @1:150x44")

        let other = try await attacher.open(terminalID: "tmux:%1", size: Self.phone)
        let otherOpen = try await sizes(tmux)
        #expect(otherOpen == (sized ? "@0:150x44 @1:60x20" : before), "the current window is left alone")
        await other.release()
        let otherReleased = try await sizes(tmux)
        #expect(otherReleased == "@0:150x44 @1:150x44")

        let current = try await attacher.open(terminalID: "tmux:%0", size: Self.phone)
        let currentOpen = try await sizes(tmux)
        #expect(currentOpen == (sized ? "@0:60x20 @1:150x44" : before))
        try await current.resize(to: TerminalSize(columns: 50, rows: 18, pixelWidth: 0, pixelHeight: 0))
        let resized = try await sizes(tmux)
        #expect(resized == (sized ? "@0:50x18 @1:150x44" : before))
        await current.release()
        let released = try await sizes(tmux)
        #expect(released == "@0:150x44 @1:150x44", "the current window comes back")
      }
    }

    // MARK: Window sizes with a desk (#115, #116)

    /// A real client on a terminal, as a person at the desk has: `tmux attach` on a pty from
    /// Python's `pty`, sized with `TIOCSWINSZ`. Its stdin takes `size C R` and `keys HEX`.
    private final class Desk: @unchecked Sendable {
      private let process: LocalShellStream
      private let tmux: (String) async throws -> String

      static let script = """
        import fcntl, os, pty, signal, struct, sys, termios, threading
        pid, fd = pty.fork()
        if pid == 0:
            os.environ["TERM"] = "xterm-256color"
            os.execv(sys.argv[1], [sys.argv[1], "attach", "-t", sys.argv[2]])
        def size(columns, rows):
            fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", int(rows), int(columns), 0, 0))
            os.kill(pid, signal.SIGWINCH)
        size(sys.argv[3], sys.argv[4])
        def drain():
            while True:
                try:
                    if not os.read(fd, 65536): break
                except OSError:
                    break
        threading.Thread(target=drain, daemon=True).start()
        for line in sys.stdin:
            words = line.split()
            if words[0] == "size": size(words[1], words[2])
            elif words[0] == "keys": os.write(fd, bytes.fromhex(words[1]))
        os.kill(pid, signal.SIGTERM)
        """

      /// Attaches to `target` at `columns` by `rows`, and returns once tmux has the client.
      init(
        binaryPath: String, target: String, columns: Int, rows: Int,
        tmux: @escaping (String) async throws -> String
      ) async throws {
        self.tmux = tmux
        process = try LocalShellStream(
          command: "/usr/bin/python3 -c \(shellQuoted(Self.script)) \(shellQuoted(binaryPath)) "
            + "\(shellQuoted(target)) \(columns) \(rows)")
        try await settle(columns: columns, rows: rows)
      }

      func resize(columns: Int, rows: Int) async throws {
        try await process.send(Data("size \(columns) \(rows)\n".utf8))
        try await settle(columns: columns, rows: rows)
      }

      /// Types `hex` at the desk. `026e` is the prefix and `n`, the next window.
      func keys(_ hex: String) async throws {
        try await process.send(Data("keys \(hex)\n".utf8))
      }

      func close() async { await process.close() }

      /// Waits for tmux to report the desk at this size, and throws if it never does. tmux
      /// sizes the windows in the same pass as the client, so they are settled too.
      private func settle(columns: Int, rows: Int) async throws {
        var clients = ""
        for _ in 0..<100 {
          clients = try await tmux(
            "list-clients -F '#{client_control_mode} #{client_width}x#{client_height}'")
          if clients.split(separator: "\n").contains("0 \(columns)x\(rows)") { return }
          try await Task.sleep(for: .milliseconds(50))
        }
        throw NotSized(clients: clients)
      }

      struct NotSized: Error {
        let clients: String
      }
    }

    /// Polls the window sizes until they read `expected`, then answers what they read.
    private func sizes(
      _ tmux: (String) async throws -> String, settlingAt expected: String
    ) async throws -> String {
      for _ in 0..<100 {
        let now = try await sizes(tmux)
        if now == expected { return now }
        try await Task.sleep(for: .milliseconds(50))
      }
      return try await sizes(tmux)
    }

    /// Measured on 3.7c: `@W:` alone leaves a window the desk is not viewing at the phone's size,
    /// and `@W:P ; @W:` gives it back at `P`. The desk still takes the window over
    /// when it views it.
    @Test("with a desk attached, a window it is not viewing comes back at its own size")
    func handBackWithADesk() async throws {
      try await withLiveServer { control, tmux in
        let sized = try await sizesOneWindow(tmux)
        let desk = try await Desk(
          binaryPath: control.binaryPath, target: "probe", columns: 150, rows: 45, tmux: tmux)
        defer { Task { await desk.close() } }
        #expect(try await sizes(tmux) == "@0:150x44 @1:150x44")

        let bridge = try await attacher(control).open(terminalID: "tmux:%1", size: Self.phone)
        #expect(try await sizes(tmux) == (sized ? "@0:150x44 @1:60x20" : "@0:150x44 @1:150x44"))
        await bridge.release()
        #expect(try await sizes(tmux) == "@0:150x44 @1:150x44", "back with the desk on @0")

        try await desk.resize(columns: 170, rows: 41)
        try await desk.keys("026e")
        let viewed = try await sizes(tmux, settlingAt: "@0:170x40 @1:170x40")
        #expect(viewed == "@0:170x40 @1:170x40", "the desk takes the window over")
      }
    }

    /// Two controllers on one window, as two iPad scenes on one pane.
    @Test("two controllers on one window: the newest size holds, and the first comes back")
    func twoControllers() async throws {
      try await withLiveServer { control, tmux in
        let sized = try await sizesOneWindow(tmux)
        let desk = try await Desk(
          binaryPath: control.binaryPath, target: "probe", columns: 150, rows: 45, tmux: tmux)
        defer { Task { await desk.close() } }
        let attacher = try attacher(control)
        let first = try await attacher.open(terminalID: "tmux:%1", size: Self.phone)
        let second = try await attacher.open(
          terminalID: "tmux:%1", size: TerminalSize(columns: 50, rows: 18, pixelWidth: 0, pixelHeight: 0))
        #expect(try await sizes(tmux) == (sized ? "@0:150x44 @1:50x18" : "@0:150x44 @1:150x44"))
        await second.release()
        #expect(try await sizes(tmux) == (sized ? "@0:150x44 @1:60x20" : "@0:150x44 @1:150x44"))
        await first.release()
        #expect(try await sizes(tmux) == "@0:150x44 @1:150x44")
      }
    }

    /// The attach line's client size holds the whole session's windows before 3.3. Under
    /// `window-size smallest` with a desk, 3.2a held `@0` at 150x44 when the desk grew unless
    /// `@W:` went first. On 3.7c it still does, with or without it: the limit `TmuxAttacher`'s
    /// comment records.
    @Test("under window-size smallest, a desk that grows keeps its window only before 3.3")
    func attachLineUnderSmallest() async throws {
      try await withLiveServer { control, tmux in
        let sized = try await sizesOneWindow(tmux)
        _ = try await tmux("set-option -g window-size smallest")
        let desk = try await Desk(
          binaryPath: control.binaryPath, target: "probe", columns: 150, rows: 45, tmux: tmux)
        defer { Task { await desk.close() } }
        let bridge = try await attacher(control).open(terminalID: "tmux:%1", size: Self.phone)
        let collected = Collector(bridge.output)
        try await desk.resize(columns: 200, rows: 51)
        let expected = sized ? "@0:150x44 @1:60x20" : "@0:200x50 @1:150x44"
        let grown = try await sizes(tmux, settlingAt: expected)
        #expect(grown == expected)
        #expect(await collected.eventually { $0.text.contains("\u{1B}[") }, "the pane opened")
        await bridge.release()
      }
    }

    // MARK: Sessions (#117)

    /// Measured on 3.2a and 3.7c: the old session's client hears `%layout-change` after
    /// `join-pane`, and `%unlinked-window-close` after `move-window`, and none of the pane's
    /// output after either.
    @Test(
      "a pane moved to another session keeps its output, and its window comes back on release",
      arguments: ["join-pane -d -s %1 -t %2", "move-window -d -s @1 -t other:"])
    func movedToAnotherSession(move: String) async throws {
      try await withLiveServer { control, tmux in
        let sized = try await sizesOneWindow(tmux)
        try await newSession("other", tmux)
        _ = try await tmux("respawn-pane -k -t %1 cat")
        let bridge = try await attacher(control).open(terminalID: "tmux:%1", size: Self.phone)
        let collected = Collector(bridge.output)
        #expect(await collected.eventually { $0.text.contains("\u{1B}[") }, "the first paint")

        _ = try await tmux(move)
        #expect(
          await collected.eventually { $0.text.contains("\u{1B}[2J\u{1B}[3J") },
          "painted again, from the other session's client")
        #expect(try await tmux("display-message -p -t %1 '#{session_name}'") == "other")
        let window = try await tmux("display-message -p -t %1 '#{window_width}x#{window_height}'")
        #expect(window == (sized ? "60x20" : "150x44"))

        _ = try await tmux("send-keys -t %1 -l moved-and-heard")
        #expect(await collected.eventually { $0.text.contains("moved-and-heard") })
        #expect(collected.end == nil)

        await bridge.release()
        let released = try await tmux("display-message -p -t %1 '#{window_width}x#{window_height}'")
        #expect(released == "150x44")
      }
    }

    /// Measured on 3.2a and 3.7c: moving a session's last pane away sends that session's client
    /// `%layout-change` and then `%exit`. The check written between them may or may not be
    /// answered, so the viewer either follows the pane or ends `.streamEnded`, which the scene
    /// reattaches. It must never end as a closed pane.
    @Test("a session's last pane moved to another session is followed or reattached, never closed")
    func lastPaneMoved() async throws {
      try await withLiveServer { control, tmux in
        try await newSession("solo", tmux)
        try await newSession("other", tmux)
        let solo = try await tmux("list-panes -t solo -F '#{pane_id}'")
        let target = try await tmux("list-panes -t other -F '#{pane_id}'")
        _ = try await tmux("respawn-pane -k -t \(solo) cat")
        let bridge = try await attacher(control).open(terminalID: "tmux:\(solo)", size: Self.phone)
        let collected = Collector(bridge.output)
        #expect(await collected.eventually { $0.text.contains("\u{1B}[") }, "the first paint")

        _ = try await tmux("join-pane -d -s \(solo) -t \(target)")
        #expect(
          await collected.eventually {
            $0.end != nil || $0.text.contains("\u{1B}[2J\u{1B}[3J")
          })
        #expect(collected.end != "finished", "the pane is alive, in the other session")
        if collected.end == nil {
          _ = try await tmux("send-keys -t \(solo) -l moved-and-heard")
          #expect(await collected.eventually { $0.text.contains("moved-and-heard") })
        } else {
          #expect(collected.end == "\(TerminalCloseReason.streamEnded)")
        }
        await bridge.release()
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
        let environment =
          "HOME=\(shellQuoted(home.path)); export HOME; "
          + (configDirectorySet
            ? "CLAUDE_CONFIG_DIR=\(shellQuoted(config.path)); export CLAUDE_CONFIG_DIR; " : "")
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

    // MARK: Codex (#102 S4b)

    /// A `codex` that is `/bin/sleep` under another name, behind a shell that set the pane's
    /// title with OSC 0, as Codex does. This measures that a real `ps` names it by the path it was
    /// started by, that tmux carries the title to `#{pane_title}`, and that both reach the pane.
    @Test("a process named codex is Codex, blocked by its Action Required title and then working")
    func codex() async throws {
      try await withThrowaway { control in
        let scratch = try LocalShell.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let codex = scratch.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(
          atPath: codex.path, withDestinationPath: "/bin/sleep")
        let tmux = shellQuoted(control.binaryPath)

        let pane = try await control.startTerminal()
        let raw = try #require(TmuxID.raw(of: pane))
        /// Runs `script` in the pane, in place of what ran there.
        func respawn(_ script: String) async throws {
          let result = try await LocalShell.runner(
            "\(tmux) respawn-pane -k -t \(shellQuoted(raw)) \(shellQuoted(script))")
          #expect(result.exitStatus == 0, "\(result.standardError)")
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

        // The trailing `:` keeps the shell from exec-ing Codex, so the shell leads the group and
        // Codex is only a member of it, as measured.
        try await respawn(
          "printf '\\033]0;[ ! ] Action Required | app\\007'; \(shellQuoted(codex.path)) 600; :")
        let waiting = try await settled(.blocked)
        let agent = waiting.pane(id: pane)?.agent
        #expect(agent?.kind == TranscriptAgent.codex.rawValue)
        #expect(agent?.status == .blocked)
        #expect(agent?.blockedKind == nil)
        #expect(agent?.session == nil)
        #expect(waiting.pane(id: pane)?.title == "app")
        #expect(waiting.blockedPanes.map(\.id) == [pane])

        // Here Codex leads its group.
        try await respawn("printf '\\033]0;⠋ app\\007'; exec \(shellQuoted(codex.path)) 600")
        let working = try await settled(.working)
        #expect(working.pane(id: pane)?.agent?.kind == TranscriptAgent.codex.rawValue)
        #expect(working.pane(id: pane)?.agent?.status == .working)
        #expect(working.pane(id: pane)?.title == "app")
        #expect(working.blockedPanes.isEmpty)
      }
    }

    // MARK: Mirrors (#102 S5)

    /// A herdr client in a tmux pane, and a tmux client in a herdr pane, both stood in for.
    ///
    /// The herdr client is a copy of `cat` named `herdr`, with no arguments, so its session comes
    /// from `HERDR_SOCKET_PATH`. **A copy, signed again, and not a link.** macOS `ps -E` shows no
    /// environment for a platform binary such as `/bin/cat`, measured on this probe's first run;
    /// an ad-hoc signed copy is not one, as Homebrew's `herdr` and `tmux` are not.
    ///
    /// The tmux client is a real `tmux attach` under `script`, which gives it a terminal, with a
    /// made-up `HERDR_PANE_ID`. Its stdin is the stream's pipe, held open: `script` reads
    /// end-of-file as ^D, which ends the session's shell. It needs `TERM`, which the stream's
    /// environment leaves out.
    ///
    /// Both carry `DRIVERR_PROBE_SECRET`, which must not come back from the host.
    @Test("a herdr client in a pane and a client in a herdr pane both claim, and no secret leaves")
    func mirrors() async throws {
      try await withLiveServer { control, tmux in
        let scratch = try LocalShell.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let herdr = scratch.appendingPathComponent("herdr")
        try FileManager.default.copyItem(atPath: "/bin/cat", toPath: herdr.path)
        let signed = try await LocalShell.runner("codesign -f -s - \(shellQuoted(herdr.path))")
        #expect(signed.exitStatus == 0, "\(signed.standardError)")
        let socket = "/tmp/driverr-probe/sessions/probe/herdr.sock"

        let respawned = try await LocalShell.runner(
          "\(shellQuoted(control.binaryPath)) respawn-pane -k -t \(shellQuoted("%1")) "
            + shellQuoted(
              "env HERDR_SOCKET_PATH=\(socket) DRIVERR_PROBE_SECRET=nope \(shellQuoted(herdr.path))"))
        #expect(respawned.exitStatus == 0, "\(respawned.standardError)")

        let client = try LocalShellStream(
          command: "env TERM=xterm-256color HERDR_PANE_ID=w9:p9 HERDR_SOCKET_PATH=\(socket) "
            + "DRIVERR_PROBE_SECRET=nope "
            + "script -q /dev/null \(shellQuoted(control.binaryPath)) attach -t probe")
        defer { Task { await client.close() } }

        let expected: Set<MirrorClaim> = [
          MirrorClaim(paneID: "tmux:%1", session: .named("probe")),
          MirrorClaim(paneID: "w9:p9", session: .named("probe")),
        ]
        var tree = try await control.snapshot()
        for _ in 0..<50 where tree.mirrorClaims != expected {
          try await Task.sleep(for: .milliseconds(100))
          tree = try await control.snapshot()
        }
        #expect(tree.mirrorClaims == expected)

        // The read itself, for the client: the four variables come back and nothing else does,
        // although the unfiltered environment holds the secret.
        let pid = try #require(Int(try await tmux("list-clients -F '#{client_pid}'")))
        let raw = try await LocalShell.runner("ps -wwE -o command= -p \(pid)")
        #expect(raw.standardOutput.contains("DRIVERR_PROBE_SECRET=nope"), "the secret is there to leak")
        let read = try await LocalShell.runner(TmuxProcessDetailsRead.command(forPIDs: [pid]))
        #expect(read.standardOutput.contains("HERDR_PANE_ID=w9:p9"), "\(read.standardOutput)")
        #expect(!read.standardOutput.contains("DRIVERR_PROBE_SECRET"))
        #expect(!read.standardOutput.contains("PATH=/usr/bin"))
        let details = TmuxProcessDetailsRead.details(from: read.standardOutput, forPIDs: [pid])
        #expect(details[pid]?.environment.keys.sorted() == ["HERDR_PANE_ID", "HERDR_SOCKET_PATH"])
        #expect(details[pid]?.arguments.contains("attach -t probe") == true)

        // And for the herdr stand-in, the leader of `%1`.
        let tty = try await tmux("display-message -p -t \(shellQuoted("%1")) '#{pane_tty}'")
        let leader = try #require(
          Int(
            try await LocalShell.runner(
              "ps -A -o pid=,tpgid=,tty= | awk -v t=\(shellQuoted(TmuxProcessTable.ttyName(ofPaneTTY: tty))) '$3==t && $1==$2 {print $1}'"
            ).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)))
        let leaderRaw = try await LocalShell.runner("ps -wwE -o command= -p \(leader)")
        #expect(leaderRaw.standardOutput.contains("DRIVERR_PROBE_SECRET=nope"), "the secret is there to leak")
        let leaderRead = try await LocalShell.runner(
          TmuxProcessDetailsRead.command(forPIDs: [leader]))
        #expect(leaderRead.standardOutput.contains("HERDR_SOCKET_PATH=\(socket)"), "\(leaderRead.standardOutput)")
        #expect(!leaderRead.standardOutput.contains("DRIVERR_PROBE_SECRET"))
        #expect(
          TmuxProcessDetailsRead.details(from: leaderRead.standardOutput, forPIDs: [leader])[leader]?
            .environment.keys.sorted() == ["HERDR_SOCKET_PATH", "TMUX"])
      }
    }
  }
#endif
