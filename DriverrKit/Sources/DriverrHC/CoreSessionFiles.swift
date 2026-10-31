import DriverrCore
import Foundation

/// Which Claude session each terminal on this core is in.
///
/// herdr-core has no `agent_session`. Claude Code keeps a `<pid>.json` per running process
/// under `~/.claude/sessions`, and rewrites its `sessionId` on `/clear` and on resume, so the
/// foreground pid names the session even with two Claudes in one folder. This reads that over
/// the core's `file.read`, whenever `CoreEventState` says a terminal's may have moved, because a
/// host command in the reader would let a failed read replace an exact page with the directory's
/// newest file, and `/clear` would wait for the reader's next re-resolve.
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
  /// The last good id per address.
  private var remembered: [String: String] = [:]

  init(home: String?) {
    self.home = home
  }

  /// Each local Claude terminal's session id, by address, after reading those in `addresses`.
  ///
  /// Every other id stands, as does the last good id of a read that failed, as
  /// `CoreEventFeed` keeps the last document, so one bad read cannot move an open chat onto a
  /// guess. This also covers Claude running something in the foreground, when the pid is not
  /// Claude's. An id goes when its terminal leaves or stops being Claude, which `terminals`
  /// says, so it must be all of them.
  func identifiers(
    for terminals: [CoreTerminal],
    reading addresses: Set<String>,
    over connection: CoreConnection
  ) async -> [String: String] {
    guard let home else { return [:] }
    let claudes = terminals.filter(CoreSnapshotMapper.isLocalClaude)
    let reads = await withTaskGroup(of: (String, String?).self) { group in
      for terminal in claudes where addresses.contains(terminal.address) {
        group.addTask {
          (terminal.address, await Self.identifier(of: terminal, home: home, over: connection))
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

  private static func identifier(
    of terminal: CoreTerminal,
    home: String,
    over connection: CoreConnection
  ) async -> String? {
    guard let pid = terminal.foreground?.pid,
      let file = try? await connection.call(
        "file.read",
        params: CoreFileReadParams(path: "\(home)/.claude/sessions/\(pid).json"),
        as: CoreFileReadResult.self
      ),
      let record = try? JSONDecoder().decode(Record.self, from: Data(file.text.utf8)),
      record.pid == pid,
      isSessionID(record.sessionId)
    else { return nil }
    return record.sessionId
  }

  /// Whether the reader could ever match this to a filename. It refuses the same ids, in
  /// `probeReportedSession(for:)`.
  private static func isSessionID(_ id: String) -> Bool {
    !id.isEmpty && !id.contains("/")
      && id == id.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
