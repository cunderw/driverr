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

  public static func isCore(_ id: String) -> Bool {
    id.hasPrefix(prefix)
  }
}

/// A host running both the TUI and a core, as one `HerdrControl`.
///
/// **One control and not two sessions.** About twenty sites read `model.herdr` and
/// `model.session`, and two sessions applying snapshots would wipe each other's caches.
/// Their terminals are different, so a host with both shows both: this merges the two trees
/// and routes each call by the `CorePaneID` prefix.
///
/// Holds two `any HerdrControl`, because this module cannot see `CoreControl`.
public struct CombinedControl: HerdrControl {
  private let tui: any HerdrControl
  private let core: any HerdrControl

  public init(tui: any HerdrControl, core: any HerdrControl) {
    self.tui = tui
    self.core = core
  }

  /// What serves a host, from what each discovery found. `nil` when neither found anything,
  /// and the caller reports that through a bare `CLIControl`.
  public static func joining(
    tui: (any HerdrControl)?,
    core: (any HerdrControl)?
  ) -> (any HerdrControl)? {
    guard let tui else { return core }
    guard let core else { return tui }
    return CombinedControl(tui: tui, core: core)
  }

  /// The TUI's, because `ConnectionModel.bridgeClient` runs this binary, and no core pane
  /// gets that far. See `TerminalSceneModel.refusingCorePane`.
  public var binaryPath: String { tui.binaryPath }

  /// Binds the TUI side. `Host.herdrSocketPath` names a herdr session, which a core is not.
  public func bound(toSocketPath path: String?) -> any HerdrControl {
    CombinedControl(tui: tui.bound(toSocketPath: path), core: core)
  }

  /// The TUI's panes, then the core's.
  ///
  /// The core failing returns the TUI's tree, and both failing throws the TUI's error, which
  /// is the one with a next step.
  ///
  /// **The TUI failing returns the core's tree only when no session is running**, so a
  /// stopped session does not hide a running core. Any other failure is rethrown. A failed
  /// poll passed over as a tree clears `SessionModel.lastFailure`, and `ConnectionModel.apply`
  /// then forgets every TUI pane's transcript, screen, draft and surface.
  public func snapshot() async throws -> SessionTree {
    async let tuiTree = Result { try await tui.snapshot() }
    async let coreTree = Result { try await core.snapshot() }

    switch await (tuiTree, coreTree) {
    case (.success(let tui), .success(let core)):
      return SessionTree(
        workspaces: tui.workspaces + core.workspaces,
        focusedPaneID: tui.focusedPaneID
      )
    case (.success(let tree), .failure):
      return tree
    case (.failure(let failure), .success(let tree)):
      guard await tuiHasNoSession() else { throw failure }
      return tree
    case (.failure(let failure), .failure):
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

  /// | TUI | core | answer |
  /// |---|---|---|
  /// | ready | ready | `.combined` |
  /// | ready | anything else | the TUI's |
  /// | anything else | ready | `.coreReady`, because there are terminals to show |
  /// | anything else | anything else | the TUI's |
  ///
  /// So a core this build refuses is deliberately not surfaced beside a working TUI. That
  /// stays so until #21.
  public func availability() async -> HerdrAvailability {
    async let tuiCheck = tui.availability()
    async let coreCheck = core.availability()
    let (tuiAnswer, coreAnswer) = await (tuiCheck, coreCheck)

    guard case .coreReady(let coreVersion) = coreAnswer else { return tuiAnswer }
    if case .ready(let herdrVersion, _) = tuiAnswer {
      return .combined(herdrVersion: herdrVersion, coreVersion: coreVersion)
    }
    return coreAnswer
  }

  public func attachCommand(for pane: Pane) -> String {
    side(for: pane.id).attachCommand(for: pane)
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
    let coreIDs = ids.filter(CorePaneID.isCore)
    let tuiIDs = ids.filter { !CorePaneID.isCore($0) }

    async let tuiPanes = tui.readPanes(ids: tuiIDs, lines: lines)
    async let corePanes = core.readPanes(ids: coreIDs, lines: lines)
    return try await tuiPanes.merging(corePanes) { first, _ in first }
  }

  public func readScreen(of pane: Pane, lines: Int) async throws -> PaneScreen {
    try await side(for: pane.id).readScreen(of: pane, lines: lines)
  }

  public func perform(_ action: PaneAction, on paneID: String) async throws {
    try await side(for: paneID).perform(action, on: paneID)
  }

  public func rename(_ target: RenameTarget, to label: String) async throws {
    let id =
      switch target {
      case .workspace(let id), .tab(let id): id
      }
    try await side(for: id).rename(target, to: label)
  }

  private func side(for id: String) -> any HerdrControl {
    CorePaneID.isCore(id) ? core : tui
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
}
