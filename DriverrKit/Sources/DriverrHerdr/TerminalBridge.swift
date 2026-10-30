import DriverrCore
import Foundation

/// A live byte conversation with a remote command.
///
/// Like `CommandRunner`, this module states the need and the app provides it, because
/// this module must not import `DriverrSSH`. `DriverrSSH.ExecStream` has this shape.
public protocol HerdrStream: Sendable {
  var output: AsyncThrowingStream<Data, any Error> { get }
  /// How the command finished: its exit status and a bounded tail of stderr. Read after
  /// `output` ends.
  ///
  /// `nil`, or a `ProcessEnd` with a `nil` status, means a bare end of stream, not success.
  /// A torn-down channel sends no `exit-status`.
  ///
  /// **A conforming type must bound how long this waits.** The status and stderr arrive on
  /// their own paths, unordered against the end of `output`.
  var end: ProcessEnd? { get async }
  func send(_ data: Data) async throws
  func close() async
}

/// Starts a remote command and hands back the conversation with it.
public typealias StreamRunner = @Sendable (String) async throws -> any HerdrStream

/// A pane, live, through herdr's terminal control bridge.
///
/// Not `herdr terminal attach`, which streams raw bytes and cannot scroll. The bridge
/// sends frames out and takes commands in, including `terminal.scroll`.
///
/// The `--cols`/`--rows` at open are this client's own. But `terminal.scroll` moves the
/// pane's shared scroll offset, and the pane's PTY takes the controller's size until
/// release, which reflows the desk. herdr allows one controller per terminal and refuses a
/// second (`TerminalCloseReason.refused`) unless it asks to take over. `observe` changes
/// neither offset nor size.
public protocol PaneBridge: Sendable {
  /// The pane's terminal output, decoded from the bridge's frames and ready to feed an
  /// emulator exactly as PTY bytes are.
  ///
  /// Finishes cleanly on `.paneClosed`, and throws a `TerminalCloseReason` for anything
  /// else, which the caller must react to.
  ///
  /// `.streamEnded` means the stream stopped with no `terminal.closed`: the channel went
  /// away and herdr may still hold the attach token. See `BridgeFramePump`.
  var output: AsyncThrowingStream<Data, any Error> { get }
  func send(text: String) async throws
  func send(bytes: Data) async throws
  func resize(to size: TerminalSize) async throws
  func scroll(_ direction: ScrollDirection, lines: Int) async throws
  /// A left click at `cell`, as a press and then a release.
  ///
  /// herdr reports it only if the program asked for mouse events. An older herdr skips the
  /// command, so this never types into a pane.
  func click(_ cell: TerminalCell) async throws
  /// Hands the controller back. herdr allows one controller at a time, so a screen nobody
  /// is looking at must not keep holding it.
  func release() async
}

/// A read-only view of a pane, through `herdr terminal session observe`.
///
/// An observer never takes the attach token or resizes the PTY, and coexists with a
/// controller and other observers. herdr silently drops input sent to an observer, so this
/// protocol has no input method.
public protocol PaneObserver: Sendable {
  /// Finishes the same way `PaneBridge.output` does.
  var output: AsyncThrowingStream<Data, any Error> { get }
  /// Ends the observe stream. There is no token to hand back, so nothing is sent first.
  func release() async
}

/// A pane whose bytes are the program's own, with no frames around them.
///
/// herdr-core's attach stream, and so a pane that behaves like a pty: its history is in the
/// local emulator and a tap is encoded locally. A `PaneBridge` or `PaneObserver` that is also
/// this says so, and the feed built from it has no `scroll` or `click`.
public protocol RawTerminalStream: Sendable {
  /// This many bytes have reached the emulator, so the far side may send more.
  ///
  /// Never waits. Called from the same turn that rendered them.
  func consumed(_ bytes: Int)
  /// Whether this viewer has the keyboard. It reaches a program that asked for focus events.
  func focus(_ gained: Bool) async throws
}

/// Opens a pane without a bridge command, for a backend that holds its own connection.
///
/// See `HerdrControl.paneAttacher(for:)`.
public protocol PaneAttacher: Sendable {
  /// A viewer that can type, and that takes the terminal's size as it opens.
  func open(terminalID: String, size: TerminalSize) async throws -> any PaneBridge
  func observe(terminalID: String, size: TerminalSize) async throws -> any PaneObserver
}

/// Opens panes through herdr's control bridge.
public struct TerminalBridgeClient: Sendable {
  private let binaryPath: String
  /// `Host.herdrSocketPath`, exported ahead of both bridge commands as `CLIControl` does.
  /// Without it they reach the default herdr, which does not know the terminal id.
  private let socketPath: String?
  private let run: StreamRunner

  public init(
    binaryPath: String = "herdr",
    socketPath: String? = nil,
    run: @escaping StreamRunner
  ) {
    self.binaryPath = binaryPath
    self.socketPath = socketPath
    self.run = run
  }

  /// The command that starts a controller for one terminal.
  ///
  /// `takeover` defaults to `false`, so attaching does not evict the user at their desk.
  /// Only the Take over action, offered after `.refused`, sets it.
  static func controlCommand(
    binaryPath: String,
    terminalID: String,
    size: TerminalSize,
    takeover: Bool = false,
    socketPath: String? = nil
  ) -> String {
    CLIControl.withSocketPathEnv(
      "\(shellQuoted(binaryPath)) terminal session control \(shellQuoted(terminalID))"
        + " --cols \(size.columns) --rows \(size.rows)"
        + (takeover ? " --takeover" : ""),
      socketPath: socketPath
    )
  }

  /// The command that starts a read-only observer for one terminal. An observer holds no
  /// token, so it never takes `--takeover`.
  static func observeCommand(
    binaryPath: String,
    terminalID: String,
    size: TerminalSize,
    socketPath: String? = nil
  ) -> String {
    CLIControl.withSocketPathEnv(
      "\(shellQuoted(binaryPath)) terminal session observe \(shellQuoted(terminalID))"
        + " --cols \(size.columns) --rows \(size.rows)",
      socketPath: socketPath
    )
  }

  public func open(
    terminalID: String,
    size: TerminalSize,
    takeover: Bool = false
  ) async throws -> any PaneBridge {
    let stream = try await run(
      Self.controlCommand(
        binaryPath: binaryPath,
        terminalID: terminalID,
        size: size,
        takeover: takeover,
        socketPath: socketPath
      )
    )
    return HerdrPaneBridge(stream: stream)
  }

  public func observe(terminalID: String, size: TerminalSize) async throws -> any PaneObserver {
    let stream = try await run(
      Self.observeCommand(
        binaryPath: binaryPath,
        terminalID: terminalID,
        size: size,
        socketPath: socketPath
      )
    )
    return HerdrPaneObserver(stream: stream)
  }
}

/// Decodes a herdr stream's NDJSON records into frame bytes, for both `HerdrPaneBridge`
/// and `HerdrPaneObserver`.
///
/// **A stream that stops with no `terminal.closed` is not an ordinary close.** When herdr
/// ends a session it has already taken the token back. When the phone loses its link,
/// the host never learns, and herdr keeps the token. So a bare end throws `.streamEnded`,
/// not `.paneClosed`.
///
/// Before that, `HerdrStream.end` is checked. A bridge process that exited nonzero throws
/// `.processFailed` with herdr's message instead.
private final class BridgeFramePump: @unchecked Sendable {
  let output: AsyncThrowingStream<Data, any Error>
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let task: Task<Void, Never>

  init(stream: any HerdrStream) {
    (output, continuation) = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self
    )
    let continuation = self.continuation
    task = Task {
      var decoder = TerminalFrameDecoder()
      do {
        for try await chunk in stream.output {
          for record in decoder.consume(chunk) {
            switch record {
            case .frame(let bytes):
              continuation.yield(bytes)
            case .closed(let reason):
              if reason == .paneClosed {
                continuation.finish()
              } else {
                continuation.finish(throwing: reason)
              }
              return
            }
          }
        }
        // A bare end, unless we cancelled it ourselves. The check makes that ordering
        // certain rather than a race.
        guard !Task.isCancelled else {
          continuation.finish()
          return
        }
        // A nonzero exit means herdr answered and refused, so there is nothing to
        // reattach to. A `nil` end, no status or status zero stays `.streamEnded`, because
        // it says nothing about the pane.
        let end = await stream.end
        if let end, end.isFailure, let status = end.exitStatus {
          continuation.finish(
            throwing: TerminalCloseReason.processFailed(
              status: status,
              message: TerminalFrameDecoder.herdrMessage(fromStandardError: end.standardErrorTail)
            )
          )
          return
        }
        continuation.finish(throwing: TerminalCloseReason.streamEnded)
      } catch {
        continuation.finish(throwing: error)
      }
    }
  }

  func cancel() {
    task.cancel()
    continuation.finish()
  }
}

/// The bridge protocol itself: NDJSON in, NDJSON out.
final class HerdrPaneBridge: PaneBridge, @unchecked Sendable {
  var output: AsyncThrowingStream<Data, any Error> { pump.output }

  private let stream: any HerdrStream
  private let pump: BridgeFramePump

  init(stream: any HerdrStream) {
    self.stream = stream
    self.pump = BridgeFramePump(stream: stream)
  }

  deinit { pump.cancel() }

  func send(text: String) async throws {
    try await write(TerminalControlCommand.input(text: text, bytes: nil))
  }

  func send(bytes: Data) async throws {
    try await write(
      TerminalControlCommand.input(text: nil, bytes: bytes.base64EncodedString())
    )
  }

  func resize(to size: TerminalSize) async throws {
    try await write(
      .resize(
        cols: size.columns,
        rows: size.rows,
        cellWidth: size.pixelWidth / max(size.columns, 1),
        cellHeight: size.pixelHeight / max(size.rows, 1)
      )
    )
  }

  func scroll(_ direction: ScrollDirection, lines: Int) async throws {
    // herdr rejects a non-positive line count, so a tiny drag is a no-op here.
    guard lines > 0 else { return }
    try await write(.scroll(direction: direction.rawValue, lines: lines))
  }

  func click(_ cell: TerminalCell) async throws {
    try await write(.mouse(kind: "down", column: cell.column, row: cell.row))
    try await write(.mouse(kind: "up", column: cell.column, row: cell.row))
  }

  func release() async {
    try? await write(.release)
    await stream.close()
    pump.cancel()
  }

  private func write(_ command: TerminalControlCommand) async throws {
    var line = try JSONEncoder().encode(command)
    line.append(0x0A)
    try await stream.send(line)
  }
}

/// The observer half: the same decoding as `HerdrPaneBridge`, no input path, and a
/// `release()` that writes nothing first.
final class HerdrPaneObserver: PaneObserver, @unchecked Sendable {
  var output: AsyncThrowingStream<Data, any Error> { pump.output }

  private let stream: any HerdrStream
  private let pump: BridgeFramePump

  init(stream: any HerdrStream) {
    self.stream = stream
    self.pump = BridgeFramePump(stream: stream)
  }

  deinit { pump.cancel() }

  func release() async {
    await stream.close()
    pump.cancel()
  }
}

/// Commands the controller accepts on stdin, one JSON object per line.
///
/// Mirrors `TerminalControlCommand` in herdr's `src/client/mod.rs`. Hand-encoded, because
/// the field names are herdr's, and a Swift rename must not change them.
enum TerminalControlCommand: Encodable {
  case input(text: String?, bytes: String?)
  case resize(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int)
  case scroll(direction: String, lines: Int)
  /// A left button press or release, `kind` `down` or `up`, at a 0-based cell. herdr
  /// 0.9.1 and older report it as unknown on stderr and carry on.
  case mouse(kind: String, column: Int, row: Int)
  case release

  private enum CodingKeys: String, CodingKey {
    case type
    case text
    case bytes
    case cols
    case rows
    case cellWidth = "cell_width_px"
    case cellHeight = "cell_height_px"
    case direction
    case lines
    case kind
    case column
    case row
    case modifiers
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .input(text, bytes):
      try container.encode("terminal.input", forKey: .type)
      // One or the other, never both: herdr answers "terminal.input accepts text or
      // bytes, not both" and drops the command.
      if let text {
        try container.encode(text, forKey: .text)
      } else if let bytes {
        try container.encode(bytes, forKey: .bytes)
      }
    case let .resize(cols, rows, cellWidth, cellHeight):
      try container.encode("terminal.resize", forKey: .type)
      try container.encode(cols, forKey: .cols)
      try container.encode(rows, forKey: .rows)
      try container.encode(cellWidth, forKey: .cellWidth)
      try container.encode(cellHeight, forKey: .cellHeight)
    case let .scroll(direction, lines):
      try container.encode("terminal.scroll", forKey: .type)
      try container.encode(direction, forKey: .direction)
      try container.encode(lines, forKey: .lines)
    case let .mouse(kind, column, row):
      try container.encode("terminal.mouse", forKey: .type)
      try container.encode(kind, forKey: .kind)
      try container.encode(column, forKey: .column)
      try container.encode(row, forKey: .row)
      // A tap holds no modifier. herdr expects the field.
      try container.encode(0, forKey: .modifiers)
    case .release:
      try container.encode("terminal.release", forKey: .type)
    }
  }
}

/// What a decoded bridge record means to Driverr.
enum TerminalBridgeRecord: Equatable {
  case frame(Data)
  case closed(reason: TerminalCloseReason)
}

/// Turns a byte stream into bridge records.
///
/// - A read is not a line. A frame can span two chunks, so the tail is held until its
///   newline arrives.
/// - An unknown record type is skipped, as in `HerdrWireTypes`.
struct TerminalFrameDecoder {
  private var pending = Data()
  private var lastSequence: Int?
  /// Sequence numbers that arrived out of order or with a gap.
  ///
  /// Counted, not thrown: a pane with a gap beats no pane.
  ///
  /// `seq` restarts at 1 on every `control` or `observe` session, so a gap means frames
  /// lost within this session, never a detach.
  private(set) var sequenceGaps = 0

  mutating func consume(_ chunk: Data) -> [TerminalBridgeRecord] {
    pending.append(chunk)
    var records: [TerminalBridgeRecord] = []

    while let newline = pending.firstIndex(of: 0x0A) {
      let line = pending[pending.startIndex..<newline]
      pending = pending[pending.index(after: newline)...]
      if let record = decode(Data(line)) { records.append(record) }
    }
    // What is left has no newline yet.
    pending = Data(pending)
    return records
  }

  private mutating func decode(_ line: Data) -> TerminalBridgeRecord? {
    guard !line.isEmpty,
      let record = try? JSONDecoder().decode(HerdrTerminalRecord.self, from: line)
    else { return nil }

    switch record.type {
    case "terminal.frame":
      if let seq = record.seq {
        if let last = lastSequence, seq != last + 1 { sequenceGaps += 1 }
        lastSequence = seq
      }
      // An encoding other than `ansi` is skipped rather than fed to the emulator.
      guard record.encoding == nil || record.encoding == "ansi" else { return nil }
      guard let base64 = record.bytes, let bytes = Data(base64Encoded: base64) else {
        return nil
      }
      return .frame(bytes)
    case "terminal.closed":
      return .closed(reason: Self.closeReason(from: record.reason))
    default:
      return nil
    }
  }

  /// Maps herdr's `reason` string to `TerminalCloseReason`. herdr's wording matters only
  /// here.
  ///
  /// - `"terminal attach failed: … retry with --takeover"` → `.refused`
  /// - `"terminal attach taken over"` → `.takenOver`
  /// - `"terminal <id> exited"`, or no reason → `.paneClosed`
  /// - `"detached"` → `.detached`
  /// - `"server is shutting down"` → `.serverShuttingDown`
  /// - anything else → `.other`, kept verbatim
  ///
  /// The last two match by substring, case-insensitively, because their exact wording is
  /// not confirmed against a herdr that sends them. A miss falls back to `.other`.
  private static func closeReason(from reason: String?) -> TerminalCloseReason {
    guard let reason else { return .paneClosed }
    if reason.contains("already has an attached client") { return .refused }
    if reason.contains("taken over") { return .takenOver }
    if reason.hasSuffix(" exited") { return .paneClosed }
    // `lowercased()`, not `localizedLowercase`. A Turkish locale lowercases `I` to a
    // dotless `ı`, and the match would depend on the user's region.
    let lowered = reason.lowercased()
    if lowered.contains("shutting down") { return .serverShuttingDown }
    if lowered.contains("detached") { return .detached }
    return .other(reason)
  }

  /// Pulls herdr's own sentence out of the bridge process's stderr tail, or `nil`.
  ///
  /// herdr writes either a plain line, `herdr: <message>`, or a JSON error envelope. A
  /// missing herdr gives the shell's `herdr: command not found`, the plain form.
  ///
  /// The envelope is tried on the whole tail, which may be pretty-printed, and then on the
  /// last non-empty line, which may follow progress output. Otherwise the last line is
  /// used with `herdr:` stripped. Length is bounded later, by
  /// `TerminalEndDisposition.boundedMessage`.
  static func herdrMessage(fromStandardError tail: String) -> String? {
    let whole = tail.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !whole.isEmpty else { return nil }
    if let message = envelopeMessage(in: whole) { return message }
    guard
      let last = whole
        .split(whereSeparator: { $0.isNewline })
        .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    else { return nil }
    let lastLine = String(last).trimmingCharacters(in: .whitespaces)
    if let message = envelopeMessage(in: lastLine) { return message }
    var line = lastLine
    // Match `herdr:` without the space. A bare prefix arrives already trimmed.
    if line.hasPrefix("herdr:") { line.removeFirst("herdr:".count) }
    let stripped = line.trimmingCharacters(in: .whitespaces)
    return stripped.isEmpty ? nil : stripped
  }

  /// The `error.message` of herdr's JSON-RPC error envelope, if this text is one.
  ///
  /// `JSONSerialization`, not `Decodable`, so anything else on stderr returns `nil` and an
  /// envelope with extra fields still decodes.
  private static func envelopeMessage(in text: String) -> String? {
    guard text.hasPrefix("{"), let data = text.data(using: .utf8) else { return nil }
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let error = object["error"] as? [String: Any],
      let message = error["message"] as? String
    else { return nil }
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// One record off the bridge.
///
/// Every field but `type` is optional, following the rule in `HerdrWireTypes`.
struct HerdrTerminalRecord: Decodable {
  let type: String
  let seq: Int?
  let full: Bool?
  let encoding: String?
  /// Set on `terminal.closed`. Absent for an ordinary close.
  let reason: String?
  let width: Int?
  let height: Int?
  let bytes: String?
}
