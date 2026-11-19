import DriverrCore
import DriverrHerdr
import Foundation

extension TmuxControl {
  /// Where tmux might be, in the order worth trying. The same three probes as herdr's, and for
  /// the same reason: an SSH exec channel runs a non-login shell whose `PATH` may lack Homebrew.
  ///
  /// It always exits 0, and the printed path is the whole result.
  static let discoveryCommand = #"""
    tmux_path=$(command -v tmux 2>/dev/null)
    if [ -n "$tmux_path" ]; then printf '%s\n' "$tmux_path"; exit 0; fi
    "${SHELL:-/bin/sh}" -lc 'command -v tmux' </dev/null 2>/dev/null
    for candidate in \#(fallbackPaths.map { "\"\($0)\"" }.joined(separator: " ")); do
      [ -x "$candidate" ] && printf '%s\n' "$candidate"
    done
    exit 0
    """#

  /// The directories herdr's discovery searches, with `tmux` in them.
  static var fallbackPaths: [String] { CLIControl.fallbackDirectories.map { "\($0)/tmux" } }

  /// An absolute path ending in `tmux`, which no banner, function body or alias line is.
  static func discoveredPath(in output: String) -> String? {
    for line in output.split(separator: "\n") {
      let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard candidate.hasPrefix("/"), candidate.split(separator: "/").last == "tmux" else {
        continue
      }
      return candidate
    }
    return nil
  }

  /// Finds tmux on the host and returns a control bound to it, or `nil` when it cannot be
  /// found. Whether that tmux is new enough is `tmuxAvailability()`'s answer. `open` and
  /// `resizesWindow` are `init`'s.
  public static func discovering(
    run: @escaping CommandRunner,
    open: StreamRunner? = nil,
    resizesWindow: @escaping @Sendable () async -> Bool = { true }
  ) async -> TmuxControl? {
    guard let result = try? await run(discoveryCommand),
      let path = discoveredPath(in: result.standardOutput)
    else { return nil }
    return TmuxControl(binaryPath: path, run: run, open: open, resizesWindow: resizesWindow)
  }
}
