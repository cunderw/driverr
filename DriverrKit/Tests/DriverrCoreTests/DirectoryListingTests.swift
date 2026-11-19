import Foundation
import Testing

@testable import DriverrCore

@Suite("DirectoryListing")
struct DirectoryListingTests {
  private static let tail = "&& pwd -P && find -L . -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null"

  private static func command(_ target: String) -> String {
    DirectoryListing.command(for: target)
  }

  private static func output(_ path: String, _ names: [String]) -> CommandResult {
    let body = names.map { "./\($0)\0" }.joined()
    return CommandResult(standardOutput: path + "\n" + body, standardError: "", exitStatus: 0)
  }

  // MARK: Command and quoting

  @Test("a plain path is passed to cd after `--`, with the whole command in one pipeline")
  func plainPath() {
    #expect(Self.command("/srv/app") == "cd -- /srv/app \(Self.tail)")
  }

  @Test("a path with a space is single-quoted")
  func spaces() {
    #expect(Self.command("/srv/my app") == "cd -- '/srv/my app' \(Self.tail)")
  }

  @Test("a single quote in a path cannot end the quoting")
  func singleQuote() {
    #expect(Self.command("/srv/it's") == #"cd -- '/srv/it'\''s' \#(Self.tail)"#)
  }

  @Test("a dollar sign and a backtick stay literal")
  func expansionCharacters() {
    #expect(Self.command("/srv/$HOME") == "cd -- '/srv/$HOME' \(Self.tail)")
    #expect(Self.command("/srv/`id`") == "cd -- '/srv/`id`' \(Self.tail)")
    #expect(Self.command("/srv/$(id)") == "cd -- '/srv/$(id)' \(Self.tail)")
  }

  @Test("a path starting with a dash reaches cd as a path, not an option")
  func leadingDash() {
    #expect(Self.command("-x") == "cd -- -x \(Self.tail)")
  }

  @Test("a leading tilde is the home directory, written with $HOME")
  func homeDirectory() {
    #expect(Self.command("~") == #"cd -- "$HOME" \#(Self.tail)"#)
    #expect(Self.command("~/") == #"cd -- "$HOME"/ \#(Self.tail)"#)
    #expect(Self.command("~/work") == #"cd -- "$HOME"/work \#(Self.tail)"#)
    #expect(Self.command("~/my work/it's") == #"cd -- "$HOME"/'my work/it'\''s' \#(Self.tail)"#)
  }

  @Test("an empty path means the home directory")
  func emptyPath() {
    #expect(Self.command("") == Self.command("~"))
  }

  @Test("another user's tilde is a literal name, never expanded")
  func tildeUser() {
    #expect(Self.command("~root") == "cd -- '~root' \(Self.tail)")
    #expect(Self.command("~root/x") == "cd -- '~root/x' \(Self.tail)")
  }

  @Test("a tilde that is not the first character is literal")
  func tildeInside() {
    #expect(Self.command("/srv/~/x") == "cd -- '/srv/~/x' \(Self.tail)")
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

  @Test("a clean exit with no resolved path is also an error")
  func noResolvedPath() {
    let result = CommandResult(standardOutput: "", standardError: "", exitStatus: 0)
    #expect(throws: AppError.directoryUnavailable(path: "~/x")) {
      try DirectoryListing.parse(result, requestedPath: "~/x")
    }
  }

  @Test("a non-zero exit is an error even when the shell printed the path first")
  func listFailure() {
    let result = CommandResult(standardOutput: "/locked\n", standardError: "", exitStatus: 1)
    #expect(throws: AppError.directoryUnavailable(path: "/locked")) {
      try DirectoryListing.parse(result, requestedPath: "/locked")
    }
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
      let base = URL(fileURLWithPath: realpath(temporary, nil).map { String(cString: $0) } ?? temporary)
      home = base.appendingPathComponent("driverr-dirlist-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func directory(_ name: String) throws {
      try FileManager.default.createDirectory(
        at: home.appendingPathComponent(name), withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: home) }

    func run(_ command: String) async throws -> CommandResult {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-c", command]
      process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
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
}
