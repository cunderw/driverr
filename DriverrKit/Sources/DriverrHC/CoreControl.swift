import DriverrCore
import DriverrHerdr
import Foundation

/// Drives a herdr-core over one `hc connect` exec channel.
///
/// **Typing goes through a viewer**, never `terminal.send` or `terminal.keys`, which wait for
/// about 3 s of quiet and refuse a blocked agent. See `typing(into:_:)`.
///
/// Reading a screen and acting on a pane are not here yet and throw, except `readPanes`, whose
/// contract already maps an unreadable pane to an empty one.
public struct CoreControl: HerdrControl {
  /// How long one call may take, the opening included.
  public static let defaultCallDeadline: Duration = .seconds(5)

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
  private let sessionFiles: CoreSessionFiles

  public init(
    binaryPath: String = "hc",
    home: String? = nil,
    callDeadline: Duration = CoreControl.defaultCallDeadline,
    open: @escaping StreamRunner
  ) {
    self.binaryPath = binaryPath
    self.home = home
    sessionFiles = CoreSessionFiles(home: home)
    link = CoreLink(
      command: "\(shellQuoted(binaryPath)) connect",
      callDeadline: callDeadline,
      open: open
    )
  }

  public func snapshot() async throws -> SessionTree {
    let (connection, handshake) = await link.established()
    guard let connection else { throw Self.failure(for: handshake) }
    // Beside the list, on every poll, until #19's `doc` event says when it changed. Only this
    // core's: a machine it added has its own document, and `on` would be a call per machine.
    async let document = try? connection.call(
      "doc.get",
      params: CoreDocGetParams(name: CoreAppDocument.name),
      as: CoreDocGetResult<CoreAppDocument>.self
    )
    let list = try await connection.call(
      "terminal.list", params: CoreNoParams(), as: CoreListResult.self)
    let sessions = await sessionFiles.identifiers(for: list.terminals, over: connection)
    return CoreSnapshotMapper.tree(
      from: list, document: await link.settled(document), sessions: sessions)
  }

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

  public func readPanes(ids: [String], lines: Int) async throws -> [String: [String]] {
    Dictionary(uniqueKeysWithValues: ids.map { ($0, []) })
  }

  public func readScreen(of pane: Pane, lines: Int) async throws -> PaneScreen {
    throw Self.notYet
  }

  public func perform(_ action: PaneAction, on paneID: String) async throws {
    throw Self.notYet
  }

  public func rename(_ target: RenameTarget, to label: String) async throws {
    throw Self.notYet
  }

  private static let notYet = AppError.herdrCommandFailed(
    reason: "Driverr can't do this on a herdr-core terminal yet.")

  private static func availability(for handshake: CoreHandshake) -> HerdrAvailability {
    switch handshake {
    case .ready(let version):
      .coreReady(version: version)
    case .refused(let version, let generation, let missingMethods):
      .coreIncompatible(
        version: version, generation: generation, missingMethods: missingMethods)
    case .notCore:
      .notInstalled
    }
  }

  private static func failure(for handshake: CoreHandshake) -> AppError {
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
  private var document: CoreAppDocument?

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
      guard let stream = try? await open(command) else { return (nil, .notCore) }
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

  /// The document to order this poll by, given what the read came back with.
  ///
  /// `nil` is a failed read, which keeps the last good one, so one bad poll cannot reorder
  /// the rows under a thumb. A read that found no document clears it.
  func settled(_ read: CoreDocGetResult<CoreAppDocument>?) -> CoreAppDocument? {
    if let read { document = read.value }
    return document
  }

  func close() async {
    await current?.connection?.close()
    current = nil
  }
}
