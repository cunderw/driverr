import DriverrCore
import Foundation
import Testing

@testable import DriverrSSH

/// Uploads over a real SSH handshake and exec channel, with a real `/bin/sh` writing a real
/// file.
///
/// Every test uses a temp inbox. `EmbeddedSSHServer` runs `/bin/sh -lc` with the test
/// process's `HOME`, so the default inbox is the developer's own, and the command's first
/// act is a sweep that deletes things in it.
@Suite("Image upload against a real server")
struct ImageUploaderTests {
  /// A server running real commands, a connected coordinator, and a temp inbox, torn down
  /// whether the body passes or throws. `truncatingStandardInputAfter`: see
  /// `EmbeddedSSHServer.init(truncatesStandardInputAfter:)`.
  private func withUploadHost(
    truncatingStandardInputAfter: Int? = nil,
    _ body: (ConnectionCoordinator, URL) async throws -> Void
  ) async throws {
    let password = UUID().uuidString
    let server = try await EmbeddedSSHServer(
      username: "carson",
      password: password,
      executesRealCommands: true,
      truncatesStandardInputAfter: truncatingStandardInputAfter
    )
    let inbox = FileManager.default.temporaryDirectory
      .appendingPathComponent("driverr-inbox-\(UUID().uuidString)", isDirectory: true)
    let host = DriverrCore.Host(
      name: "embedded",
      hostname: "127.0.0.1",
      port: server.port,
      username: "carson"
    )
    let coordinator = ConnectionCoordinator(transport: NIOSSHTransport())
    // Every teardown in a `defer`, the client's too, or a throwing body leaks the transport's
    // event loop group.
    defer {
      Task {
        await coordinator.disconnect()
        await server.stop()
      }
      try? FileManager.default.removeItem(at: inbox)
    }

    try await coordinator.connect(
      to: host,
      validator: TOFUHostKeyValidator(
        store: InMemoryKnownHostsStore(),
        prompt: AcceptingPrompt()
      ),
      credential: .password(password)
    )

    try await body(coordinator, inbox)
  }

  /// Not text, because raw bytes rely on a binary-clean channel and ASCII would hide an
  /// armouring bug.
  private func payload(_ count: Int) -> Data {
    var bytes = Data(capacity: count)
    for index in 0..<count { bytes.append(UInt8((index * 31 + 7) % 256)) }
    return bytes
  }

  /// A name with a quote and a space, and the path comes back from the host.
  @Test("a photo lands in the inbox, byte for byte, under a hostile name")
  func uploadsAPhoto() async throws {
    try await withUploadHost { coordinator, inbox in
      let bytes = payload(100_000)
      let uploader = ImageUploader(
        coordinator: coordinator,
        bytes: bytes,
        fileName: "it's a photo.png",
        inboxDirectory: shellQuoted(inbox.path)
      )

      let outcome = try await uploader.upload()

      #expect(outcome.bytesSent == bytes.count)
      #expect(outcome.hostPath == inbox.appendingPathComponent("it's a photo.png").path)
      let landed = try Data(contentsOf: URL(fileURLWithPath: outcome.hostPath))
      #expect(landed == bytes)
      // The rename happened, so nothing is left half-written.
      #expect(!FileManager.default.fileExists(atPath: outcome.hostPath + ".part"))
    }
  }

  /// Created 0700 by `umask` in the command. The mode is what stops another account reading
  /// files Driverr leaves on the host.
  @Test("the inbox is created 0700 by the command itself")
  func createsTheInboxPrivately() async throws {
    try await withUploadHost { coordinator, inbox in
      #expect(!FileManager.default.fileExists(atPath: inbox.path))

      let uploader = ImageUploader(
        coordinator: coordinator,
        bytes: payload(64),
        fileName: "a.png",
        inboxDirectory: shellQuoted(inbox.path)
      )
      _ = try await uploader.upload()

      let attributes = try FileManager.default.attributesOfItem(atPath: inbox.path)
      let mode = try #require(attributes[.posixPermissions] as? NSNumber)
      #expect(mode.intValue == 0o700)
    }
  }

  /// Proven by the sweep working, not by the command containing `find`.
  @Test("an upload deletes anything in the inbox older than a day")
  func sweepsStaleFiles() async throws {
    try await withUploadHost { coordinator, inbox in
      try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
      let stale = inbox.appendingPathComponent("stale.png")
      let fresh = inbox.appendingPathComponent("fresh.png")
      try Data("old".utf8).write(to: stale)
      try Data("new".utf8).write(to: fresh)
      // 25 hours: inside the intended window and outside what `-mtime +1` applies, which only
      // matches files over 48 hours old.
      try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-25 * 60 * 60)],
        ofItemAtPath: stale.path
      )

      let uploader = ImageUploader(
        coordinator: coordinator,
        bytes: payload(128),
        fileName: "a.png",
        inboxDirectory: shellQuoted(inbox.path)
      )
      let outcome = try await uploader.upload()

      #expect(!FileManager.default.fileExists(atPath: stale.path))
      // A sweep that took everything would delete a screenshot sent minutes ago.
      #expect(FileManager.default.fileExists(atPath: fresh.path))
      #expect(FileManager.default.fileExists(atPath: outcome.hostPath))
    }
  }

  /// A client cannot produce a short write: `ExecStream.close()` closes the whole channel
  /// and takes the exit status with it. So a stub consumes the payload and exits with the
  /// mismatch status. `InboxUploadCommandTests` asserts the real command uses it.
  @Test("the mismatch exit status is reported as a size mismatch, not a generic failure")
  func reportsASizeMismatch() async throws {
    try await withUploadHost { coordinator, _ in
      let count = 4096
      let uploader = ImageUploader(
        coordinator: coordinator,
        bytes: payload(count),
        command: InboxUploadCommand(
          script:
            "head -c \(count) > /dev/null; exit \(InboxUploadCommand.sizeMismatchExitStatus)",
          byteCount: count
        )
      )

      await #expect(throws: ImageUploadFailure.sizeMismatch(expectedBytes: count)) {
        try await uploader.upload()
      }
    }
  }

  /// The real command, with the server delivering 4096 of 8192 bytes and closing stdin.
  /// `head` writes what it got, `wc -c` disagrees, and the script exits 65 on an open
  /// channel. The `.part` survives and the destination is never created.
  @Test("bytes arriving short at the host exit 65, leave the .part, and create no file")
  func reportsASizeMismatchFromTheRealCommand() async throws {
    let total = 8192
    try await withUploadHost(truncatingStandardInputAfter: total / 2) { coordinator, inbox in
      let uploader = ImageUploader(
        coordinator: coordinator,
        bytes: payload(total),
        fileName: "short.png",
        inboxDirectory: shellQuoted(inbox.path)
      )

      await #expect(throws: ImageUploadFailure.sizeMismatch(expectedBytes: total)) {
        try await uploader.upload()
      }

      let destination = inbox.appendingPathComponent("short.png")
      #expect(!FileManager.default.fileExists(atPath: destination.path))
      let part = destination.path + ".part"
      #expect(FileManager.default.fileExists(atPath: part))
      // Left for the next sweep, so the rename is the only thing an agent can see.
      let landed = try Data(contentsOf: URL(fileURLWithPath: part))
      #expect(landed.count == total / 2)
    }
  }

  /// The host's stderr is the only thing that can say why.
  @Test("any other non-zero exit carries the status and stderr")
  func reportsACommandFailure() async throws {
    try await withUploadHost { coordinator, _ in
      let count = 2048
      let uploader = ImageUploader(
        coordinator: coordinator,
        bytes: payload(count),
        command: InboxUploadCommand(
          script: "head -c \(count) > /dev/null; echo 'No space left on device' >&2; exit 28",
          byteCount: count
        )
      )

      do {
        _ = try await uploader.upload()
        Issue.record("the upload should have failed")
      } catch let failure as ImageUploadFailure {
        guard case .commandFailed(let status, let standardError) = failure else {
          Issue.record("expected commandFailed, got \(failure)")
          return
        }
        #expect(status == 28)
        #expect(standardError.contains("No space left on device"))
      }
    }
  }

  /// `cat` waits for an EOF a torn-down connection never brings. A throwing `send` and an
  /// output stream ending with no status produce the same typed failure, so this asserts
  /// the case, not the sentence.
  @Test("a connection torn down mid-upload fails as a dropped channel")
  func reportsADroppedChannel() async throws {
    try await withUploadHost { coordinator, _ in
      let count = 512 * 1024
      let uploader = ImageUploader(
        coordinator: coordinator,
        bytes: payload(count),
        command: InboxUploadCommand(script: "cat > /dev/null", byteCount: count)
      )

      let upload = Task { try await uploader.upload() }
      // Wait for bytes on the wire, or this would test a failed open.
      for await update in uploader.progress where update.bytesSent > 0 { break }
      await coordinator.disconnect()

      switch await upload.result {
      case .success(let outcome):
        Issue.record("the upload should not have completed, got \(outcome.hostPath)")
      case .failure(let error):
        guard let failure = error as? ImageUploadFailure, case .channelDropped = failure else {
          Issue.record("expected channelDropped, got \(error)")
          return
        }
      }
    }
  }

  /// One event per 32 KB write, plus a zero at the start so a bar can draw at 0.
  @Test("progress reports every chunk, in order, ending at the total")
  func reportsProgress() async throws {
    try await withUploadHost { coordinator, inbox in
      let count = 100_000
      let uploader = ImageUploader(
        coordinator: coordinator,
        bytes: payload(count),
        fileName: "a.png",
        inboxDirectory: shellQuoted(inbox.path)
      )
      // Possible because the stream is armed in `init`, not in `upload()`.
      let collected = Task {
        var seen: [Int] = []
        for await update in uploader.progress { seen.append(update.bytesSent) }
        return seen
      }

      _ = try await uploader.upload()
      let seen = await collected.value

      #expect(seen == [0, 32_768, 65_536, 98_304, 100_000])
      #expect(seen.last == count)
    }
  }

  /// A `for await` that never ends leaks a task per failure.
  @Test("the progress stream finishes even when the upload fails")
  func finishesProgressOnFailure() async throws {
    try await withUploadHost { coordinator, _ in
      let count = 1024
      let uploader = ImageUploader(
        coordinator: coordinator,
        bytes: payload(count),
        command: InboxUploadCommand(
          script: "head -c \(count) > /dev/null; exit 7",
          byteCount: count
        )
      )
      let collected = Task {
        var seen: [Int] = []
        for await update in uploader.progress { seen.append(update.bytesSent) }
        return seen
      }

      _ = try? await uploader.upload()

      #expect(await collected.value == [0, count])
    }
  }

  /// `Task.cancel()` does not interrupt a suspended `await`, and neither the NIO write
  /// bridge nor the exec channel checks the flag. Without `Task.checkCancellation()` in the
  /// chunk loop, every chunk is written and the image lands after the user tapped Remove.
  ///
  /// 4 MB is about 122 chunks, so cancelling on the first lands early whatever the loopback
  /// speed. The assertion is on the destination file; whether the `.part` survives is the
  /// shell's business.
  @Test("a cancelled upload stops short and writes no file into the inbox")
  func cancellingMidSendStopsShort() async throws {
    try await withUploadHost { coordinator, inbox in
      let bytes = payload(4_000_000)
      let uploader = ImageUploader(
        coordinator: coordinator,
        bytes: bytes,
        fileName: "cancelled.png",
        inboxDirectory: shellQuoted(inbox.path)
      )
      let progress = uploader.progress

      let work = Task { try await uploader.upload() }

      // Cancels on evidence of transfer; a fixed sleep would race the loopback.
      var lastSent = 0
      for await update in progress {
        lastSent = update.bytesSent
        if update.bytesSent > 0, update.bytesSent < update.totalBytes {
          work.cancel()
          break
        }
      }

      await #expect(throws: CancellationError.self) { _ = try await work.value }
      #expect(lastSent > 0)
      #expect(lastSent < bytes.count)
      #expect(
        !FileManager.default.fileExists(
          atPath: inbox.appendingPathComponent("cancelled.png").path))
    }
  }
}

/// The upload over `FakeSSHTransport`, whose stream takes every byte and then stays open
/// with no output, as a host does when its command waits for input that is not coming.
/// `StalledCommandTests` runs the real command.
@Suite("Image upload to a host that stops answering", .timeLimit(.minutes(1)))
struct ImageUploadStallTests {
  @Test("the upload fails as stalled on the deadline, finishes its progress and closes the stream")
  func aStalledUpload() async throws {
    let transport = FakeSSHTransport()
    let coordinator = ConnectionCoordinator(transport: transport)
    try await coordinator.connect(
      to: DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson"),
      validator: TOFUHostKeyValidator(store: InMemoryKnownHostsStore(), prompt: AcceptingPrompt()),
      credential: .password("hunter2")
    )
    let uploader = ImageUploader(
      coordinator: coordinator,
      bytes: Data(repeating: 0x5A, count: 100),
      command: InboxUploadCommand(script: "head -c 101", byteCount: 101),
      idleDeadline: .milliseconds(50)
    )
    let collected = Task {
      var seen: [Int] = []
      for await update in uploader.progress { seen.append(update.bytesSent) }
      return seen
    }

    await #expect(throws: ImageUploadFailure.stalled) { try await uploader.upload() }

    #expect(await collected.value == [0, 100])
    #expect(await transport.streamLog.last == "close: head -c 101")
  }

  /// The link died before the upload started, so the channel never opens.
  @Test("an upload whose channel never opens fails as stalled, and a channel that opens late is closed")
  func aStalledOpen() async throws {
    let (closes, closed) = AsyncStream.makeStream(of: String.self)
    let transport = FakeSSHTransport(onStreamClose: { closed.yield($0) })
    let coordinator = ConnectionCoordinator(transport: transport)
    try await coordinator.connect(
      to: DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson"),
      validator: TOFUHostKeyValidator(store: InMemoryKnownHostsStore(), prompt: AcceptingPrompt()),
      credential: .password("hunter2")
    )
    // Forty times the deadline, so a loaded machine does not open the channel first.
    await transport.stopAnswering(for: .seconds(2))
    let uploader = ImageUploader(
      coordinator: coordinator,
      bytes: Data(repeating: 0x5A, count: 100),
      command: InboxUploadCommand(script: "head -c 100", byteCount: 100),
      idleDeadline: .milliseconds(50)
    )
    let finished = DoneFlag()
    let collected = Task {
      var seen: [Int] = []
      for await update in uploader.progress { seen.append(update.bytesSent) }
      // Not when the wait below gave up and cancelled this task.
      if !Task.isCancelled { finished.set() }
      return seen
    }

    await #expect(throws: ImageUploadFailure.stalled) { try await uploader.upload() }

    // Bounded, because a stream left open would hold `collected.value` for ever. Each step
    // is shorter than the deadline under test, and a finished stream ends the loop at once.
    for _ in 0..<40 where !finished.isSet {
      try await Task.sleep(for: .milliseconds(25))
    }
    collected.cancel()
    #expect(finished.isSet, "the progress stream was left open when the channel did not open")
    #expect(await collected.value == [], "nothing was sent, so no progress is reported")

    for await _ in closes { break }
    let log = await transport.streamLog
    #expect(
      log == [
        "unanswered: head -c 100", "open: head -c 100", "unanswered: close head -c 100", "close: head -c 100",
      ])
  }
}

private final class DoneFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func set() { lock.withLock { value = true } }
  var isSet: Bool { lock.withLock { value } }
}

/// `ExecStream.close()` settles on the channel's event loop, and
/// `NIOSSHTransport.disconnect()` shuts that loop's group down. A `close()` after a
/// disconnect awaited a promise nobody would settle and parked the whole test process.
/// Each case runs on a deadline, so a suspension is a named failure rather than a hang.
@Suite("Closing a channel after the connection has gone")
struct ChannelCloseAfterDisconnectTests {
  private func withConnection(
    _ body: (ConnectionCoordinator) async throws -> Void
  ) async throws {
    let password = UUID().uuidString
    let server = try await EmbeddedSSHServer(
      username: "carson",
      password: password,
      executesRealCommands: true
    )
    let host = DriverrCore.Host(
      name: "embedded",
      hostname: "127.0.0.1",
      port: server.port,
      username: "carson"
    )
    let coordinator = ConnectionCoordinator(transport: NIOSSHTransport())
    defer {
      Task {
        await coordinator.disconnect()
        await server.stop()
      }
    }
    try await coordinator.connect(
      to: host,
      validator: TOFUHostKeyValidator(
        store: InMemoryKnownHostsStore(),
        prompt: AcceptingPrompt()
      ),
      credential: .password(password)
    )
    try await body(coordinator)
  }

  /// Runs `close` and says whether it came back within the budget.
  private func returns(
    within budget: Int = 100,
    _ close: @escaping @Sendable () async -> Void
  ) async throws -> Bool {
    let done = DoneFlag()
    let closing = Task {
      await close()
      done.set()
    }
    for _ in 0..<budget where !done.isSet {
      try await Task.sleep(for: .milliseconds(50))
    }
    closing.cancel()
    return done.isSet
  }

  @Test("an exec stream's close returns instead of suspending for ever")
  func execStreamCloseReturnsAfterADisconnect() async throws {
    try await withConnection { coordinator in
      let stream = try await coordinator.openStream(command: "cat > /dev/null")
      await coordinator.disconnect()

      let returned = try await returns { await stream.close() }
      #expect(returned, "ExecStream.close() suspended after the connection was torn down")
    }
  }

  /// A terminal is the channel most likely to be open when the link drops.
  @Test("a PTY channel's close returns instead of suspending for ever")
  func ptyCloseReturnsAfterADisconnect() async throws {
    try await withConnection { coordinator in
      let pty = try await coordinator.openPTY(size: TerminalSize(columns: 80, rows: 24))
      await coordinator.disconnect()

      let returned = try await returns { await pty.close() }
      #expect(returned, "PTYChannel.close() suspended after the connection was torn down")
    }
  }

  /// Runs a throwing call on a deadline and reports how it ended. `#expect(throws:)` awaits
  /// its closure, so a call that never returns would hang the process instead of failing.
  private func outcome(
    within budget: Int = 100,
    of call: @escaping @Sendable () async throws -> Void
  ) async throws -> CallOutcome {
    let box = CallOutcomeBox()
    let calling = Task {
      do {
        try await call()
        box.record(nil)
      } catch {
        box.record(error)
      }
    }
    for _ in 0..<budget where !box.didFinish {
      try await Task.sleep(for: .milliseconds(50))
    }
    calling.cancel()
    return CallOutcome(finished: box.didFinish, thrown: box.thrown)
  }

  /// A send that quietly succeeded on a dead channel would drop keystrokes unnoticed, so the
  /// failure is asserted, not just the return.
  @Test("a PTY channel's send fails rather than suspending after a disconnect")
  func ptySendFailsAfterADisconnect() async throws {
    try await withConnection { coordinator in
      let pty = try await coordinator.openPTY(size: TerminalSize(columns: 80, rows: 24))
      await coordinator.disconnect()

      let call = try await outcome { try await pty.send(Data("ls\n".utf8)) }

      #expect(call.finished, "PTYChannel.send() suspended after the connection was torn down")
      #expect(throws: AppError.self) { try call.rethrowing() }
    }
  }

  /// Reached by rotating or opening the keyboard after the link has gone.
  @Test("a PTY channel's resize fails rather than suspending after a disconnect")
  func ptyResizeFailsAfterADisconnect() async throws {
    try await withConnection { coordinator in
      let pty = try await coordinator.openPTY(size: TerminalSize(columns: 80, rows: 24))
      await coordinator.disconnect()

      let call = try await outcome {
        try await pty.resize(to: TerminalSize(columns: 120, rows: 40))
      }

      #expect(call.finished, "PTYChannel.resize() suspended after the connection was torn down")
      #expect(throws: AppError.self) { try call.rethrowing() }
    }
  }
}

/// How a call that must not suspend ended. See `outcome(within:of:)`.
private struct CallOutcome {
  /// False means the call never came back inside the budget.
  let finished: Bool
  let thrown: (any Error)?

  /// Re-raises what the call threw, so a call that returned without throwing fails
  /// `#expect(throws:)`. Synchronous because the waiting already happened.
  func rethrowing() throws {
    if let thrown { throw thrown }
  }
}

private final class CallOutcomeBox: @unchecked Sendable {
  private let lock = NSLock()
  private var finished = false
  private var error: (any Error)?

  func record(_ error: (any Error)?) {
    lock.withLock {
      finished = true
      self.error = error
    }
  }

  var didFinish: Bool { lock.withLock { finished } }
  var thrown: (any Error)? { lock.withLock { error } }
}
