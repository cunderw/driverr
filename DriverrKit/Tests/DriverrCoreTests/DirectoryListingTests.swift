import Foundation
import Testing

@testable import DriverrCore

@Suite("DirectoryListing")
struct DirectoryListingTests {
  private static let marker = "driverr-directory-listing"

  private static func command(_ target: String) -> String {
    DirectoryListing.command(for: target)
  }

  /// The command the exec channel hands the login shell, for a `cd` argument already quoted.
  private static func expected(_ cdArgument: String) -> String {
    "sh -c " + HookInstallCommands.loginShellQuoted(script(cdArgument))
  }

  private static func script(_ cdArgument: String) -> String {
    "cd -- \(cdArgument) >/dev/null && printf '\\n%s\\n' \(marker) && pwd -P && "
      + "{ find -L . -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null; true; }"
  }

  /// What the command prints: the marker, the resolved path, then the NUL-terminated names.
  private static func output(_ path: String, _ names: [String], noise: String = "") -> CommandResult {
    let body = names.map { "./\($0)\0" }.joined()
    return CommandResult(
      standardOutput: noise + "\n" + marker + "\n" + path + "\n" + body, standardError: "", exitStatus: 0)
  }

  // MARK: Command and quoting

  @Test("a plain path is passed to cd after `--`, and the whole script runs under `sh -c`")
  func plainPath() {
    #expect(Self.command("/srv/app") == Self.expected("/srv/app"))
  }

  @Test("a path with a space is single-quoted")
  func spaces() {
    #expect(Self.command("/srv/my app") == Self.expected("'/srv/my app'"))
  }

  @Test("a single quote in a path cannot end the quoting")
  func singleQuote() {
    #expect(Self.command("/srv/it's") == Self.expected(#"'/srv/it'\''s'"#))
  }

  @Test("a dollar sign and a backtick stay literal")
  func expansionCharacters() {
    #expect(Self.command("/srv/$HOME") == Self.expected("'/srv/$HOME'"))
    #expect(Self.command("/srv/`id`") == Self.expected("'/srv/`id`'"))
    #expect(Self.command("/srv/$(id)") == Self.expected("'/srv/$(id)'"))
  }

  @Test("a path starting with a dash reaches cd as a path, not an option")
  func leadingDash() {
    #expect(Self.command("-x") == Self.expected("-x"))
  }

  @Test("a leading tilde is the home directory, written with $HOME")
  func homeDirectory() {
    #expect(Self.command("~") == Self.expected(#""$HOME""#))
    #expect(Self.command("~/") == Self.expected(#""$HOME"/"#))
    #expect(Self.command("~/work") == Self.expected(#""$HOME"/work"#))
    #expect(Self.command("~/my work/it's") == Self.expected(#""$HOME"/'my work/it'\''s'"#))
  }

  @Test("an empty path means the home directory")
  func emptyPath() {
    #expect(Self.command("") == Self.command("~"))
  }

  @Test("another user's tilde is a literal name, never expanded")
  func tildeUser() {
    #expect(Self.command("~root") == Self.expected("'~root'"))
    #expect(Self.command("~root/x") == Self.expected("'~root/x'"))
  }

  @Test("a tilde that is not the first character is literal")
  func tildeInside() {
    #expect(Self.command("/srv/~/x") == Self.expected("'/srv/~/x'"))
  }

  /// The login shell may be fish, which reads `\\'` and `\\\\` inside single quotes as escapes.
  /// This reads the word the way fish does, so a quoting that only bash, zsh and dash read
  /// back correctly fails here.
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

  @Test("a name holding a backslash and a quote reaches sh as one literal word, even through fish")
  func fishSafeWord() {
    let hostile = #"/srv/a\'; touch p; #"#
    let word = Self.fishWord(afterShC: Self.command(hostile))
    #expect(word == Self.script(#"'/srv/a\'\''; touch p; #'"#))
  }

  // MARK: Parsing

  @Test("the first line is the resolved path and the names follow, NUL-separated")
  func basicParse() throws {
    let listing = try DirectoryListing.parse(Self.output("/srv/app", ["web", "api"]), requestedPath: "~/app")
    #expect(listing.path == "/srv/app")
    #expect(listing.names == ["api", "web"])
    #expect(!listing.isTruncated)
  }

  @Test("an empty folder is an empty listing, not an error")
  func emptyFolder() throws {
    let listing = try DirectoryListing.parse(Self.output("/srv/empty", []), requestedPath: "/srv/empty")
    #expect(listing.path == "/srv/empty")
    #expect(listing.names.isEmpty)
    #expect(!listing.isTruncated)
  }

  @Test("names with spaces, newlines, quotes and unicode survive NUL splitting")
  func oddNames() throws {
    let names = ["my app", "two\nlines", "carriage\r\nreturn", "it's", "日本語", "e\u{301}clair", "😀 fun", "$HOME"]
    let listing = try DirectoryListing.parse(Self.output("/p", names), requestedPath: "/p")
    #expect(Set(listing.names) == Set(names))
    #expect(listing.names.count == names.count)
  }

  @Test("dot directories are hidden")
  func dotDirectoriesHidden() throws {
    let listing = try DirectoryListing.parse(
      Self.output("/p", [".git", ".config", "src", "...", ".", "docs"]), requestedPath: "/p")
    #expect(listing.names == ["docs", "src"])
  }

  @Test("names sort case-insensitively, with a stable order between names that differ only in case")
  func sortOrder() throws {
    let listing = try DirectoryListing.parse(
      Self.output("/p", ["banana", "apple", "Cherry", "Apple", "cherry"]), requestedPath: "/p")
    #expect(listing.names == ["Apple", "apple", "banana", "Cherry", "cherry"])
  }

  @Test("the 500th name is the last one kept and exactly 500 is not truncated")
  func capBoundary() throws {
    let exact = (0..<500).map { String(format: "d%03d", $0) }
    let listing = try DirectoryListing.parse(Self.output("/p", exact), requestedPath: "/p")
    #expect(listing.names.count == 500)
    #expect(!listing.isTruncated)
  }

  @Test("more than 500 names keep the first 500 in sorted order and mark the listing truncated")
  func capTruncates() throws {
    let all = (0..<501).map { String(format: "d%03d", $0) }
    let listing = try DirectoryListing.parse(Self.output("/p", all.reversed()), requestedPath: "/p")
    #expect(listing.names.count == DirectoryListing.entryLimit)
    #expect(listing.names.first == "d000")
    #expect(listing.names.last == "d499")
    #expect(listing.isTruncated)
  }

  @Test("hidden directories do not count toward the cap")
  func hiddenDoNotCount() throws {
    let visible = (0..<500).map { String(format: "d%03d", $0) }
    let hidden = (0..<50).map { ".h\($0)" }
    let listing = try DirectoryListing.parse(Self.output("/p", visible + hidden), requestedPath: "/p")
    #expect(listing.names.count == 500)
    #expect(!listing.isTruncated)
  }

  @Test("a resolved path with trailing slashes is normalised, and the root stays a slash")
  func resolvedPathShape() throws {
    let trailing = try DirectoryListing.parse(Self.output("/srv/app/", ["x"]), requestedPath: "/srv/app")
    #expect(trailing.path == "/srv/app")
    let doubled = try DirectoryListing.parse(Self.output("/srv/app//", ["x"]), requestedPath: "/srv/app")
    #expect(doubled.path == "/srv/app")
    let root = try DirectoryListing.parse(Self.output("/", ["usr", "etc"]), requestedPath: "/")
    #expect(root.path == "/")
    #expect(root.names == ["etc", "usr"])
  }

  @Test("a child path joins with one slash, including under the root")
  func childPath() throws {
    let root = try DirectoryListing.parse(Self.output("/", ["usr"]), requestedPath: "/")
    #expect(root.childPath("usr") == "/usr")
    let nested = try DirectoryListing.parse(Self.output("/srv/app", ["web"]), requestedPath: "/srv/app")
    #expect(nested.childPath("web") == "/srv/app/web")
    // A name that looks like a tilde is a folder in this one, so the path stays absolute.
    #expect(nested.childPath("~") == "/srv/app/~")
  }

  // MARK: Failure

  @Test("a failed cd is an AppError naming the requested path")
  func cdFailure() {
    let result = CommandResult(
      standardOutput: "", standardError: "cd: no such file or directory: /nope", exitStatus: 1)
    #expect(throws: AppError.directoryUnavailable(path: "/nope")) {
      try DirectoryListing.parse(result, requestedPath: "/nope")
    }
  }

  @Test("a marker with no path after it is an error")
  func markerWithoutPath() {
    let result = CommandResult(standardOutput: "\n\(Self.marker)\n", standardError: "", exitStatus: 0)
    #expect(throws: AppError.directoryUnavailable(path: "/x")) {
      try DirectoryListing.parse(result, requestedPath: "/x")
    }
  }

  @Test("a clean exit with no resolved path is also an error")
  func noResolvedPath() {
    let result = CommandResult(standardOutput: "", standardError: "", exitStatus: 0)
    #expect(throws: AppError.directoryUnavailable(path: "~/x")) {
      try DirectoryListing.parse(result, requestedPath: "~/x")
    }
  }

  @Test("a non-zero exit after the path line is find's, and the names it did print are kept")
  func findFailureAfterThePath() throws {
    var result = Self.output("/srv/app", ["web", "api"])
    result = CommandResult(standardOutput: result.standardOutput, standardError: "", exitStatus: 1)
    let listing = try DirectoryListing.parse(result, requestedPath: "/srv/app")
    #expect(listing.path == "/srv/app")
    #expect(listing.names == ["api", "web"])
  }

  @Test("a folder that can be entered but not read lists as empty")
  func enteredButUnreadable() throws {
    let result = CommandResult(
      standardOutput: "\n\(Self.marker)\n/locked\n", standardError: "", exitStatus: 1)
    let listing = try DirectoryListing.parse(result, requestedPath: "/locked")
    #expect(listing.path == "/locked")
    #expect(listing.names.isEmpty)
  }

  @Test("output before the marker, with or without a line break, is not the path")
  func leadingNoise() throws {
    for noise in ["Last login: today\nWelcome", "banner with no break", "dos line\r\n", "/looks/like/a/path\n"] {
      let listing = try DirectoryListing.parse(
        Self.output("/srv/app", ["web"], noise: noise), requestedPath: "/srv/app")
      #expect(listing.path == "/srv/app", "noise: \(noise.debugDescription)")
      #expect(listing.names == ["web"], "noise: \(noise.debugDescription)")
    }
  }

  @Test("a name equal to the marker is a name")
  func markerAsName() throws {
    let listing = try DirectoryListing.parse(
      Self.output("/srv/app", [Self.marker, "web"]), requestedPath: "/srv/app")
    #expect(listing.names == [Self.marker, "web"])
  }

  @Test("the error reads in plain words, names the path and is not retryable")
  func errorWording() {
    let error = AppError.directoryUnavailable(path: "/nope")
    #expect(error.errorDescription?.contains("/nope") == true)
    #expect(!error.isRetryable)
  }
}

/// The built command, run by a real `/bin/sh` against a scratch tree.
///
/// A string comparison cannot show that the quoting survives a shell, that `-L` lists a
/// symlinked folder, or that a newline in a name does not split an entry.
@Suite("DirectoryListing in a real shell")
struct DirectoryListingShellTests {
  private struct Scratch {
    let home: URL

    init() throws {
      // The physical path, so the resolved path `pwd -P` prints compares equal. Not
      // `resolvingSymlinksInPath()`, which turns `/private/var` back into `/var`.
      let temporary = FileManager.default.temporaryDirectory.path
      var physical = temporary
      if let resolved = realpath(temporary, nil) {
        physical = String(cString: resolved)
        free(resolved)
      }
      let base = URL(fileURLWithPath: physical)
      home = base.appendingPathComponent("driverr-dirlist-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func directory(_ name: String) throws {
      try FileManager.default.createDirectory(
        at: home.appendingPathComponent(name), withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: home) }

    /// Reads a pipe to its end on a dispatch thread, so no cooperative thread blocks and the
    /// child never stalls on a full pipe.
    private static func drain(_ pipe: Pipe) async -> String {
      await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
          let data = pipe.fileHandleForReading.readDataToEndOfFile()
          continuation.resume(returning: String(decoding: data, as: UTF8.self))
        }
      }
    }

    /// Runs `command` as the exec channel does, under `/bin/sh -c`. `HOME` is the scratch
    /// folder, and `extra` adds to the environment.
    func run(_ command: String, extra: [String: String] = [:]) async throws -> CommandResult {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-c", command]
      process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"].merging(extra) { $1 }
      let outputPipe = Pipe()
      let errorPipe = Pipe()
      process.standardOutput = outputPipe
      process.standardError = errorPipe
      // Both pipes are read while the child runs: a listing past the pipe buffer would
      // otherwise block it, and it would never exit. Waits on the termination handler rather
      // than `waitUntilExit()`, so no cooperative thread blocks (CLAUDE.md, "Never block a
      // cooperative thread in a Kit test").
      async let standardOutput = Self.drain(outputPipe)
      async let standardError = Self.drain(errorPipe)
      let status: Int32
      do {
        status = try await withCheckedThrowingContinuation { continuation in
          process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
          do { try process.run() } catch { continuation.resume(throwing: error) }
        }
      } catch {
        // The drains end when the write sides close, which `run()` never got to do.
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        throw error
      }
      return CommandResult(
        standardOutput: await standardOutput, standardError: await standardError, exitStatus: Int(status))
    }
  }

  private func populate(_ scratch: Scratch) throws {
    for name in ["plain", "with space", "it's", "two\nlines", "ünï", "$HOME", ".hidden", "Zed"] {
      try scratch.directory(name)
    }
    try "x".write(to: scratch.home.appendingPathComponent("afile"), atomically: false, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: scratch.home.appendingPathComponent("link"),
      withDestinationURL: scratch.home.appendingPathComponent("plain"))
  }

  private static let expected = ["$HOME", "it's", "link", "plain", "two\nlines", "with space", "Zed", "ünï"]

  @Test("an absolute path lists folders and symlinked folders, and skips files and dot folders")
  func absolutePath() async throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    try populate(scratch)
    let result = try await scratch.run(DirectoryListing.command(for: scratch.home.path))
    let listing = try DirectoryListing.parse(result, requestedPath: scratch.home.path)
    #expect(listing.path == scratch.home.path)
    #expect(listing.names == Self.expected)
    #expect(!listing.isTruncated)
  }

  @Test("a tilde path resolves against the login account's home")
  func tildePath() async throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    try populate(scratch)
    try scratch.directory("sub dir/inner")
    let result = try await scratch.run(DirectoryListing.command(for: "~/sub dir"))
    let listing = try DirectoryListing.parse(result, requestedPath: "~/sub dir")
    #expect(listing.path == scratch.home.appendingPathComponent("sub dir").path)
    #expect(listing.names == ["inner"])
    let home = try await scratch.run(DirectoryListing.command(for: "~"))
    #expect(try DirectoryListing.parse(home, requestedPath: "~").path == scratch.home.path)
  }

  @Test("a hostile path is one argument to cd and runs nothing")
  func hostilePath() async throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let marker = scratch.home.appendingPathComponent("injected")
    let target = "/nonexistent'; touch '\(marker.path)'; '"
    let result = try await scratch.run(DirectoryListing.command(for: target))
    #expect(result.exitStatus != 0)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(throws: AppError.directoryUnavailable(path: target)) {
      try DirectoryListing.parse(result, requestedPath: target)
    }
  }

  @Test("a symlinked path resolves to the real one")
  func symlinkedPath() async throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    try scratch.directory("real/child")
    try FileManager.default.createSymbolicLink(
      at: scratch.home.appendingPathComponent("alias"),
      withDestinationURL: scratch.home.appendingPathComponent("real"))
    let alias = scratch.home.appendingPathComponent("alias").path
    let result = try await scratch.run(DirectoryListing.command(for: alias))
    let listing = try DirectoryListing.parse(result, requestedPath: alias)
    #expect(listing.path == scratch.home.appendingPathComponent("real").path)
    #expect(listing.names == ["child"])
  }

  @Test("a folder that is not there fails with the AppError")
  func missingFolder() async throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let missing = scratch.home.appendingPathComponent("absent").path
    let result = try await scratch.run(DirectoryListing.command(for: missing))
    #expect(throws: AppError.directoryUnavailable(path: missing)) {
      try DirectoryListing.parse(result, requestedPath: missing)
    }
  }

  @Test("a file in place of a folder fails with the AppError")
  func fileNotFolder() async throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let file = scratch.home.appendingPathComponent("afile")
    try "x".write(to: file, atomically: false, encoding: .utf8)
    let result = try await scratch.run(DirectoryListing.command(for: file.path))
    #expect(throws: AppError.directoryUnavailable(path: file.path)) {
      try DirectoryListing.parse(result, requestedPath: file.path)
    }
  }

  @Test("a CDPATH hit prints the folder from cd, and the listing is still the folder's own")
  func cdpath() async throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    try scratch.directory("projects/proj/inner")
    let base = scratch.home.appendingPathComponent("projects").path
    let result = try await scratch.run(DirectoryListing.command(for: "proj"), extra: ["CDPATH": base])
    let listing = try DirectoryListing.parse(result, requestedPath: "proj")
    #expect(listing.path == scratch.home.appendingPathComponent("projects/proj").path)
    #expect(listing.names == ["inner"])
  }

  @Test("`cd -` prints the folder it returns to, and the listing is still the folder's own")
  func previousFolder() async throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    try scratch.directory("back/inner")
    let back = scratch.home.appendingPathComponent("back").path
    let result = try await scratch.run(DirectoryListing.command(for: "-"), extra: ["OLDPWD": back])
    let listing = try DirectoryListing.parse(result, requestedPath: "-")
    #expect(listing.path == back)
    #expect(listing.names == ["inner"])
  }

  @Test("a folder that can be entered but not read lists as empty, not as unavailable")
  func executeOnlyFolder() async throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    try scratch.directory("closed/inner")
    let closed = scratch.home.appendingPathComponent("closed")
    try FileManager.default.setAttributes([.posixPermissions: 0o111], ofItemAtPath: closed.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: closed.path) }
    let result = try await scratch.run(DirectoryListing.command(for: closed.path))
    let listing = try DirectoryListing.parse(result, requestedPath: closed.path)
    #expect(listing.path == closed.path)
    #expect(listing.names.isEmpty)
  }

  @Test("a folder that cannot be entered is still unavailable")
  func lockedFolder() async throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    try scratch.directory("locked")
    let locked = scratch.home.appendingPathComponent("locked")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
    let result = try await scratch.run(DirectoryListing.command(for: locked.path))
    #expect(throws: AppError.directoryUnavailable(path: locked.path)) {
      try DirectoryListing.parse(result, requestedPath: locked.path)
    }
  }

  @Test("a self-referencing symlink does not hide its siblings")
  func loopingSymlink() async throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    try scratch.directory("real")
    try FileManager.default.createSymbolicLink(
      atPath: scratch.home.appendingPathComponent("loop").path, withDestinationPath: "loop")
    let result = try await scratch.run(DirectoryListing.command(for: scratch.home.path))
    let listing = try DirectoryListing.parse(result, requestedPath: scratch.home.path)
    #expect(listing.names.contains("real"))
  }

  @Test("output an rc file printed before the command, with no line break, does not reach the path")
  func shellBanner() async throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    try scratch.directory("inner")
    let result = try await scratch.run("printf 'welcome'; " + DirectoryListing.command(for: scratch.home.path))
    let listing = try DirectoryListing.parse(result, requestedPath: scratch.home.path)
    #expect(listing.path == scratch.home.path)
    #expect(listing.names == ["inner"])
  }

  @Test("a folder named with a backslash and a quote is browsed into, and nothing in its name runs")
  func backslashQuoteName() async throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let name = #"a\'; touch p; #"#
    try scratch.directory(name + "/inner")
    let top = try DirectoryListing.parse(
      try await scratch.run(DirectoryListing.command(for: scratch.home.path)), requestedPath: scratch.home.path)
    #expect(top.names == [name])
    let child = top.childPath(name)
    let result = try await scratch.run(DirectoryListing.command(for: child))
    let listing = try DirectoryListing.parse(result, requestedPath: child)
    #expect(listing.path == child)
    #expect(listing.names == ["inner"])
    #expect(!FileManager.default.fileExists(atPath: scratch.home.appendingPathComponent("p").path))
  }

  @Test("a listing far past the pipe buffer is read whole")
  func largeListing() async throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    for index in 0..<600 { try scratch.directory(String(format: "%@%03d", String(repeating: "n", count: 100), index)) }
    let result = try await scratch.run(DirectoryListing.command(for: scratch.home.path))
    #expect(result.standardOutput.utf8.count > 65_536)
    let listing = try DirectoryListing.parse(result, requestedPath: scratch.home.path)
    #expect(listing.names.count == DirectoryListing.entryLimit)
    #expect(listing.isTruncated)
  }
}
