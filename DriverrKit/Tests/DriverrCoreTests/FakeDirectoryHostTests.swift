import Foundation
import Testing

@testable import DriverrCore

/// `DirectoryListing.read` and the fake that answers it in UI runs.
private actor Sent {
  var commands: [String] = []
  func append(_ command: String) { commands.append(command) }
}

@Suite("FakeDirectoryHost and DirectoryListing.read")
struct FakeDirectoryHostTests {
  private let host = FakeDirectoryHost(
    home: "/home/user",
    folders: [
      "/home/user": ["dev", "notes", "locked"],
      "/home/user/dev": ["app", "site"],
    ],
    unavailable: ["/home/user/locked"]
  )

  private func read(_ path: String) async throws -> DirectoryListing {
    let host = host
    return try await DirectoryListing.read(path) { command in
      try #require(host.answer(command))
    }
  }

  @Test("the command reaches the runner once, exactly as `command(for:)` builds it")
  func sentOnce() async throws {
    let sent = Sent()
    let host = host
    _ = try await DirectoryListing.read("~/dev") { command in
      await sent.append(command)
      return host.answer(command) ?? CommandResult(standardOutput: "", standardError: "", exitStatus: 127)
    }
    let commands = await sent.commands
    #expect(commands == [DirectoryListing.command(for: "~/dev")])
    // One `sh -c`, not two: the command wraps itself, and the runner must not.
    #expect(commands.first?.hasPrefix("sh -c 'cd -- ") == true)
  }

  @Test("home, a home-relative path and an absolute path each list their folder")
  func lists() async throws {
    #expect(try await read("") == DirectoryListing(path: "/home/user", names: ["dev", "locked", "notes"], isTruncated: false))
    #expect(try await read("~").path == "/home/user")
    #expect(try await read("~/dev") == DirectoryListing(path: "/home/user/dev", names: ["app", "site"], isTruncated: false))
    #expect(try await read("/home/user/dev").names == ["app", "site"])
  }

  @Test("a folder listed under another, with no entry of its own, is empty")
  func emptyChild() async throws {
    #expect(try await read("/home/user/dev/app") == DirectoryListing(path: "/home/user/dev/app", names: [], isTruncated: false))
  }

  @Test("a folder that cannot be entered, and one that does not exist, are unavailable")
  func unavailable() async throws {
    await #expect(throws: AppError.directoryUnavailable(path: "/home/user/locked")) {
      try await read("/home/user/locked")
    }
    await #expect(throws: AppError.directoryUnavailable(path: "/nope")) {
      try await read("/nope")
    }
  }

  @Test("more names than a listing keeps are cut and marked")
  func truncated() async throws {
    let names = (1...(DirectoryListing.entryLimit + 20)).map { String(format: "pkg-%03d", $0) }
    let big = FakeDirectoryHost(home: "/h", folders: ["/h": names])
    let listing = try await DirectoryListing.read("~") { try #require(big.answer($0)) }
    #expect(listing.names.count == DirectoryListing.entryLimit)
    #expect(listing.isTruncated)
  }

  @Test("a command that is not a listing is not answered, and one wrapped twice is a failed cd")
  func others() throws {
    #expect(host.answer("uname -a") == nil)
    let twice = LoginShell.posix(DirectoryListing.command(for: "~"))
    let answer = try #require(host.answer(twice))
    #expect(answer.exitStatus != 0)
  }

  @Test("a failure from the runner reaches the caller")
  func runnerFailure() async {
    await #expect(throws: AppError.notConnected(host: "box")) {
      try await DirectoryListing.read("~") { _ in throw AppError.notConnected(host: "box") }
    }
  }
}
