import DriverrCore
import Foundation

/// The clients of the tmux server, from the `list-clients` that rides on the pane listing.
///
/// Each line starts with `marker`, so it is told apart from a pane row of the same output. A pane
/// row has nineteen fields and tmux's own ids, and a client line has neither.
enum TmuxClientFormat {
  static let marker = "__DRIVERR_CLIENT__"

  static var format: String { "\(marker) #{client_pid}" }

  /// Every client's pid, in tmux's order. A line that is not a client's is skipped.
  static func pids(from output: String) -> [Int] {
    output.split(separator: "\n").compactMap { line in
      guard line.hasPrefix("\(marker) ") else { return nil }
      return Int(line.dropFirst(marker.count + 1))
    }
  }
}

/// What one process was started with, as far as the mirror check needs it.
struct TmuxProcessDetails: Equatable, Sendable {
  /// `ps`'s `args`: the command line, its words joined by spaces.
  let arguments: String
  /// Only the variables in `TmuxProcessDetailsRead.variables`. The host never sends any other.
  let environment: [String: String]
}

/// One command that reads the command line and four environment variables of many processes.
///
/// **Only lines that start with `HERDR_PANE_ID=`, `HERDR_SESSION=`, `HERDR_SOCKET_PATH=` or
/// `TMUX=` leave the host.** A process's environment can hold tokens and keys, so the filter runs
/// on the host, in the command, and Driverr never sees the rest. `LiveTmuxProbeTests` checks that
/// a variable outside the four stays behind.
///
/// The filter reads lines, not variables. A value's tail after a space (macOS `ps -E`) or after a
/// newline (Linux `/proc` through `tr`) starts a line of its own, and a tail that starts with one
/// of the four names passes. Only the user's own environment can hold such a value, because only
/// the user's own processes are read.
///
/// Linux keeps a process's environment in `/proc/<pid>/environ`, NUL-separated. macOS has no
/// `/proc`, and `ps -wwE` prints the environment after the command line, separated by spaces. A
/// value that holds a space is cut at it on macOS. The Linux branch is not measured.
enum TmuxProcessDetailsRead {
  static let marker = "__DRIVERR_PROCESS__"

  static let variables = ["HERDR_PANE_ID", "HERDR_SESSION", "HERDR_SOCKET_PATH", "TMUX"]

  /// The script, wrapped for the login shell by `LoginShell.posix`. A process that has gone
  /// prints its boundary and nothing else.
  ///
  /// The pids are integers Driverr parsed, so nothing reaches the shell as syntax.
  static func command(forPIDs pids: [Int]) -> String {
    LoginShell.posix(script(forPIDs: pids))
  }

  static func script(forPIDs pids: [Int]) -> String {
    let names = variables.joined(separator: "|")
    return pids.map { pid in
      "printf '\\n%s\\n' '\(marker) \(pid)'; "
        + "ps -ww -o args= -p \(pid) 2>/dev/null | sed 's/^/args /'; "
        + "{ tr '\\0' '\\n' < /proc/\(pid)/environ || ps -wwE -o command= -p \(pid) | tr ' ' '\\n'; }"
        + " 2>/dev/null | grep -E '^(\(names))='"
    }
    .joined(separator: "; ")
  }

  /// What the command printed, by pid. A pid it did not ask for is dropped, and so is a
  /// variable outside the four, in case a host prints one.
  static func details(from output: String, forPIDs pids: [Int]) -> [Int: TmuxProcessDetails] {
    let asked = Set(pids)
    let wanted = Set(variables)
    var arguments: [Int: String] = [:]
    var environments: [Int: [String: String]] = [:]
    var current: Int?
    for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("\(marker) ") {
        current = Int(line.dropFirst(marker.count + 1)).flatMap { asked.contains($0) ? $0 : nil }
        if let current { environments[current] = [:] }
        continue
      }
      guard let pid = current else { continue }
      if line.hasPrefix("args ") {
        arguments[pid] = String(line.dropFirst("args ".count))
      } else if let equals = line.firstIndex(of: "=") {
        let name = String(line[..<equals])
        guard wanted.contains(name) else { continue }
        environments[pid, default: [:]][name] = String(line[line.index(after: equals)...])
      }
    }
    var details: [Int: TmuxProcessDetails] = [:]
    for (pid, environment) in environments {
      guard let arguments = arguments[pid] else { continue }
      details[pid] = TmuxProcessDetails(arguments: arguments, environment: environment)
    }
    return details
  }
}

/// Which panes of a tmux server show herdr, and which herdr panes show tmux. See `MirrorClaim`.
///
/// Measured on tmux 3.7c and herdr 0.9.5:
///
/// - **herdr in tmux.** The pane's foreground leader is `herdr`. `--session <n>`,
///   `--session=<n>` and `session attach <n>` name the session. With none, the client's
///   `HERDR_SOCKET_PATH`, then `HERDR_SESSION`, choose it, and else it is the standard one.
///   `--remote` shows another computer's herdr, so it never matches.
/// - **tmux in herdr.** A tmux client's environment carries `HERDR_PANE_ID`, which is Driverr's
///   herdr pane id, and `HERDR_SOCKET_PATH`. The standard session sets no `HERDR_SESSION`, so
///   the socket path decides.
/// - **A client with `TMUX` is skipped.** tmux copies the environment it started in into every
///   pane, so a server started inside herdr hands `HERDR_*` to a client started in one of its own
///   panes, which is not in herdr at all.
enum TmuxMirrors {
  /// Whether a process is herdr, by its command's last path component. Not `herdr-core` and not
  /// the app's `Herdr`.
  static func isHerdr(_ process: TmuxProcess) -> Bool {
    process.command.split(separator: "/").last == "herdr"
  }

  /// Each pane whose foreground group herdr leads, by raw pane id.
  static func herdrLeaders(
    rows: [TmuxPaneRow], processes: [TmuxProcess]
  ) -> [String: Int] {
    var leaders: [String: Int] = [:]
    for row in rows {
      guard let leader = TmuxProcessTable.foregroundGroup(forPaneTTY: row.tty, in: processes).first,
        leader.pid == leader.foregroundGroupID, isHerdr(leader)
      else { continue }
      leaders[row.paneID] = leader.pid
    }
    return leaders
  }

  /// The claims these panes and clients make, from what the host said of each process.
  static func claims(
    herdrLeaders: [String: Int],
    clientPIDs: [Int],
    details: [Int: TmuxProcessDetails]
  ) -> Set<MirrorClaim> {
    var claims: Set<MirrorClaim> = []
    for (paneID, pid) in herdrLeaders {
      // Every process in a tmux pane carries `TMUX`, so a leader without it is one whose
      // environment could not be read: a hardened binary, or a `/proc` the user cannot read.
      // Read as empty, a plain `herdr` would claim the standard session whatever it shows.
      guard let process = details[pid], process.environment["TMUX"] != nil,
        let session = herdrClientSession(
          arguments: process.arguments, environment: process.environment)
      else { continue }
      claims.insert(MirrorClaim(paneID: TmuxID.pane(paneID), session: session))
    }
    for pid in clientPIDs {
      guard let environment = details[pid]?.environment, environment["TMUX"] == nil,
        let pane = environment["HERDR_PANE_ID"], !pane.isEmpty
      else { continue }
      claims.insert(MirrorClaim(paneID: pane, session: session(from: environment)))
    }
    return claims
  }

  /// The herdr session a herdr command line shows, or `nil` when it is not a herdr client of this
  /// computer: another command, such as `herdr server` or `herdr pane list`, or `--remote`.
  ///
  /// Words are split at spaces, as `ps` joined them. A flag this does not know is passed over.
  static func herdrClientSession(
    arguments: String, environment: [String: String]
  ) -> HerdrSessionKey? {
    let words = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
    guard let program = words.first, program.split(separator: "/").last == "herdr" else {
      return nil
    }
    var named: String?
    var positional: [String] = []
    var rest = words.dropFirst()
    while let word = rest.popFirst() {
      if word == "--remote" || word.hasPrefix("--remote=") || word == "--machine"
        || word.hasPrefix("--machine=")
      {
        return nil
      } else if word == "--session" {
        named = rest.popFirst()
      } else if word.hasPrefix("--session=") {
        named = String(word.dropFirst("--session=".count))
      } else if word.hasPrefix("-") {
        continue
      } else {
        positional.append(word)
      }
    }
    if positional.count == 3, positional[0] == "session", positional[1] == "attach" {
      named = positional[2]
    } else if !positional.isEmpty {
      return nil
    }
    if let named, !named.isEmpty { return .named(named) }
    return session(from: environment)
  }

  /// The session a herdr process's environment points at: the socket path first, then the
  /// session name, and else the standard session.
  static func session(from environment: [String: String]) -> HerdrSessionKey {
    if let path = environment["HERDR_SOCKET_PATH"], !path.isEmpty {
      return HerdrSessionKey(socketPath: path)
    }
    if let name = environment["HERDR_SESSION"], !name.isEmpty { return .named(name) }
    return .standard
  }
}
