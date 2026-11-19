#if DEBUG
import Foundation

/// A host's folders, answering `DirectoryListing.command(for:)` the way `sh` on the host
/// would. For tests and UI runs, where there is no shell.
///
/// A command is recognised by exact equality with `DirectoryListing.command(for:)` for a path
/// the fake knows, so a command wrapped a second time is not recognised. Any other listing
/// command answers as a failed `cd`. A command that is not a listing is not answered at all,
/// so a caller can pass it on to another fake.
public struct FakeDirectoryHost: Sendable {
  /// The login account's home folder, which `~` and an empty path resolve to.
  public let home: String
  /// Each folder's sub-folder names, by absolute path. A name listed under a folder that has
  /// no entry of its own is an empty folder.
  public let folders: [String: [String]]
  /// Folders that are listed but cannot be entered.
  public let unavailable: Set<String>

  public init(home: String, folders: [String: [String]], unavailable: Set<String> = []) {
    self.home = home
    self.folders = folders
    self.unavailable = unavailable
  }

  /// The answer to `command`, or `nil` when it is not a listing command.
  public func answer(_ command: String) -> CommandResult? {
    guard command.contains(DirectoryListing.marker) else { return nil }
    guard let path = knownPaths.first(where: { DirectoryListing.command(for: $0.requested) == command })?.resolved,
      !unavailable.contains(path)
    else {
      return CommandResult(
        standardOutput: "", standardError: "cd: can't cd to that folder\n", exitStatus: 2)
    }
    let names = (folders[path] ?? []).map { "./\($0)\0" }.joined()
    return CommandResult(
      standardOutput: "\n\(DirectoryListing.marker)\n\(path)\n\(names)", standardError: "",
      exitStatus: 0)
  }

  /// Every way a known folder can be asked for, and the absolute path each resolves to: home
  /// as an empty path and as `~`, and each folder by its absolute path and, under home, as
  /// `~/…`.
  private var knownPaths: [(requested: String, resolved: String)] {
    let children = folders.flatMap { parent, names in
      names.map { parent == "/" ? "/" + $0 : parent + "/" + $0 }
    }
    let absolute = Set([home] + folders.keys + children)
    var paths: [(requested: String, resolved: String)] = [("", home), ("~", home)]
    for path in absolute.sorted() {
      paths.append((path, path))
      if path.hasPrefix(home + "/") { paths.append(("~/" + path.dropFirst(home.count + 1), path)) }
    }
    return paths
  }
}
#endif
