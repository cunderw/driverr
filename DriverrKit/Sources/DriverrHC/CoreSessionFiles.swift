import DriverrCore
import Foundation

/// Which Claude session each terminal on this core, or on a machine it added, is in.
///
/// herdr-core has no `agent_session`. Claude Code keeps a `<pid>.json` per running process
/// under `sessions` in its configuration directory, `~/.claude` or where `CLAUDE_CONFIG_DIR`
/// moves it (see `configDirectory(on:over:)`), and rewrites its `sessionId` on `/clear` and on resume, so the
/// foreground pid names the session even with two Claudes in one folder. This reads that over
/// the core's `file.read`, on the terminal's own machine, whenever `CoreEventState` says a
/// terminal's may have moved, because a host command in the reader would let a failed read
/// replace an exact page with the directory's newest file, and `/clear` would wait for the
/// reader's next re-resolve.
///
/// **The file is Claude Code's, not a contract.** Anything wrong with it leaves a terminal
/// with no id, and the reader falls back to its directory match. A file that reads but whose
/// transcript does not exist yet is not a failure: every new session looks like that, and the
/// reader reports the session missing rather than draw the newest file.
///
/// One read per terminal and one exact filename, never a listing. `<pid>.<hash>.key` files sit
/// beside these.
actor CoreSessionFiles {
  /// The parts of Claude Code's record that are read. `cwd` is left out on purpose, because
  /// the pid is what says whose it is. `foreground.name` is no help either, being a version.
  private struct Record: Decodable {
    let pid: Int
    let sessionId: String
  }

  private let home: String?
  /// How long a place that did not answer is left alone before it is asked again.
  private let retryAfter: Duration
  /// The last good id per address.
  private var remembered: [String: String] = [:]
  /// What each place said its configuration directory is, by machine, `nil` for the core's own
  /// computer. A task, so terminals on one place that read together share one question. Kept
  /// only once it has an answer.
  private var directories: [String?: Task<String?, Never>] = [:]
  /// When each place last failed to answer, so a place that is down is not asked at every read.
  private var failures: [String?: ContinuousClock.Instant] = [:]

  /// The wait before a place that did not answer is asked again.
  static let defaultRetryAfter: Duration = .seconds(60)

  init(home: String?, retryAfter: Duration = CoreSessionFiles.defaultRetryAfter) {
    self.home = home
    self.retryAfter = retryAfter
  }

  /// Each Claude terminal's session id, by address, after reading those in `addresses`.
  ///
  /// Every other id stands, as does the last good id of a read that failed, as
  /// `CoreEventFeed` keeps the last document, so one bad read cannot move an open chat onto a
  /// guess. This also covers Claude running something in the foreground, when the pid is not
  /// Claude's. An id goes when its terminal leaves or stops being Claude, which `terminals`
  /// says, so it must be all of them.
  ///
  /// Each terminal's read waits for its own place's directory and for nothing else, so a place
  /// that never answers holds up only its own terminals. The call returns when the last read
  /// has, which is the connection's call deadline for a place that is silent.
  func identifiers(
    for terminals: [CoreTerminal],
    reading addresses: Set<String>,
    over connection: CoreConnection
  ) async -> [String: String] {
    let claudes = terminals.filter { CoreSnapshotMapper.isClaude($0) }
    let reads = await withTaskGroup(of: (String, String?).self) { group in
      for terminal in claudes where addresses.contains(terminal.address) {
        group.addTask { [home] in
          let directory = await self.configDirectory(on: terminal.machine, over: connection)
          return (
            terminal.address,
            await Self.identifier(
              of: terminal, home: home, directory: directory, over: connection)
          )
        }
      }
      var reads: [String: String] = [:]
      for await (address, id) in group { reads[address] = id }
      return reads
    }

    let addresses = Set(claudes.map(\.address))
    remembered = remembered.filter { addresses.contains($0.key) }
    remembered.merge(reads) { _, read in read }
    return remembered
  }

  /// What `CLAUDE_CONFIG_DIR` makes of the configuration directory on this core's computer, or
  /// on `machine`, learned once from a `machine.exec` there. `nil` when the place did not say
  /// an absolute directory, which leaves the record under `~/.claude`. A place that did not is
  /// not asked again for `retryAfter`.
  ///
  /// Asked of the place itself and not over Driverr's SSH channel, because a machine's shell is
  /// only reachable through the core and its variable is its own. The core's computer answers
  /// with the variable the core was started with, which is what its Claude terminals inherited.
  /// A shell that does not have the variable cannot name it: see `AgentIntegration`.
  private func configDirectory(on machine: String?, over connection: CoreConnection) async
    -> String?
  {
    if let asking = directories[machine] { return await asking.value }
    if let failed = failures[machine], ContinuousClock.now < failed + retryAfter { return nil }
    let asking = Task { await Self.askConfigDirectory(on: machine, over: connection) }
    directories[machine] = asking
    let directory = await asking.value
    if directory != nil {
      failures[machine] = nil
    } else if directories[machine] == asking {
      directories[machine] = nil
      failures[machine] = .now
    }
    return directory
  }

  /// The core's own `timeout`, which ends the program on its computer. The call itself gives up
  /// at the connection's deadline, as a record's `file.read` does.
  private static let askTimeout: Duration = .seconds(5)

  private static func askConfigDirectory(
    on machine: String?, over connection: CoreConnection
  ) async -> String? {
    guard
      let answer = try? await connection.call(
        "machine.exec",
        params: CoreExecParams(
          line: configDirectoryCommand, on: machine,
          timeout: Double(askTimeout.components.seconds)),
        as: CoreExecResult.self),
      let result = try? CoreControl.commandResult(of: answer, on: machine ?? "This host"),
      result.exitStatus == 0
    else { return nil }
    return CoreControl.discoveredHome(in: result.standardOutput)
  }

  /// The configuration directory, printed as `AgentIntegration.claudeCode` writes it.
  static let configDirectoryCommand = LoginShell.posix(
    "printf '%s\\n' \(AgentIntegration.claudeCode.configDirectory)")

  private static func identifier(
    of terminal: CoreTerminal,
    home: String?,
    directory: String?,
    over connection: CoreConnection
  ) async -> String? {
    guard let pid = terminal.foreground?.pid,
      let params = params(of: terminal, pid: pid, home: home, directory: directory),
      let file = try? await connection.call(
        "file.read", params: params, as: CoreFileReadResult.self),
      let record = try? JSONDecoder().decode(Record.self, from: Data(file.text.utf8)),
      record.pid == pid,
      isSessionID(record.sessionId)
    else { return nil }
    return record.sessionId
  }

  /// Where this terminal's record is: under `directory` when its place named one, else under
  /// `home` here, or on its machine from that machine's home, because `file.read` with `on`
  /// starts a relative path there.
  ///
  /// **Never this host's file for a machine's terminal.** Its pid is that machine's, and the
  /// same number here is some other process, or another Claude's record.
  ///
  /// This assumes a relayed terminal's `foreground.pid` is the pid on its machine, which a
  /// record whose `pid` does not match refuses if it is not.
  private static func params(
    of terminal: CoreTerminal, pid: Int, home: String?, directory: String?
  ) -> CoreFileReadParams? {
    if let directory {
      return CoreFileReadParams(path: "\(directory)/sessions/\(pid).json", on: terminal.machine)
    }
    let record = ".claude/sessions/\(pid).json"
    if let machine = terminal.machine {
      return CoreFileReadParams(path: record, on: machine)
    }
    return home.map { CoreFileReadParams(path: "\($0)/\(record)") }
  }

  /// Whether the reader could ever match this to a filename. It refuses the same ids, in
  /// `probeReportedSession(for:)`.
  private static func isSessionID(_ id: String) -> Bool {
    !id.isEmpty && !id.contains("/")
      && id == id.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
