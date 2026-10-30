#if DEBUG
import DriverrCore
import Foundation

/// A `HerdrControl` with a session already in it and no host behind it.
///
/// It ships in the module, like `FakeSSHTransport`, for demo mode, the UI suite, previews
/// and the screenshot tour.
///
/// Deterministic: it reads no clock, random number or environment, so screenshots and UI
/// assertions are stable.
///
/// **Every recording list records what the fake was asked for, refusals included.** A
/// refused call is recorded, then throws. So `sent`, `reads`, `screenReads`, `performed`,
/// `renamed` and `snapshotCount` count attempts. A recorder that dropped refusals would
/// make a working retry look like one that never fired. An empty `readPanes` batch is not
/// a request and records nothing.
public actor FakeControl: HerdrControl {
  /// Trees to hand out in order, the last one repeating forever.
  ///
  /// Lets a UI test watch the sidebar change without reaching into the app.
  private let script: [SessionTree]
  private var tree: SessionTree
  /// Set once an action has edited the tree, so the script stops replacing it.
  ///
  /// Without it, the next poll would undo the user's action, and a closed pane would
  /// come back.
  private var scriptOverridden = false
  private let failure: AppError?
  private let availabilityOverride: HerdrAvailability
  /// What a single-pane read answers with, in place of the fixture.
  ///
  /// The only way to get a blank screen, because `fixtureScreen(for:)` always draws
  /// something. A blank screen is an answer and a refused read is a fault, and tests must
  /// reach both.
  private let screenOverride: PaneScreen?

  /// Every snapshot request, refused ones included.
  public private(set) var snapshotCount = 0

  public init(
    tree: SessionTree = FakeControl.seededTree,
    failure: AppError? = nil,
    // A real pair: herdr 0.9.1 speaks protocol 22, which is `HerdrProtocol.lastVerified`.
    // Change them together.
    availability: HerdrAvailability = .ready(
      version: "0.9.1",
      protocolVersion: HerdrProtocol.lastVerified
    ),
    screen: PaneScreen? = nil
  ) {
    script = []
    self.tree = tree
    self.failure = failure
    availabilityOverride = availability
    screenOverride = screen
  }

  /// A session that changes as it is polled, for exercising live updates.
  public init(script: [SessionTree]) {
    self.script = script
    tree = script.first ?? .empty
    failure = nil
    availabilityOverride = .ready(version: "0.9.1", protocolVersion: HerdrProtocol.lastVerified)
    screenOverride = nil
  }

  /// A fake that fails, for exercising the error surfaces without a broken host.
  public static func failing(_ error: AppError) -> FakeControl {
    FakeControl(tree: .empty, failure: error)
  }

  public func snapshot() async throws -> SessionTree {
    if let failure {
      snapshotCount += 1
      throw failure
    }
    if !script.isEmpty && !scriptOverridden {
      tree = script[min(snapshotCount, script.count - 1)]
    }
    snapshotCount += 1
    return tree
  }

  /// The plain name: a fake has no host to have discovered anything on.
  public nonisolated var binaryPath: String { "herdr" }

  public func availability() async -> HerdrAvailability {
    if let failure, case .herdrNotInstalled = failure { return .notInstalled }
    return availabilityOverride
  }

  public nonisolated func attachCommand(for pane: Pane) -> String {
    // The same command and branch `CLIControl` produces. Every seeded pane has a terminal
    // id, so only a test-built pane reaches the fallback.
    if let terminalID = pane.terminalID {
      return "herdr terminal attach \(terminalID)"
    }
    return "herdr agent attach \(pane.id)"
  }

  /// Replaces the tree, so a test can show the UI reacting to a session that changed.
  public func update(to tree: SessionTree) {
    self.tree = tree
  }

  // MARK: - Steering

  /// Everything this fake was asked to send, in order.
  ///
  /// Refused sends are included, so a reply that failed once and was retried leaves two
  /// entries.
  public private(set) var sent: [Steering] = []

  public enum Steering: Equatable, Sendable {
    case text(paneID: String, text: String)
    /// A reply typed and submitted with `pane run`, which is text plus a CR.
    ///
    /// Its own case, because text plus a newline is different bytes and Claude Code treats
    /// it differently. See `HerdrControl.submitText`.
    case submit(paneID: String, text: String)
    case keys(paneID: String, keys: [PaneKey])
  }

  /// A refusal owed to the next few steering commands and nobody else.
  ///
  /// `failing(_:)` also fails the snapshot, so no pane would exist to retry against. This
  /// fails a run of sends and then lets the rest through.
  private var steeringFailures = 0
  private var steeringFailure: AppError?

  public func failNextSends(_ count: Int, with error: AppError) {
    steeringFailures = count
    steeringFailure = error
  }

  /// Throws whatever this send is owed, if anything.
  private func refuseSteeringIfOwed() throws {
    if let failure { throw failure }
    guard steeringFailures > 0, let steeringFailure else { return }
    steeringFailures -= 1
    throw steeringFailure
  }

  public func sendText(paneID: String, text: String) async throws {
    sent.append(.text(paneID: paneID, text: text))
    try refuseSteeringIfOwed()
  }

  public func submitText(paneID: String, text: String) async throws {
    // Trimmed, so a test reads what `pane run` would receive.
    sent.append(.submit(paneID: paneID, text: CLIControl.submittable(text)))
    try refuseSteeringIfOwed()
  }

  public func sendKeys(paneID: String, keys: [PaneKey]) async throws {
    sent.append(.keys(paneID: paneID, keys: keys))
    try refuseSteeringIfOwed()
  }

  /// Every batched read, with the ids exactly as asked.
  ///
  /// The pane sheet's tests assert which panes were in a batch, because a warm pane's
  /// thumbnail must not be read over the wire. Refused batches are recorded, so
  /// `waitForReads(_:)` works against a failing fake.
  public private(set) var reads: [[String]] = []

  /// Parked until `reads` has reached `threshold` entries.
  private struct ReadWaiter {
    let id: Int
    let threshold: Int
    let continuation: CheckedContinuation<Void, Never>
  }

  private var readWaiters: [ReadWaiter] = []
  private var nextReadWaiterID = 0

  /// Suspends until this fake has answered at least `count` batched reads.
  ///
  /// Waits on a count, not a deadline, so a loaded machine is slower but still passes. A
  /// loop that stopped never arrives, and the suite's `.timeLimit` fails it.
  ///
  /// **Pass one more than the batch whose effect you assert.** The waiter resumes inside
  /// `readPanes`, before the answer is applied. The loop cannot ask again until it is.
  public func waitForReads(_ count: Int) async {
    guard reads.count < count else { return }
    let id = nextReadWaiterID
    nextReadWaiterID += 1
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        // Cancelled before the waiter was parked: resume now, or nothing ever will.
        if Task.isCancelled {
          continuation.resume()
        } else {
          readWaiters.append(ReadWaiter(id: id, threshold: count, continuation: continuation))
        }
      }
    } onCancel: {
      Task { await self.cancelReadWaiter(id) }
    }
  }

  private func resumeReadWaiters() {
    let reached = reads.count
    var parked: [ReadWaiter] = []
    for waiter in readWaiters {
      if reached >= waiter.threshold {
        waiter.continuation.resume()
      } else {
        parked.append(waiter)
      }
    }
    readWaiters = parked
  }

  private func cancelReadWaiter(_ id: Int) {
    guard let index = readWaiters.firstIndex(where: { $0.id == id }) else { return }
    readWaiters.remove(at: index).continuation.resume()
  }

  public func readPanes(ids: [String], lines: Int) async throws -> [String: [String]] {
    // Nothing was asked for, so there is nothing to record and nothing to refuse.
    guard !ids.isEmpty else { return [:] }
    reads.append(ids)
    resumeReadWaiters()
    if let failure { throw failure }
    return Dictionary(
      uniqueKeysWithValues: ids.map { id in
        (id, Array(Self.fixtureLines(for: tree.pane(id: id)).suffix(lines)))
      }
    )
  }

  /// Three plausible last lines for a pane, derived from it so each tile differs. An
  /// unknown pane reads as nothing, as a failed real read does.
  static func fixtureLines(for pane: Pane?) -> [String] {
    guard let pane else { return [] }
    return [
      "$ cd \(pane.directory ?? "~")",
      "$ herdr pane \(pane.id)",
      pane.agent.map { "\($0.name) is \($0.status.rawValue)" } ?? "$",
    ]
  }

  /// Every single-pane screen read this fake was asked for, in order.
  ///
  /// Records the line count too, which the reply surface's tests assert. Refused reads are
  /// recorded, so a test can count retries.
  public private(set) var screenReads: [(paneID: String, lines: Int)] = []

  public func readScreen(of pane: Pane, lines: Int) async throws -> PaneScreen {
    screenReads.append((pane.id, lines))
    if let failure { throw failure }
    if let screenOverride { return screenOverride }
    return PaneScreen.sanitised(Self.fixtureScreen(for: pane), lines: lines)
  }

  /// A screen the fake's pane could plausibly be showing, with real SGR in it.
  ///
  /// It uses the escape sequences Claude Code emits, with foreground 15 on the record
  /// glyph, so demo mode exercises the real marker rules. A pane with no agent gets a shell
  /// screen with no marker.
  ///
  /// Both screens carry the Nerd Font glyphs U+F09B and U+E0B0, so a capture shows whether
  /// the bundled face renders them. The agent screen sets them in a powerline segment
  /// beside bold, italic and bold italic words.
  static func fixtureScreen(for pane: Pane?) -> String {
    guard let pane else { return "" }
    let directory = pane.directory ?? "~"
    guard let agent = pane.agent else {
      return ["\u{F09B} main \u{E0B0} $ cd \(directory)", "$ swift build", "Build complete.", "$ "]
        .joined(separator: "\n")
    }

    let message: String
    let continuation: String
    switch agent.status {
    case .blocked:
      message = "Two workers want the machine at once. Should I hold the second one?"
      continuation = "Say go and I'll queue it behind the first."
    case .done:
      message = "Done — the suite is green and the branch is pushed."
      continuation = "Nothing else is waiting on you here."
    case .error:
      message = "The build failed and I stopped there."
      continuation = "The log is above."
    case .working:
      message = "Running the tests now; the first build is cold so it will be a while."
      continuation = "I'll say something when it lands."
    case .idle, .unknown:
      message = "Ready when you are."
      continuation = "Nothing in flight."
    }

    let rule = String(repeating: "─", count: 44)
    return [
      "\u{1B}[0m\u{1B}[38;5;7m⏺ \u{1B}[0mReading \(directory)",
      "\u{1B}[0m\u{1B}[38;5;7m  ⎿  2 files read on\u{1B}[0m \u{1B}[44;97m main \u{1B}[0;34m\u{E0B0}\u{1B}[0m "
        + "\u{F09B}git \u{1B}[1mbold\u{1B}[0m \u{1B}[3mitalic\u{1B}[0m \u{1B}[1;3mboth\u{1B}[0m",
      "",
      "\u{1B}[0m\u{1B}[38;5;15m⏺ \u{1B}[0m\(message)",
      "  \(continuation)",
      "",
      "\u{1B}[0m\u{1B}[38;5;7m\(rule)\u{1B}[0m",
      "\u{1B}[0m\u{1B}[38;5;7m❯\u{A0}\u{1B}[0m",
      "\u{1B}[0m\u{1B}[38;5;7m\(rule)\u{1B}[0m",
    ].joined(separator: "\n")
  }

  /// Every pane action this fake was asked to perform, in order.
  ///
  /// A refused action is recorded and not acted on.
  public private(set) var performed: [(action: PaneAction, paneID: String)] = []

  /// Performs the action on the fake's own tree, so the next `snapshot()` shows it as
  /// herdr would. A recording-only fake could not catch a UI that claims a change the
  /// tree does not show. Splitting invents the new pane's id; see
  /// `tree(_:splittingPane:)`.
  public func perform(_ action: PaneAction, on paneID: String) async throws {
    performed.append((action, paneID))
    if let failure { throw failure }

    switch action {
    case .close:
      tree = Self.tree(tree, removingPane: paneID)
    case .rename(let label):
      tree = Self.tree(tree, renamingPane: paneID, to: label)
    case .split:
      // The fake invents the new pane's id deterministically, as it stands in for herdr.
      tree = Self.tree(tree, splittingPane: paneID)
    }
    // Stop the script, or the next poll undoes this.
    scriptOverridden = true
  }

  /// Every workspace or tab rename this fake was asked for, in order.
  ///
  /// Its own list, because `performed` holds pane ids and a workspace id there would read
  /// as a missing pane.
  public private(set) var renamed: [(target: RenameTarget, label: String)] = []

  /// Renames the container *in the fake's own tree*, not just recording it.
  ///
  /// The next `snapshot()` shows the new label. See `perform`.
  public func rename(_ target: RenameTarget, to label: String) async throws {
    renamed.append((target, label))
    if let failure { throw failure }
    tree = Self.tree(tree, renaming: target, to: label)
    // Stop the script, as in `perform`.
    scriptOverridden = true
  }

  /// One workspace or one tab, relabelled, with everything else left alone.
  ///
  /// **A renamed tab stops being auto-named**, as in herdr. `Workspace.tabHeaderStyle`
  /// hides a lone auto-named tab, so otherwise the new name would be drawn nowhere.
  private static func tree(
    _ tree: SessionTree,
    renaming target: RenameTarget,
    to label: String
  ) -> SessionTree {
    SessionTree(
      workspaces: tree.workspaces.map { workspace in
        let tabs = workspace.tabs.map { tab in
          guard target == .tab(id: tab.id) else { return tab }
          return Tab(
            id: tab.id,
            workspaceID: tab.workspaceID,
            number: tab.number,
            label: label,
            isFocused: tab.isFocused,
            status: tab.status,
            isAutoNamed: false,
            panes: tab.panes
          )
        }
        return Workspace(
          id: workspace.id,
          number: workspace.number,
          label: target == .workspace(id: workspace.id) ? label : workspace.label,
          isFocused: workspace.isFocused,
          status: workspace.status,
          tabs: tabs
        )
      },
      focusedPaneID: tree.focusedPaneID
    )
  }

  private static func tree(_ tree: SessionTree, removingPane paneID: String) -> SessionTree {
    mapPanes(tree) { $0.id == paneID ? nil : $0 }
  }

  private static func tree(
    _ tree: SessionTree,
    renamingPane paneID: String,
    to label: String
  ) -> SessionTree {
    mapPanes(tree) { pane in
      guard pane.id == paneID else { return pane }
      return Pane(
        id: pane.id,
        tabID: pane.tabID,
        workspaceID: pane.workspaceID,
        title: label,
        agent: pane.agent,
        terminalID: pane.terminalID,
        directory: pane.directory,
        isFocused: pane.isFocused,
        viewportRows: pane.viewportRows
      )
    }
  }

  /// The pane a split makes, beside the one it was split from.
  ///
  /// The id counts the panes already in the tree, so splits are deterministic. It carries
  /// a terminal id like the seed's, because the scene attaches to the new pane at once.
  private static func tree(_ tree: SessionTree, splittingPane paneID: String) -> SessionTree {
    guard let source = tree.pane(id: paneID) else { return tree }
    let id = "\(source.workspaceID):p\(tree.allPanes.count + 1)"
    let new = Pane(
      id: id,
      tabID: source.tabID,
      workspaceID: source.workspaceID,
      title: "shell",
      terminalID: "term_\(id.replacingOccurrences(of: ":", with: ""))",
      directory: source.directory
    )
    return rebuild(tree) { $0.id == paneID ? [$0, new] : [$0] }
  }

  /// Every pane passed through `transform`, dropping the ones it returns `nil` for.
  private static func mapPanes(
    _ tree: SessionTree,
    _ transform: (Pane) -> Pane?
  ) -> SessionTree {
    rebuild(tree) { pane in transform(pane).map { [$0] } ?? [] }
  }

  /// Rebuilds the tree with every pane passed through `transform`, which may drop it,
  /// keep it, or put another one beside it.
  ///
  /// Recomputes the roll-ups, which is herdr's job and so this fake's. `SnapshotMapper`
  /// must not derive them. Without this, closing the only blocked pane would leave a
  /// blocked badge on its tab.
  private static func rebuild(
    _ tree: SessionTree,
    _ transform: (Pane) -> [Pane]
  ) -> SessionTree {
    SessionTree(
      workspaces: tree.workspaces.map { workspace in
        let tabs = workspace.tabs.map { tab in
          let panes = tab.panes.flatMap(transform)
          return Tab(
            id: tab.id,
            workspaceID: tab.workspaceID,
            number: tab.number,
            label: tab.label,
            isFocused: tab.isFocused,
            status: rollUp(panes),
            isAutoNamed: tab.isAutoNamed,
            panes: panes
          )
        }
        return Workspace(
          id: workspace.id,
          number: workspace.number,
          label: workspace.label,
          isFocused: workspace.isFocused,
          status: rollUp(tabs.flatMap(\.panes)),
          tabs: tabs
        )
      },
      focusedPaneID: tree.focusedPaneID
    )
  }

  /// The most urgent agent state under a set of panes, or `nil` when none of them has an
  /// agent, as herdr reports for a container of plain shells.
  private static func rollUp(_ panes: [Pane]) -> AgentStatus? {
    panes.compactMap { $0.agent?.status }
      .min { $0.sortPriority < $1.sortPriority }
  }

  // MARK: - The seed

  /// The session the demo, the tests, and the screenshots all see.
  ///
  /// Chosen to exercise what is easy to get wrong: a blocked agent that is not first in
  /// herdr's order, two shell panes with no agent (the common case), a `done` agent, and
  /// three workspaces so collapsing has something to do.
  ///
  /// Roll-ups are written out, as herdr sends them: `nil` on `w1:t2`, which holds only a
  /// shell. Pane ids, count and order are asserted by several test classes.
  public static let seededTree = SessionTree(
    workspaces: [
      Workspace(
        id: "w1",
        number: 1,
        label: "driverr",
        isFocused: true,
        status: .blocked,
        tabs: [
          Tab(
            id: "w1:t1",
            workspaceID: "w1",
            number: 1,
            label: "app",
            isFocused: true,
            status: .blocked,
            panes: [
              Pane(
                id: "w1:p1",
                tabID: "w1:t1",
                workspaceID: "w1",
                title: "terminal wiring",
                agent: Agent(name: "Claude", kind: "claude", status: .working),
                terminalID: "term_w1p1",
                directory: "~/dev/driverr",
                isFocused: true
              ),
              Pane(
                id: "w1:p2",
                tabID: "w1:t1",
                workspaceID: "w1",
                title: "needs a decision",
                // The only pane with a session reference, so views can draw the
                // "reported by herdr" tier. Most real panes have none.
                agent: Agent(
                  name: "Claude",
                  kind: "claude",
                  status: .blocked,
                  session: AgentSession(
                    agent: "claude",
                    kind: "id",
                    value: "3f8c1d20-0000-4000-8000-000000000002",
                    source: "herdr:claude"
                  )
                ),
                terminalID: "term_w1p2",
                directory: "~/dev/driverr"
              ),
            ]
          ),
          Tab(
            id: "w1:t2",
            workspaceID: "w1",
            number: 2,
            label: "tests",
            panes: [
              // No agent: a plain shell.
              Pane(
                id: "w1:p3",
                tabID: "w1:t2",
                workspaceID: "w1",
                title: "swift test",
                terminalID: "term_w1p3",
                directory: "~/dev/driverr/DriverrKit"
              )
            ]
          ),
        ]
      ),
      Workspace(
        id: "w2",
        number: 2,
        label: "tower",
        status: .idle,
        tabs: [
          Tab(
            id: "w2:t1",
            workspaceID: "w2",
            number: 1,
            label: "api",
            status: .idle,
            panes: [
              Pane(
                id: "w2:p1",
                tabID: "w2:t1",
                workspaceID: "w2",
                title: "schema sync",
                // An agent with no transcript reader, the third state a pane screen draws.
                // `PaneSurfaceSwitchTests`, `PaneChatUITests` and `PaneComposerUITests`
                // reach it by this pane's id, title and workspace.
                agent: Agent(name: "Gemini", kind: "gemini", status: .idle),
                terminalID: "term_w2p1",
                directory: "~/dev/tower"
              )
            ]
          )
        ]
      ),
      Workspace(
        id: "w3",
        number: 3,
        label: "wiki",
        status: .done,
        tabs: [
          Tab(
            id: "w3:t1",
            workspaceID: "w3",
            number: 1,
            label: "notes",
            status: .done,
            panes: [
              Pane(
                id: "w3:p1",
                tabID: "w3:t1",
                workspaceID: "w3",
                title: "index rebuild",
                // Codex with no `AgentSession`, so it resolves by its own `cwd`, the usual
                // Codex case.
                agent: Agent(name: "Codex", kind: "codex", status: .done),
                terminalID: "term_w3p1",
                directory: "~/wiki"
              ),
              Pane(
                id: "w3:p2",
                tabID: "w3:t1",
                workspaceID: "w3",
                title: "wiki",
                terminalID: "term_w3p2",
                directory: "~/wiki/site"
              ),
            ]
          )
        ]
      ),
    ],
    focusedPaneID: "w1:p1"
  )

  /// The seeded session, then the same session with a second agent blocked.
  ///
  /// A UI test watches the second badge appear without a refresh.
  public static let blockingScript: [SessionTree] = [seededTree, treeWithSecondBlockedPane]

  /// `seededTree` with `w1:p2`, the pane every chat test opens, missing.
  ///
  /// herdr can omit a live pane from one poll. Then `TerminalSceneModel.currentPane` is
  /// `nil`, `TerminalScreen.isShowingChat` is false, and the chat leaves `paneSurfaces`
  /// until the next poll.
  public static let treeWithoutTheBlockedPane: SessionTree = mapPanes(seededTree) { pane in
    pane.id == "w1:p2" ? nil : pane
  }

  /// `treeWithoutTheBlockedPane` with `w2:p1`'s Gemini failed, so nothing is blocked and one
  /// pane wears the `error` badge.
  public static let treeWithAFailedAgent: SessionTree = mapPanes(treeWithoutTheBlockedPane) {
    pane in
    guard pane.id == "w2:p1", let agent = pane.agent else { return pane }
    return Pane(
      id: pane.id,
      tabID: pane.tabID,
      workspaceID: pane.workspaceID,
      title: pane.title,
      agent: Agent(name: agent.name, kind: agent.kind, status: .error, session: agent.session),
      terminalID: pane.terminalID,
      directory: pane.directory,
      isFocused: pane.isFocused,
      viewportRows: pane.viewportRows
    )
  }

  /// A pane that vanishes for exactly one poll and comes back.
  ///
  /// At `SessionModel.defaultPollInterval` the drop lands about twelve seconds after the
  /// connect, once the chat has settled. The last entry repeats, so the pane stays back.
  public static let vanishingPaneScript: [SessionTree] = [
    seededTree, seededTree, seededTree, seededTree, treeWithoutTheBlockedPane, seededTree,
  ]

  /// `seededTree` with `w2:p1`'s Gemini flipped from idle to blocked.
  ///
  /// An agent pane, because only an agent can be blocked.
  public static let treeWithSecondBlockedPane: SessionTree = mapPanes(
    seededTree, blockingSchemaSync)

  /// `w2:p1`'s agent blocked, and every other pane as it was.
  private static func blockingSchemaSync(_ pane: Pane) -> Pane {
    guard pane.id == "w2:p1", let agent = pane.agent else { return pane }
    return Pane(
      id: pane.id,
      tabID: pane.tabID,
      workspaceID: pane.workspaceID,
      title: pane.title,
      agent: Agent(name: agent.name, kind: agent.kind, status: .blocked, session: agent.session),
      terminalID: pane.terminalID,
      directory: pane.directory,
      isFocused: pane.isFocused,
      viewportRows: pane.viewportRows
    )
  }

  /// The App Store tour's session: `seededTree` with eight more panes and a fourth
  /// workspace, so the pane switcher's grid is full on an iPad.
  ///
  /// The seed's panes keep their ids, titles and order, and none of the new ones can block,
  /// so the tour's Needs You list is the seed's. Fourteen panes: driverr 4, tower 4, wiki 3
  /// and docs 3, which fill four columns on the iPad's page-sized sheet.
  public static let storeTourTree: SessionTree = {
    func pane(
      _ id: String, _ title: String, _ agent: Agent? = nil, in tab: String,
      at directory: String
    ) -> Pane {
      Pane(
        id: id,
        tabID: tab,
        workspaceID: String(id.prefix { $0 != ":" }),
        title: title,
        agent: agent,
        terminalID: "term_\(id.replacingOccurrences(of: ":", with: ""))",
        directory: directory
      )
    }
    // Each list goes after the seed pane it is keyed by, in the seed pane's tab.
    let added: [String: [Pane]] = [
      "w1:p3": [pane("w1:p4", "lint", in: "w1:t2", at: "~/dev/driverr")],
      "w2:p1": [
        pane(
          "w2:p2", "migrations", Agent(name: "Claude", kind: "claude", status: .working),
          in: "w2:t1", at: "~/dev/tower"),
        pane("w2:p3", "api server", in: "w2:t1", at: "~/dev/tower"),
        pane(
          "w2:p4", "load test", Agent(name: "Codex", kind: "codex", status: .done),
          in: "w2:t1", at: "~/dev/tower/bench"),
      ],
      "w3:p2": [
        pane(
          "w3:p3", "link check", Agent(name: "Claude", kind: "claude", status: .idle),
          in: "w3:t1", at: "~/wiki")
      ],
    ]
    let docs = Workspace(
      id: "w4",
      number: 4,
      label: "docs",
      tabs: [
        Tab(
          id: "w4:t1",
          workspaceID: "w4",
          number: 1,
          label: "site",
          panes: [
            pane(
              "w4:p1", "release notes", Agent(name: "Claude", kind: "claude", status: .working),
              in: "w4:t1", at: "~/dev/docs"),
            pane("w4:p2", "site preview", in: "w4:t1", at: "~/dev/docs"),
            pane(
              "w4:p3", "style pass", Agent(name: "Gemini", kind: "gemini", status: .done),
              in: "w4:t1", at: "~/dev/docs"),
          ]
        )
      ]
    )
    let grown = SessionTree(
      workspaces: seededTree.workspaces + [docs], focusedPaneID: seededTree.focusedPaneID)
    // Rebuilt, so the roll-ups count the new panes as herdr's would.
    return rebuild(grown) { [$0] + (added[$0.id] ?? []) }
  }()

  /// `storeTourTree`, then the same with `w2:p1` blocked, as `blockingScript` does for the
  /// seed. The tour waits for both blocked panes.
  public static let storeTourScript: [SessionTree] = [
    storeTourTree, mapPanes(storeTourTree, blockingSchemaSync),
  ]

  /// `seededTree` with `w1:p1`'s Claude idle instead of working.
  ///
  /// Paired with `seededTree` it gives an idle to working transition while the reader
  /// rests at the end of the chat. The working row then arrives just under the fold,
  /// inside `ChatEndProximity.jumpTolerance`, so no jump control appears. `w1:p1` is the
  /// pane whose chat the UI tests open.
  public static let treeWithIdleAgent: SessionTree = mapPanes(seededTree) { pane in
    guard pane.id == "w1:p1", let agent = pane.agent else { return pane }
    return Pane(
      id: pane.id,
      tabID: pane.tabID,
      workspaceID: pane.workspaceID,
      title: pane.title,
      agent: Agent(name: agent.name, kind: agent.kind, status: .idle, session: agent.session),
      terminalID: pane.terminalID,
      directory: pane.directory,
      isFocused: pane.isFocused,
      viewportRows: pane.viewportRows
    )
  }

  /// A pane showing Claude Code's `AskUserQuestion` picker, with nothing about it in the
  /// session file.
  ///
  /// A real `pane read --format ansi` capture. Claude Code writes the question to the
  /// session file only once it is answered, so the screen is the only source.
  public static let askUserQuestionScreen = PaneScreen.sanitised(
    [
      "\u{1B}[0m\u{1B}[38;5;7m\u{1B}[48;5;8m❯ \u{1B}[0m\u{1B}[38;5;15m\u{1B}[48;5;8mUse the AskUserQuestion tool to ask me one single-select question \"Pick a fruit\" with header \"Fruit\" and options \u{1B}[0m\u{1B}[48;5;8m     \u{1B}[0m",
      "\u{1B}[0m\u{1B}[48;5;8m  \u{1B}[0m\u{1B}[38;5;15m\u{1B}[48;5;8mApple, Banana, Cherry, each with a short description. Do nothing else.\u{1B}[0m\u{1B}[48;5;8m                                                \u{1B}[0m",
      "\u{1B}[0m\u{1B}[38;5;7m────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────\u{1B}[0m",
      "\u{1B}[0m\u{1B}[38;5;0m\u{1B}[48;5;12m ☐ Fruit \u{1B}[0m",
      "",
      "\u{1B}[0m\u{1B}[1m\u{1B}[38;5;15mPick a fruit\u{1B}[0m",
      "",
      "\u{1B}[0m\u{1B}[38;5;12m❯ \u{1B}[0m\u{1B}[38;5;7m1. \u{1B}[0m\u{1B}[38;5;12mApple\u{1B}[0m",
      "     \u{1B}[0m\u{1B}[38;5;7mA crisp, sweet red or green fruit\u{1B}[0m",
      "  \u{1B}[0m\u{1B}[38;5;7m2.\u{1B}[0m Banana",
      "     \u{1B}[0m\u{1B}[38;5;7mA soft, creamy yellow tropical fruit\u{1B}[0m",
      "  \u{1B}[0m\u{1B}[38;5;7m3.\u{1B}[0m Cherry",
      "     \u{1B}[0m\u{1B}[38;5;7mA small, tart red stone fruit\u{1B}[0m",
      "  \u{1B}[0m\u{1B}[38;5;7m4. Type something.\u{1B}[0m",
      "\u{1B}[0m\u{1B}[38;5;7m────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────\u{1B}[0m",
      "  5. Chat about this",
      "",
      "\u{1B}[0m\u{1B}[38;5;7mEnter to select · ↑/↓ to navigate · Esc to cancel\u{1B}[0m",
    ].joined(separator: "\n"),
    lines: PaneScreen.maximumLines
  )

  /// `seededTree` with `w1:p2`'s Claude reported working while its conversation ends on a
  /// question.
  ///
  /// herdr classifies by pane output, so its status can lag the session file. Every other
  /// tree reports this pane blocked. The session reference is kept so the chat resolves.
  public static let treeWithAWorkingAsker: SessionTree = mapPanes(seededTree) { pane in
    guard pane.id == "w1:p2", let agent = pane.agent else { return pane }
    return Pane(
      id: pane.id,
      tabID: pane.tabID,
      workspaceID: pane.workspaceID,
      title: pane.title,
      agent: Agent(name: agent.name, kind: agent.kind, status: .working, session: agent.session),
      terminalID: pane.terminalID,
      directory: pane.directory,
      isFocused: pane.isFocused,
      viewportRows: pane.viewportRows
    )
  }

  /// `seededTree` with `w1:p2`'s Claude never yet spoken to, with no `agent_session`.
  ///
  /// Its chat resolves `.noSessionFiles`. The pane stays blocked, as a new Claude on its
  /// trust prompt reports.
  public static let treeWithUnstartedAgent: SessionTree = mapPanes(seededTree) { pane in
    guard pane.id == "w1:p2", let agent = pane.agent else { return pane }
    return Pane(
      id: pane.id,
      tabID: pane.tabID,
      workspaceID: pane.workspaceID,
      title: pane.title,
      agent: Agent(name: agent.name, kind: agent.kind, status: agent.status, session: nil),
      terminalID: pane.terminalID,
      directory: pane.directory,
      isFocused: pane.isFocused,
      viewportRows: pane.viewportRows
    )
  }

  /// `seededTree` with `w1:p2`'s Claude reporting a new session whose file is not written
  /// yet.
  ///
  /// Claude Code writes the file with the first prompt. The directory holds an older
  /// session, so the chat resolves `.reportedSessionMissing`. The pane is idle, as an
  /// unprompted session is, and the chat draws the wait.
  public static let treeWithUnwrittenSession = unwrittenSession(status: .idle)

  /// `treeWithUnwrittenSession` with the agent working. A working agent has had its first
  /// prompt, so the chat draws the fault instead of the wait.
  public static let treeWithUnwrittenSessionWorking = unwrittenSession(status: .working)

  private static func unwrittenSession(status: AgentStatus) -> SessionTree {
    mapPanes(seededTree) { pane in
      guard pane.id == "w1:p2", let agent = pane.agent, let session = agent.session else {
        return pane
      }
      return Pane(
        id: pane.id,
        tabID: pane.tabID,
        workspaceID: pane.workspaceID,
        title: pane.title,
        agent: Agent(
          name: agent.name, kind: agent.kind, status: status,
          session: AgentSession(
            agent: session.agent,
            kind: session.kind,
            value: "5d6e7f80-0000-4000-8000-000000000003",
            source: session.source
          )
        ),
        terminalID: pane.terminalID,
        directory: pane.directory,
        isFocused: pane.isFocused,
        viewportRows: pane.viewportRows
      )
    }
  }

  /// A session big enough that collapsing it is the point.
  ///
  /// Thirteen panes across four workspaces, for previews of collapsing. Nothing asserts on
  /// it, so it may grow.
  public static let crowdedTree: SessionTree = {
    func pane(
      _ id: String,
      _ title: String,
      _ agent: Agent? = nil,
      in tab: String,
      of workspace: String,
      at directory: String
    ) -> Pane {
      Pane(
        id: id,
        tabID: tab,
        workspaceID: workspace,
        title: title,
        agent: agent,
        terminalID: "term_\(id.replacingOccurrences(of: ":", with: "_"))",
        directory: directory
      )
    }
    func tab(
      _ id: String,
      _ label: String,
      of workspace: String,
      number: Int,
      panes: [Pane]
    ) -> Tab {
      Tab(
        id: id,
        workspaceID: workspace,
        number: number,
        label: label,
        status: rollUp(panes),
        panes: panes
      )
    }

    let driverr = [
      tab(
        "c1:t1", "app", of: "c1", number: 1,
        panes: [
          pane("c1:p1", "terminal wiring", Agent(name: "Claude", kind: "claude", status: .working), in: "c1:t1", of: "c1", at: "~/dev/driverr"),
          pane("c1:p2", "needs a decision", Agent(name: "Claude", kind: "claude", status: .blocked), in: "c1:t1", of: "c1", at: "~/dev/driverr"),
          pane("c1:p3", "swift test", in: "c1:t1", of: "c1", at: "~/dev/driverr/DriverrKit"),
          pane("c1:p4", "screenshots", Agent(name: "Codex", kind: "codex", status: .idle), in: "c1:t1", of: "c1", at: "~/dev/driverr/docs"),
        ]
      ),
      tab(
        "c1:t2", "tests", of: "c1", number: 2,
        panes: [
          pane("c1:p5", "xcodebuild", in: "c1:t2", of: "c1", at: "~/dev/driverr"),
          pane("c1:p6", "simulator log", in: "c1:t2", of: "c1", at: "~/dev/driverr/.build-logs"),
        ]
      ),
      tab(
        "c1:t3", "release", of: "c1", number: 3,
        panes: [
          pane("c1:p7", "metadata push", Agent(name: "Claude", kind: "claude", status: .done), in: "c1:t3", of: "c1", at: "~/dev/driverr/docs/appstore")
        ]
      ),
    ]
    let tower = [
      tab(
        "c2:t1", "api", of: "c2", number: 1,
        panes: [
          pane("c2:p1", "schema sync", Agent(name: "Codex", kind: "codex", status: .working), in: "c2:t1", of: "c2", at: "~/dev/tower"),
          pane("c2:p2", "migrations", Agent(name: "Claude", kind: "claude", status: .blocked), in: "c2:t1", of: "c2", at: "~/dev/tower/db"),
          pane("c2:p3", "psql", in: "c2:t1", of: "c2", at: "~/dev/tower"),
        ]
      )
    ]
    let wiki = [
      tab(
        "c3:t1", "notes", of: "c3", number: 1,
        panes: [
          pane("c3:p1", "index rebuild", Agent(name: "Claude", kind: "claude", status: .done), in: "c3:t1", of: "c3", at: "~/wiki"),
          pane("c3:p2", "wiki", in: "c3:t1", of: "c3", at: "~/wiki/site"),
        ]
      )
    ]
    let scratch = [
      tab("c4:t1", "shell", of: "c4", number: 1, panes: [
        pane("c4:p1", "zsh", in: "c4:t1", of: "c4", at: "~")
      ])
    ]

    func workspace(_ id: String, _ label: String, number: Int, focused: Bool = false, tabs: [Tab])
      -> Workspace
    {
      Workspace(
        id: id,
        number: number,
        label: label,
        isFocused: focused,
        status: rollUp(tabs.flatMap(\.panes)),
        tabs: tabs
      )
    }

    return SessionTree(
      workspaces: [
        workspace("c1", "driverr", number: 1, focused: true, tabs: driverr),
        workspace("c2", "tower", number: 2, tabs: tower),
        workspace("c3", "wiki", number: 3, tabs: wiki),
        workspace("c4", "scratch", number: 4, tabs: scratch),
      ],
      focusedPaneID: "c1:p1"
    )
  }()

  /// A session with nothing in it: herdr running, but no workspaces yet.
  ///
  /// Not a failure: the sidebar renders its own empty view.
  public static let emptyTree = SessionTree.empty
}
#endif
