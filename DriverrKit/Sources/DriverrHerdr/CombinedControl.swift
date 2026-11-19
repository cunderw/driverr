import DriverrCore
import Foundation

/// Marks a pane, tab or workspace as herdr-core's.
///
/// Here, not in `DriverrHC`, because `CombinedControl` routes on it and this module does not
/// import that one.
public enum CorePaneID {
  public static let prefix = "core:"

  public static func id(forAddress address: String) -> String {
    prefix + address
  }

  /// The address `id(forAddress:)` was given, which is what the core calls the terminal.
  public static func address(of id: String) -> String {
    String(id.dropFirst(isCore(id) ? prefix.count : 0))
  }

  public static func isCore(_ id: String) -> Bool {
    id.hasPrefix(prefix)
  }

  /// The `box` in `core:box/t7`: the machine the core added that this terminal is on, or `nil`
  /// for one on the core's own computer and for any id that is not the core's.
  public static func machine(of id: String) -> String? {
    guard isCore(id) else { return nil }
    let address = address(of: id)
    guard let slash = address.firstIndex(of: "/"), slash > address.startIndex else { return nil }
    return String(address[..<slash])
  }
}

/// A host running more than one source of panes, as one `HerdrControl`: herdr's TUI, a
/// herdr-core, and tmux, in any combination of two or three.
///
/// **One control and not several sessions.** About twenty sites read `model.herdr` and
/// `model.session`, and two sessions applying snapshots would wipe each other's caches.
/// Their terminals are different, so a host with several shows them all: this merges the trees
/// and routes each call by its id's prefix.
///
/// One side is the **primary**, whose ids carry no prefix: the TUI, or the first prefixed side
/// when no TUI answered. Every other side is a `Side`, found by `CorePaneID.prefix` or
/// `TmuxID.prefix`. A call for an id no side claims goes to the primary.
///
/// Holds `any HerdrControl`s, because this module cannot see `CoreControl` or `TmuxControl`.
public struct CombinedControl: HerdrControl {
  /// A control whose pane, tab and workspace ids all start with `prefix`.
  public struct Side: Sendable {
    public let prefix: String
    public let control: any HerdrControl

    public init(prefix: String, control: any HerdrControl) {
      self.prefix = prefix
      self.control = control
    }
  }

  /// What the last poll made of the primary, which a change on a side has no reason to ask
  /// again.
  private enum TUISide: Sendable {
    case tree(SessionTree)
    /// No session is running, so the sides' trees stand alone. The error is for when they can't.
    case noSession(any Error)
    case failed(any Error)
  }

  /// A struct cannot remember, and this control is copied into every model that reads it.
  ///
  /// So every copy shares one backoff, and a host is on one schedule however many models poll
  /// it. The schedule counts snapshots, not time, so two pollers on one host reach each check
  /// sooner than one would.
  private actor Memory {
    var tui: TUISide?
    /// What each side's last whole read gave, in `sides` order. `changedSnapshot()` answers a
    /// polled side from here, so a change on the core runs no tmux command.
    var sideReads: [Result<SessionTree, any Error>]?
    /// Polls left that answer from a remembered `.noSession` without asking the TUI.
    private var ticksToSkip = 0
    /// What the last check that found no session set `ticksToSkip` to. Zero once the TUI
    /// answers or fails some other way, so the next no session starts the schedule again.
    private var gap = 0

    /// The remembered `.noSession` when this poll is one to skip, counted off.
    func skipTUI() -> TUISide? {
      guard case .noSession = tui, ticksToSkip > 0 else { return nil }
      ticksToSkip -= 1
      return tui
    }

    /// What a poll that asked the TUI found, and how many polls to leave it for.
    func checked(_ tui: TUISide) {
      self.tui = tui
      if case .noSession = tui {
        gap = min(max(gap * 2, 1), CombinedControl.longestTUIBackoff)
      } else {
        gap = 0
      }
      ticksToSkip = gap
    }

    /// Whether a primary that is not a TUI has ever answered with a tree.
    private(set) var primaryHasRead = false

    /// What a poll found of a primary that is not a TUI. No backoff: it is asked every time.
    func found(_ primary: TUISide) {
      tui = primary
      if case .tree = primary { primaryHasRead = true }
      ticksToSkip = 0
      gap = 0
    }

    func read(_ sides: [Result<SessionTree, any Error>]) {
      sideReads = sides
    }

    func resetBackoff() {
      ticksToSkip = 0
      gap = 0
    }
  }

  /// The most polls in a row that skip a TUI with no session running, counted in ticks. The
  /// wall time that comes to depends on the caller's poll interval.
  ///
  /// A judgement, not a measurement. A session started at the desk shows within it, and a
  /// host that never starts one is asked once in eleven polls instead of every one. The gap
  /// doubles from one poll after each check that finds no session, so the checks fall on
  /// polls 1, 3, 6, 11, 20 and then every eleventh.
  static let longestTUIBackoff = 10

  /// The primary. Named for the TUI, which it is whenever one answered.
  private let tui: any HerdrControl
  /// Whether the primary is herdr's TUI, which never starts a terminal. See `starter`.
  private let primaryIsTUI: Bool
  private let sides: [Side]
  private let memory = Memory()
  /// The herdr session the TUI is bound to, which a `MirrorClaim` must name to hide its pane.
  /// `nil` is the standard session, as it is for the TUI. See `bound(toSocketPath:)`.
  private let socketPath: String?

  /// The TUI and a core, the shape this control first had.
  public init(tui: any HerdrControl, core: any HerdrControl) {
    self.init(tui: tui, sides: [Side(prefix: CorePaneID.prefix, control: core)])
  }

  /// The TUI takes every id no side claims. Sides are asked in order, for routing and for
  /// `availability()`, so a core goes before tmux.
  public init(tui: any HerdrControl, sides: [Side]) {
    self.init(primary: tui, primaryIsTUI: true, sides: sides)
  }

  /// A host with no TUI: `primary` is a side whose ids carry its own prefix.
  public init(primary: any HerdrControl, sides: [Side]) {
    self.init(primary: primary, primaryIsTUI: false, sides: sides)
  }

  private init(
    primary: any HerdrControl, primaryIsTUI: Bool, sides: [Side], socketPath: String? = nil
  ) {
    self.tui = primary
    self.primaryIsTUI = primaryIsTUI
    self.sides = sides
    self.socketPath = socketPath
  }

  /// What serves a host, from what each discovery found. `nil` when nothing was found, and the
  /// caller reports that through a bare `CLIControl`.
  public static func joining(
    tui: (any HerdrControl)?,
    core: (any HerdrControl)?
  ) -> (any HerdrControl)? {
    joining(tui: tui, sides: core.map { [Side(prefix: CorePaneID.prefix, control: $0)] } ?? [])
  }

  /// The same, with the prefixed sides found, in order. One control alone is returned as it
  /// is. With no TUI, the first side is the primary.
  public static func joining(tui: (any HerdrControl)?, sides: [Side]) -> (any HerdrControl)? {
    if let tui {
      return sides.isEmpty ? tui : CombinedControl(tui: tui, sides: sides)
    }
    guard let first = sides.first else { return nil }
    let rest = Array(sides.dropFirst())
    return rest.isEmpty ? first.control : CombinedControl(primary: first.control, sides: rest)
  }

  /// The TUI's, because `ConnectionModel.bridgeClient` runs this binary, and a core pane
  /// opens through `paneAttacher(for:)` instead.
  public var binaryPath: String { tui.binaryPath }

  /// Binds the TUI side. `Host.herdrSocketPath` names a herdr session, which a core or a tmux
  /// server is not. The path is kept, because it says which session a mirror must show.
  public func bound(toSocketPath path: String?) -> any HerdrControl {
    CombinedControl(
      primary: tui.bound(toSocketPath: path), primaryIsTUI: primaryIsTUI, sides: sides,
      socketPath: path)
  }

  /// The first stream a side has, never the TUI's. Only a core has one today. The TUI is
  /// polled, and `changedSnapshot()` reads a side's news on the TUI's last tree.
  ///
  /// **Each control's `changes` is asked at most once.** A request can open a new stream and
  /// replace the one a listener holds, so a lazy `compactMap(...).first`, which evaluates the
  /// winner twice, would hand out a stream nobody signals.
  public var changes: AsyncStream<Void>? {
    for control in nonTUI {
      if let changes = control.changes { return changes }
    }
    return nil
  }

  public var needsPolling: Bool { tui.needsPolling || sides.contains { $0.control.needsPolling } }

  /// The news of each side that is pushed, not polled, on the last whole read of every other
  /// side, with no command on the host for those. The TUI's own poll goes on regardless, so those
  /// trees are at most a tick old. A remembered no session can be as old as
  /// `longestTUIBackoff`.
  ///
  /// **A pushed side that failed goes back to a whole poll.** It usually means the link
  /// went, and the other trees came over that link. Answered with them, the side's panes look
  /// gone, and `ConnectionModel.apply` forgets each one's chat, screen and draft.
  public func changedSnapshot() async throws -> SessionTree {
    guard var tuiSide = await memory.tui, let remembered = await memory.sideReads,
      remembered.count == sides.count
    else { return try await snapshot() }
    // A core standing in for an absent TUI is where the news is, so it is read, not remembered.
    // **Never asks for `changes` to decide.** Each request for a stream can replace the one the
    // listener holds, so that question here would leave the session deaf.
    if !primaryIsTUI, !tui.needsPolling {
      guard case .success(let tree) = await Result({ try await tui.changedSnapshot() }) else {
        return try await snapshot()
      }
      tuiSide = .tree(tree)
    }
    var reads: [Result<SessionTree, any Error>] = []
    for (side, last) in zip(sides, remembered) {
      guard !side.control.needsPolling else {
        reads.append(last)
        continue
      }
      let read = await Result { try await side.control.changedSnapshot() }
      guard case .success = read else { return try await snapshot() }
      reads.append(read)
    }
    return try merged(tuiSide, reads)
  }

  /// The TUI's panes, then each side's, in order.
  ///
  /// A side failing leaves its panes out, and every side failing returns the TUI's tree. Both
  /// failing throws the TUI's error, which is the one with a next step. A tree with no core in
  /// it has no `coreID`, so a host whose core is down covers no machine.
  ///
  /// **The TUI failing returns the sides' trees only when no session is running**, so a
  /// stopped session does not hide a running core or tmux. Any other failure is rethrown. A
  /// failed poll passed over as a tree clears `SessionModel.lastFailure`, and
  /// `ConnectionModel.apply` then forgets every TUI pane's transcript, screen, draft and
  /// surface. A core standing in for an absent TUI is left out only while it has never read,
  /// as an incompatible core is. After that its failure is rethrown, for the same reason.
  ///
  /// **A TUI with no session is asked less and less often**, because each check is a failing
  /// snapshot and a status command on the user's machine. A poll in the gap reads only the
  /// sides and answers with them, as `changedSnapshot()` does, and sides that all fail there
  /// get the whole read. `longestTUIBackoff` has the schedule, and `resetBackoff()` ends it.
  public func snapshot() async throws -> SessionTree {
    if let tuiSide = await memory.skipTUI() {
      let reads = await readSides()
      await memory.read(reads)
      if reads.contains(where: \.isSuccess) { return try merged(tuiSide, reads) }
    }

    async let tuiTree = Result { try await tui.snapshot() }
    async let sideTrees = readSides()
    let (tuiRead, reads) = await (tuiTree, sideTrees)

    let tuiSide: TUISide
    switch tuiRead {
    case .success(let tree):
      tuiSide = .tree(tree)
    case .failure(let failure) where !primaryIsTUI:
      // A core standing in for an absent TUI that has never read is left out, as an
      // incompatible core beside a ready tmux is. **One that has read is rethrown.** A dropped
      // core link with SSH still up would otherwise answer with tmux's panes alone, and
      // `ConnectionModel.apply` would forget every core pane's chat, screen and draft.
      tuiSide = await memory.primaryHasRead ? .failed(failure) : .noSession(failure)
    case .failure(let failure) where reads.contains(where: \.isSuccess):
      tuiSide = await tuiHasNoSession() ? .noSession(failure) : .failed(failure)
    case .failure(let failure):
      tuiSide = .failed(failure)
    }
    if primaryIsTUI {
      await memory.checked(tuiSide)
    } else {
      await memory.found(tuiSide)
    }
    await memory.read(reads)
    return try merged(tuiSide, reads)
  }

  /// Every side's whole read, at once, in `sides` order.
  private func readSides() async -> [Result<SessionTree, any Error>] {
    await withTaskGroup(of: (Int, Result<SessionTree, any Error>).self) { group in
      for (index, side) in sides.enumerated() {
        group.addTask { (index, await Result { try await side.control.snapshot() }) }
      }
      var reads = [Result<SessionTree, any Error>?](repeating: nil, count: sides.count)
      for await (index, read) in group { reads[index] = read }
      return reads.compactMap { $0 }
    }
  }

  /// This control's backoff, and every control's own, such as a tmux with no server.
  public func resetBackoff() async {
    await memory.resetBackoff()
    await tui.resetBackoff()
    for side in sides { await side.control.resetBackoff() }
  }

  /// The TUI's focus and the first core id. With no TUI tree, the first side's focus.
  private func merged(
    _ tuiSide: TUISide,
    _ reads: [Result<SessionTree, any Error>]
  ) throws -> SessionTree {
    let trees = reads.compactMap { try? $0.get() }
    switch tuiSide {
    case .tree(let tui):
      return SessionTree(
        workspaces: tui.workspaces + trees.flatMap(\.workspaces),
        focusedPaneID: tui.focusedPaneID,
        coreID: tui.coreID ?? trees.lazy.compactMap(\.coreID).first
      )
    case .noSession(let failure):
      guard !trees.isEmpty else { throw failure }
      return SessionTree(
        workspaces: trees.flatMap(\.workspaces),
        focusedPaneID: trees.lazy.compactMap(\.focusedPaneID).first,
        coreID: trees.lazy.compactMap(\.coreID).first
      )
    case .failed(let failure):
      throw failure
    }
  }

  /// Not `.notInstalled`, which `CLIControl.availability` also answers when its status
  /// command fails to run. This control exists only where herdr was found at connect, so that
  /// is the likelier cause, and a failure on screen costs less than the drafts it would lose.
  private func tuiHasNoSession() async -> Bool {
    if case .serverNotRunning = await tui.availability() { return true }
    return false
  }

  /// The TUI's answer, joined with each side's in order by `joined(_:_:)`.
  public func availability() async -> HerdrAvailability {
    async let tuiCheck = tui.availability()
    let sideAnswers = await withTaskGroup(of: (Int, HerdrAvailability).self) { group in
      for (index, side) in sides.enumerated() {
        group.addTask { (index, await side.control.availability()) }
      }
      var answers = [HerdrAvailability?](repeating: nil, count: sides.count)
      for await (index, answer) in group { answers[index] = answer }
      return answers.compactMap { $0 }
    }
    return sideAnswers.reduce(await tuiCheck, Self.joined)
  }

  /// Two answers as one, the first being what the host had so far.
  ///
  /// | so far | side | answer |
  /// |---|---|---|
  /// | TUI ready | core ready | `.combined` |
  /// | TUI ready | core refused | `.readyWithCoreRefused`, because a core is there and is not shown |
  /// | anything else | core ready | `.coreReady`, because there are terminals to show |
  /// | anything | tmux ready | `.withTmux`, which keeps a herdr that is not ready to say so |
  /// | anything | anything else | so far |
  static func joined(_ soFar: HerdrAvailability, _ side: HerdrAvailability) -> HerdrAvailability {
    switch (soFar, side) {
    case (.ready(let herdrVersion, _), .coreReady(let coreVersion)):
      return .combined(herdrVersion: herdrVersion, coreVersion: coreVersion)
    case let (
      .ready(herdrVersion, protocolVersion), .coreIncompatible(version, generation, missingMethods)
    ):
      return .readyWithCoreRefused(
        version: herdrVersion,
        protocolVersion: protocolVersion,
        coreVersion: version,
        coreGeneration: generation,
        coreMissingMethods: missingMethods
      )
    case (_, .coreReady):
      return side
    case (_, .tmuxReady(let version)):
      return .withTmux(soFar, tmuxVersion: version)
    default:
      return soFar
    }
  }

  public func attachCommand(for pane: Pane) -> String? {
    side(for: pane.id).attachCommand(for: pane)
  }

  public func paneAttacher(for paneID: String) -> (any PaneAttacher)? {
    side(for: paneID).paneAttacher(for: paneID)
  }

  public func commandRunner(forPane id: String) -> CommandRunner? {
    side(for: id).commandRunner(forPane: id)
  }

  public func imageUploader(forPane id: String, bytes: Data, fileName: String)
    -> (any ImageUploading)?
  {
    side(for: id).imageUploader(forPane: id, bytes: bytes, fileName: fileName)
  }

  public func sendText(paneID: String, text: String) async throws {
    try await side(for: paneID).sendText(paneID: paneID, text: text)
  }

  public func submitText(paneID: String, text: String) async throws {
    try await side(for: paneID).submitText(paneID: paneID, text: text)
  }

  public func sendKeys(paneID: String, keys: [PaneKey]) async throws {
    try await side(for: paneID).sendKeys(paneID: paneID, keys: keys)
  }

  /// One read per side, and one failure to ask throws, as `readPanes` documents.
  public func readPanes(ids: [String], lines: Int) async throws -> [String: [String]] {
    var groups = [[String]](repeating: [], count: sides.count)
    var tuiIDs: [String] = []
    for id in ids {
      if let index = sideIndex(for: id) { groups[index].append(id) } else { tuiIDs.append(id) }
    }
    let controls = [tui] + sides.map(\.control)
    let batches = [tuiIDs] + groups
    return try await withThrowingTaskGroup(of: [String: [String]].self) { group in
      for (control, batch) in zip(controls, batches) {
        group.addTask { try await control.readPanes(ids: batch, lines: lines) }
      }
      var panes: [String: [String]] = [:]
      for try await read in group { panes.merge(read) { first, _ in first } }
      return panes
    }
  }

  public func readScreen(of pane: Pane, lines: Int) async throws -> PaneScreen {
    try await side(for: pane.id).readScreen(of: pane, lines: lines)
  }

  public func canPerform(_ kind: PaneActionKind, on paneID: String) -> Bool {
    side(for: paneID).canPerform(kind, on: paneID)
  }

  public func perform(_ action: PaneAction, on paneID: String) async throws {
    try await side(for: paneID).perform(action, on: paneID)
  }

  public func canRename(_ target: RenameTarget) -> Bool {
    side(for: target.id).canRename(target)
  }

  public func rename(_ target: RenameTarget, to label: String) async throws {
    try await side(for: target.id).rename(target, to: label)
  }

  /// The first control that can, never the TUI: a herdr pane is opened inside a tab, and only
  /// a core can start one with nothing open.
  public var canStartTerminal: Bool { starter != nil }

  public func startTerminal() async throws -> String {
    guard let starter else { return try await tui.startTerminal() }
    return try await starter.startTerminal()
  }

  private var starter: (any HerdrControl)? {
    nonTUI.first { $0.canStartTerminal }
  }

  /// Whether any side can start an agent, the TUI included. See `startAgent(_:)`.
  public var canStartAgent: Bool { launchers.contains { $0.canStartAgent } }

  /// Started by the first control that can: the TUI, which puts a workspace on the desk, then a
  /// core, then tmux. Not `starter`, which never picks the TUI.
  ///
  /// **A TUI whose last poll found no session goes last**, because its `workspace create` would
  /// fail with a core or tmux beside it that is up. With no other side that can, it is still
  /// asked, so herdr's own error is the answer. **One side only**: a failure is the
  /// answer and no other side is tried, because a failure after a pane opened would open a
  /// second.
  public func startAgent(_ launch: AgentLaunch) async throws -> String {
    var candidates = launchers
    if primaryIsTUI, case .noSession = await memory.tui {
      candidates.append(candidates.removeFirst())
    }
    guard let launcher = candidates.first(where: { $0.canStartAgent }) else {
      throw AppError.herdrCommandFailed(reason: "This host cannot start an agent.")
    }
    return try await launcher.startAgent(launch)
  }

  /// Every control, in the order an agent start tries them: the primary, then the sides.
  private var launchers: [any HerdrControl] { [tui] + sides.map(\.control) }

  /// Every control but the TUI, the primary first when it is not the TUI.
  private var nonTUI: [any HerdrControl] {
    (primaryIsTUI ? [] : [tui]) + sides.map(\.control)
  }

  private func sideIndex(for id: String) -> Int? {
    sides.firstIndex { id.hasPrefix($0.prefix) }
  }

  private func side(for id: String) -> any HerdrControl {
    sideIndex(for: id).map { sides[$0].control } ?? tui
  }
}

extension Result where Failure == any Error {
  /// `Result(catching:)`, for an async body.
  fileprivate init(_ body: @Sendable () async throws -> Success) async {
    do {
      self = .success(try await body())
    } catch {
      self = .failure(error)
    }
  }

  fileprivate var isSuccess: Bool {
    if case .success = self { return true }
    return false
  }
}
