import DriverrCore
import Foundation

/// Whether this host can serve herdr, and if not, which of the several different "no"s it
/// is.
///
/// Each outcome needs a different message and next action, so this is returned, not
/// thrown.
public enum HerdrAvailability: Equatable, Sendable {
  /// herdr is here, a server is up, and Driverr understands its protocol.
  case ready(version: String, protocolVersion: Int)
  /// Installed, but nothing is listening. Recoverable by the user starting herdr.
  case serverNotRunning(version: String?)
  /// Not found anywhere Driverr looked.
  case notInstalled
  /// Running, but speaking a protocol older than this build's wire types can map.
  ///
  /// Deliberately one-sided: a herdr *newer* than this build is `.ready`. See
  /// `HerdrProtocol.minimum`.
  case tooOld(version: String, protocolVersion: Int)
  /// Running, and `herdr status server` printed something this build cannot read.
  ///
  /// **Not `.serverNotRunning`.** A server is up and Driverr cannot read its output, so
  /// telling the user to start a session would be wrong. A renamed status field causes
  /// this.
  case statusUnreadable(version: String?)
  /// A herdr-core answered on `hc connect` and passed the compatibility gate.
  ///
  /// No `.serverNotRunning` counterpart: `hc connect` starts a core when none is up.
  case coreReady(version: String)
  /// Both are here and both answered, so the host shows both. See `CombinedControl`.
  case combined(herdrVersion: String, coreVersion: String)
  /// A core answered and this build cannot use it.
  ///
  /// Gated on `hello`'s generation and method list, not a protocol number. `generation` is
  /// `nil` when the core refused the opening without saying what it speaks. A core of
  /// another generation refuses that way.
  case coreIncompatible(version: String?, generation: Int?, missingMethods: [String])
  /// The TUI answered, and a core beside it is one this build cannot use.
  ///
  /// Ready, because the TUI's panes are all there. The first two are the TUI's `.ready`, and
  /// the rest are the core's `.coreIncompatible`, which `coreRefusal` says in words.
  case readyWithCoreRefused(
    version: String,
    protocolVersion: Int,
    coreVersion: String?,
    coreGeneration: Int?,
    coreMissingMethods: [String]
  )

  public var isReady: Bool {
    switch self {
    case .ready, .coreReady, .combined, .readyWithCoreRefused: true
    case .serverNotRunning, .notInstalled, .tooOld, .statusUnreadable, .coreIncompatible: false
    }
  }

  /// Which herdr answered, for the host list's "herdr …", or `nil` if none did.
  ///
  /// A core reads "core 0.1.14" there, so its much lower version is not taken for an old
  /// herdr. With both, the TUI's: its version is the one with a floor.
  public var readyVersion: String? {
    switch self {
    case .ready(let version, _), .combined(let version, _),
      .readyWithCoreRefused(let version, _, _, _, _):
      version
    case .coreReady(let version): "core \(version)"
    case .serverNotRunning, .notInstalled, .tooOld, .statusUnreadable, .coreIncompatible: nil
    }
  }

  /// Why the core beside a working TUI is not in use, or `nil` when none is being passed over.
  public var coreRefusal: String? {
    guard case let .readyWithCoreRefused(_, _, version, generation, missingMethods) = self else {
      return nil
    }
    return Self.coreIncompatible(
      version: version, generation: generation, missingMethods: missingMethods
    ).message
  }

  /// What to tell the user, and what they can do about it.
  public var message: String {
    switch self {
    case let .ready(version, _), let .readyWithCoreRefused(version, _, _, _, _):
      // No protocol number: it has no next action and would draw attention from
      // "Connected". The refused core is `coreRefusal`, a line of its own.
      "herdr \(version)"
    case let .serverNotRunning(version):
      // Names the next step, the Open Shell button below.
      (version.map { "herdr \($0) is installed here, but no session is running." }
        ?? "herdr is installed here, but no session is running.")
        + " Open Shell and run `herdr` to start a session."
    case .notInstalled:
      // Headline and action first. The directories come from
      // `CLIControl.fallbackPaths`, so the message names only places that were searched.
      """
      herdr isn't installed on this host. Install herdr, then try again. Driverr checked \
      the PATH of the non-login shell SSH gives it, asked the login shell, and looked in \
      \(CLIControl.searchedDirectories).
      """
    case let .tooOld(version, protocolVersion):
      """
      herdr \(version) speaks protocol \(protocolVersion); Driverr needs at least \
      protocol \(HerdrProtocol.minimum). Update herdr.
      """
    case let .statusUnreadable(version):
      // herdr is fine and Driverr is behind. No "start a session": one is running.
      (version.map { "herdr \($0) is running here, but this version of Driverr can't read " }
        ?? "herdr is running here, but this version of Driverr can't read ")
        + "its status. Update Driverr."
    case let .coreReady(version):
      "herdr-core \(version)"
    case let .combined(herdrVersion, coreVersion):
      "herdr \(herdrVersion) · herdr-core \(coreVersion)"
    case let .coreIncompatible(version, generation, missingMethods):
      Self.coreIncompatibleMessage(
        name: version.map { "herdr-core \($0)" } ?? "This herdr-core",
        generation: generation,
        missingMethods: missingMethods
      )
    }
  }

  private static func coreIncompatibleMessage(
    name: String,
    generation: Int?,
    missingMethods: [String]
  ) -> String {
    let needed = HerdrProtocol.coreGeneration
    guard missingMethods.isEmpty else {
      return "\(name) has no \(missingMethods.joined(separator: ", ")). Update herdr-core."
    }
    guard let generation else {
      return "\(name) doesn't speak protocol generation \(needed). Update herdr-core or Driverr."
    }
    return generation < needed
      ? "\(name) speaks protocol generation \(generation); Driverr needs \(needed). Update herdr-core."
      : "\(name) speaks protocol generation \(generation); Driverr speaks \(needed). Update Driverr."
  }
}

/// Which herdr protocol versions this build's wire types can map.
public enum HerdrProtocol {
  /// The oldest protocol Driverr accepts. A floor, not an exact match.
  ///
  /// `HerdrWireTypes` decodes only the fields Driverr uses, so a newer herdr is accepted.
  /// An exact match would refuse every herdr release.
  ///
  /// Raise it only when a field Driverr reads changes shape, because raising it drops
  /// older herdr.
  public static let minimum = 17

  /// The newest protocol whose schema has been re-checked against `HerdrWireTypes`.
  ///
  /// **Not a gate.** Nothing is refused above it. `LiveHerdrSnapshotTests` uses it to tell
  /// a developer to re-read `herdr api schema --json` when herdr moves on.
  ///
  /// Protocol 22 is herdr 0.9.1. Its schema only adds fields to the ones
  /// `HerdrWireTypes` decodes.
  public static let lastVerified = 22

  /// The herdr-core protocol generation this build speaks.
  ///
  /// An exact match, unlike `minimum`: a generation is a break decided on purpose, and within
  /// one the API only grows.
  public static let coreGeneration = 1
}

extension CLIControl {
  /// Absolute paths to try when no shell's `PATH` answers, in the order they are printed.
  ///
  /// - `/opt/homebrew/bin`: Homebrew on Apple Silicon, not on an exec channel's default
  ///   `PATH`.
  /// - `/usr/local/bin`: Homebrew on Intel.
  /// - `$HOME/.local/bin`: herdr's installer default, expanded by the remote shell.
  ///
  /// `discoveryCommand` asks the login shell first, so custom prefixes need no entry here.
  static var fallbackPaths: [String] { fallbackDirectories.map { "\($0)/herdr" } }

  /// The directories of `fallbackPaths`. Public because a herdr-core installs to the same
  /// places.
  public static let fallbackDirectories = [
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "$HOME/.local/bin",
  ]

  /// The directories of `fallbackPaths`, phrased for the not-found message.
  ///
  /// Derived, so the message cannot name a place the code did not search.
  static var searchedDirectories: String {
    let directories = fallbackPaths.map { path in
      String(path.dropLast("/herdr".count)).replacingOccurrences(of: "$HOME", with: "~")
    }
    guard let last = directories.last else { return "" }
    guard directories.count > 1 else { return last }
    return directories.dropLast().joined(separator: ", ") + " and " + last
  }

  /// Where herdr might be, in the order worth trying.
  ///
  /// An SSH exec channel runs a non-login, non-interactive shell. On zsh it reads only
  /// `~/.zshenv`, so Homebrew's `shellenv` is often missing from `PATH`.
  ///
  /// Three probes, cheapest first, each printing a candidate:
  /// 1. the current `PATH`;
  /// 2. the user's login shell, whose output is untrusted (see `discoveredPath(in:)`);
  /// 3. `fallbackPaths`.
  ///
  /// It always exits 0. The printed path is the whole result.
  static let discoveryCommand = #"""
    herdr_path=$(command -v herdr 2>/dev/null)
    if [ -n "$herdr_path" ]; then printf '%s\n' "$herdr_path"; exit 0; fi
    "${SHELL:-/bin/sh}" -lc 'command -v herdr' </dev/null 2>/dev/null
    for candidate in \#(fallbackPaths.map { "\"\($0)\"" }.joined(separator: " ")); do
      [ -x "$candidate" ] && printf '%s\n' "$candidate"
    done
    exit 0
    """#

  /// Picks herdr's path out of the probe's output.
  ///
  /// Not the first line, because a login profile may print a banner. The answer is an
  /// absolute path ending in `herdr`, which no banner, function body or alias line is.
  static func discoveredPath(in output: String) -> String? {
    for line in output.split(separator: "\n") {
      let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard candidate.hasPrefix("/"),
        candidate.split(separator: "/").last.map(String.init) == "herdr"
      else { continue }
      return candidate
    }
    return nil
  }

  /// Finds herdr on the host and returns a control bound to it.
  ///
  /// Returns `nil` when herdr cannot be found, which the caller reports as
  /// `.notInstalled`.
  public static func discovering(run: @escaping CommandRunner) async -> CLIControl? {
    guard let result = try? await run(discoveryCommand),
      let path = discoveredPath(in: result.standardOutput)
    else { return nil }
    return CLIControl(binaryPath: path, run: run)
  }

  /// Asks the host what herdr it has.
  public func availability() async -> HerdrAvailability {
    let result: CommandResult
    do {
      result = try await runStatus()
    } catch {
      return .notInstalled
    }

    // 127 is the shell's convention for a missing command. The message is the fallback.
    if result.exitStatus == 127 || result.standardError.contains("command not found") {
      return .notInstalled
    }

    let fields = Self.statusFields(result.standardOutput + "\n" + result.standardError)
    let version = fields["version"]

    // **Ignore both compatibility flags herdr prints.** `private_protocol_compatible`
    // compares the host's CLI with its server; a `no` is a broken install that herdr's own
    // errors explain. `endpoint_compatible` is about a protocol Driverr does not speak.
    // Refusing on either would refuse a working host.

    guard let status = fields["status"] else {
      // **No `status` key. The two exit codes mean opposite things.**
      //
      // Exit 0: herdr always prints `status`, running or not, so the key was renamed.
      // That is `.statusUnreadable`, not "start a session".
      //
      // Nonzero: herdr could not answer, for example with `HERDR_SOCKET_PATH` pointing at
      // a non-socket. That stays `.serverNotRunning`, whose next step shows herdr's error.
      return result.exitStatus == 0
        ? .statusUnreadable(version: version)
        : .serverNotRunning(version: version)
    }
    guard status == "running" else {
      // Any `status` other than `running` means not up.
      return .serverNotRunning(version: version)
    }
    guard let version, let protocolVersion = Self.protocolVersion(in: fields) else {
      // Running, but in a shape this build cannot parse. A version problem, not a missing
      // server.
      return .statusUnreadable(version: version)
    }
    guard protocolVersion >= HerdrProtocol.minimum else {
      return .tooOld(version: version, protocolVersion: protocolVersion)
    }
    return .ready(version: version, protocolVersion: protocolVersion)
  }

  /// The server's private protocol number, under either name herdr has printed it by.
  ///
  /// herdr 0.9.1 prints `private_protocol`, and earlier versions print `protocol`. Both are
  /// herdr's `PROTOCOL_VERSION`, the number `HerdrProtocol.minimum` compares. The new name
  /// is preferred, so one build serves hosts on both sides of the rename.
  static func protocolVersion(in fields: [String: String]) -> Int? {
    (fields["private_protocol"] ?? fields["protocol"]).flatMap(Int.init)
  }

  /// `key: value` lines, which is what `herdr status server` prints.
  static func statusFields(_ output: String) -> [String: String] {
    var fields: [String: String] = [:]
    for line in output.split(separator: "\n") {
      guard let separator = line.firstIndex(of: ":") else { continue }
      let key = line[..<separator].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      guard !key.isEmpty, fields[key] == nil else { continue }
      fields[key] = value
    }
    return fields
  }
}
