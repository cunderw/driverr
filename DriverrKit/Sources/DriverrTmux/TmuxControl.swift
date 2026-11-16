import DriverrCore
import DriverrHerdr
import Foundation

/// Drives a host's tmux server through its command-line client, as `CLIControl` drives herdr.
///
/// One exec channel per request, over the same `CommandRunner`. tmux has no `-F` listing for
/// an agent, so the snapshot joins three reads: the panes, the host's process table and
/// Claude Code's own record of each foreground process. See `TmuxProcessTable`.
///
/// Ids are `TmuxID`'s: `tmux:%3` for a pane, `tmux:@2` for a window and `tmux:$1` for a
/// session. They map to `Pane`, `Tab` and `Workspace` ids, so a tmux pane is told apart by its
/// prefix wherever a herdr one could be.
///
/// **The default tmux server only.** A server started with `-L` or `-S` is not looked for.
///
/// **Polls, because nothing subscribes.** tmux's control mode reports only the attached
/// session's panes, so `changes` is `nil` and `needsPolling` is `true`. Control mode is for
/// the live terminal, in a later slice.
public struct TmuxControl: HerdrControl {
  /// How to reach `tmux` on the host. Discovery may set an absolute path, because an SSH exec
  /// channel's non-login shell may lack Homebrew on `PATH`. See `discovering(run:)`.
  public let binaryPath: String
  private let run: CommandRunner

  public init(binaryPath: String = "tmux", run: @escaping CommandRunner) {
    self.binaryPath = binaryPath
    self.run = run
  }

  /// The command every call starts with: the binary, and `-u`.
  ///
  /// **`-u` is not optional.** An SSH exec channel often has no locale, and tmux then takes the
  /// terminal for ASCII-only and prints every control character and every byte above 127 as
  /// `_`. Measured on 3.7c with an empty environment: the unit separator of `list-panes`'s
  /// format became `_`, so no line could be read, and a title such as `✳ Claude Code` became
  /// `__ Claude Code`. `-u` says the output is UTF-8 whatever the locale.
  private var binary: String { "\(shellQuoted(binaryPath)) -u" }

  // MARK: Availability

  /// What this host has, in `HerdrControl`'s terms. See `tmuxAvailability()` for the real one.
  public func availability() async -> HerdrAvailability {
    await tmuxAvailability().asHerdrAvailability
  }

  /// Runs `tmux -V` and compares it with `TmuxVersion.minimum`.
  ///
  /// `tmux -V` needs no server, so a host with tmux and no session is `.ready`: the first
  /// `new-session` starts one.
  public func tmuxAvailability() async -> TmuxAvailability {
    guard let result = try? await run("\(binary) -V") else { return .notInstalled }
    return TmuxAvailability.from(result)
  }

  // MARK: Snapshot

  public func snapshot() async throws -> SessionTree {
    async let listing = execute(TmuxCommands.listPanes(binary: binary), allowingNoServer: true)
    // The process table only adds agents, so a host that will not answer it still has a tree.
    async let processTable = try? run(TmuxProcessTable.command)

    let output = try await listing
    // Awaited whether or not it is used, so a host's commands do not depend on a race.
    let processes = await processTable
    let rows = TmuxPaneFormat.rows(from: output)
    guard !rows.isEmpty else { return .empty }

    let agents = await agents(forRows: rows, processTable: processes)
    try Task.checkCancellation()
    return TmuxSnapshotMapper.tree(from: rows, agents: agents)
  }

  /// The agent in each pane, by raw pane id. A failure at any step leaves a pane a shell.
  private func agents(
    forRows rows: [TmuxPaneRow],
    processTable: CommandResult?
  ) async -> [String: Agent] {
    guard let processTable, processTable.succeeded else { return [:] }
    let processes = TmuxProcessTable.parse(processTable.standardOutput)

    var candidates: [String: [Int]] = [:]
    for row in rows {
      let pids = TmuxProcessTable.candidates(forPaneTTY: row.tty, in: processes)
      if !pids.isEmpty { candidates[row.paneID] = pids }
    }
    let pids = Array(Set(candidates.values.flatMap { $0 })).sorted()
    // **The exit status is ignored.** `cat` of the last pid's missing file exits 1, and the shell
    // reports only the last command's, so a host whose final pid has no record would read as a
    // failure of the whole read.
    guard !pids.isEmpty, let files = try? await run(ClaudeRecordFiles.command(forPIDs: pids))
    else { return [:] }

    let contents = ClaudeRecordFiles.contents(of: files.standardOutput, forPIDs: pids)
    var agents: [String: Agent] = [:]
    for (paneID, pids) in candidates {
      for pid in pids {
        // The record's own pid has to match, so another process's file is never taken.
        guard let data = contents[pid], let record = ClaudeSessionRecord.parse(data),
          record.pid == nil || record.pid == pid
        else { continue }
        agents[paneID] = record.agent
        break
      }
    }
    return agents
  }

  // MARK: Terminal

  /// A PTY command that shows this pane's session, read-only and at the desk's size.
  ///
  /// **A stand-in.** It shows the session's current pane, not necessarily this one. The live
  /// terminal slice opens a pane through `paneAttacher(for:)` and this goes.
  public func attachCommand(for pane: Pane) -> String {
    let session = TmuxID.raw(of: pane.workspaceID).map(shellQuoted)
    guard let session else { return "\(binary) attach-session -f read-only,ignore-size" }
    return TmuxCommands.attach(binary: binary, session: session)
  }

  // MARK: Input

  public func sendText(paneID: String, text: String) async throws {
    let pane = try quotedPane(paneID)
    guard let command = TmuxCommands.input(binary: binary, pane: pane, text: text, submit: false)
    else { return }
    _ = try await execute(command)
  }

  public func submitText(paneID: String, text: String) async throws {
    let pane = try quotedPane(paneID)
    // Never `nil`: a submit always has an Enter to send.
    guard
      let command = TmuxCommands.input(
        binary: binary, pane: pane, text: TmuxCommands.submittable(text), submit: true)
    else { return }
    _ = try await execute(command)
  }

  public func sendKeys(paneID: String, keys: [PaneKey]) async throws {
    let pane = try quotedPane(paneID)
    guard let command = TmuxCommands.keys(binary: binary, pane: pane, keys: keys) else { return }
    _ = try await execute(command)
  }

  // MARK: Reads

  public func readPanes(ids: [String], lines: Int) async throws -> [String: [String]] {
    // A tmux id that does not parse is answered with no rows and never reaches the shell.
    let panes = ids.compactMap { id in
      TmuxID.rawPane(of: id).map { (id: id, quoted: shellQuoted($0)) }
    }
    var answers = [String: [String]](minimumCapacity: ids.count)
    for id in ids { answers[id] = [] }
    guard !panes.isEmpty else { return answers }

    let result: CommandResult
    do {
      result = try await run(TmuxCommands.readPanes(binary: binary, panes: panes))
    } catch let error as AppError {
      throw error
    } catch {
      throw AppError.channelFailed(reason: "Could not run tmux on this host.")
    }

    // **The exit status is ignored.** The shell reports only the last command's, which
    // describes one pane and not the batch.
    let read = TmuxCommands.panes(from: result.standardOutput, ids: panes.map(\.id), lines: lines)
    // Empty for every pane and a complaint on stderr means tmux refused the request. Either
    // alone is a legitimate answer: a cleared screen, or a closed pane. Neither a pane that is
    // gone nor a server that is gone is a refusal, so those lines are not complaints.
    let complaints = result.standardError.split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && !$0.hasPrefix("can't find pane") && !Self.isNoServer($0) }
    if read.values.allSatisfy(\.isEmpty), !complaints.isEmpty {
      throw Self.failure(
        exitStatus: result.exitStatus, standardError: complaints.joined(separator: "\n"))
    }
    answers.merge(read) { _, read in read }
    return answers
  }

  public func readScreen(of pane: Pane, lines: Int) async throws -> PaneScreen {
    let quoted = try quotedPane(pane.id)
    let output = try await execute(TmuxCommands.readScreen(binary: binary, pane: quoted))
    return PaneScreen.sanitised(output, lines: lines)
  }

  // MARK: Actions

  public func perform(_ action: PaneAction, on paneID: String) async throws {
    let pane = try quotedPane(paneID)
    _ = try await execute(TmuxCommands.perform(binary: binary, action: action, pane: pane))
  }

  public func rename(_ target: RenameTarget, to label: String) async throws {
    guard let raw = TmuxID.raw(of: target.id),
      TmuxID.kind(of: target.id) == (target.isWorkspace ? .session : .window)
    else { throw Self.notTmux(target.id) }
    _ = try await execute(
      TmuxCommands.rename(binary: binary, target: target, id: shellQuoted(raw), label: label)
    )
  }

  public var canStartTerminal: Bool { true }

  /// Opens a window in the most recently used session, or a session when no server runs, and
  /// returns the id of its pane.
  public func startTerminal() async throws -> String {
    var output: String
    do {
      output = try await execute(TmuxCommands.newWindow(binary: binary))
    } catch AppError.herdrCommandFailed(let reason) where Self.isNoServer(reason) {
      output = try await execute(TmuxCommands.newSession(binary: binary))
    }
    let raw = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let id = TmuxID.validRaw(raw, kind: .pane) else { throw AppError.herdrResponseUnreadable }
    return TmuxID.pane(id)
  }

  // MARK: Plumbing

  private func quotedPane(_ id: String) throws -> String {
    guard let raw = TmuxID.rawPane(of: id) else { throw Self.notTmux(id) }
    return shellQuoted(raw)
  }

  private static func notTmux(_ id: String) -> AppError {
    AppError.herdrCommandFailed(reason: "\(id) is not a tmux pane on this host.")
  }

  /// Runs a tmux command and returns its stdout, or throws something a person can act on.
  ///
  /// `allowingNoServer` turns "no server running" into empty output, because for a read that
  /// is an honest answer: no panes.
  private func execute(_ command: String, allowingNoServer: Bool = false) async throws -> String {
    let result: CommandResult
    do {
      result = try await run(command)
    } catch let error as AppError {
      throw error
    } catch {
      throw AppError.channelFailed(reason: "Could not run tmux on this host.")
    }
    guard result.exitStatus == 0 else {
      if allowingNoServer, Self.isNoServer(result.standardError) { return "" }
      throw Self.failure(exitStatus: result.exitStatus, standardError: result.standardError)
    }
    return result.standardOutput
  }

  /// tmux says one of these when no server is up. The two differ by whether the socket file
  /// exists, and mean the same to the user.
  ///
  /// **Only the two connect errors that mean nothing is listening.** `error connecting to … (Permission denied)`
  /// is a server the user cannot reach, and reading it as an empty tree would show a host with
  /// sessions as having none.
  static func isNoServer(_ message: String) -> Bool {
    if message.contains("no server running") || message.contains("no sessions") { return true }
    return message.contains("error connecting to")
      && (message.contains("No such file or directory") || message.contains("Connection refused"))
  }

  /// Maps a non-zero exit to an `AppError`. 127 is the shell's "command not found".
  ///
  /// `herdrNotInstalled` is the nearest case today, and says herdr. The wiring slice gives a
  /// tmux host its own wording.
  static func failure(exitStatus: Int, standardError: String) -> AppError {
    let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
    if exitStatus == 127 || detail.contains("command not found") { return .herdrNotInstalled }
    return .herdrCommandFailed(reason: detail.isEmpty ? "tmux exited with \(exitStatus)." : detail)
  }
}

extension RenameTarget {
  fileprivate var isWorkspace: Bool {
    if case .workspace = self { return true }
    return false
  }
}
