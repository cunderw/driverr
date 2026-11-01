import DriverrCore
import DriverrHerdr
import Foundation
import Observation

/// One host's herdr session, as the sidebar needs it.
///
/// Thin by design: `DriverrHerdr` builds the tree and `DriverrCore` orders it. This owns
/// when to ask and what to show meanwhile.
@MainActor
@Observable
final class SessionModel {
  enum State: Equatable {
    /// Not asked yet. "Asked and got nothing" is an empty session.
    case idle
    case loading
    case loaded(SessionTree)
    case failed(AppError)
  }

  private(set) var state: State = .idle

  /// The last tree loaded, kept on screen across a refresh so the sidebar does not blank.
  private(set) var tree: SessionTree = .empty

  /// The expanded workspaces. Held here because the host screen's `@State` dies on every
  /// pop. Seeded once from the first snapshot's focus, so later focus changes do not reopen
  /// a workspace the reader closed.
  private(set) var expandedWorkspaceIDs: Set<String>?

  /// When each pane last became blocked in this connection. The age fallback for a
  /// Needs-you row whose agent has no readable transcript.
  private var blockedSinceByPaneID: [String: Date] = [:]

  /// The most recent failed read, retained until a later read succeeds.
  private(set) var lastFailure: AppError?

  /// What changed between two reads of the session, polled or pushed. Those reads are the only
  /// thing that sees panes move, so the chat's freshness hangs off them rather than off a second
  /// poller.
  struct Changes: Equatable {
    /// Panes whose agent status, reported session, agent kind or working directory moved.
    /// See `hasMoved(from:to:)`.
    var moved: [Pane] = []
    /// Every pane id still in the tree, so holders of per-pane state can drop the rest.
    var liveIDs: Set<String> = []
    /// Every pane in the new tree, so a model made from a view's older value is corrected on
    /// the next read, not on the pane's next move.
    var livePanes: [Pane] = []

    var isEmpty: Bool { moved.isEmpty }
  }

  /// Told what moved after every successful read. `ConnectionModel` sets it and feeds its
  /// per-pane caches, so the session knows nothing about them. Called from a task, not a view
  /// body, so the handler may mutate observable state.
  @ObservationIgnored var onSessionChanged: ((Changes) -> Void)?

  @ObservationIgnored private let control: any HerdrControl
  @ObservationIgnored private var liveUpdates: Task<Void, Never>?
  /// How many consumers hold live updates open. See `startLiveUpdates`.
  @ObservationIgnored private var consumers = 0
  @ObservationIgnored private let pollInterval: Duration
  private(set) var pollingPaused = false

  /// Reads under way, so a change that lands during one waits for it. See `changedOnHost()`.
  @ObservationIgnored private var readsInFlight = 0
  @ObservationIgnored private var changedDuringRead = false

  /// How often to re-read the session while the screen is on, for a control that has to be
  /// asked.
  ///
  /// The TUI is polled: Driverr reaches it only through its CLI over SSH, so its
  /// `events.subscribe` is out of reach, and `herdr agent wait` watches one named agent, not
  /// panes opening or closing. A core pushes, through `HerdrControl.changes`, and this timer
  /// runs there only to get back from a failed read, because nothing else would ask again.
  /// Three seconds is a judgement, not a measurement.
  static let defaultPollInterval = Duration.seconds(3)

  init(control: any HerdrControl, pollInterval: Duration = SessionModel.defaultPollInterval) {
    self.control = control
    self.pollInterval = pollInterval
  }

  var isLoading: Bool { state == .loading }

  var failure: AppError? { lastFailure }

  /// True once a snapshot came back empty: herdr is running with no session yet.
  var isEmptySession: Bool {
    if case .loaded(let tree) = state { return tree.isEmpty }
    return false
  }

  func refresh() async {
    state = .loading
    await read { [control] in try await control.snapshot() }
  }

  /// The host said something changed, so read it, with no `.loading` for a screen that is only
  /// being kept current.
  ///
  /// **One at a time.** A poll on a combined host can be out for a second, and a read that
  /// started before this change must not land after it. So this waits its turn, and goes once
  /// however many changes came meanwhile.
  private func changedOnHost() async {
    guard readsInFlight == 0 else {
      changedDuringRead = true
      return
    }
    await read { [control] in try await control.changedSnapshot() }
  }

  private func read(_ tree: @Sendable () async throws -> SessionTree) async {
    readsInFlight += 1
    await load(tree)
    readsInFlight -= 1
    guard readsInFlight == 0, changedDuringRead else { return }
    changedDuringRead = false
    await changedOnHost()
  }

  private func load(_ read: @Sendable () async throws -> SessionTree) async {
    do {
      let tree = try await read()
      // Diffed against the tree being replaced, before it is replaced.
      let changes = Self.changes(from: self.tree, to: tree)
      recordBlockedSince(from: self.tree, to: tree)
      if expandedWorkspaceIDs == nil {
        expandedWorkspaceIDs = tree.defaultExpandedWorkspaceIDs
      }
      self.tree = tree
      state = .loaded(tree)
      lastFailure = nil
      onSessionChanged?(changes)
    } catch let error as AppError {
      state = .failed(error)
      lastFailure = error
    } catch {
      let error = AppError.herdrCommandFailed(reason: "herdr could not be reached.")
      state = .failed(error)
      lastFailure = error
    }
  }

  // MARK: - Renaming a workspace or a tab

  /// The open rename prompt, if any. One value, so only one row can be renamed at a time,
  /// like `PaneActionsModel.Prompt`.
  ///
  /// **On the model, not in the view.** The poll replaces the tree and rebuilds
  /// `SessionTreeView`, so a draft in `@State` would not survive a tick.
  enum RenamePrompt: Equatable {
    /// The field is open on this target, which was called `currentLabel` when it opened.
    /// Carried, not looked up, because a poll can rename the row from the desk mid-edit and
    /// the commit must compare against what the reader was editing.
    case editing(RenameTarget, currentLabel: String)
    /// herdr refused it. Drawn inline under the row, as `PanePromptBar` does, not as an
    /// alert from a `List` row.
    case failed(RenameTarget, AppError)

    var target: RenameTarget {
      switch self {
      case .editing(let target, _), .failed(let target, _): target
      }
    }
  }

  private(set) var renamePrompt: RenamePrompt?

  /// The label being typed while the rename row is open.
  var renameDraft: String = ""

  /// The rename herdr has not answered yet, so a second commit cannot start another. This
  /// is the guard. The editor is already closed when it is set, so the Rename button's
  /// `.disabled` is only a backstop.
  private(set) var renameInFlight: RenameTarget?

  /// Opens the rename row on this target, with the name it has now already in it.
  func startRenaming(_ target: RenameTarget, currentLabel: String) {
    renameDraft = currentLabel
    renamePrompt = .editing(target, currentLabel: currentLabel)
  }

  func cancelRenaming() {
    renamePrompt = nil
  }

  /// Which prompt, if any, belongs under this row. Not named `renamePrompt(for:)`, which
  /// would read as a typo beside the property.
  func pendingRename(for target: RenameTarget) -> RenamePrompt? {
    renamePrompt?.target == target ? renamePrompt : nil
  }

  var isRenameInFlight: Bool { renameInFlight != nil }

  /// Commits the rename. A blank or unchanged label cancels; `RenameLabel` owns the rule.
  func commitRename() async {
    guard case .editing(let target, let currentLabel) = renamePrompt else { return }
    renamePrompt = nil
    guard RenameLabel.isWorthSending(renameDraft, whenCurrentLabelIs: currentLabel),
      let label = RenameLabel.sanitised(renameDraft)
    else { return }
    await performRename(target, to: label)
  }

  /// Clears a refused rename's notice.
  func dismissRenameFailure() {
    if case .failed = renamePrompt { renamePrompt = nil }
  }

  /// Sends it, then re-reads the session at once. A row that keeps its old name until the
  /// next poll reads as a failed tap and invites a second rename.
  private func performRename(_ target: RenameTarget, to label: String) async {
    guard renameInFlight == nil else { return }
    renameInFlight = target
    do {
      try await control.rename(target, to: label)
      await refresh()
    } catch let error as AppError {
      renamePrompt = .failed(target, error)
    } catch {
      renamePrompt = .failed(target, .herdrCommandFailed(reason: "herdr could not be reached."))
    }
    renameInFlight = nil
  }

  func isWorkspaceExpanded(_ workspace: Workspace) -> Bool {
    (expandedWorkspaceIDs ?? tree.defaultExpandedWorkspaceIDs).contains(workspace.id)
  }

  func setWorkspace(_ workspace: Workspace, expanded: Bool) {
    var expandedIDs = expandedWorkspaceIDs ?? tree.defaultExpandedWorkspaceIDs
    if expanded {
      expandedIDs.insert(workspace.id)
    } else {
      expandedIDs.remove(workspace.id)
    }
    expandedWorkspaceIDs = expandedIDs
  }

  func blockedSince(for pane: Pane) -> Date? {
    blockedSinceByPaneID[pane.id]
  }

  /// The Needs-you section's panes, most recently blocked first.
  ///
  /// Ties keep tree order. A pane already blocked when the connection opened has no
  /// recorded time, so it sorts last in tree order via `distantPast`. Here, not in the
  /// view, so the rule can be asserted.
  var blockedPanesNewestFirst: [Pane] {
    tree.blockedPanes.enumerated()
      .sorted { lhs, rhs in
        let left = blockedSinceByPaneID[lhs.element.id] ?? .distantPast
        let right = blockedSinceByPaneID[rhs.element.id] ?? .distantPast
        return left == right ? lhs.offset < rhs.offset : left > right
      }
      .map(\.element)
  }

  /// Loads once, because a `.task` can re-run on any identity change.
  func loadIfNeeded() async {
    guard case .idle = state else { return }
    await refresh()
  }

  /// Retains the live updates, starting them if nobody held them yet.
  ///
  /// A retain/release pair, because the host screen and the terminal scene both consume
  /// the session and either can leave first. Only one loop ever runs, so a re-running
  /// `.task` does not double the traffic.
  ///
  /// Where the control pushes, this listens as well. Listening starts ahead of the first read,
  /// and what changed while nobody listened is read once on the way in, so no change falls
  /// between the two.
  func startLiveUpdates() {
    consumers += 1
    pollingPaused = false
    guard liveUpdates == nil else { return }
    let changes = control.changes
    let isPushed = changes != nil
    liveUpdates = Task { [weak self, pollInterval] in
      let listener = changes.map { changes in
        Task { [weak self] in
          for await _ in changes { await self?.changedOnHost() }
        }
      }
      defer { listener?.cancel() }

      // Load first, then wait, so the screen is not blank for a whole tick.
      await self?.loadIfNeeded()
      if isPushed { await self?.changedOnHost() }
      while !Task.isCancelled {
        try? await Task.sleep(for: pollInterval)
        guard !Task.isCancelled, let self else { return }
        if self.needsPolling { await self.refresh() }
      }
    }
  }

  private var needsPolling: Bool { control.needsPolling || lastFailure != nil }

  /// Releases one consumer's hold, and stops polling when the last one lets go. A warm
  /// connection is idle; a polling one runs a command on the user's machine every tick.
  ///
  /// Clamped at zero, so an unbalanced release cannot swallow a later retain.
  func stopLiveUpdates() {
    consumers = max(0, consumers - 1)
    guard consumers == 0 else { return }
    pausePolling()
  }

  var isLive: Bool { liveUpdates != nil }

  /// Stops polling without releasing any hold, for a connection that was just lost. The
  /// holders are still on screen, and the tree stays so the sidebar does not look like the
  /// session vanished.
  func pausePolling() {
    liveUpdates?.cancel()
    liveUpdates = nil
    pollingPaused = true
  }

  private func recordBlockedSince(from old: SessionTree, to new: SessionTree) {
    let oldStatusByPaneID = Dictionary(
      uniqueKeysWithValues: old.allPanes.map { ($0.id, $0.agent?.status) }
    )
    let blockedPaneIDs = Set(
      new.allPanes.compactMap { pane in
        pane.agent?.status == .blocked ? pane.id : nil
      }
    )
    blockedSinceByPaneID = blockedSinceByPaneID.filter { blockedPaneIDs.contains($0.key) }
    // One `Date()` per snapshot, so panes that blocked in the same interval tie and keep
    // tree order in the Needs-you sort.
    let now = Date()
    for pane in new.allPanes where pane.agent?.status == .blocked {
      if oldStatusByPaneID[pane.id] != .blocked || blockedSinceByPaneID[pane.id] == nil {
        blockedSinceByPaneID[pane.id] = now
      }
    }
  }

  /// What moved between two trees. Pure, so `DriverrTests` asserts it on literal trees.
  ///
  /// A new pane counts as moved. Nothing is cached for it yet, and a pane that arrives
  /// blocked is the one someone is about to open.
  static func changes(from old: SessionTree, to new: SessionTree) -> Changes {
    let before = Dictionary(uniqueKeysWithValues: old.allPanes.map { ($0.id, $0) })
    var changes = Changes()
    for pane in new.allPanes {
      changes.liveIDs.insert(pane.id)
      changes.livePanes.append(pane)
      guard let was = before[pane.id] else {
        changes.moved.append(pane)
        continue
      }
      if hasMoved(from: was, to: pane) { changes.moved.append(pane) }
    }
    return changes
  }

  /// The four fields a conversation's freshness depends on.
  ///
  /// - `agent.status`, so blocked, working, blocked again does not show the old question.
  /// - `agent.session?.identifier`, because `/clear` or a restart starts a new file.
  /// - `agent.kind` and `directory`, because either changes the resolver's answer.
  ///
  /// The title is left out: `terminal_title_stripped` keeps Claude Code's spinner frames,
  /// so it changes on every poll.
  private static func hasMoved(from old: Pane, to new: Pane) -> Bool {
    old.agent?.status != new.agent?.status
      || old.agent?.session?.identifier != new.agent?.session?.identifier
      || old.agent?.kind != new.agent?.kind
      || old.directory != new.directory
  }

  /// Stops polling and hands back how many consumers were holding it.
  ///
  /// A reconnect builds a new session, and the holders cannot all retain again: the
  /// terminal scene retained once, in `TerminalPresenter.beginPresentation`, and a reconnect
  /// does not begin a new presentation. So the connection carries the count to the new
  /// session, and this one stops.
  func handOverConsumers() -> Int {
    let held = consumers
    consumers = 0
    pausePolling()
    return held
  }
}
