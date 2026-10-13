import DriverrCore
import DriverrTranscript
import Foundation
import Observation

/// One pane's conversation, fetched once and kept.
///
/// `DriverrTranscript` says which file and what is in a page of it. This model decides when
/// to ask and what a screen shows meanwhile.
///
/// The pane's chat and the Needs you row share one model per pane through
/// `PaneTranscriptCache`, so a large session file is not re-read per consumer on every
/// poll.
@MainActor
@Observable
final class PaneTranscriptModel {
  enum State: Equatable {
    /// Not asked yet. "Asked and got nothing" is a `Transcript` whose outcome is
    /// `.noReadableTurns`.
    case idle
    case loading
    case ready(TranscriptSource, Transcript)
    /// The resolver answered with something other than a file. Kept whole because the
    /// picker needs the candidates and each screen words it differently.
    case unavailable(TranscriptResolution)
    /// The host refused, or the link went away. The only state with a retry; the others
    /// are answers.
    case failed(AppError)
  }

  /// The pane this reads, as the latest snapshot reported it. After a `/clear` or a restart
  /// the pane has a new session id, and a stale copy would draw another conversation as
  /// this pane's.
  ///
  /// **Written only by `ConnectionModel.apply(_:)`**, from the live tree. Not by the cache:
  /// a view can hold an older `Pane` and write a replaced session back.
  ///
  /// `@ObservationIgnored`, so recording a pane redraws nothing. The poll's diff or the next
  /// `loadIfNeeded()` acts on the change.
  @ObservationIgnored private(set) var pane: Pane
  private(set) var state: State = .idle

  /// The file chosen from the picker, if any. `TranscriptPick` owns how long it lasts. It is
  /// held on this cached model and never written to disk, so it survives polls and surface
  /// switches but not a disconnect.
  private(set) var pick: TranscriptPick?

  /// How many turns the next fetch asks for. The reader fetches a tail, so a bigger page is
  /// a superset and paging is one number, not a cursor.
  private(set) var turnsWanted = TranscriptReader.defaultTurns

  /// A wider page is being fetched while the current one stays on screen. Not `.loading`,
  /// because `.loading` takes the chat off screen and loses the scroll position.
  private(set) var isPagingBack = false

  /// Each candidate's opening line, keyed by filename. Empty until the picker opens, so the
  /// round trip is spent only when asked for.
  private(set) var briefs: [String: String] = [:]

  /// Which runs of tool calls the reader has opened.
  ///
  /// Held here, not in `PaneChatView`'s `@State`, because a switch to Terminal tears the
  /// chat down. `OpenToolRuns` owns what survives a re-read.
  var openRuns = OpenToolRuns()

  /// Turns the reader expanded past the length bound. Held here for `openRuns`' reason.
  var expanded: Set<String> = []

  /// A reply that went over and is not in the file yet.
  ///
  /// The agent writes the session file, not the send, so for a while the conversation looks
  /// unanswered and invites a second send. This draws the reply with a note until a re-read
  /// finds it. It lives here because the chat renders it and already observes this model.
  private(set) var pendingTurn: PendingTurn?

  /// What the last `Load more` failed with, or `nil`. `pageBack` keeps the old page on
  /// failure, and this lets the control say so. Cleared when another page is asked for.
  private(set) var lastPagingError: AppError?

  /// When the page on screen was fetched, for the appearance refresh's staleness check.
  @ObservationIgnored private(set) var lastFetchedAt: Date?

  /// What the page on screen was resolved from, recorded when the fetch started. `pane`
  /// moves every poll, and the question is whether it moved since the page was resolved.
  @ObservationIgnored private(set) var resolvedFrom: Inputs?

  /// A re-read running underneath a page that stays on screen.
  private(set) var isRefreshing = false

  /// Every turn on the page with its markdown already parsed.
  ///
  /// Written only from `settle`, so the parse runs once per changed turn and not in
  /// `TranscriptTurnView`'s body on every scroll. `TranscriptRender.rendering(_:reusing:parse:)`
  /// owns the reuse. Not a field on `TranscriptTurn`, so parser fixtures do not pay for it.
  private(set) var render = TranscriptRender()

  /// The three things about a pane that decide which file its conversation is in. The rest
  /// of a `Pane` changes on most polls and must not throw the page away.
  struct Inputs: Equatable {
    let sessionID: String?
    let agentKind: String?
    let directory: String?

    init(_ pane: Pane) {
      sessionID = pane.agent?.session?.identifier
      agentKind = pane.agent?.kind
      directory = pane.directory
    }
  }

  /// A reply the reader has sent that the session file does not show yet.
  struct PendingTurn: Equatable {
    let text: String
    let at: Date

    /// What the row says under it, so the echo is never mistaken for a turn from the file.
    var note: String { "Sent — not yet in the session file" }
  }

  /// Told when a re-read finds the conversation has moved on.
  ///
  /// This is the composer's second retirement signal for `Sent`. An agent can answer one
  /// permission prompt and block on the next, so herdr's status never leaves `blocked` and
  /// only the file moves. A closure, so this model does not learn about composers.
  @ObservationIgnored var onAdvanced: (@MainActor (String) -> Void)?

  /// How this conversation is read. A `var` because the reader is bound to a link, and
  /// `relink(to:)` moves it on a reconnect.
  @ObservationIgnored private var reader: TranscriptReader
  /// Injected so tests can assert staleness and the echo without waiting.
  @ObservationIgnored private let now: @MainActor () -> Date
  /// The in-flight fetch, owned here rather than by the view that asked.
  ///
  /// **This is why `loadIfNeeded()` is not `async`.** A load driven by a view's
  /// `.task(id:)` is cancelled when the identity changes, which a poll tick can do, and the
  /// model would sit in `.loading` for ever. An unstructured `Task` does not inherit the
  /// caller's cancellation.
  @ObservationIgnored private(set) var currentLoad: Task<Void, Never>?
  /// The in-flight brief fetch, owned here for `currentLoad`'s reason. Readable so a test
  /// can wait for it.
  @ObservationIgnored private(set) var briefLoad: Task<Void, Never>?
  /// Whether the briefs have been asked for. A flag, not "are they empty", because no
  /// readable opening line is a real answer and must not be re-asked on every redraw.
  @ObservationIgnored private var hasAskedForBriefs = false

  // MARK: - What this host has installed

  /// The slash commands this host offers. `SlashCommandCatalog.empty` until the first
  /// answer, which differs from a host that answered with nothing.
  private(set) var skillCatalog = SlashCommandCatalog.empty
  /// The working directory the catalogue in hand was fetched for.
  ///
  /// The host is implied, because the cache belongs to one connection. A reconnect may reach
  /// another machine, so `relink(to:)` clears this. `String??`: the outer optional is "has
  /// anything been fetched", the inner is `Pane.directory`.
  @ObservationIgnored private var skillCatalogKey: String??
  /// When the catalogue in hand was fetched.
  @ObservationIgnored private var skillCatalogFetchedAt: Date?
  /// The in-flight catalogue fetch, owned here for `currentLoad`'s reason. Readable so a
  /// test can wait for it.
  @ObservationIgnored private(set) var skillCatalogLoad: Task<Void, Never>?

  /// How old the catalogue must be before it is fetched again. Much longer than the page's
  /// bound, because installed commands change rarely and the answer is the app's largest
  /// single fetch.
  static let skillCatalogStaleness: TimeInterval = 300

  /// Asks the host what it has installed, at most once per appearance.
  ///
  /// The key guard refetches when the pane's directory moved, because project scope
  /// changed. The staleness guard stops repeated appearances from polling. Not `async`, for
  /// `currentLoad`'s reason.
  ///
  /// **Appearance is the only trigger.** `refresh()` runs on every poll, send and reconnect,
  /// which is the wrong place for the largest fetch.
  /// `PaneTranscriptModelTests.appearanceRefreshesOnlyWhenStale` counts the round trips.
  func loadSkillsIfNeeded(maxAge: TimeInterval = PaneTranscriptModel.skillCatalogStaleness) {
    guard skillCatalogLoad == nil else { return }
    let wanted = pane.directory
    if skillCatalogKey == .some(wanted), let skillCatalogFetchedAt,
      now().timeIntervalSince(skillCatalogFetchedAt) < maxAge
    {
      return
    }
    skillCatalogLoad = Task { [weak self] in
      guard let self else { return }
      let found = await reader.skills(cwd: wanted)
      guard !Task.isCancelled else { return }
      skillCatalog = found
      skillCatalogKey = .some(wanted)
      skillCatalogFetchedAt = now()
      skillCatalogLoad = nil
    }
  }

  init(
    pane: Pane,
    reader: TranscriptReader,
    now: @escaping @MainActor () -> Date = Date.init,
    subagent: SubagentTarget? = nil
  ) {
    self.pane = pane
    self.reader = reader
    self.now = now
    self.subagent = subagent
  }

  // MARK: - A sub-agent's own conversation

  /// What a sub-agent's chat reads, and `nil` for a pane's own conversation.
  ///
  /// **A second model, not a second source on this one.** The Needs you row quotes
  /// `lastAssistantMessage` off the pane's model, so pointing it at a sub-agent's file would
  /// put the sub-agent's words in the pane's row. A spawn-line tap pushes a new model onto
  /// `subagents` instead.
  struct SubagentTarget: Equatable {
    let link: SubagentLink
    /// What the spawn line called it, for the back bar.
    let title: String
    /// The expanded project directory the pane's file is in, read off the file's path.
    let directory: String
    /// The session whose file holds the spawn. Only a teammate's link reads it; see
    /// `TranscriptReader.subagentFile`.
    let sessionID: String
  }

  let subagent: SubagentTarget?

  /// The file `subagent`'s link resolved to, once it has. Resolved again only while it has
  /// not, so a tick re-reads the file rather than re-searching the project.
  @ObservationIgnored private var subagentFile: TranscriptFile?

  /// The sub-agent conversations opened from this pane's chat, newest on top. Always empty on
  /// a sub-agent's own model: its spawn lines carry no link.
  private(set) var subagents = SubagentStack<PaneTranscriptModel>()

  /// The conversation the chat shows.
  var shown: PaneTranscriptModel { subagents.top ?? self }

  var isShowingSubagent: Bool { !subagents.isEmpty }

  /// Opens the sub-agent a spawn line links to, on top of this conversation. Needs a page on
  /// screen, because the directory and session come from the file holding the spawn.
  func openSubagent(link: SubagentLink, title: String) {
    guard subagent == nil, case .ready(let source, _) = state else { return }
    // A Claude session file is `<projectDir>/<sessionId>.jsonl`. The project directory comes
    // from the file's path, not `source.directory`, which is the pane's working directory.
    let path = source.file.path as NSString
    let name = path.lastPathComponent
    let sessionID = name.hasSuffix(".jsonl") ? String(name.dropLast(".jsonl".count)) : name
    let child = PaneTranscriptModel(
      pane: pane,
      reader: reader,
      now: now,
      subagent: SubagentTarget(
        link: link, title: title, directory: path.deletingLastPathComponent,
        sessionID: sessionID)
    )
    subagents.push(child)
    child.loadIfNeeded()
  }

  /// Back to the conversation under the top one.
  func closeSubagent() {
    subagents.pop()?.stop()
  }

  /// Back to the pane's own conversation, from however deep.
  func closeAllSubagents() {
    guard !subagents.isEmpty else { return }
    for closed in subagents.removeAll() { closed.stop() }
  }

  /// Drops a closed sub-agent's in-flight work. Its watcher is the view's, and stops when the
  /// view stops showing it.
  private func stop() {
    currentLoad?.cancel()
    currentLoad = nil
  }

  /// The page, when there is one.
  var transcript: Transcript? {
    guard case .ready(_, let transcript) = state else { return nil }
    return transcript
  }

  /// Where the file came from, for the provenance header.
  var source: TranscriptSource? {
    guard case .ready(let source, _) = state else { return nil }
    return source
  }

  /// The agent's last words, for the Needs you row.
  var lastAssistantMessage: String? { transcript?.lastAssistantMessage }

  /// When this conversation was last written to, on the host's clock. A pane's waiting time
  /// is measured from this.
  var lastActivity: Date? { transcript?.lastActivity }

  var isLoading: Bool { state == .loading }

  /// What the pager says about the page in hand, or `nil` before there is one.
  var paging: TranscriptPaging? {
    guard case .ready(_, let transcript) = state else { return nil }
    return TranscriptPaging(turnsHeld: transcript.turns.count, window: transcript.window)
  }

  /// Fetches once. Safe from a view body or a re-running `.task`.
  func loadIfNeeded() {
    if case .idle = state {
      start()
      return
    }
    // Appearance also refreshes a stale page. The staleness bound stops a redrawing view
    // from paying for a read each time.
    refreshIfStale()
  }

  /// How old the page must be before appearing re-reads it. Short enough that coming back
  /// shows what happened; long enough that a re-running `.task` is not a second poller.
  static let appearanceStaleness: TimeInterval = 30

  /// Re-reads if the page has been on screen long enough to be worth it, or if the pane
  /// has moved out from under it.
  func refreshIfStale(maxAge: TimeInterval = PaneTranscriptModel.appearanceStaleness) {
    if hasMovedOn {
      refresh()
      return
    }
    guard let lastFetchedAt, now().timeIntervalSince(lastFetchedAt) >= maxAge else { return }
    refresh()
  }

  // MARK: - Watching the file grow

  /// How often an open chat asks whether its session file has been written to. Matches the
  /// session poll, so the chat and the pane status agree on how current they are.
  ///
  /// A tick is `TranscriptCommands.sizeCommand`, a few hundred bytes. A page (1 to 100 KB)
  /// is fetched only when the probe reports movement.
  static let watchInterval: Duration = .seconds(3)

  /// How old a `.ready` page must be before a tick does a full re-resolve instead of the
  /// probe.
  ///
  /// The re-resolve catches what the probe cannot: a continuation file, a rotation, and
  /// `hasMovedOn`. These are rare, and a re-resolve reads a whole page, so it runs far less
  /// often than `appearanceStaleness`.
  ///
  /// With no page (`.unavailable`, `.failed`) the tick uses `appearanceStaleness`, since
  /// re-asking is only a listing. A missing reported session and an empty directory are
  /// probed by name every tick instead, because a restarted agent writes its file only on
  /// the first prompt. See `checkForGrowth()`.
  static let watchedStaleness: TimeInterval = 120

  /// What the file looked like when the page on screen settled, or at the last tick.
  ///
  /// The path travels with the size, because a continuation moves the conversation to
  /// another file and a size is only comparable within one file. `modified` is optional
  /// because `settle` has only the listing, which carries an age and not an mtime (see
  /// `TranscriptFile.age`). The mtime is compared only when both sides have one.
  ///
  /// **Seeded at `settle`, not at the first tick.** A first-tick baseline would absorb a
  /// turn written just after the page landed, and it would not show until the staleness
  /// re-read.
  ///
  /// The listing's size and the probe's size must agree for an unwritten file. On a host both
  /// are `wc -c`. `FakeTranscriptHost` must match, or every tick re-reads the page while the
  /// growth test still passes.
  private struct Probe: Equatable {
    let path: String
    let modified: TimeInterval?
    let sizeInBytes: Int

    /// Whether the file has moved since `baseline`. The mtime only speaks when both
    /// readings have one.
    func hasMoved(from baseline: Probe) -> Bool {
      if path != baseline.path || sizeInBytes != baseline.sizeInBytes { return true }
      guard let modified, let was = baseline.modified else { return false }
      return modified != was
    }
  }

  @ObservationIgnored private var lastProbe: Probe?

  /// The two states that end when a new session writes its first file: herdr named a file
  /// that is not in the directory, or the directory holds no session file.
  private var isWaitingForAFile: Bool {
    switch state {
    case .unavailable(.absent(.reportedSessionMissing)), .unavailable(.absent(.noSessionFiles)):
      return true
    default:
      return false
    }
  }

  /// One tick of the watcher: asks whether the file has been written to, and re-reads it if
  /// it has. No sleep inside, so a test can drive it. `watch(every:)` is the loop.
  ///
  /// In order:
  ///
  /// 1. A load in flight wins, so a tick does not duplicate it.
  /// 2. With no page, a file waiting to appear is probed by name with
  ///    `TranscriptReader.probeReportedSession(for:)` and re-resolved on the first answer.
  ///    Otherwise `.unavailable` and `.failed` fall through to `refreshIfStale()`.
  /// 3. A page resolved for an older pane is re-resolved at once, because it is the wrong
  ///    conversation. The poll's `refresh()` misses this while a load is in flight. A page
  ///    older than `watchedStaleness` is re-resolved whatever the probe says.
  /// 4. Otherwise a change of path, size or mtime re-reads.
  ///
  /// A probe that answers `nil` leaves the page and the baseline alone, so an unsolicited
  /// check cannot take a working conversation off screen. The baseline is written only for
  /// a page on screen: by `settle`, or here when nothing moved.
  func checkForGrowth() async {
    guard currentLoad == nil else { return }
    guard case .ready(let source, _) = state else {
      // A named file not there yet is probed every tick. `hasMovedOn` goes to
      // `refreshIfStale()`, which answers it at once.
      if isWaitingForAFile, !hasMovedOn,
        (try? await reader.probeReportedSession(for: pane)) != nil
      {
        refresh()
        return
      }
      refreshIfStale()
      return
    }
    if hasMovedOn {
      refresh()
      return
    }
    if let lastFetchedAt, now().timeIntervalSince(lastFetchedAt) >= Self.watchedStaleness {
      refreshIfStale(maxAge: Self.watchedStaleness)
      return
    }

    guard let stamp = try? await reader.probe(source.file) else { return }
    // Re-checked after the round trip, so the baseline is not written against a page that
    // was replaced meanwhile.
    guard currentLoad == nil, case .ready(let current, _) = state else { return }

    let taken = Probe(
      path: current.file.path, modified: stamp.modified, sizeInBytes: stamp.sizeInBytes)
    guard let baseline = lastProbe, taken.hasMoved(from: baseline) else {
      // Nothing moved, so this probe becomes the baseline. It also adds the mtime that the
      // listing-seeded baseline lacks.
      lastProbe = taken
      return
    }
    // **Do not advance the baseline here.** The read `refresh()` starts can fail, and
    // `settle` drops a quiet failure. A baseline written before the read would then match
    // the grown file, and the chat would stay behind until the file grew again. A failing
    // read is retried each tick, serialised on `currentLoad`.
    refresh()
  }

  /// Keeps asking until the task is cancelled.
  ///
  /// The sleep comes first, because appearance has just read the file. `PaneChatView` runs
  /// this from a `.task` keyed on the pane, the sub-agent shown and scene activity, so its
  /// cancellation is the only exit. `Task.sleep` throws on cancellation.
  func watch(every interval: Duration = PaneTranscriptModel.watchInterval) async {
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: interval)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await checkShownForGrowth()
    }
  }

  /// One tick of `watch(every:)`, on the conversation on screen only. While a sub-agent is
  /// shown the pane's own file is not probed. The Needs you row refreshes from the poll.
  func checkShownForGrowth() async {
    await shown.checkForGrowth()
  }

  /// Whether the pane changed session, agent kind or working directory since the page was
  /// resolved, which makes the page the wrong conversation.
  var hasMovedOn: Bool {
    // A sub-agent's file is fixed by its link, whatever the pane does. The pane's own model
    // closes the stack when the pane moves on.
    guard subagent == nil, let resolvedFrom else { return false }
    return Inputs(pane) != resolvedFrom
  }

  /// Re-reads the tail without taking the page off screen.
  ///
  /// Not `reload()`, which returns to a spinner and loses the reader's place. This keeps
  /// `turnsWanted` and `openRuns`, and re-runs the resolver, so a pane whose session changed
  /// gets its new file.
  func refresh() {
    guard currentLoad == nil else { return }
    if case .idle = state {
      start()
      return
    }
    isRefreshing = true
    currentLoad = Task { [weak self] in await self?.fetch(quietly: true) }
  }

  /// Moves this conversation onto the link that came back, and re-reads it there.
  ///
  /// The model moves rather than being replaced; see `PaneTranscriptCache.takeOver(from:)`.
  /// It keeps what the reader chose (the page, `turnsWanted`, open runs, expanded messages,
  /// the pick) and drops in-flight work, which belongs to the dead link. The re-read is
  /// `refresh()`, for that method's reason.
  ///
  /// An `.idle` model is not re-read. Nothing is on screen, and a fetch per blocked pane on
  /// every reconnect would be wasted. Its next `loadIfNeeded()` uses the new reader.
  func relink(to reader: TranscriptReader) {
    // Cancelled, not awaited. The load still lands and `settle` drops it. Clearing
    // `currentLoad` lets the `refresh()` below start.
    currentLoad?.cancel()
    currentLoad = nil
    briefLoad?.cancel()
    briefLoad = nil
    hasAskedForBriefs = false
    // The catalogue belongs to the link. A reconnect may reach another machine, and the key
    // is only the directory.
    skillCatalogLoad?.cancel()
    skillCatalogLoad = nil
    skillCatalog = .empty
    skillCatalogKey = nil
    skillCatalogFetchedAt = nil
    isPagingBack = false
    // A paging failure belongs to the old link.
    lastPagingError = nil
    // The stamp came from the old link. The `refresh()` below re-reads, and settles a new
    // baseline.
    lastProbe = nil
    self.reader = reader
    // A sub-agent on screen reads through the same link, so it moves with it.
    for open in subagents.entries { open.relink(to: reader) }
    if case .idle = state { return }
    refresh()
  }

  /// Records the latest snapshot of the pane. Only `ConnectionModel.apply(_:)` calls this;
  /// see `pane`. Writes nothing observed.
  func update(to pane: Pane) {
    guard pane.id == self.pane.id else { return }
    self.pane = pane
  }

  /// A reply just went over. Echo it, and re-read to find it.
  ///
  /// The echo stands in until the re-read lands; see `pendingTurn`. `text` is `nil` for a
  /// key press, which has nothing to echo but still re-reads.
  func recordSend(_ text: String?) {
    if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      pendingTurn = PendingTurn(text: text, at: now())
    }
    refresh()
  }

  /// Throws the page away so the next `loadIfNeeded()` fetches again, back to a spinner.
  /// For a page that is wrong, not stale: a changed session, or a pane that left the tree.
  func invalidate() {
    currentLoad?.cancel()
    currentLoad = nil
    briefLoad?.cancel()
    briefLoad = nil
    hasAskedForBriefs = false
    isPagingBack = false
    isRefreshing = false
    lastPagingError = nil
    pendingTurn = nil
    resolvedFrom = nil
    lastFetchedAt = nil
    // The baseline belongs to the page being thrown away.
    lastProbe = nil
    turnsWanted = TranscriptReader.defaultTurns
    render = TranscriptRender()
    // Sub-agents opened from this page go with it, and a retry on a sub-agent's own chat
    // searches for its file again.
    closeAllSubagents()
    subagentFile = nil
    state = .idle
  }

  /// Throws the page away only if `hasMovedOn`. The session poll's diff calls this.
  func invalidateIfMovedOn() {
    guard hasMovedOn else { return }
    invalidate()
  }

  // MARK: - Choosing a file by hand

  /// Records the picker's choice and reads that file.
  ///
  /// The resolver re-checks the pick against a fresh listing and answers `chosenByHand`
  /// only if the file is still there. This model never decides a file is the pane's.
  func choose(_ file: TranscriptFile, in directory: String) {
    pick = TranscriptPick(directory: directory, file: file)
    currentLoad?.cancel()
    currentLoad = nil
    // The baseline belongs to the file being left.
    lastProbe = nil
    start()
  }

  /// Reads every listed candidate's opening line, once.
  ///
  /// Called when the picker opens, not when the refusal is drawn. A failure falls back to
  /// the filename and mtime, as a candidate with no readable line does.
  func loadBriefsIfNeeded() {
    guard !hasAskedForBriefs,
      case .unavailable(.ambiguous(let directory, let candidates)) = state
    else { return }
    hasAskedForBriefs = true
    let wanted = TranscriptPicker(directory: directory, candidates: candidates).candidates
      .map(\.file)
    briefLoad = Task { [weak self] in
      guard let self else { return }
      let found = try? await reader.briefs(in: directory, for: wanted)
      guard !Task.isCancelled else { return }
      briefs = found ?? [:]
    }
  }

  // MARK: - Paging back through the file

  /// Widens the page by `TranscriptPaging.defaultIncrement` turns.
  ///
  /// Guards: a `.ready` page, no page already in flight (checked here, not by a disabled
  /// button, which a fast tap can beat), and more of the file behind the page.
  func loadMore() {
    guard case .ready(let source, _) = state, !isPagingBack, paging?.loadMore != nil else {
      return
    }
    isPagingBack = true
    lastPagingError = nil
    turnsWanted += TranscriptPaging.defaultIncrement
    currentLoad = Task { [weak self] in await self?.pageBack(from: source) }
  }

  /// Fetches the wider page without disturbing the one on screen.
  ///
  /// Not routed through `fetch()`/`settle()`, which replace the state. The resolver is not
  /// re-run, because asking for more cannot change the file, and a directory that turned
  /// ambiguous would take the conversation off screen mid-scroll.
  ///
  /// A failure keeps the current page and rolls `turnsWanted` back.
  private func pageBack(from source: TranscriptSource) async {
    let wanted = turnsWanted
    do {
      let wider = try await reader.read(source.file, turns: wanted)
      guard !Task.isCancelled else { return }
      isPagingBack = false
      currentLoad = nil
      state = .ready(source, wider)
      // This path bypasses `settle`, so it repeats the render rebuild. Without it the older
      // turns have no render, and a newest turn that grew meanwhile keeps stale blocks.
      render = TranscriptRender.rendering(wider.turns, reusing: render)
    } catch {
      guard !Task.isCancelled else { return }
      turnsWanted = max(TranscriptReader.defaultTurns, wanted - TranscriptPaging.defaultIncrement)
      isPagingBack = false
      currentLoad = nil
      // Said out loud, or the tap reads as having done nothing.
      lastPagingError =
        (error as? AppError)
        ?? .transcriptUnreadable(reason: "Earlier turns could not be read.")
    }
  }

  /// What the retry on a failed fetch does.
  func reload() {
    invalidate()
    start()
  }

  private func start() {
    state = .loading
    currentLoad = Task { [weak self] in await self?.fetch() }
  }

  private func fetch(quietly: Bool = false) async {
    // Captured before the round trip. The poll can move `pane` while the fetch runs, and
    // recording the later value would make the page look current when it is not.
    let asked = Inputs(pane)
    if let subagent {
      await fetchSubagent(subagent, asked: asked, quietly: quietly)
      return
    }
    do {
      let resolution = try await reader.resolve(for: pane, pick: pick)
      // The resolver decides whether the pick still applies. If it did not honour it, the
      // file is gone or herdr now reports the session, so the pick is dropped.
      let honoured = resolution.source?.provenance == .chosenByHand
      guard let source = resolution.source else {
        // An answer, not a failure. `quietly` is forwarded because some of these answers
        // are transient; see the guard in `settle`.
        settle(.unavailable(resolution), resolvedFrom: asked, keepingPick: false, quietly: quietly)
        return
      }
      // One page size for both consumers. The reader fetches at least 60 records whatever
      // it is asked, so a smaller page saves nothing.
      let transcript = try await reader.read(source.file, turns: turnsWanted)
      settle(.ready(source, transcript), resolvedFrom: asked, keepingPick: honoured)
    } catch let error as AppError {
      settle(.failed(error), resolvedFrom: asked, quietly: quietly)
    } catch {
      settle(
        .failed(.transcriptUnreadable(reason: "The session file could not be read.")),
        resolvedFrom: asked,
        quietly: quietly
      )
    }
  }

  /// A sub-agent's fetch. `resolve` is skipped, because the file is the one the link names.
  ///
  /// The source's file is rebuilt with the read's own size. `settle` seeds the growth
  /// baseline from it, and the size from the one-time link lookup would differ from every
  /// later probe, so each tick would re-read.
  private func fetchSubagent(_ target: SubagentTarget, asked: Inputs, quietly: Bool) async {
    do {
      if subagentFile == nil {
        let found: TranscriptFile?
        switch target.link {
        case .toolUse(let id):
          found = try await reader.subagentFile(
            toolUseID: id, directory: target.directory, sessionID: target.sessionID)
        case .teammate(let name):
          found = try await reader.subagentFile(
            teammateName: name, directory: target.directory, sessionID: target.sessionID)
        }
        guard !Task.isCancelled else { return }
        subagentFile = found
      }
      guard let file = subagentFile else {
        settle(
          .unavailable(.absent(.subagentFileNotFound)), resolvedFrom: asked, keepingPick: false,
          quietly: quietly)
        return
      }
      let transcript = try await reader.read(file, turns: turnsWanted)
      let read = TranscriptFile(
        path: file.path, sizeInBytes: transcript.window.fileSizeInBytes, age: file.age,
        isSubagentFile: true)
      settle(
        .ready(
          TranscriptSource(
            file: read, provenance: .subagent, directory: pane.directory ?? target.directory),
          transcript),
        resolvedFrom: asked)
    } catch let error as AppError {
      settle(.failed(error), resolvedFrom: asked, quietly: quietly)
    } catch {
      settle(
        .failed(.transcriptUnreadable(reason: "The agent's session file could not be read.")),
        resolvedFrom: asked,
        quietly: quietly
      )
    }
  }

  /// Records a verdict, unless this load was cancelled.
  ///
  /// **Nothing below here checks cancellation.** `TranscriptReader`, its `CommandRunner`
  /// and the exec channel all run to completion, so a cancelled load still arrives. Without
  /// the guard, `invalidate()` does not stick (a stale `.ready` lands and `loadIfNeeded()`
  /// then no-ops for good) and `reload()` races itself. `Task.isCancelled` is task-local, so
  /// one check covers both. Every verdict comes through here, not only `.ready`.
  ///
  /// `keepingPick` is `false` only when the resolver answered with another file. A `.failed`
  /// keeps the pick, or a retry after a dropped link would silently resolve a different
  /// conversation.
  private func settle(
    _ verdict: State,
    resolvedFrom asked: Inputs,
    keepingPick: Bool = true,
    quietly: Bool = false
  ) {
    isRefreshing = false
    guard !Task.isCancelled else { return }
    currentLoad = nil

    // A quiet re-read must not take a working page off screen. Every refresh trigger is
    // unsolicited, so over a `.ready` page a `.failed` verdict is dropped, and
    // `lastFetchedAt` stays put so the next trigger re-asks at once.
    //
    // `.unavailable` is dropped too, because many of its reasons are transient: a short
    // listing (`noSessionFiles`, `reportedSessionMissing`), a second writer or an unparsed
    // mtime (`ambiguous`), or a snapshot briefly missing the agent or cwd. A command that
    // fails throws and arrives as `.failed`, not here.
    //
    // The exception is a verdict resolved from different `Inputs`. It is about a different
    // conversation and replaces the page. The permanent reasons all change `Inputs`.
    //
    // Costs, accepted: there is no miss counter, so a file deleted for good leaves its page
    // up until the pane moves or the reader retries, and each tick then spends one dropped
    // listing. `relink(to:)` does not change `Inputs`, so a reconnect to a machine without
    // the directory keeps the old page until a retry.
    //
    // **Keep this above the `pick` clearing.** `.unavailable` settles with
    // `keepingPick: false`, so a guard below it would drop the verdict and still lose the
    // hand-picked file.
    if quietly, case .ready = state {
      switch verdict {
      case .failed: return
      case .unavailable where asked == resolvedFrom: return
      default: break
      }
    }

    if !keepingPick { pick = nil }

    let previous = self.transcript
    // **Guarded, because Observation notifies on every write, not every change.** Most
    // re-reads return the page already on screen, and an unguarded write re-evaluates the
    // chat's whole `LazyVStack`. Guarded on `drawsSame(_:as:)`, not `==`; see its note.
    if !Self.drawsSame(verdict, as: state) { state = verdict }
    // These stay outside the guard, and none redraws the chat. `lastFetchedAt` is what
    // `refreshIfStale` measures. `resolvedFrom` must record the newer inputs, or
    // `hasMovedOn` stays true. `retirePendingTurn` writes only when the echo has landed.
    lastFetchedAt = now()
    resolvedFrom = asked
    if case .ready(let source, let transcript) = verdict {
      // The growth baseline, from the page that landed; see `Probe`. **Keep it outside the
      // `drawsSame` guard and unconditional.** It is the only write that advances the
      // baseline after a growth-triggered read, because `checkForGrowth()` leaves it alone.
      lastProbe = Probe(
        path: source.file.path, modified: nil, sizeInBytes: source.file.sizeInBytes)
      retirePendingTurn(against: transcript)
      // Reuse is keyed on id and text, so only a changed turn re-parses. Guarded on `==`,
      // which is cheap because unchanged values share storage.
      let rendered = TranscriptRender.rendering(transcript.turns, reusing: render)
      if render != rendered { render = rendered }
      // The newest turn's id, not the turn count, because paging back grows the count.
      if let newest = transcript.turns.last?.id, newest != previous?.turns.last?.id {
        onAdvanced?(pane.id)
      }
    }
  }

  /// Whether `verdict` would draw exactly what `held` already draws.
  ///
  /// **Not `==`.** `TranscriptSource` carries `readAt` and `file.age`, which move on every
  /// read even when the file did not, so two reads of an unwritten file are never equal.
  /// The header draws their difference (`modifiedAt`), which is fixed, so keeping the held
  /// source draws the same header. A write the chat does not render still changes the size
  /// and the `window`, so it still settles.
  ///
  /// Other verdicts carry no clock and use `==`.
  private static func drawsSame(_ verdict: State, as held: State) -> Bool {
    guard case .ready(let arrived, let page) = verdict,
      case .ready(let onScreen, let drawn) = held
    else { return verdict == held }
    return arrived.file.path == onScreen.file.path
      && arrived.file.sizeInBytes == onScreen.file.sizeInBytes
      && arrived.provenance == onScreen.provenance
      && arrived.directory == onScreen.directory
      && page == drawn
  }

  /// Drops the echo once the file has caught up. Matched on the text, not the turn count,
  /// because a re-read can bring earlier agent turns while the reply is still missing.
  private func retirePendingTurn(against transcript: Transcript) {
    guard let pendingTurn else { return }
    let wanted = pendingTurn.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let arrived = transcript.turns.contains { turn in
      guard turn.isHuman, let text = turn.text else { return false }
      return text.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
    }
    if arrived { self.pendingTurn = nil }
  }
}
