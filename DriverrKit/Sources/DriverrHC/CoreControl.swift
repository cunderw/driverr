import DriverrCore
import DriverrHerdr
import Foundation

/// Drives a herdr-core over one `hc connect` exec channel.
///
/// **Read-only so far.** `snapshot`, `availability` and `attachCommand` are real. Everything
/// that changes a terminal or reads its screen throws, except `readPanes`, whose contract
/// already maps an unreadable pane to an empty one. #18 and later fill these in.
public struct CoreControl: HerdrControl {
  /// How long one call may take, the opening included.
  public static let defaultCallDeadline: Duration = .seconds(5)

  /// Where the core was found. `herdr-core` or `hc`; the two are one program.
  public let binaryPath: String
  let link: CoreLink

  public init(
    binaryPath: String = "hc",
    callDeadline: Duration = CoreControl.defaultCallDeadline,
    open: @escaping StreamRunner
  ) {
    self.binaryPath = binaryPath
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
    return CoreSnapshotMapper.tree(from: list, document: await link.settled(document))
  }

  /// Asks by connecting. `hc connect` starts a core if none is running, and nothing else
  /// answers without doing the same, so there is no `.serverNotRunning` here.
  public func availability() async -> HerdrAvailability {
    Self.availability(for: await link.established().handshake)
  }

  public func attachCommand(for pane: Pane) -> String {
    "\(shellQuoted(binaryPath)) attach \(shellQuoted(pane.terminalID ?? pane.id))"
  }

  public func sendText(paneID: String, text: String) async throws {
    throw Self.notYet
  }

  public func submitText(paneID: String, text: String) async throws {
    throw Self.notYet
  }

  public func sendKeys(paneID: String, keys: [PaneKey]) async throws {
    throw Self.notYet
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
