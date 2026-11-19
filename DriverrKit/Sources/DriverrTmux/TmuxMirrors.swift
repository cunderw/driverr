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

/// One command that reads the command line and six environment variables of many processes.
///
/// **Only lines that start with `HERDR_PANE_ID=`, `HERDR_SESSION=`, `HERDR_SOCKET_PATH=`,
/// `TMUX=`, `HC_SESSION=` or `HC_SOCKET=` leave the host.** A process's environment can hold
/// tokens and keys, so the filter runs on the host, in the command, and Driverr never sees the
/// rest. `LiveTmuxProbeTests` checks that a variable outside the six stays behind.
///
/// The filter reads lines, not variables. A value's tail after a space (macOS `ps -E`) or after a
/// newline (Linux `/proc` through `tr`) starts a line of its own, and a tail that starts with one
/// of the six names passes. Only the user's own environment can hold such a value, because only
/// the user's own processes are read.
///
/// Linux keeps a process's environment in `/proc/<pid>/environ`, NUL-separated. macOS has no
/// `/proc`, and `ps -wwE` prints the environment after the command line, separated by spaces. A
/// value that holds a space is cut at it on macOS. The Linux branch is not measured.
///
/// Measured on macOS: `ps -wwE` reads the hardened `hc` client as the same user. A login `zsh`
/// in a tmux or herdr pane shows no environment at all, so a shell is never the one read.
enum TmuxProcessDetailsRead {
  static let marker = "__DRIVERR_PROCESS__"
  /// The boundary before the exec channel's own `HC_SESSION` and `HC_SOCKET`. See
  /// `script(forPIDs:readingOwnCore:)`.
  static let ownCoreMarker = "__DRIVERR_OWN_CORE__"

  static let variables = [
    "HERDR_PANE_ID", "HERDR_SESSION", "HERDR_SOCKET_PATH", "TMUX", "HC_SESSION", "HC_SOCKET",
  ]
  /// What picks the core an `hc` command reaches. See `CoreSessionKey`.
  static let coreVariables = ["HC_SESSION", "HC_SOCKET"]

  /// The script, wrapped for the login shell by `LoginShell.posix`. A process that has gone
  /// prints its boundary and nothing else.
  ///
  /// The pids are integers Driverr parsed, so nothing reaches the shell as syntax.
  static func command(forPIDs pids: [Int], readingOwnCore: Bool = false) -> String {
    LoginShell.posix(script(forPIDs: pids, readingOwnCore: readingOwnCore))
  }

  /// With `readingOwnCore`, the script first prints this exec channel's own `HC_SESSION` and
  /// `HC_SOCKET`, the two variables `hc connect` reads on the same channel to pick the core
  /// Driverr reaches. `sh -c` inherits the channel's environment unchanged.
  static func script(forPIDs pids: [Int], readingOwnCore: Bool = false) -> String {
    let names = variables.joined(separator: "|")
    let own =
      readingOwnCore
      ? [
        "printf '\\n%s\\n' '\(ownCoreMarker)'; "
          + "env | grep -E '^(\(coreVariables.joined(separator: "|")))='"
      ] : []
    return (own
      + pids.map { pid in
        "printf '\\n%s\\n' '\(marker) \(pid)'; "
          + "ps -ww -o args= -p \(pid) 2>/dev/null | sed 's/^/args /'; "
          + "{ tr '\\0' '\\n' < /proc/\(pid)/environ || ps -wwE -o command= -p \(pid) | tr ' ' '\\n'; }"
          + " 2>/dev/null | grep -E '^(\(names))='"
      })
    .joined(separator: "; ")
  }

  /// The exec channel's own `HC_SESSION` and `HC_SOCKET`, from the lines between
  /// `ownCoreMarker` and the first process. `nil` when the script did not read them.
  static func ownCoreEnvironment(from output: String) -> [String: String]? {
    var environment: [String: String]?
    let wanted = Set(coreVariables)
    for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
      if line == ownCoreMarker {
        environment = [:]
        continue
      }
      if line.hasPrefix("\(marker) ") { break }
      guard environment != nil, let equals = line.firstIndex(of: "=") else { continue }
      let name = String(line[..<equals])
      guard wanted.contains(name) else { continue }
      environment?[name] = String(line[line.index(after: equals)...])
    }
    return environment
  }

  /// What the command printed, by pid. A pid it did not ask for is dropped, and so is a
  /// variable outside the six, in case a host prints one. The exec channel's own lines come
  /// before the first boundary, so they are no process's.
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

/// Which panes of a tmux server show herdr or a herdr-core, and which herdr panes and core
/// terminals show tmux. See `MirrorClaim`.
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
///
/// Measured on tmux 3.7c and hc 0.1.21:
///
/// - **tmux in a core terminal.** The core's `foreground.pid` for the terminal is the tmux
///   client's `client_pid`, whether the terminal runs tmux itself or a shell that started it. So
///   no environment is read: every client is a `.tmuxClient` claim while a core runs on the host,
///   and `CombinedControl` matches the pid against the core's own read. The environment would not
///   do: a terminal's `HC_TERMINAL_ID` reaches every process started from it, and nothing in it
///   names the core.
/// - **A core terminal in tmux.** The pane's foreground leader is `hc attach <address>`, whose
///   `comm` is the path it was started by (`…/bin/hc`, a link to `herdr-core`). It reaches the
///   core that `HC_SOCKET`, else `HC_SESSION`, else `default` picks. It ignores
///   `HC_TERMINAL_SOCKET`. The claim stands only when that is the core this exec channel's own
///   `hc connect` reaches. See `CoreSessionKey` for what that comparison cannot tell apart.
enum TmuxMirrors {
  /// Whether a process is herdr, by its command's last path component. Not `herdr-core` and not
  /// the app's `Herdr`.
  static func isHerdr(_ process: TmuxProcess) -> Bool {
    process.command.split(separator: "/").last == "herdr"
  }

  /// Whether a process is herdr-core, by its command's last path component: `hc`, the link it is
  /// installed as, or `herdr-core`. The core itself, its terminal holder and an `hc attach` client
  /// are all one of the two.
  static func isCore(_ process: TmuxProcess) -> Bool {
    isCore(program: process.command)
  }

  static func isCore<S: StringProtocol>(program: S) -> Bool {
    let name = program.split(separator: "/").last
    return name == "hc" || name == "herdr-core"
  }

  /// Each pane whose foreground group herdr-core leads, by raw pane id.
  static func coreLeaders(
    rows: [TmuxPaneRow], processes: [TmuxProcess]
  ) -> [String: Int] {
    var leaders: [String: Int] = [:]
    for row in rows {
      guard let leader = TmuxProcessTable.foregroundGroup(forPaneTTY: row.tty, in: processes).first,
        leader.pid == leader.foregroundGroupID, isCore(leader)
      else { continue }
      leaders[row.paneID] = leader.pid
    }
    return leaders
  }

  /// The `.coreAttach` claims of panes that `hc attach` leads, against the core `own` names.
  ///
  /// A leader with no `TMUX` is one whose environment could not be read, and is passed over, as a
  /// herdr leader is. With no `own`, the read did not say which core Driverr reaches, and nothing
  /// claims.
  static func coreAttachClaims(
    coreLeaders: [String: Int],
    details: [Int: TmuxProcessDetails],
    own: [String: String]?
  ) -> Set<MirrorClaim> {
    guard let own else { return [] }
    let reached = CoreSessionKey(environment: own)
    var claims: Set<MirrorClaim> = []
    for (paneID, pid) in coreLeaders {
      guard let process = details[pid], process.environment["TMUX"] != nil,
        let address = attachedAddress(arguments: process.arguments),
        CoreSessionKey(environment: process.environment) == reached
      else { continue }
      claims.insert(MirrorClaim(.coreAttach(paneID: TmuxID.pane(paneID), address: address)))
    }
    return claims
  }

  /// The terminal an `hc attach` command line attaches to, by address: `t7`, `t1b` or
  /// `machine/t7`. `nil` for any other command, for the picker that a bare `hc` or `hc attach`
  /// opens, and for a terminal named by its name, which the core's tree does not key on.
  ///
  /// `--history` takes a value. Any other flag is passed over, so `--observe`, which only
  /// watches, still claims: it shows the same terminal.
  static func attachedAddress(arguments: String) -> String? {
    let words = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
    guard let program = words.first, isCore(program: program) else { return nil }
    var positional: [String] = []
    var rest = words.dropFirst()
    while let word = rest.popFirst() {
      if word == "--history" {
        _ = rest.popFirst()
      } else if !word.hasPrefix("-") {
        positional.append(word)
      }
    }
    guard positional.count == 2, positional[0] == "attach", isAddress(positional[1]) else {
      return nil
    }
    return positional[1]
  }

  /// `t` and digits, then any lowercase letters, after an optional `machine/`.
  private static func isAddress(_ word: String) -> Bool {
    let terminal = word.split(separator: "/", omittingEmptySubsequences: false)
    guard terminal.count <= 2, terminal.allSatisfy({ !$0.isEmpty }), let local = terminal.last,
      local.first == "t"
    else { return false }
    let tail = local.dropFirst()
    let digits = tail.prefix { $0.isASCII && $0.isNumber }
    return !digits.isEmpty
      && tail.dropFirst(digits.count).allSatisfy { $0.isASCII && $0.isLowercase }
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
    if let named, !named.isEmpty { return HerdrSessionKey(sessionName: named) }
    return session(from: environment)
  }

  /// The session a herdr process's environment points at: the socket path first, then the
  /// session name, and else the standard session.
  static func session(from environment: [String: String]) -> HerdrSessionKey {
    if let path = environment["HERDR_SOCKET_PATH"], !path.isEmpty {
      return HerdrSessionKey(socketPath: path)
    }
    return HerdrSessionKey(sessionName: environment["HERDR_SESSION"])
  }
}

/// Which herdr-core an `hc` command reaches, from the variables that pick it.
///
/// Measured on hc 0.1.21. `HC_SOCKET` names the socket outright. Else `HC_SESSION` names the
/// session, and an unset or empty one is `default`, as `HC_SESSION=default` is. A session's
/// socket is `$XDG_RUNTIME_DIR/herdr-core/<session>.sock`, or
/// `~/.local/state/herdr-core/<session>/<session>.sock` with no `XDG_RUNTIME_DIR`. So a socket
/// path in either layout is read back as its session, and only the end of it is read, as
/// `HerdrSessionKey` does.
///
/// **Limit.** A session name is not a core. One user with two `HOME`s or two `XDG_RUNTIME_DIR`s
/// on one host can run two cores with one session name, and their keys compare equal. Nothing in
/// an `hc` client's environment or in the core's `hello` tells those two apart.
enum CoreSessionKey: Hashable, Sendable {
  case named(String)
  /// A socket path neither layout explains, compared as it is written.
  case socket(String)

  init(environment: [String: String]) {
    if let path = environment["HC_SOCKET"], !path.isEmpty {
      self.init(socketPath: path)
    } else if let name = environment["HC_SESSION"], !name.isEmpty {
      self = .named(name)
    } else {
      self = .named(Self.standardName)
    }
  }

  init(socketPath: String) {
    let parts = socketPath.split(separator: "/", omittingEmptySubsequences: false)
    guard let file = parts.last, file.hasSuffix(".sock"), parts.count >= 2 else {
      self = .socket(socketPath)
      return
    }
    let session = file.dropLast(".sock".count)
    let parent = parts[parts.count - 2]
    if !session.isEmpty,
      parent == Self.directoryName
        || (parent == session && parts.count >= 3 && parts[parts.count - 3] == Self.directoryName)
    {
      self = .named(String(session))
    } else {
      self = .socket(socketPath)
    }
  }

  /// The session hc runs with no `HC_SESSION`.
  static let standardName = "default"
  /// The directory hc keeps its sockets under, in the runtime and in the state directory.
  static let directoryName = "herdr-core"
}
