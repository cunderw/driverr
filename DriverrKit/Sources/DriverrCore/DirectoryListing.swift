import Foundation

/// The sub-folders of one folder on the SSH host, for the folder browser that starts an
/// agent in a chosen folder.
///
/// It browses the SSH host's own file system only. A machine a herdr-core added has its own
/// file system, and nothing here reaches it.
///
/// `command(for:)` builds one shell command, run over an SSH exec channel, and
/// `parse(_:requestedPath:)` reads its output. The two live together so the output shape has
/// one owner. A path is never concatenated into the command unquoted.
///
/// The exec channel hands the command to the login shell, which may be fish, so the script
/// runs under `sh -c`, quoted by `HookInstallCommands.loginShellQuoted`: fish reads `\'` and
/// `\\` inside single quotes as escapes, and a folder name can hold both.
///
/// The output is a marker line, the resolved path and the names. The parse starts at the
/// marker, because an rc file can print before the command does. A folder whose own name
/// holds a line break is listed correctly. A resolved path that holds one is not.
public struct DirectoryListing: Hashable, Sendable {
  /// The most names one listing keeps. A folder with more is cut and marked `isTruncated`,
  /// so a huge folder does not become a huge list on a phone.
  public static let entryLimit = 500

  /// The folder's absolute path with symlinks resolved, as `pwd -P` printed it. No trailing
  /// slash, except the root, which is `/`.
  public let path: String
  /// Sub-folder names, sorted without regard to case. Dot folders are left out: a typed path
  /// still reaches them. Symlinks to folders are included.
  public let names: [String]
  /// The folder had more than `entryLimit` visible sub-folders, and `names` holds the first
  /// ones in sorted order.
  public let isTruncated: Bool

  public init(path: String, names: [String], isTruncated: Bool) {
    self.path = path
    self.names = names
    self.isTruncated = isTruncated
  }

  /// The line that opens the output, on a line of its own.
  static let marker = "driverr-directory-listing"

  /// The shell command that lists `path`.
  ///
  /// A leading `~` is the login account's home and is written as `"$HOME"`, because a
  /// quoted `~` does not expand. `~user` is a folder name like any other. An empty path means
  /// the home folder.
  ///
  /// `cd`'s own output goes to `/dev/null`: with `CDPATH` set, or for `cd -`, it prints the
  /// folder, and that line would stand in front of the path. The marker is printed after a
  /// line break, so a banner with no final newline does not glue onto it. `find`'s status is
  /// ignored: it fails on a folder that can be entered but not read, and on a symlink loop,
  /// and the names it did print are still right.
  public static func command(for path: String) -> String {
    let script =
      "cd -- \(cdArgument(path)) >/dev/null && printf '\\n%s\\n' \(marker) && pwd -P && "
      + "{ find -L . -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null; true; }"
    return "sh -c " + HookInstallCommands.loginShellQuoted(script)
  }

  private static func cdArgument(_ path: String) -> String {
    if path.isEmpty || path == "~" { return #""$HOME""# }
    if path.hasPrefix("~/") {
      let rest = String(path.dropFirst(2))
      return rest.isEmpty ? #""$HOME"/"# : #""$HOME"/"# + shellQuoted(rest)
    }
    return shellQuoted(path)
  }

  /// Reads the output of `command(for:)`.
  ///
  /// - Throws: `AppError.directoryUnavailable` when the output holds no marker and path: the
  ///   `cd` failed. It is named after `requestedPath`, which is what the user typed or
  ///   picked. The exit status is not read: a failure after the path is `find`'s.
  public static func parse(_ result: CommandResult, requestedPath: String) throws -> DirectoryListing {
    let unavailable = AppError.directoryUnavailable(path: requestedPath)
    // Scalars, not Characters: "\r\n" is one Character, and a name may end in one.
    let all = Array(result.standardOutput.unicodeScalars)
    guard let found = all.firstRange(of: Array("\n\(marker)\n".unicodeScalars)) else { throw unavailable }
    let scalars = all[found.upperBound...]
    guard let lineEnd = scalars.firstIndex(of: "\n") else { throw unavailable }
    let resolved = normalised(String(String.UnicodeScalarView(scalars[..<lineEnd])))
    guard !resolved.isEmpty else { throw unavailable }

    var names: [String] = []
    for entry in scalars[scalars.index(after: lineEnd)...].split(separator: "\0") {
      var name = String(String.UnicodeScalarView(entry))
      if name.hasPrefix("./") { name.removeFirst(2) }
      guard !name.isEmpty, !name.hasPrefix(".") else { continue }
      names.append(name)
    }
    names.sort {
      let order = $0.compare($1, options: .caseInsensitive)
      // Names that differ only in case still need one fixed order.
      return order == .orderedSame ? $0 < $1 : order == .orderedAscending
    }
    return DirectoryListing(
      path: resolved,
      names: Array(names.prefix(entryLimit)),
      isTruncated: names.count > entryLimit
    )
  }

  /// `path` without trailing slashes, and `/` for the root.
  private static func normalised(_ path: String) -> String {
    guard path.hasPrefix("/") else { return path }
    var trimmed = Substring(path)
    while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
    return String(trimmed)
  }

  /// The absolute path of a sub-folder of this one, to browse it or to start an agent in it.
  public func childPath(_ name: String) -> String {
    path == "/" ? "/" + name : path + "/" + name
  }
}
