import DriverrCore
import Foundation

/// What Driverr asks of a herdr session.
///
/// One live conformance, `CLIControl`, and `FakeControl`. herdr's socket is not reachable
/// over SSH without a remote prerequisite, so there is no socket conformance.
public protocol HerdrControl: Sendable {
  /// The whole session as a tree. herdr returns four flat arrays; the tree is assembled
  /// at this boundary so nothing downstream has to join ids.
  func snapshot() async throws -> SessionTree

  /// The command that puts one pane's live terminal on a PTY.
  ///
  /// Returned as a string, because attaching needs a PTY, which the app opens. Takes the
  /// whole `Pane`, because the command depends on it. See `CLIControl.attachCommand(for:)`.
  func attachCommand(for pane: Pane) -> String

  /// Whether this host can serve herdr at all, and which "no" it is if not.
  func availability() async -> HerdrAvailability

  /// Where herdr was found on this host.
  ///
  /// The terminal bridge starts a second herdr process and must use the same binary. It
  /// may be an absolute path, because an SSH exec channel's non-login shell may lack
  /// Homebrew on `PATH`.
  var binaryPath: String { get }

  /// Types literal text into a pane, as if typed at the keyboard. Needs no PTY.
  ///
  /// **A trailing newline stays literal and does not submit.** Use `submitText` to send.
  func sendText(paneID: String, text: String) async throws

  /// Types text into a pane **and submits it**, in one command.
  ///
  /// `pane send-text "yes\n"` delivers `yes` and LF. `pane run "yes"` delivers `yes` and
  /// CR. Claude Code reads LF as a line break and CR as submit, so `sendText` with a
  /// newline leaves the reply unsent in the input box.
  ///
  /// One call, not send-text then Enter, because a failure between the two would leave a
  /// half-typed answer in the pane.
  func submitText(paneID: String, text: String) async throws

  /// Presses keys in a pane.
  ///
  /// Separate from `sendText` on the wire and in meaning: an Escape is not a string.
  func sendKeys(paneID: String, keys: [PaneKey]) async throws

  /// The last `lines` rows of several panes at once.
  ///
  /// One request for the pane sheet's thumbnails, instead of one exec channel per pane.
  ///
  /// A pane that could not be read maps to an empty array, so one closed pane does not
  /// blank the rest. Only a failure to ask at all throws.
  func readPanes(ids: [String], lines: Int) async throws -> [String: [String]]

  /// One pane's visible screen, styled and sanitised, for the reply surface.
  ///
  /// It differs from `readPanes` in two ways:
  ///
  /// - It asks for `--format ansi`, because the SGR separates the agent's message from the
  ///   rest of the screen.
  /// - It reads the exit status and stderr. A refusal is an empty stdout with a message on
  ///   stderr, and must not render as a blank pane.
  ///
  /// Throws on a refusal, and returns an empty `PaneScreen` for a blank pane. Takes the
  /// whole `Pane`, because `viewport_rows` bounds the request. See `readScreenCommand`.
  func readScreen(of pane: Pane, lines: Int) async throws -> PaneScreen

  /// Does something to a pane other than typing into it: split, rename or close.
  ///
  /// Each action is a pane id, a herdr subcommand and no answer worth reading. The next
  /// snapshot shows whether it worked.
  func perform(_ action: PaneAction, on paneID: String) async throws

  /// Renames a workspace or a tab.
  ///
  /// Not a `PaneAction`, because it takes a workspace or tab id, not a pane id.
  /// `RenameTarget` says which. As with `perform`, the next snapshot shows the result; see
  /// `SessionModel.commitRename`.
  func rename(_ target: RenameTarget, to label: String) async throws
}

/// Drives herdr through its command-line interface.
///
/// The CLI is a client of herdr's socket API and returns the same envelope, so this maps
/// the same wire types, one exec channel per request.
public struct CLIControl: HerdrControl {
  /// How to reach `herdr` on the host. Discovery may set an absolute path, because an SSH
  /// exec channel's shell may lack Homebrew or `~/.local/bin` on `PATH`. See
  /// `CLIControl.discoveryCommand`.
  public let binaryPath: String
  /// Where herdr's socket is, when it is not the default (`Host.herdrSocketPath`). When
  /// set, it is exported ahead of every command. See `withSocketPathEnv`.
  ///
  /// A `var`, because the control is built before the `Host` is known and
  /// `ConnectionModel.connect()` sets it afterwards.
  public var herdrSocketPath: String?
  private let run: CommandRunner

  public init(
    binaryPath: String = "herdr",
    herdrSocketPath: String? = nil,
    run: @escaping CommandRunner
  ) {
    self.binaryPath = binaryPath
    self.herdrSocketPath = herdrSocketPath
    self.run = run
  }

  /// Prefixes a command with `export HERDR_SOCKET_PATH=<value>;` when the host asked for
  /// a non-default socket, and leaves it alone otherwise.
  ///
  /// `export`, not `VAR=value command`, which covers only one simple command.
  /// `readCommand` joins several `herdr` calls with `;`.
  static func withSocketPathEnv(_ command: String, socketPath: String?) -> String {
    guard let socketPath, !socketPath.isEmpty else { return command }
    return "export HERDR_SOCKET_PATH=\(shellQuoted(socketPath)); \(command)"
  }

  public func attachCommand(for pane: Pane) -> String {
    // `--takeover` is never passed. Attaching must not evict the user at their desk.

    // By terminal, not by agent, when herdr sent a terminal id. `agent attach` fails with
    // `agent_not_found` on a pane with no agent, which is most panes.
    let command: String
    if let terminalID = pane.terminalID {
      command = "\(shellQuoted(binaryPath)) terminal attach \(shellQuoted(terminalID))"
    } else {
      // Only when herdr sent no terminal id. The field is required from protocol 19, and
      // the floor is 17.
      command = "\(shellQuoted(binaryPath)) agent attach \(shellQuoted(pane.id))"
    }
    return Self.withSocketPathEnv(command, socketPath: herdrSocketPath)
  }

  /// Bypasses `execute`, which throws on a non-zero exit, because here the exit status is
  /// the answer.
  func runStatus() async throws -> CommandResult {
    try await run(
      Self.withSocketPathEnv(
        "\(shellQuoted(binaryPath)) status server",
        socketPath: herdrSocketPath
      )
    )
  }

  public func snapshot() async throws -> SessionTree {
    let output = try await execute("api snapshot")
    let response = try decode(HerdrResponse<HerdrSnapshotResult>.self, from: output)
    return SnapshotMapper.tree(from: response.result.snapshot)
  }

  public func sendText(paneID: String, text: String) async throws {
    // Always quoted: this text is typed by a person, and a stray quote or `$(…)` would
    // otherwise reach the remote shell.
    _ = try await execute("pane send-text \(shellQuoted(paneID)) \(shellQuoted(text))")
  }

  public func submitText(paneID: String, text: String) async throws {
    // One argument, trailing newlines trimmed. `pane run` joins arguments with a space
    // and appends one CR, so a trailing newline would send a stray blank line.
    let submitted = Self.submittable(text)
    _ = try await execute("pane run \(shellQuoted(paneID)) \(shellQuoted(submitted))")
  }

  /// A reply as it goes over: trailing newlines and spaces trimmed, everything else left
  /// exactly as typed.
  ///
  /// Only the trailing end. An interior newline is a line break the person meant, and the
  /// final CR still submits the whole message.
  static func submittable(_ text: String) -> String {
    var text = Substring(text)
    while let last = text.last, last.isNewline || last == " " || last == "\t" {
      text = text.dropLast()
    }
    return String(text)
  }

  public func sendKeys(paneID: String, keys: [PaneKey]) async throws {
    guard !keys.isEmpty else { return }
    // **One herdr call per key, chained in one exec.** Two printable keys in one
    // `pane send-keys` arrive as one burst, and Claude Code's picker drops both. `&&` stops
    // at the first refusal, which `execute` reports.
    let pane = shellQuoted(paneID)
    let calls = keys.map { "pane send-keys \(pane) \(shellQuoted($0.rawValue))" }
    _ = try await execute(calls.joined(separator: " && \(shellQuoted(binaryPath)) "))
  }

  /// What separates one pane's rows from the next one's in a batched read.
  ///
  /// The boundary carries the pane id, because pane output is arbitrary. A bare marker in
  /// a pane's text would shift every later pane onto the wrong tile.
  static let paneMarker = "__DRIVERR_PANE__"

  public func readPanes(ids: [String], lines: Int) async throws -> [String: [String]] {
    // `herdr pane read` with no id is a usage error, which would be reported as a herdr
    // refusal.
    guard !ids.isEmpty else { return [:] }

    let result: CommandResult
    do {
      result = try await run(
        Self.readCommand(binaryPath: binaryPath, ids: ids, lines: lines, socketPath: herdrSocketPath)
      )
    } catch let error as AppError {
      throw error
    } catch {
      throw AppError.channelFailed(reason: "Could not run herdr on this host.")
    }

    // **Not `execute`, and the exit status is ignored.** The shell reports only the last
    // command's status, which describes one pane, not the batch.
    let panes = Self.panes(from: result.standardOutput, ids: ids, lines: lines)

    // Empty for every pane and a complaint on stderr means herdr refused the request.
    // Either alone is a legitimate answer: a cleared session, or one closed pane.
    if panes.values.allSatisfy(\.isEmpty), !result.standardError.isEmpty {
      throw Self.failure(exitStatus: result.exitStatus, standardError: result.standardError)
    }
    return panes
  }

  /// One command that reads every pane, with a boundary printed before each.
  ///
  /// `printf` with a leading newline puts each boundary on its own line, whatever the
  /// previous read ended with. The blank line is trimmed with the previous chunk.
  ///
  /// **`--source visible`, never `--source recent`.** `recent` takes the last N buffer
  /// rows, blanks included, and trims afterwards. A shell at a prompt more than N rows
  /// above the screen's bottom then reads as empty, with exit 0. `visible` trims first and
  /// applies `--lines` to what is left, which matches `TerminalSession.visibleLines(last:)`.
  /// `CLIControlTests` checks only the string. The opt-in `LiveHerdrProbeTests` checks
  /// herdr's behaviour.
  static func readCommand(
    binaryPath: String,
    ids: [String],
    lines: Int,
    socketPath: String? = nil
  ) -> String {
    let commands = ids.map { id in
      #"printf '\n%s\n' "# + shellQuoted("\(paneMarker) \(id)") + "; "
        + "\(shellQuoted(binaryPath)) pane read \(shellQuoted(id))"
        + " --source visible --lines \(lines) --format text"
    }
    .joined(separator: "; ")
    return withSocketPathEnv(commands, socketPath: socketPath)
  }

  /// Splits a batch's output back into one array of rows per pane.
  ///
  /// Every id asked for gets an entry, so "asked and got nothing" differs from "never
  /// asked".
  static func panes(from output: String, ids: [String], lines: Int) -> [String: [String]] {
    var boundaries: [String: String] = [:]
    for id in ids { boundaries["\(paneMarker) \(id)"] = id }

    var panes = [String: [String]](minimumCapacity: ids.count)
    for id in ids { panes[id] = [] }

    var current: String?
    var chunk: [String] = []
    func flush() {
      if let current { panes[current] = rows(of: chunk, limit: lines) }
      chunk = []
    }

    for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
      if let id = boundaries[String(line)] {
        flush()
        current = id
      } else if current != nil {
        chunk.append(String(line))
      }
      // Output before the first boundary belongs to no pane.
    }
    flush()

    return panes
  }

  /// One pane's chunk, as the rows a thumbnail should draw.
  static func rows(of chunk: [String], limit: Int) -> [String] {
    // herdr 0.8.0 printed a failed read's error envelope to stdout, inside the chunk.
    // Later versions use stderr. Kept for older herdr, which the protocol floor admits.
    let joined = chunk.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    if joined.hasPrefix("{"),
      (try? JSONDecoder().decode(HerdrErrorResponse.self, from: Data(joined.utf8))) != nil
    {
      return []
    }

    var rows = chunk.map(trimmingTrailingWhitespace)
    // Drops the blank line before the next boundary, so a blank pane returns no rows.
    while rows.last?.isEmpty == true { rows.removeLast() }
    return Array(rows.suffix(limit))
  }

  private static func trimmingTrailingWhitespace(_ line: String) -> String {
    var line = line
    while let last = line.last, last.isWhitespace { line.removeLast() }
    return line
  }

  public func readScreen(of pane: Pane, lines: Int) async throws -> PaneScreen {
    let result: CommandResult
    do {
      result = try await run(
        Self.readScreenCommand(
          binaryPath: binaryPath,
          pane: pane,
          lines: lines,
          socketPath: herdrSocketPath
        )
      )
    } catch let error as AppError {
      throw error
    } catch {
      throw AppError.channelFailed(reason: "Could not run herdr on this host.")
    }

    // One pane is one command, so the exit status describes this read. A refusal is an
    // empty stdout with the message on stderr, which looks like a blank pane otherwise.
    if result.exitStatus != 0 {
      throw Self.failure(
        exitStatus: result.exitStatus,
        standardError: Self.refusal(in: result) ?? result.standardError
      )
    }

    // Exit 0 with an error envelope is still a refusal. Gated on an empty stdout, so a
    // screen that contains JSON is not read as a failure.
    if result.standardOutput.isEmpty, let message = Self.errorMessage(in: result.standardError) {
      throw AppError.herdrCommandFailed(reason: message)
    }

    // Exit 0, empty stdout and nothing on stderr is a blank screen.
    return PaneScreen.sanitised(result.standardOutput, lines: lines)
  }

  /// The single-pane read, as one command.
  ///
  /// **`pane read`, never `agent read`.** With N above the viewport, `agent read` fails
  /// with `agent_not_idle` on a working agent, which is when the reader wants it.
  ///
  /// **`--lines` only when the viewport is known.** More rows than the viewport makes herdr
  /// scroll to capture, about 420 ms instead of 30 ms, for the same bytes. Without
  /// `viewport_rows` no `--lines` is sent, and the caller's tail is taken here.
  static func readScreenCommand(
    binaryPath: String,
    pane: Pane,
    lines: Int,
    socketPath: String? = nil
  ) -> String {
    var command =
      "\(shellQuoted(binaryPath)) pane read \(shellQuoted(pane.id)) --source visible"
    if let bounded = boundedLines(requested: lines, viewportRows: pane.viewportRows) {
      command += " --lines \(bounded)"
    }
    command += " --format ansi"
    return withSocketPathEnv(command, socketPath: socketPath)
  }

  /// How many lines to ask for, or `nil` for "do not ask". See `readScreenCommand`.
  static func boundedLines(requested: Int, viewportRows: Int?) -> Int? {
    guard let viewportRows, viewportRows > 0 else { return nil }
    return max(1, min(requested, viewportRows))
  }

  /// What herdr said when it refused, or `nil` when it did not.
  ///
  /// Checks both streams: herdr 0.8.0 wrote the envelope to stdout, later versions to
  /// stderr. Returns the message, not the raw JSON.
  static func refusal(in result: CommandResult) -> String? {
    errorMessage(in: result.standardError) ?? errorMessage(in: result.standardOutput)
  }

  private static func errorMessage(in stream: String) -> String? {
    let trimmed = stream.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("{"),
      let failure = try? JSONDecoder().decode(HerdrErrorResponse.self, from: Data(trimmed.utf8))
    else { return nil }
    return failure.error.message ?? failure.error.code ?? "herdr refused the request."
  }

  public func perform(_ action: PaneAction, on paneID: String) async throws {
    _ = try await execute(Self.arguments(for: action, paneID: paneID))
  }

  public func rename(_ target: RenameTarget, to label: String) async throws {
    _ = try await execute(Self.arguments(for: target, label: label))
  }

  /// The herdr subcommand for each action.
  ///
  /// Non-private so a test can assert the exact command.
  static func arguments(for action: PaneAction, paneID: String) -> String {
    let pane = shellQuoted(paneID)
    switch action {
    case .split(let direction):
      return "pane split \(pane) --direction \(direction.rawValue)"
    case .rename(let label):
      // Quoted, so a multi-word label stays one argument.
      return "pane rename \(pane) \(shellQuoted(label))"
    case .close:
      return "pane close \(pane)"
    }
  }

  /// The herdr subcommand for renaming a container.
  ///
  /// Non-private so a test can assert the exact command.
  ///
  /// Both take the id, then the label as trailing words. `shellQuoted` keeps a multi-word
  /// label one argument.
  static func arguments(for target: RenameTarget, label: String) -> String {
    let label = shellQuoted(label)
    switch target {
    case .workspace(let id):
      return "workspace rename \(shellQuoted(id)) \(label)"
    case .tab(let id):
      return "tab rename \(shellQuoted(id)) \(label)"
    }
  }

  /// Runs a herdr subcommand and returns its stdout, or throws something a person can act
  /// on.
  private func execute(_ arguments: String) async throws -> String {
    let command = Self.withSocketPathEnv(
      "\(shellQuoted(binaryPath)) \(arguments)",
      socketPath: herdrSocketPath
    )
    let result: CommandResult
    do {
      result = try await run(command)
    } catch let error as AppError {
      throw error
    } catch {
      throw AppError.channelFailed(reason: "Could not run herdr on this host.")
    }

    guard result.exitStatus == 0 else {
      throw Self.failure(exitStatus: result.exitStatus, standardError: result.standardError)
    }
    return result.standardOutput
  }

  /// Maps a non-zero exit to a specific `AppError`.
  ///
  /// A missing herdr and a refused request need different responses. 127 is the shell's
  /// "command not found".
  static func failure(exitStatus: Int, standardError: String) -> AppError {
    let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
    if exitStatus == 127 || detail.contains("command not found") {
      return .herdrNotInstalled
    }
    return .herdrCommandFailed(reason: detail.isEmpty ? "herdr exited with \(exitStatus)." : detail)
  }

  private func decode<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
    let data = Data(output.utf8)
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      // An error envelope is herdr's answer, not a decoding bug. Show its message.
      if let failure = try? JSONDecoder().decode(HerdrErrorResponse.self, from: data) {
        throw AppError.herdrCommandFailed(
          reason: failure.error.message ?? failure.error.code ?? "herdr refused the request."
        )
      }
      throw AppError.herdrResponseUnreadable
    }
  }

}
