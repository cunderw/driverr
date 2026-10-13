import Foundation
import Testing

@testable import DriverrCore

/// The hook read and write commands, run by `/bin/sh` against a scratch home whose `PATH`
/// holds only `sh`, `cat`, `cksum`, `cp`, `head`, `mv` and `rm`. The install needs the first
/// six. `rm` only removes a refused copy, and the write reports the same status without it.
@Suite("Hook install commands")
struct HookInstallCommandsTests {
  private let claude = AgentIntegration.claudeCode

  private struct Host {
    let root: URL
    var home: URL { root.appendingPathComponent("home") }
    var claudeDir: URL { home.appendingPathComponent(".claude") }
    var settings: URL { claudeDir.appendingPathComponent("settings.json") }
    var bin: URL { root.appendingPathComponent("bin") }

    static let tools = ["/bin/sh", "/bin/cat", "/usr/bin/cksum", "/bin/cp", "/usr/bin/head", "/bin/mv", "/bin/rm"]

    init(withClaudeDirectory: Bool = true, tools: [String] = Host.tools) throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("driverr-hooks-\(UUID().uuidString)")
      let manager = FileManager.default
      try manager.createDirectory(at: bin, withIntermediateDirectories: true)
      try manager.createDirectory(at: home, withIntermediateDirectories: true)
      if withClaudeDirectory { try manager.createDirectory(at: claudeDir, withIntermediateDirectories: true) }
      for tool in tools {
        try manager.createSymbolicLink(
          at: bin.appendingPathComponent((tool as NSString).lastPathComponent),
          withDestinationURL: URL(fileURLWithPath: tool)
        )
      }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// Runs a command as the exec channel hands it to a login shell, with `input` as its
    /// standard input.
    ///
    /// The input comes from a scratch file, not a `Pipe`. A write that refuses the file
    /// exits without reading it, and a write into a pipe nobody reads raises SIGPIPE in the
    /// test process. A file also ends, which the channel's input does not: the write must
    /// stop at its byte count and not at the end of the file, so `commandExcludesTheFile`
    /// pins the count and `bytesPastTheCountAreNotWritten` gives it more than the count.
    func run(
      _ command: String,
      input: Data = Data(),
      loginShell: String = "/bin/sh",
      environment: [String: String] = [:]
    ) async throws -> CommandResult {
      let inputFile = root.appendingPathComponent("stdin-\(UUID().uuidString)")
      try input.write(to: inputFile)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: loginShell)
      process.arguments = ["-c", command]
      process.environment = ["HOME": home.path, "PATH": bin.path].merging(environment) { $1 }
      process.standardInput = try FileHandle(forReadingFrom: inputFile)
      let output = Pipe()
      let error = Pipe()
      process.standardOutput = output
      process.standardError = error
      // Waits on the termination handler rather than `waitUntilExit()`, so no cooperative
      // thread blocks (CLAUDE.md, "Never block a cooperative thread in a Kit test").
      let status: Int32 = try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        do { try process.run() } catch { continuation.resume(throwing: error) }
      }
      return CommandResult(
        standardOutput: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
        standardError: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
        exitStatus: Int(status)
      )
    }

    /// Runs a plan's write as the installer does: the command, with the file on its stdin.
    func write(
      _ plan: HookInstallPlan,
      loginShell: String = "/bin/sh",
      environment: [String: String] = [:]
    ) async throws -> CommandResult {
      try await run(
        plan.command, input: Data(plan.settingsText.utf8), loginShell: loginShell, environment: environment)
    }

    var part: URL { claudeDir.appendingPathComponent("settings.json.driverr-part") }

    func contents(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
  }

  private func readAndPlan(_ host: Host) async throws -> HookInstallPlan? {
    let read = try HookInstallCommands.parseRead(try await host.run(HookInstallCommands.read(for: claude)), for: claude)
    return try HookInstallCommands.plan(for: claude, read: read)
  }

  @Test("a missing settings.json is read as missing and created by the write, with no backup")
  func createsAMissingFile() async throws {
    let host = try Host()
    defer { host.remove() }
    let read = try HookInstallCommands.parseRead(try await host.run(HookInstallCommands.read(for: claude)), for: claude)
    #expect(read == .missing)
    let plan = try #require(try HookInstallCommands.plan(for: claude, read: read))
    let result = try await host.write(plan)
    #expect(HookInstallCommands.outcome(of: result, for: claude) == nil)
    #expect(try host.contents(host.settings) == plan.settingsText)
    #expect(!host.exists(host.claudeDir.appendingPathComponent("settings.json.driverr-backup")))
    #expect(try claude.status(in: host.contents(host.settings)) == .installed)
  }

  @Test("an existing file is merged, backed up, keeps its mode, and a second run has nothing to do")
  func mergesAnExistingFile() async throws {
    let host = try Host()
    defer { host.remove() }
    try HookSettingsFixture.realShape.write(to: host.settings, atomically: false, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: host.settings.path)

    let plan = try #require(try await readAndPlan(host))
    let result = try await host.write(plan)
    #expect(HookInstallCommands.outcome(of: result, for: claude) == nil, "stderr: \(result.standardError)")
    #expect(
      try host.contents(host.settings)
        == HookSettingsFixture.realShapeHead + ",\n" + HookSettingsFixture.groupAtSix + HookSettingsFixture.realShapeTail
    )
    #expect(
      try host.contents(host.claudeDir.appendingPathComponent("settings.json.driverr-backup"))
        == HookSettingsFixture.realShape
    )
    #expect(!host.exists(host.part))
    let mode = try FileManager.default.attributesOfItem(atPath: host.settings.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    #expect(try await readAndPlan(host) == nil)
  }

  @Test("a file changed after the read makes the write exit 75 and leaves it alone")
  func compareAndSwap() async throws {
    let host = try Host()
    defer { host.remove() }
    try "{}\n".write(to: host.settings, atomically: false, encoding: .utf8)
    let plan = try #require(try await readAndPlan(host))
    let changed = "{\n  \"model\": \"changed-meanwhile\"\n}\n"
    try changed.write(to: host.settings, atomically: false, encoding: .utf8)

    let result = try await host.write(plan)
    #expect(result.exitStatus == 75)
    #expect(HookInstallCommands.outcome(of: result, for: claude) == .changedSinceRead)
    #expect(try host.contents(host.settings) == changed)
    #expect(!host.exists(host.claudeDir.appendingPathComponent("settings.json.driverr-backup")))
    #expect(!host.exists(host.part))
  }

  /// The copy is written and then refused, so this is the one refusal that has a file to
  /// clean up. The input is altered after the plan computed its checksum, and keeps its
  /// length, which is what a corrupted transfer looks like to the host.
  @Test(
    "a copy that does not match what was sent exits 74, leaves the file alone and removes the copy",
    arguments: [true, false])
  func aRefusedCopyIsRemoved(hostHasRm: Bool) async throws {
    let host = try Host(tools: hostHasRm ? Host.tools : Host.tools.filter { !$0.hasSuffix("/rm") })
    defer { host.remove() }
    try "{}\n".write(to: host.settings, atomically: false, encoding: .utf8)
    let plan = try #require(try await readAndPlan(host))
    let tampered = plan.settingsText.replacingOccurrences(of: "\"matcher\"", with: "\"Matcher\"")
    #expect(tampered != plan.settingsText)
    #expect(tampered.utf8.count == plan.settingsText.utf8.count)

    let result = try await host.run(plan.command, input: Data(tampered.utf8))
    #expect(result.exitStatus == 74, "stderr: \(result.standardError)")
    #expect(HookInstallCommands.outcome(of: result, for: claude) == .writeDidNotMatch)
    #expect(try host.contents(host.settings) == "{}\n")
    // Without `rm` the copy stays, as it did before, and the status is still the refusal's.
    #expect(host.exists(host.part) == !hostHasRm)
  }

  /// A link that drops mid-transfer closes the command's input early. `cksum` prints the
  /// size with the CRC, so a short copy is refused like an altered one.
  @Test(
    "input that ends before the byte count exits 74, removes the copy and changes nothing",
    arguments: [true, false], [0, 1, 2])
  func shortInputIsRefused(fileExists: Bool, cut: Int) async throws {
    let host = try Host()
    defer { host.remove() }
    if fileExists { try "{}\n".write(to: host.settings, atomically: false, encoding: .utf8) }
    let plan = try #require(try await readAndPlan(host))
    let whole = Data(plan.settingsText.utf8)
    // None of it, half of it, and all but the last byte.
    let sent = [Data(), whole.prefix(whole.count / 2), whole.dropLast()][cut]
    #expect(sent.count < whole.count)

    let result = try await host.run(plan.command, input: sent)
    #expect(result.exitStatus == 74, "stderr: \(result.standardError)")
    #expect(HookInstallCommands.outcome(of: result, for: claude) == .writeDidNotMatch)
    #expect(!host.exists(host.part))
    if fileExists {
      #expect(try host.contents(host.settings) == "{}\n")
    } else {
      #expect(!host.exists(host.settings))
    }
  }

  /// The count is what ends the read. On the channel nothing else does, because its input
  /// stays open, so a write that read to the end of its input would never exit.
  @Test("the write reads its byte count and leaves what follows")
  func bytesPastTheCountAreNotWritten() async throws {
    let host = try Host()
    defer { host.remove() }
    let plan = try #require(try await readAndPlan(host))
    let result = try await host.run(plan.command, input: Data((plan.settingsText + "trailing\n").utf8))
    #expect(HookInstallCommands.outcome(of: result, for: claude) == nil, "stderr: \(result.standardError)")
    #expect(try host.contents(host.settings) == plan.settingsText)
  }

  @Test("a file created after a read that found none also fails the swap")
  func compareAndSwapOnAMissingFile() async throws {
    let host = try Host()
    defer { host.remove() }
    let plan = try #require(try await readAndPlan(host))
    try "{}\n".write(to: host.settings, atomically: false, encoding: .utf8)
    let result = try await host.write(plan)
    #expect(HookInstallCommands.outcome(of: result, for: claude) == .changedSinceRead)
    #expect(try host.contents(host.settings) == "{}\n")
  }

  @Test("a symlinked settings.json is refused by the read and by the write")
  func refusesASymlink() async throws {
    let host = try Host()
    defer { host.remove() }
    let real = host.root.appendingPathComponent("dotfiles-settings.json")
    try "{}\n".write(to: real, atomically: false, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: host.settings, withDestinationURL: real)

    let read = try await host.run(HookInstallCommands.read(for: claude))
    #expect(read.exitStatus == 77)
    #expect(throws: HookInstallFailure.notARegularFile(path: "~/.claude/settings.json")) {
      try HookInstallCommands.parseRead(read, for: claude)
    }
    let plan = try #require(try HookInstallCommands.plan(for: claude, read: .present(text: "{}\n", checksum: POSIXChecksum(of: "{}\n".utf8))))
    let write = try await host.write(plan)
    #expect(HookInstallCommands.outcome(of: write, for: claude) == .notARegularFile(path: "~/.claude/settings.json"))
    #expect(try host.contents(real) == "{}\n")
  }

  @Test("a missing ~/.claude is its own failure, and nothing is created")
  func missingConfigDirectory() async throws {
    let host = try Host(withClaudeDirectory: false)
    defer { host.remove() }
    let read = try await host.run(HookInstallCommands.read(for: claude))
    #expect(read.exitStatus == 78)
    #expect(throws: HookInstallFailure.noConfigDirectory(path: "~/.claude")) {
      try HookInstallCommands.parseRead(read, for: claude)
    }
    let plan = try #require(try HookInstallCommands.plan(for: claude, read: .missing))
    let write = try await host.write(plan)
    #expect(HookInstallCommands.outcome(of: write, for: claude) == .noConfigDirectory(path: "~/.claude"))
    #expect(!host.exists(host.claudeDir))
  }

  @Test("shell syntax inside the file is written literally")
  func shellSyntaxIsLiteral() async throws {
    let host = try Host()
    defer { host.remove() }
    let original = "{\n  \"a\": \"it's $HOME and `id` and $(echo x) and \\\\n\",\n  \"b\": [\"x\", \"y\"]\n}\n"
    try original.write(to: host.settings, atomically: false, encoding: .utf8)
    let plan = try #require(try await readAndPlan(host))
    let result = try await host.write(plan)
    #expect(HookInstallCommands.outcome(of: result, for: claude) == nil, "stderr: \(result.standardError)")
    #expect(try host.contents(host.settings) == plan.settingsText)
    #expect(try host.contents(host.settings).hasPrefix("{\n  \"a\": \"it's $HOME and `id` and $(echo x) and \\\\n\",\n"))
  }

  /// fish reads `\\` inside single quotes as one backslash. fish is not installed here, so
  /// `loginShellQuotedKeepsBackslashesOutsideQuotes` pins the form fish needs.
  @Test("a backslash-heavy file arrives byte for byte through sh, bash and zsh", arguments: ["/bin/sh", "/bin/bash", "/bin/zsh"])
  func backslashesSurvive(loginShell: String) async throws {
    let host = try Host()
    defer { host.remove() }
    let original = #"""
      {
        "a": "C:\\Users\\x\\\\share",
        "b": "\\\\",
        "c": "tab\there \"quoted\" \u0041 \u00e9 it's",
        "d": "\\'\\\\'\\"
      }

      """#
    try original.write(to: host.settings, atomically: false, encoding: .utf8)
    let read = try HookInstallCommands.parseRead(
      try await host.run(HookInstallCommands.read(for: claude), loginShell: loginShell), for: claude
    )
    #expect(read == .present(text: original, checksum: POSIXChecksum(of: original.utf8)))
    let plan = try #require(try HookInstallCommands.plan(for: claude, read: read))
    let result = try await host.write(plan, loginShell: loginShell)
    #expect(HookInstallCommands.outcome(of: result, for: claude) == nil, "stderr: \(result.standardError)")
    #expect(try host.contents(host.settings) == plan.settingsText)
    #expect(try host.contents(host.settings).hasPrefix(original.dropLast(3)))
  }

  @Test("the login-shell quoting leaves no backslash or quote inside the quotes")
  func loginShellQuotedKeepsBackslashesOutsideQuotes() {
    #expect(HookInstallCommands.loginShellQuoted(#"a\b'c"#) == #"'a'\\'b'\''c'"#)
    #expect(HookInstallCommands.loginShellQuoted("x\ny") == "'x\ny'")
  }

  @Test("CLAUDE_CONFIG_DIR, when the shell has it, is where the read and write go")
  func claudeConfigDir() async throws {
    let host = try Host(withClaudeDirectory: false)
    defer { host.remove() }
    let other = host.root.appendingPathComponent("other-claude")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let environment = ["CLAUDE_CONFIG_DIR": other.path]
    let read = try HookInstallCommands.parseRead(
      try await host.run(HookInstallCommands.read(for: claude), environment: environment), for: claude
    )
    #expect(read == .missing)
    let plan = try #require(try HookInstallCommands.plan(for: claude, read: read))
    let result = try await host.write(plan, environment: environment)
    #expect(HookInstallCommands.outcome(of: result, for: claude) == nil)
    #expect(try host.contents(other.appendingPathComponent("settings.json")) == plan.settingsText)
    #expect(!host.exists(host.claudeDir))
  }

  @Test("a cksum that fails is its own error, in the read and in the write")
  func checksumFailure() async throws {
    let host = try Host(tools: Host.tools.filter { !$0.hasSuffix("cksum") })
    defer { host.remove() }
    try "{}\n".write(to: host.settings, atomically: false, encoding: .utf8)
    let read = try await host.run(HookInstallCommands.read(for: claude))
    #expect(read.exitStatus == 71)
    #expect(throws: HookInstallFailure.self) { try HookInstallCommands.parseRead(read, for: claude) }
    let plan = try #require(
      try HookInstallCommands.plan(for: claude, read: .present(text: "{}\n", checksum: POSIXChecksum(of: "{}\n".utf8)))
    )
    let write = try await host.write(plan)
    #expect(write.exitStatus == 71)
    guard case .checksumFailed? = HookInstallCommands.outcome(of: write, for: claude) else {
      Issue.record("expected checksumFailed, got \(String(describing: HookInstallCommands.outcome(of: write, for: claude)))")
      return
    }
    #expect(try host.contents(host.settings) == "{}\n")
  }

  /// With no settings file, the first `cksum` the write runs is the one on its own copy. So a
  /// host with no `cksum` fails there, after the copy exists, where the test above fails
  /// before it does.
  @Test("a cksum that fails on the written copy exits 71, creates no file and removes the copy")
  func aCopyThatCannotBeChecksummedIsRemoved() async throws {
    let host = try Host(tools: Host.tools.filter { !$0.hasSuffix("cksum") })
    defer { host.remove() }
    let plan = try #require(try HookInstallCommands.plan(for: claude, read: .missing))
    let write = try await host.write(plan)
    #expect(write.exitStatus == 71)
    guard case .checksumFailed? = HookInstallCommands.outcome(of: write, for: claude) else {
      Issue.record("expected checksumFailed, got \(String(describing: HookInstallCommands.outcome(of: write, for: claude)))")
      return
    }
    #expect(!host.exists(host.settings))
    #expect(!host.exists(host.part))
  }

  @Test("a settings file over 96 KiB is refused before any command is built")
  func sizeCap() {
    let filler = String(repeating: "x", count: 96 * 1024)
    let text = "{\"pad\": \"\(filler)\"}\n"
    do {
      _ = try HookInstallCommands.plan(for: claude, read: .present(text: text, checksum: POSIXChecksum(of: text.utf8)))
      Issue.record("a file over the cap was planned")
    } catch {
      guard case .settingsTooLarge(let bytes) = error else {
        Issue.record("expected settingsTooLarge, got \(error)")
        return
      }
      #expect(bytes > HookInstallCommands.maximumSettingsBytes)
    }
  }

  @Test("a file without a final newline gains one, and nothing else changes")
  func finalNewline() throws {
    let plan = try #require(
      try HookInstallCommands.plan(for: claude, read: .present(text: "{}", checksum: POSIXChecksum(of: "{}".utf8)))
    )
    #expect(plan.settingsText.hasSuffix("}\n"))
    #expect(!plan.settingsText.hasSuffix("\n\n"))
  }

  @Test("bytes that do not match the host's checksum are refused")
  func readMismatch() {
    let tampered = CommandResult(standardOutput: "present 1 2\n{}\n", standardError: "", exitStatus: 0)
    #expect(throws: HookInstallFailure.readDidNotMatch) { try HookInstallCommands.parseRead(tampered, for: claude) }
    let garbage = CommandResult(standardOutput: "hello", standardError: "", exitStatus: 0)
    #expect(throws: HookInstallFailure.readDidNotMatch) { try HookInstallCommands.parseRead(garbage, for: claude) }
  }

  @Test("invalid JSON read from the host fails the plan and builds no write")
  func invalidJSONPlansNothing() {
    let text = "{\"a\": }\n"
    #expect(throws: HookInstallFailure.settings(.invalidJSON)) {
      try HookInstallCommands.plan(for: claude, read: .present(text: text, checksum: POSIXChecksum(of: text.utf8)))
    }
  }

  @Test(
    "exit statuses map to their failures",
    arguments: [
      (0, HookInstallFailure?.none),
      (75, .changedSinceRead),
      (74, .writeDidNotMatch),
      (77, .notARegularFile(path: "~/.claude/settings.json")),
      (78, .noConfigDirectory(path: "~/.claude")),
      (71, .checksumFailed(message: "cp: disk full")),
      (1, .commandFailed(exitStatus: 1, message: "cp: disk full")),
    ]
  )
  func exitMapping(status: Int, failure: HookInstallFailure?) {
    let result = CommandResult(standardOutput: "", standardError: "cp: disk full\n", exitStatus: status)
    #expect(HookInstallCommands.outcome(of: result, for: claude) == failure)
  }

  /// The file goes to the host on the command's stdin. The command is an argument to the
  /// login shell, and any account on the host can read an argument with `ps`.
  @Test("the write command holds the file's byte count and none of the file")
  func commandExcludesTheFile() throws {
    let text = HookSettingsFixture.realShape
    let plan = try #require(
      try HookInstallCommands.plan(for: claude, read: .present(text: text, checksum: POSIXChecksum(of: text.utf8)))
    )
    #expect(plan.settingsText.contains(HookSettingsFixture.secret), "the fixture did not reach the plan")
    #expect(plan.command.contains("head -c \(plan.settingsText.utf8.count) "))
    for value in [HookSettingsFixture.secret, "EXAMPLE_API_KEY", "example-model", "/opt/example/guard.sh", "Bash|Edit|Write"] {
      #expect(!plan.command.contains(value), "the write command holds \(value)")
    }
    #expect(!plan.command.contains("AskUserQuestion"), "the write command holds the JSON Driverr adds")
  }

  /// The command view shows the steps and the JSON added, never the user's file. The plan's
  /// text carries the secret, which proves the fixture reached the plan.
  @Test("the command view never shows a value from the existing file")
  func displayExcludesTheFile() throws {
    let text = HookSettingsFixture.realShape
    let plan = try #require(
      try HookInstallCommands.plan(for: claude, read: .present(text: text, checksum: POSIXChecksum(of: text.utf8)))
    )
    #expect(plan.settingsText.contains(HookSettingsFixture.secret))
    let shown = plan.display.text
    for value in [HookSettingsFixture.secret, "EXAMPLE_API_KEY", "example-model", "/opt/example/guard.sh", "Bash|Edit|Write"] {
      #expect(!shown.contains(value), "the command view shows \(value)")
    }
    #expect(!shown.contains(String(POSIXChecksum(of: text.utf8).crc)))
  }

  @Test("the command view shows both commands, the JSON added, and says the rest is kept")
  func displayContents() {
    let display = HookInstallCommands.display(for: claude)
    #expect(display.readCommand == HookInstallCommands.read(for: claude))
    #expect(display.addedJSON.contains("\"command\": \"cat >/dev/null # driverr:claude.ask-user-question:v1\""))
    #expect(display.addedJSON.contains("\"hooks\" → \"PreToolUse\""))
    #expect(display.writeCommand.contains("<checksum from step 1>"))
    #expect(display.writeCommand.contains("head -c <size of the new file in bytes> > "))
    #expect(display.writeNote.contains("standard input"))
    #expect(display.text.contains(display.writeNote))
    #expect(display.writeCommand.contains("cp -p"))
    #expect(display.writeCommand.contains("mv "))
    #expect(display.note.contains("kept unchanged"))
  }
}
