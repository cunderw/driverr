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
  private let backoff = NoServerBackoff()

  public init(binaryPath: String = "tmux", run: @escaping CommandRunner) {
    self.binaryPath = binaryPath
    self.run = run
  }

  /// The most polls in a row that skip a tmux with no server, counted in ticks, as
  /// `CombinedControl.longestTUIBackoff` does for a TUI with no session. The gap doubles from
  /// one poll, so the checks fall on polls 1, 3, 6, 11, 20 and then every eleventh.
  ///
  /// A judgement, not a measurement. A session started at the desk shows within it, and a host
  /// whose tmux is only installed is asked once in eleven polls instead of every one.
  static let longestNoServerBackoff = 10

  /// A struct cannot remember, and this control is copied into every model that reads it, so
  /// every copy shares one schedule.
  private actor NoServerBackoff {
    private var ticksToSkip = 0
    private var gap = 0

    /// Whether this poll is one to skip, counted off.
    func skip() -> Bool {
      guard ticksToSkip > 0 else { return false }
      ticksToSkip -= 1
      return true
    }

    /// What a listing found. An empty one means no server, because a tmux server exits with its
    /// last session.
    func listed(empty: Bool) {
      gap = empty ? min(max(gap * 2, 1), TmuxControl.longestNoServerBackoff) : 0
      ticksToSkip = gap
    }

    func reset() {
      ticksToSkip = 0
      gap = 0
    }
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

  /// What this host has, in `HerdrControl`'s terms: one of `HerdrAvailability`'s tmux cases.
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

  public func resetBackoff() async {
    await backoff.reset()
  }

  /// The panes, and then the agents in them.
  ///
  /// **The process table is read only when there are panes**, so a host with tmux installed and
  /// no server costs one command a check, and `longestNoServerBackoff` spaces the checks out.
  /// `resetBackoff()` ends the gap.
  public func snapshot() async throws -> SessionTree {
    if await backoff.skip() { return .empty }
    let output = try await execute(
      TmuxCommands.listPanes(binary: binary), allowingNoServer: true)
    let rows = TmuxPaneFormat.rows(from: output)
    await backoff.listed(empty: rows.isEmpty)
    guard !rows.isEmpty else { return .empty }

    // The process table only adds agents, so a host that will not answer it still has a tree.
    let processes = try? await run(TmuxProcessTable.command)
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

  /// `nil`: no command shows one tmux pane and leaves the desk alone.
  ///
  /// `attach-session -t %N` makes that pane's window current in its session, so the desk's
  /// view moves with the phone, and attaching to the session alone shows whichever pane is
  /// current there. The live terminal opens a pane through `paneAttacher(for:)` instead, and
  /// until it does, `TerminalSceneModel` says the terminal is unavailable.
  public func attachCommand(for pane: Pane) -> String? { nil }

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

  /// `false` until a tmux pane's terminal can be shown. A window started now would open on the
  /// desk and then show nothing on the phone. `startTerminal()` still works, for that day.
  public var canStartTerminal: Bool { false }

  /// Opens a window in the most recently used session, or a session when no server runs, and
  /// returns the id of its pane.
  public func startTerminal() async throws -> String {
    var output: String
    do {
      output = try await execute(TmuxCommands.newWindow(binary: binary))
    } catch AppError.herdrCommandFailed(let reason) where Self.isNoServer(reason) {
      output = try await execute(TmuxCommands.newSession(binary: binary))
    }
    // The server may be new, so the next snapshot asks rather than answering from the gap.
    await backoff.reset()
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
  static func failure(exitStatus: Int, standardError: String) -> AppError {
    let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
    if exitStatus == 127 || detail.contains("command not found") { return .tmuxNotInstalled }
    return .herdrCommandFailed(reason: detail.isEmpty ? "tmux exited with \(exitStatus)." : detail)
  }
}

extension RenameTarget {
  fileprivate var isWorkspace: Bool {
    if case .workspace = self { return true }
    return false
  }
}
