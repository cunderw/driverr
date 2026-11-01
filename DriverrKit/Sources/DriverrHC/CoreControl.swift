import DriverrCore
import DriverrHerdr
import Foundation

/// Drives a herdr-core over one `hc connect` exec channel.
///
/// **Typing goes through a viewer**, never `terminal.send` or `terminal.keys`, which wait for
/// about 3 s of quiet and refuse a blocked agent. See `typing(into:_:)`.
///
/// **Reading a screen opens nothing.** `terminal.read` is a plain call on the connection, so it
/// is no viewer and cannot take the size. See `readScreen(of:lines:)` and `readPanes(ids:lines:)`.
///
/// **A core has no rename.** `name` is `terminal.run`'s alone, a label means nothing to the core,
/// and the desktop app keeps a space's or tab's name in its own document, which Driverr never
/// writes. So `canPerform` and `canRename` hide it, and the rest of an action is plain calls.
public struct CoreControl: HerdrControl {
  /// How long one call may take, the opening included.
  public static let defaultCallDeadline: Duration = .seconds(5)
  /// How often a subscription's silence is checked. See `CoreEventFeed.silentTicksAllowed`.
  public static let defaultHeartbeatTick: Duration = .seconds(5)

  /// Scrollback to paint at the head of a typing attach: what SwiftTerm keeps by default.
  static let attachHistoryLines = 500
  /// Between a paste and the key that submits it, unless the program's template says. The
  /// core's own `terminal.send` waits the same.
  static let defaultPasteGap: Duration = .milliseconds(200)
  /// Between named keys, as the core's own `terminal.keys` paces them.
  static let keyGap: Duration = .milliseconds(30)

  /// Where the core was found. `herdr-core` or `hc`; the two are one program.
  public let binaryPath: String
  /// The host's `$HOME`, which `file.read` needs because it expands no `~`. `nil` reads no
  /// session files, and a Claude terminal then falls to the reader's directory match.
  public let home: String?
  let link: CoreLink
  private let feed: CoreEventFeed

  public init(
    binaryPath: String = "hc",
    home: String? = nil,
    callDeadline: Duration = CoreControl.defaultCallDeadline,
    heartbeatTick: Duration = CoreControl.defaultHeartbeatTick,
    open: @escaping StreamRunner
  ) {
    self.binaryPath = binaryPath
    self.home = home
    link = CoreLink(
      command: "\(shellQuoted(binaryPath)) connect",
      callDeadline: callDeadline,
      open: open
    )
    feed = CoreEventFeed(
      link: link, sessionFiles: CoreSessionFiles(home: home), heartbeatTick: heartbeatTick)
  }

  /// What the events have said, subscribing first if nothing is subscribed. See `CoreEventFeed`.
  public func snapshot() async throws -> SessionTree {
    try await feed.tree()
  }

  public var changes: AsyncStream<Void>? { feed.changes() }

  public var needsPolling: Bool { false }

  /// Asks by connecting. `hc connect` starts a core if none is running, and nothing else
  /// answers without doing the same, so there is no `.serverNotRunning` here.
  public func availability() async -> HerdrAvailability {
    Self.availability(for: await link.established().handshake)
  }

  public func attachCommand(for pane: Pane) -> String {
    "\(shellQuoted(binaryPath)) attach \(shellQuoted(pane.terminalID ?? pane.id))"
  }

  public func paneAttacher(for paneID: String) -> (any PaneAttacher)? { self }

  public func sendText(paneID: String, text: String) async throws {
    try await typing(into: paneID) { type, _ in try await type(Data(text.utf8)) }
  }

  /// The text, a pause, then the key that submits, as the core's own `terminal.send` writes
  /// them. A TUI that takes a paste as one event needs the pause to see a separate Enter.
  ///
  /// CR for a `submit` this cannot spell: the core encodes it against the program's keyboard
  /// modes, and a viewer does not hold those.
  public func submitText(paneID: String, text: String) async throws {
    try await typing(into: paneID) { type, terminal in
      try await type(Data(text.utf8))
      let gap = terminal?.pasteGapMilliseconds.map { Duration.milliseconds($0) }
      try await Task.sleep(for: gap ?? Self.defaultPasteGap)
      let submit = terminal?.submit.flatMap(PaneKey.init(rawValue:)) ?? .enter
      try await type(submit.viewerBytes)
    }
  }

  public func sendKeys(paneID: String, keys: [PaneKey]) async throws {
    try await typing(into: paneID) { type, _ in
      for (index, key) in keys.enumerated() {
        if index > 0 { try await Task.sleep(for: Self.keyGap) }
        try await type(key.viewerBytes)
      }
    }
  }

  /// Runs `body` with a short-lived viewer that can type and cannot resize.
  ///
  /// A held `observe` cannot type, because the core drops an observer's input. **At 0x0 the
  /// core returns before it resizes**, at the attach and at each write, so typing from a chat
  /// never reflows the desk, and `resumed` keeps the attach itself from counting as activity.
  /// No credit is returned, because nobody reads this stream and it closes in a moment.
  private func typing(
    into paneID: String,
    _ body: (
      _ type: (Data) async throws -> Void,
      _ terminal: CoreAttachResult.Attached?
    ) async throws -> Void
  ) async throws {
    let (connection, handshake) = await link.established()
    guard let connection else { throw Self.failure(for: handshake) }
    let viewer = try await connection.openChannel(
      "terminal.attach",
      params: CoreAttachParams(
        terminal: CorePaneID.address(of: paneID), cols: 0, rows: 0, resumed: true),
      as: CoreAttachResult.self,
      handler: { _ in }
    )
    do {
      try await body(
        { try await connection.write(.data, $0, toChannel: viewer.channel) },
        viewer.answer.terminal
      )
    } catch {
      await connection.closeChannel(viewer.channel)
      throw error
    }
    await connection.closeChannel(viewer.channel)
  }

  /// One `terminal.read` per pane, side by side on the one connection, each bounded by its own
  /// deadline. There is no batch call. `PaneThumbnailModel` is the only caller, and it asks only
  /// for the tiles with no emulator, on its tick, while the sheet is up.
  ///
  /// **No answer to any read throws, and so does a connection gone by the end.** Each is a
  /// failure to ask, and tiles answered empty would replace the pictures the sheet keeps through
  /// one. A stalled link stays open and only ever times out. A core that refuses a read has
  /// answered, so that pane alone is empty.
  public func readPanes(ids: [String], lines: Int) async throws -> [String: [String]] {
    // A combined host's TUI batch comes through here with no core panes in it.
    guard !ids.isEmpty else { return [:] }
    let (connection, handshake) = await link.established()
    guard let connection else { throw Self.failure(for: handshake) }

    typealias Read = (id: String, rows: [String], answered: Bool)
    let reads = await withTaskGroup(of: Read.self) { group in
      for id in ids {
        group.addTask {
          do {
            let screen = try await Self.screen(ofPane: id, lines: lines, on: connection)
            return (id, screen.lines.map(\.text), true)
          } catch {
            return (id, [], !CoreConnection.gotNoAnswer(error, to: "terminal.read"))
          }
        }
      }
      return await group.reduce(into: []) { $0.append($1) }
    }
    guard reads.contains(where: \.answered), await connection.isOpen else {
      throw Self.failure(for: .notCore)
    }
    return Dictionary(reads.map { ($0.id, $0.rows) }, uniquingKeysWith: { first, _ in first })
  }

  public func readScreen(of pane: Pane, lines: Int) async throws -> PaneScreen {
    let (connection, handshake) = await link.established()
    guard let connection else { throw Self.failure(for: handshake) }
    return try await Self.screen(ofPane: pane.id, lines: lines, on: connection)
  }

  /// The screen alone, whatever `lines` asks for: `lines` bounds what is handed on, and asking
  /// the core for history could have it scroll a full-screen app.
  private static func screen(
    ofPane paneID: String,
    lines: Int,
    on connection: CoreConnection
  ) async throws -> PaneScreen {
    let read = try await connection.call(
      "terminal.read",
      params: CoreReadParams(terminal: CorePaneID.address(of: paneID)),
      as: CoreReadResult.self
    )
    return PaneScreen.sanitised(read.text, lines: lines)
  }

  /// An exhaustive switch, so a new action does not compile until it is answered here.
  public func canPerform(_ kind: PaneActionKind, on paneID: String) -> Bool {
    switch kind {
    case .split, .close: true
    case .rename: false
    }
  }

  public func canRename(_ target: RenameTarget) -> Bool { false }

  /// Plain calls, not a viewer, so the desk keeps its size.
  public func perform(_ action: PaneAction, on paneID: String) async throws {
    let (connection, handshake) = await link.established()
    guard let connection else { throw Self.failure(for: handshake) }
    let terminal = CoreTerminalParams(terminal: CorePaneID.address(of: paneID))

    switch action {
    case .close:
      // Hangup, then terminate, then kill. Even a program that ignores all of it normally ends
      // inside a call's deadline, and a call that expires reaches the failure prompt. No
      // `terminal.rm`, because a finished terminal has already left the tree.
      _ = try await connection.call("terminal.kill", params: terminal, as: CoreTerminal.self)
    case .split:
      // The direction means nothing here: a core has no layout, so the new terminal is its own,
      // and the desktop app decides where one with a space goes.
      let source = try await connection.call(
        "terminal.get", params: terminal, as: CoreTerminal.self)
      _ = try await connection.call(
        "terminal.run", params: CoreRunParams(shellBeside: source), as: CoreTerminal.self)
    case .rename:
      throw Self.noRename
    }
  }

  public func rename(_ target: RenameTarget, to label: String) async throws {
    throw Self.noRename
  }

  private static let noRename = AppError.herdrCommandFailed(reason: "herdr-core has no rename.")

  private static func availability(for handshake: CoreHandshake) -> HerdrAvailability {
    switch handshake {
    case .ready(let version, _):
      .coreReady(version: version)
    case .refused(let version, let generation, let missingMethods):
      .coreIncompatible(
        version: version, generation: generation, missingMethods: missingMethods)
    case .notCore:
      .notInstalled
    }
  }

  static func failure(for handshake: CoreHandshake) -> AppError {
    .herdrCommandFailed(
      reason: handshake == .notCore
        ? "herdr-core is not answering."
        : availability(for: handshake).message
    )
  }
}

extension CoreControl: PaneAttacher {
  /// Active from the start, at the phone's size, because the emulator's width is fixed from
  /// here on. So the desk reflows at open and not at the first keystroke, and the history
  /// arrives at the width it will be read at.
  public func open(terminalID: String, size: TerminalSize) async throws -> any PaneBridge {
    try await attach(
      CoreAttachParams(
        terminal: terminalID,
        cols: size.columns,
        rows: size.rows,
        history: Self.attachHistoryLines
      )
    )
  }

  /// No history, because an observer's bytes arrive at the terminal's width, not the phone's.
  public func observe(terminalID: String, size: TerminalSize) async throws -> any PaneObserver {
    try await attach(
      CoreAttachParams(
        terminal: terminalID, cols: size.columns, rows: size.rows, observe: true)
    )
  }

  private func attach(_ params: CoreAttachParams) async throws -> CoreAttachment {
    let (connection, handshake) = await link.established()
    guard let connection else { throw Self.failure(for: handshake) }
    return try await CoreAttachment.open(on: connection, params: params)
  }
}

extension PaneKey {
  /// What a viewer writes for this key.
  ///
  /// The arrows are plain `CSI A`: the core encodes `terminal.keys` against the program's
  /// keyboard modes, and a viewer does not hold those.
  fileprivate var viewerBytes: Data {
    switch self {
    case .enter: Data([0x0D])
    case .esc: Data([0x1B])
    case .tab: Data([0x09])
    case .interrupt: Data([0x03])
    case .up: Data("\u{1B}[A".utf8)
    case .down: Data("\u{1B}[B".utf8)
    case .right: Data("\u{1B}[C".utf8)
    case .left: Data("\u{1B}[D".utf8)
    case .yes, .no, .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8,
      .digit9:
      Data(rawValue.utf8)
    }
  }
}

/// Holds the one connection a `CoreControl` talks through, and replaces it after it dies.
///
/// A struct cannot, and the control is copied into every model that reads it.
///
/// **Reopened on demand, by the next call.** A core can restart under a live SSH link, and
/// nothing else would notice. A refusal is the exception, and sticks: the host's core does
/// not change generation while connected, and asking again would run `hc` on every poll.
actor CoreLink {
  typealias Established = (connection: CoreConnection?, handshake: CoreHandshake)

  private let command: String
  private let callDeadline: Duration
  private let open: StreamRunner

  private var current: Established?
  private var opening: Task<Established, Never>?

  init(command: String, callDeadline: Duration, open: @escaping StreamRunner) {
    self.command = command
    self.callDeadline = callDeadline
    self.open = open
  }

  /// The live connection, opening one if needed.
  ///
  /// Concurrent callers share one opening. A loop, because `isOpen` is another actor's state
  /// and this one's can change across the hop.
  func established() async -> Established {
    while true {
      if let opening { return await opening.value }
      guard let current else { break }
      if case .refused = current.handshake { return current }
      guard let connection = current.connection else { break }
      if await connection.isOpen { return current }
      if self.current?.connection === connection { self.current = nil }
    }

    let task = Task { [command, callDeadline, open] () -> Established in
      let opened = await CoreStreamRace.open(command, within: callDeadline, by: open)
      guard let stream = opened else { return (nil, .notCore) }
      let connection = CoreConnection(stream: stream, callDeadline: callDeadline)
      let handshake = await connection.handshake()
      guard case .ready = handshake else { return (nil, handshake) }
      return (connection, handshake)
    }
    opening = task
    let established = await task.value
    opening = nil
    current = established
    return established
  }

  func close() async {
    await current?.connection?.close()
    current = nil
  }
}

/// Stops waiting for an `hc connect` that does not come.
///
/// Nothing polls a core, so a read waiting here would be the last anyone made. Not a task
/// group, because a group waits for every child, including the one that hung. A stream that
/// turns up after the deadline is closed, because nobody holds it.
private final class CoreStreamRace: @unchecked Sendable {
  private let lock = NSLock()
  private var waiting: CheckedContinuation<(any HerdrStream)?, Never>?
  private var deadline: Task<Void, Never>?

  private init(_ continuation: CheckedContinuation<(any HerdrStream)?, Never>) {
    waiting = continuation
  }

  static func open(
    _ command: String,
    within limit: Duration,
    by open: @escaping StreamRunner
  ) async -> (any HerdrStream)? {
    await withCheckedContinuation { continuation in
      let race = CoreStreamRace(continuation)
      let deadline = Task {
        try? await Task.sleep(for: limit)
        guard !Task.isCancelled else { return }
        race.settle(nil)
      }
      race.lock.withLock { race.deadline = deadline }
      Task {
        let stream = try? await open(command)
        if !race.settle(stream) { await stream?.close() }
      }
    }
  }

  /// Whether this was the answer.
  @discardableResult
  private func settle(_ stream: (any HerdrStream)?) -> Bool {
    let settled = lock.withLock {
      defer { waiting = nil }
      deadline?.cancel()
      return waiting
    }
    settled?.resume(returning: stream)
    return settled != nil
  }
}
