import DriverrCore
import DriverrHerdr
import Foundation

extension CoreControl {
  /// The two names the program ships under, the unambiguous one first.
  ///
  /// `hc` is a short name, and another program can have it.
  static let binaryNames = ["herdr-core", "hc"]

  /// How long the whole search may take. On a host with the TUI this runs beside
  /// `CLIControl.discovering`, so a strange `hc` that never answers costs this and fails
  /// nothing.
  public static let discoveryDeadline: Duration = .seconds(6)

  /// Where a core might be, in the same three tiers as `CLIControl.discoveryCommand`.
  ///
  /// Each tier prints every match rather than stopping at `hc`, so a `herdr-core` further down
  /// still wins. Stops early only on the first tier's `herdr-core`, which nothing can beat,
  /// and which saves the login shell. `discoveredPath(in:)` chooses.
  ///
  /// It always exits 0. The printed paths are the whole result.
  static let discoveryCommand = #"""
    core_path=$(command -v herdr-core 2>/dev/null)
    if [ -n "$core_path" ]; then printf '%s\n' "$core_path"; exit 0; fi
    command -v hc 2>/dev/null
    "${SHELL:-/bin/sh}" -lc 'command -v herdr-core; command -v hc' </dev/null 2>/dev/null
    for candidate in \#(fallbackPaths.map { "\"\($0)\"" }.joined(separator: " ")); do
      [ -x "$candidate" ] && printf '%s\n' "$candidate"
    done
    exit 0
    """#

  private static var fallbackPaths: [String] {
    binaryNames.flatMap { name in CLIControl.fallbackDirectories.map { "\($0)/\(name)" } }
  }

  /// Picks the core's path out of the probe's output: the first absolute path to
  /// `herdr-core`, or failing that to `hc`.
  ///
  /// Absolute only, because a login profile may print a banner, and `command -v` prints an
  /// alias or a function by its definition.
  static func discoveredPath(in output: String) -> String? {
    let candidates = output.split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { $0.hasPrefix("/") }
    for name in binaryNames {
      if let path = candidates.first(where: { $0.split(separator: "/").last.map(String.init) == name }) {
        return path
      }
    }
    return nil
  }

  /// Asks for the host's home directory. See `CoreControl.home`.
  static let homeCommand = #"printf '%s' "$HOME""#

  /// The home directory out of `homeCommand`'s output: its last line, if that is absolute.
  ///
  /// The last, because a login file may print a banner first, and only ahead of the command.
  static func discoveredHome(in output: String) -> String? {
    let line = output.split(separator: "\n").last?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return line?.hasPrefix("/") == true ? line : nil
  }

  /// Finds a core on the host and returns a control already connected to it.
  ///
  /// Connecting is the only test of what the program is, so a stranger called `hc` is
  /// `nil` here, as is a host with neither name. A core this build refuses is returned,
  /// because its `availability()` has something to tell the user.
  ///
  /// `nil` too when `deadline` passes. Abandoned rather than awaited, as in
  /// `ConnectionModel.bounded`: nothing under the exec channel checks cancellation.
  public static func discovering(
    run: @escaping CommandRunner,
    open: @escaping StreamRunner,
    deadline: Duration = discoveryDeadline,
    callDeadline: Duration = defaultCallDeadline
  ) async -> CoreControl? {
    let search = Task { () -> CoreControl? in
      guard let result = try? await run(discoveryCommand),
        let path = discoveredPath(in: result.standardOutput),
        !Task.isCancelled
      else { return nil }

      let home = try? await run(homeCommand)
      let control = CoreControl(
        binaryPath: path,
        home: home.flatMap { discoveredHome(in: $0.standardOutput) },
        callDeadline: callDeadline,
        open: open
      )
      let handshake = await control.link.established().handshake
      guard handshake != .notCore else { return nil }
      guard !Task.isCancelled else {
        await control.link.close()
        return nil
      }
      return control
    }
    return await withCheckedContinuation { continuation in
      let race = DiscoveryRace(continuation)
      Task { race.settle(await search.value) }
      Task {
        try? await Task.sleep(for: deadline)
        search.cancel()
        race.settle(nil)
      }
    }
  }
}

/// The first answer of a search and its deadline, whichever comes.
///
/// A lock and not a task group, which would wait for the search that hung.
private final class DiscoveryRace: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<CoreControl?, Never>?

  init(_ continuation: CheckedContinuation<CoreControl?, Never>) {
    self.continuation = continuation
  }

  func settle(_ control: CoreControl?) {
    let waiting = lock.withLock {
      defer { continuation = nil }
      return continuation
    }
    waiting?.resume(returning: control)
  }
}
