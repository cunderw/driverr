import Foundation
import Testing

@testable import DriverrCore

/// The key install, run by `/bin/sh`, bash and zsh against a scratch home whose `PATH`
/// holds only `sh`, `mkdir`, `tail` and `awk`, the tools the install may assume.
@Suite("Authorized key install commands")
struct AuthorizedKeyInstallCommandsTests {
  private static let blob = Data((0..<51).map { UInt8($0) })
  private static let identity = SSHIdentity(name: "Driverr key · 27 Sep 2026", publicKeyBlob: blob)
  private static var base64: String { blob.base64EncodedString() }

  private struct Host {
    let root: URL
    var home: URL { root.appendingPathComponent("home") }
    var ssh: URL { home.appendingPathComponent(".ssh") }
    var file: URL { ssh.appendingPathComponent("authorized_keys") }
    var bin: URL { root.appendingPathComponent("bin") }

    static let tools = ["/bin/sh", "/bin/mkdir", "/usr/bin/tail", "/usr/bin/awk"]

    init(tools: [String] = Host.tools) throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("driverr-keys-\(UUID().uuidString)")
      let manager = FileManager.default
      try manager.createDirectory(at: bin, withIntermediateDirectories: true)
      try manager.createDirectory(at: home, withIntermediateDirectories: true)
      for tool in tools {
        try manager.createSymbolicLink(
          at: bin.appendingPathComponent((tool as NSString).lastPathComponent),
          withDestinationURL: URL(fileURLWithPath: tool)
        )
      }
    }

    func remove() {
      // A test that made ~/.ssh read-only must restore write access, or the scratch stays.
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
      try? FileManager.default.removeItem(at: root)
    }

    /// Runs a command as the exec channel hands it to a login shell.
    func run(_ command: String, loginShell: String = "/bin/sh") async throws -> CommandResult {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: loginShell)
      process.arguments = ["-c", command]
      process.environment = ["HOME": home.path, "PATH": bin.path]
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

    func install(_ identity: SSHIdentity = AuthorizedKeyInstallCommandsTests.identity, loginShell: String = "/bin/sh")
      async throws -> Result<KeyInstallOutcome, AuthorizedKeyInstallFailure>
    {
      let result = try await run(AuthorizedKeyInstallCommands.install(identity), loginShell: loginShell)
      do {
        return .success(try AuthorizedKeyInstallCommands.outcome(of: result))
      } catch {
        return .failure(error)
      }
    }

    func contents() throws -> String { try String(contentsOf: file, encoding: .utf8) }
    func mode(_ url: URL) throws -> Int {
      try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }
  }

  private var line: String { "ssh-ed25519 \(Self.base64) Driverr key · 27 Sep 2026" }

  @Test("the command is exactly this script")
  func golden() {
    let script = """
      LC_ALL=C; export LC_ALL; umask 077
      for t in mkdir tail awk; do command -v $t >/dev/null 2>&1 || { echo "$t: not found" >&2; exit 127; }; done
      b='\(Self.base64)'; line='ssh-ed25519 \(Self.base64) Driverr key · 27 Sep 2026'
      d="$HOME/.ssh"; f="$d/authorized_keys"
      md=; mf=
      if [ ! -d "$d" ]; then [ -e "$d" ] && exit 77; mkdir "$d" || exit 73; md=1; fi
      if [ -L "$f" ] && [ ! -e "$f" ]; then exit 77; fi
      if [ -e "$f" ] && [ ! -f "$f" ]; then exit 77; fi
      has() { awk -v b="$b" '{for(i=1;i<=NF;i++)if($i==b){x=1;exit}}END{exit !x}' "$f"; }
      if [ -e "$f" ]; then has; s=$?; [ $s = 0 ] && { echo present; exit 0; }; [ $s = 1 ] || exit 66; else mf=1; fi
      { [ -z "$(tail -c 1 "$f" 2>/dev/null)" ] || printf '\\n'; printf '%s\\n' "$line"; } >> "$f" || exit 74
      has || exit 74
      if command -v restorecon >/dev/null 2>&1; then { [ -z "$md" ] || restorecon "$d"; [ -z "$mf" ] || restorecon "$f"; } 2>/dev/null; fi
      echo installed
      """
    #expect(AuthorizedKeyInstallCommands.install(Self.identity) == "sh -c " + HookInstallCommands.loginShellQuoted(script))
  }

  @Test("a missing ~/.ssh is made 0700 with the file 0600, and a second run does nothing", arguments: ["/bin/sh", "/bin/bash", "/bin/zsh"])
  func createsAndIsIdempotent(loginShell: String) async throws {
    let host = try Host()
    defer { host.remove() }

    #expect(try await host.install(loginShell: loginShell) == .success(.installed))
    #expect(try host.contents() == line + "\n")
    #expect(try host.mode(host.ssh) == 0o700)
    #expect(try host.mode(host.file) == 0o600)

    #expect(try await host.install(loginShell: loginShell) == .success(.alreadyInstalled))
    #expect(try host.contents() == line + "\n")
  }

  @Test("restorecon labels only what the install made, and never with -F")
  func restoreconOnlyOnWhatWasMade() async throws {
    let host = try Host()
    defer { host.remove() }
    let log = host.root.appendingPathComponent("restorecon.log")
    let fake = host.bin.appendingPathComponent("restorecon")
    try "#!/bin/sh\necho \"$@\" >> '\(log.path)'\n".write(to: fake, atomically: false, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

    #expect(try await host.install() == .success(.installed))
    #expect(try String(contentsOf: log, encoding: .utf8) == "\(host.ssh.path)\n\(host.file.path)\n")

    try FileManager.default.removeItem(at: log)
    let other = SSHIdentity(name: "second", publicKeyBlob: Data((100..<151).map { UInt8($0) }))
    #expect(try await host.install(other) == .success(.installed))
    #expect(!FileManager.default.fileExists(atPath: log.path), "an existing ~/.ssh and file were relabelled")
  }

  @Test("an existing file keeps its lines and its mode, and the key is appended")
  func appendsOnly() async throws {
    let host = try Host()
    defer { host.remove() }
    try FileManager.default.createDirectory(at: host.ssh, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    let existing = "ssh-rsa AAAAother laptop\n"
    try existing.write(to: host.file, atomically: false, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: host.file.path)

    #expect(try await host.install() == .success(.installed))
    #expect(try host.contents() == existing + line + "\n")
    #expect(try host.mode(host.ssh) == 0o755)
    #expect(try host.mode(host.file) == 0o644)
  }

  @Test("a file without a final newline gets one before the key")
  func missingFinalNewline() async throws {
    let host = try Host()
    defer { host.remove() }
    try FileManager.default.createDirectory(at: host.ssh, withIntermediateDirectories: false)
    try "ssh-rsa AAAAother laptop".write(to: host.file, atomically: false, encoding: .utf8)

    #expect(try await host.install() == .success(.installed))
    #expect(try host.contents() == "ssh-rsa AAAAother laptop\n" + line + "\n")
  }

  @Test("the key under another name or behind an options prefix counts as present")
  func matchesOnTheBlob() async throws {
    let host = try Host()
    defer { host.remove() }
    try FileManager.default.createDirectory(at: host.ssh, withIntermediateDirectories: false)
    let existing = "restrict,pty,from=\"127.0.0.1,::1\" ssh-ed25519 \(Self.base64) renamed\n"
    try existing.write(to: host.file, atomically: false, encoding: .utf8)

    #expect(try await host.install() == .success(.alreadyInstalled))
    #expect(try host.contents() == existing)
  }

  @Test("a read-only ~/.ssh with no file fails the append with 74, and nothing is made")
  func readOnlyDirectory() async throws {
    let host = try Host()
    defer { host.remove() }
    try FileManager.default.createDirectory(at: host.ssh, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o500])

    let result = try await host.install()
    guard case .failure(.writeFailed(let message)) = result else {
      Issue.record("Expected a write failure, got \(result)")
      return
    }
    #expect(message.contains("Permission denied"))
    #expect(!FileManager.default.fileExists(atPath: host.file.path))
  }

  @Test("a symlinked file is followed: the target gets the key and the link stays a link")
  func followsASymlink() async throws {
    let host = try Host()
    defer { host.remove() }
    try FileManager.default.createDirectory(at: host.ssh, withIntermediateDirectories: false)
    let target = host.root.appendingPathComponent("dotfiles-authorized_keys")
    try "ssh-rsa AAAAother laptop\n".write(to: target, atomically: false, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: host.file, withDestinationURL: target)

    #expect(try await host.install() == .success(.installed))
    #expect(try String(contentsOf: target, encoding: .utf8) == "ssh-rsa AAAAother laptop\n" + line + "\n")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: host.file.path) == target.path)
  }

  @Test("a symlink to nothing is refused with 77, and nothing is made where it points")
  func refusesADanglingSymlink() async throws {
    let host = try Host()
    defer { host.remove() }
    try FileManager.default.createDirectory(at: host.ssh, withIntermediateDirectories: false)
    let target = host.root.appendingPathComponent("missing-authorized_keys")
    try FileManager.default.createSymbolicLink(at: host.file, withDestinationURL: target)

    #expect(try await host.install() == .failure(.notARegularFile))
    #expect(!FileManager.default.fileExists(atPath: target.path))
  }

  @Test("a directory where the file goes, or a file where ~/.ssh goes, is refused with 77")
  func refusesWhatIsInTheWay() async throws {
    let host = try Host()
    defer { host.remove() }
    try FileManager.default.createDirectory(at: host.file, withIntermediateDirectories: true)
    #expect(try await host.install() == .failure(.notARegularFile))

    let other = try Host()
    defer { other.remove() }
    try "not a directory".write(to: other.ssh, atomically: false, encoding: .utf8)
    #expect(try await other.install() == .failure(.notARegularFile))
  }

  @Test("a quote, a backslash and a newline in the key's name arrive as one literal line", arguments: ["/bin/sh", "/bin/bash", "/bin/zsh"])
  func commentIsLiteral(loginShell: String) async throws {
    let host = try Host()
    defer { host.remove() }
    let identity = SSHIdentity(name: "it's a \\n key $HOME `id`\nssh-ed25519 AAAAinjected", publicKeyBlob: Self.blob)

    #expect(try await host.install(identity, loginShell: loginShell) == .success(.installed))
    #expect(
      try host.contents() == "ssh-ed25519 \(Self.base64) it's a \\n key $HOME `id`ssh-ed25519 AAAAinjected\n")
  }

  @Test("a host without awk reports it as missing, before anything is made")
  func missingTool() async throws {
    let host = try Host(tools: ["/bin/sh", "/bin/mkdir", "/usr/bin/tail"])
    defer { host.remove() }

    #expect(try await host.install() == .failure(.missingTool(message: "awk: not found")))
    #expect(!FileManager.default.fileExists(atPath: host.ssh.path))
  }

  @Test(
    "each exit status maps to its failure",
    arguments: [
      (77, "", AuthorizedKeyInstallFailure.notARegularFile),
      (73, "mkdir: Permission denied", .couldNotCreateDirectory(message: "mkdir: Permission denied")),
      (66, "awk: can't open file", .unreadable(message: "awk: can't open file")),
      (74, "sh: /home/a/.ssh/authorized_keys: Read-only file system", .readOnlyFileSystem),
      (74, "sh: write error: No space left on device", .diskFull),
      (74, "sh: Permission denied", .writeFailed(message: "sh: Permission denied")),
      (127, "sh: awk: not found", .missingTool(message: "sh: awk: not found")),
      (126, "sh: awk: Permission denied", .missingTool(message: "sh: awk: Permission denied")),
      (1, "boom", .commandFailed(exitStatus: 1, message: "boom")),
    ]
  )
  func exitMapping(status: Int, stderr: String, failure: AuthorizedKeyInstallFailure) {
    #expect(throws: failure) {
      try AuthorizedKeyInstallCommands.outcome(of: CommandResult(standardOutput: "", standardError: stderr, exitStatus: status))
    }
  }

  @Test("the last line of stdout is the answer, after anything an rc file printed")
  func lastLineIsTheAnswer() throws {
    let banner = "Welcome to the box\ninstalled\n"
    #expect(try AuthorizedKeyInstallCommands.outcome(of: CommandResult(standardOutput: banner, standardError: "", exitStatus: 0)) == .installed)
    #expect(try AuthorizedKeyInstallCommands.outcome(of: CommandResult(standardOutput: "present\n", standardError: "", exitStatus: 0)) == .alreadyInstalled)
    #expect(throws: AuthorizedKeyInstallFailure.commandFailed(exitStatus: 0, message: "")) {
      try AuthorizedKeyInstallCommands.outcome(of: CommandResult(standardOutput: "", standardError: "", exitStatus: 0))
    }
  }

  @Test("the fake host answers the real command: install, then present, keeping the literal line")
  func fakeHost() async throws {
    let identity = SSHIdentity(name: "it's \\ mine", publicKeyBlob: Self.blob)
    let fake = FakeAuthorizedKeysHost(lines: ["ssh-rsa AAAAother laptop"])
    #expect(await AuthorizedKeyInstaller.install(identity, run: fake.run) == .success(.installed))
    #expect(await fake.lines == ["ssh-rsa AAAAother laptop", "ssh-ed25519 \(Self.base64) it's \\ mine"])
    #expect(await AuthorizedKeyInstaller.install(identity, run: fake.run) == .success(.alreadyInstalled))
    #expect(await fake.installCount == 1)

    let failing = FakeAuthorizedKeysHost(failure: (74, "sh: Read-only file system"))
    #expect(await AuthorizedKeyInstaller.install(identity, run: failing.run) == .failure(.host(.readOnlyFileSystem)))
  }
}
