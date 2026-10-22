import DriverrCore
import DriverrTranscript
import Foundation
import Testing

@testable import Driverr

/// The app-level transcript plumbing, with no host and no simulator behind it.
///
/// `TranscriptReader` is driven by a `CommandRunner` closure, so everything here runs against
/// canned answers. This covers what `DriverrTranscript` does not own: when to fetch, how often,
/// and what the screen sees while a fetch is in flight. The pane's chat and the Needs you row
/// depend on it, and getting it wrong re-reads a large file on every three-second poll.
@MainActor
@Suite("PaneTranscriptModel", .timeLimit(.minutes(1)))
struct PaneTranscriptModelTests {
  // MARK: - A host that answers

  /// One session file, fresh, in the directory the pane's `cwd` derives.
  private func host(
    files: [(name: String, age: Int)] = [("a1b2.jsonl", 12)],
    records: [String] = [Records.human("ship it"), Records.assistant("shipping.")],
    endsMidRecord: Bool = false,
    fileSize: Int? = nil,
    onCommand: (@Sendable (String) -> Void)? = nil,
    refusals: Switch? = nil,
    subagentMetas: [String] = [],
    subagentListFails: Bool = false
  ) -> @Sendable (String) async throws -> CommandResult {
    let directory = "/Users/x/.claude/projects/-Users-x-Dev-driverr"
    let body = records.joined(separator: "\n") + (records.isEmpty ? "" : "\n")
    let listing =
      (["1000000000", directory]
      + files.map { "\(1_000_000_000 - $0.age)\t\(body.utf8.count)\t\($0.name)" })
      .joined(separator: "\n") + "\n"
    let page =
      "\(fileSize ?? body.utf8.count)\t\(endsMidRecord ? "partial" : "complete")\n" + body
    return { command in
      onCommand?(command)
      if refusals?.isOn == true {
        return CommandResult(standardOutput: "", standardError: "boom", exitStatus: 1)
      }
      // The sub-agent list, before the listing, because it also asks for `date +%s`.
      if command.contains("*.meta.json") {
        guard !subagentListFails else {
          return CommandResult(standardOutput: "", standardError: "boom", exitStatus: 1)
        }
        let lines = subagentMetas.enumerated().map { index, meta in
          "999999000\t999999990\t100\tagent-a\(index).jsonl\t\(meta)"
        }
        let answer = (["1000000000", "\(directory)/a1b2/subagents", "#\(subagentMetas.count)"] + lines)
          .joined(separator: "\n") + "\n"
        return CommandResult(standardOutput: answer, standardError: "", exitStatus: 0)
      }
      if command.contains("date +%s") {
        return CommandResult(standardOutput: listing, standardError: "", exitStatus: 0)
      }
      // The growth check. Fixed, because this file never changes, the case where the watcher
      // must spend nothing but the probe.
      if command.contains("stat -c %Y") {
        return CommandResult(
          standardOutput: "999999988\t\(body.utf8.count)\n", standardError: "", exitStatus: 0)
      }
      return CommandResult(standardOutput: page, standardError: "", exitStatus: 0)
    }
  }

  private func pane(
    agent: Agent? = Agent(name: "Claude", kind: "claude", status: .blocked),
    directory: String? = "/Users/x/Dev/driverr"
  ) -> Pane {
    Pane(
      id: "w1:p2",
      tabID: "w1:t1",
      workspaceID: "w1",
      title: "needs a decision",
      agent: agent,
      terminalID: "term_w1p2",
      directory: directory
    )
  }

  /// The page, and the sub-agent list a landed page starts, so a count at the runner
  /// includes both.
  private func settled(_ model: PaneTranscriptModel) async {
    await model.currentLoad?.value
    await model.subagentListLoad?.value
  }

  // MARK: - What the reader opened

  /// Which runs are open lives on the model, because the surface switch tears `PaneChatView`
  /// down and an opened run has to still be open on the way back.
  ///
  /// `OpenToolRuns` covers the rule in `swift test`. This adds that a run's identity, taken
  /// from the file's own records, is stable across a real fetch, parse and fetch.
  @Test("a re-read of the same file keeps an opened run open")
  func anOpenedRunSurvivesAReread() async {
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(
        run: host(
          records: [
            Records.human("make the pool async"),
            Records.tools([("Read", "pool.rs"), ("Bash", "cargo test")]),
          ]
        )
      )
    )

    model.loadIfNeeded()
    await settled(model)
    guard let run = model.transcript?.turns.first(where: { $0.toolRun != nil }) else {
      Issue.record("Expected a run of tool calls in the page, got \(model.state)")
      return
    }
    model.openRuns.toggle(run)
    #expect(model.openRuns.isOpen(run))

    model.reload()
    await settled(model)
    guard let reread = model.transcript?.turns.first(where: { $0.toolRun != nil }) else {
      Issue.record("Expected the run again after a re-read, got \(model.state)")
      return
    }
    #expect(reread.id == run.id)
    #expect(model.openRuns.isOpen(reread))
  }

  // MARK: - Loading

  @Test("a resolved pane loads its turns and says where the file came from")
  func loadsTurnsAndProvenance() async {
    let model = PaneTranscriptModel(pane: pane(), reader: TranscriptReader(run: host()))

    model.loadIfNeeded()
    await settled(model)

    guard case .ready(let source, let transcript) = model.state else {
      Issue.record("Expected a loaded transcript, got \(model.state)")
      return
    }
    #expect(source.provenance == .matchedByDirectory)
    #expect(transcript.turns.count == 2)
    #expect(transcript.lastAssistantMessage == "shipping.")
  }

  /// The Needs you row reads exactly this, so it has its own name.
  @Test("the agent's last words are reachable without unwrapping the state")
  func lastAssistantMessageIsReachable() async {
    let model = PaneTranscriptModel(pane: pane(), reader: TranscriptReader(run: host()))

    model.loadIfNeeded()
    await settled(model)

    #expect(model.lastAssistantMessage == "shipping.")
  }

  /// The host screen polls every three seconds and calls this from a row body. A re-fetch
  /// here would re-read a session file twenty times a minute per blocked pane.
  @Test("twenty loads cost exactly one fetch")
  func loadIsIdempotent() async {
    let commands = Counter()
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(run: host(onCommand: { _ in commands.bump() }))
    )

    model.loadIfNeeded()
    await settled(model)
    let afterFirst = commands.value
    // A model that refetched every time would settle into the same `.ready` state, so only
    // the count at the runner can tell.
    for _ in 0..<20 { model.loadIfNeeded() }
    await settled(model)

    #expect(afterFirst > 0)
    #expect(commands.value == afterFirst)
  }

  /// A load owned by a view's `.task(id:)` is cancelled when the identity changes, which a
  /// poll can do, and a model left in `.loading` with no task behind it never leaves. So the
  /// model owns its task.
  @Test("the load survives the view that asked for it")
  func loadIsOwnedByTheModel() async {
    let model = PaneTranscriptModel(pane: pane(), reader: TranscriptReader(run: host()))

    // Exactly what a `.task` would do to it, from outside.
    let asker = Task { model.loadIfNeeded() }
    asker.cancel()
    _ = await asker.value
    await settled(model)

    #expect(model.transcript?.turns.count == 2)
  }

  /// Cancellation is cooperative, and nothing under `TranscriptReader` checks it.
  ///
  /// `invalidate()` cancels the in-flight task, but a load suspended in `resolve` or `read`
  /// still runs to completion and would write its verdict after the state went back to
  /// `.idle`. The thrown-away page would come back, the next `loadIfNeeded()` would no-op until
  /// something else invalidates, and `reload()` could land a stale `.ready` over a fresh
  /// `.failed`.
  @Test("a load cancelled in flight does not land after the invalidation")
  func aCancelledLoadDoesNotOverwriteIdle() async {
    let gate = Gate()
    let commands = Counter()
    let answer = host(onCommand: { _ in commands.bump() })
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(run: { command in
        await gate.wait()
        return try await answer(command)
      })
    )

    model.loadIfNeeded()
    // Captured before invalidating, which nils it, so the assertions run after the cancelled
    // load has finished rather than after a guessed interval.
    let cancelled = model.currentLoad
    model.invalidate()
    // Only now does the host answer, to a task already told to stop.
    await gate.open()
    await cancelled?.value

    #expect(model.state == .idle)

    // The next load fetches, rather than finding a page the cancelled task put back.
    let beforeSecond = commands.value
    model.loadIfNeeded()
    await settled(model)
    #expect(commands.value > beforeSecond)
    #expect(model.transcript?.turns.count == 2)
  }

  @Test("invalidating lets the next load fetch again")
  func invalidateAllowsARefetch() async {
    let commands = Counter()
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(run: host(onCommand: { _ in commands.bump() }))
    )

    model.loadIfNeeded()
    await settled(model)
    let afterFirst = commands.value
    model.invalidate()
    model.loadIfNeeded()
    await settled(model)

    #expect(commands.value == afterFirst * 2)
  }

  // MARK: - Every sub-agent the session spawned

  private static let explore =
    #"{"agentType":"Explore","description":"Find the callers","toolUseId":"toolu_1","finished":true}"#

  @Test("the session's sub-agents are listed after its page lands, from its own directory")
  func theListFollowsThePage() async {
    let log = SubagentCommandLog()
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(
        run: host(onCommand: { log.record($0) }, subagentMetas: [Self.explore])))
    model.loadIfNeeded()
    await settled(model)

    #expect(model.transcript != nil)
    #expect(model.subagentList.total == 1)
    #expect(model.subagentList.summaries.first?.pageLink == .toolUse(id: "toolu_1"))
    let asked = log.commands.filter { $0.contains("*.meta.json") }
    #expect(asked.count == 1)
    #expect(asked.first?.contains("-Users-x-Dev-driverr/a1b2/subagents") == true)
  }

  /// The growth probe re-reads the page every few seconds while the agent writes. The list
  /// must not ride along on each one.
  @Test("a re-read inside the list's staleness does not ask for the list again")
  func theListIsNotReaskedOnEveryRead() async {
    let log = SubagentCommandLog()
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(
        run: host(onCommand: { log.record($0) }, subagentMetas: [Self.explore])))
    model.loadIfNeeded()
    await settled(model)
    model.refresh()
    await settled(model)
    model.refresh()
    await settled(model)

    #expect(log.commands.filter { $0.contains("*.meta.json") }.count == 1)
  }

  /// A spawn is the moment the list changes, so a page that gains one must not wait out the
  /// staleness that holds back every other re-read.
  @Test("a page that gains a spawn line asks for the list again inside the staleness")
  func aNewSpawnRefetchesTheList() async {
    let pages = MutablePages(records: [
      Records.human("ship it", uuid: "u1"), Records.assistant("shipping.", uuid: "a1"),
    ])
    let log = SubagentCommandLog()
    let run = growingHost(pages)
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(run: { command in
        log.record(command)
        return try await run(command)
      }))
    model.loadIfNeeded()
    await settled(model)
    #expect(log.commands.filter { $0.contains("*.meta.json") }.count == 1)

    pages.append(Records.spawn(description: "Find the callers", id: "toolu_s1", uuid: "s1"))
    model.refresh()
    await settled(model)

    #expect(model.transcript?.turns.contains { $0.agentEvent?.kind == .spawned } == true)
    #expect(log.commands.filter { $0.contains("*.meta.json") }.count == 2)
  }

  @Test("a list the host refuses leaves the page on screen and no list")
  func aFailedListKeepsThePage() async {
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(run: host(subagentMetas: [Self.explore], subagentListFails: true)))
    model.loadIfNeeded()
    await settled(model)

    #expect(model.transcript?.turns.count == 2)
    #expect(model.subagentList.isEmpty)
  }

  @Test("invalidating drops the list with the page")
  func invalidateDropsTheList() async {
    let model = PaneTranscriptModel(
      pane: pane(), reader: TranscriptReader(run: host(subagentMetas: [Self.explore])))
    model.loadIfNeeded()
    await settled(model)
    #expect(!model.subagentList.isEmpty)

    model.invalidate()
    #expect(model.subagentList.isEmpty)
  }

  // MARK: - Everything that is not a conversation

  /// A shell pane never reaches the chat surface, but the resolver still answers for one
  /// and the model must carry that answer rather than throwing it away.
  @Test("a pane with no agent is unavailable rather than empty")
  func paneWithNoAgentIsUnavailable() async {
    let model = PaneTranscriptModel(
      pane: pane(agent: nil),
      reader: TranscriptReader(run: host())
    )

    model.loadIfNeeded()
    await settled(model)

    #expect(model.state == .unavailable(.absent(.paneHasNoAgent)))
    #expect(model.transcript == nil)
  }

  /// Gemini, because the claim needs an agent this build cannot read; which one does not
  /// matter.
  @Test("an agent Driverr cannot read is named rather than fetched")
  func unsupportedAgentIsNotFetched() async {
    let commands = Counter()
    let model = PaneTranscriptModel(
      pane: pane(agent: Agent(name: "Gemini", kind: "gemini", status: .blocked)),
      reader: TranscriptReader(run: host(onCommand: { _ in commands.bump() }))
    )

    model.loadIfNeeded()
    await settled(model)

    #expect(model.state == .unavailable(.absent(.agentNotSupported(agent: "Gemini"))))
    // Not one round trip: there is nothing on the far side worth asking for.
    #expect(commands.value == 0)
  }

  /// Two live files in one directory. The resolver refuses, and the model carries the
  /// refusal through so the picker has the candidates to list.
  @Test("an ambiguous directory arrives with its candidates intact")
  func ambiguityCarriesItsCandidates() async {
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(run: host(files: [("a.jsonl", 4), ("b.jsonl", 21)]))
    )

    model.loadIfNeeded()
    await settled(model)

    guard case .unavailable(.ambiguous(_, let candidates)) = model.state else {
      Issue.record("Expected ambiguity, got \(model.state)")
      return
    }
    #expect(candidates.map(\.name) == ["a.jsonl", "b.jsonl"])
  }

  // MARK: - Choosing a file by hand, and how long the choice lasts

  /// A host serving two live sessions, each with its own opening line.
  ///
  /// One closure rather than a `FakeTranscriptHost`: what is proven is when the model asks and
  /// what it keeps, and a fixture that assembled the records would prove the fixture.
  private func ambiguousHost(
    files: [(name: String, age: Int)] = [("mine.jsonl", 4), ("theirs.jsonl", 21)],
    briefs: [(name: String, line: String)] = [
      ("mine.jsonl", "review the diff on the focus branch"),
      ("theirs.jsonl", "start on the pane-focus bug"),
    ],
    onCommand: (@Sendable (String) -> Void)? = nil
  ) -> @Sendable (String) async throws -> CommandResult {
    let directory = "/Users/x/.claude/projects/-Users-x-Dev-driverr"
    let listing =
      (["1000000000", directory]
      + files.map { "\(1_000_000_000 - $0.age)\t4096\t\($0.name)" }).joined(separator: "\n")
      + "\n"
    let briefOutput =
      briefs.map { "\($0.name)\t\(Records.human($0.line))" }.joined(separator: "\n") + "\n"
    return { command in
      onCommand?(command)
      if command.contains("date +%s") {
        return CommandResult(standardOutput: listing, standardError: "", exitStatus: 0)
      }
      if command.contains("FNR>") {
        return CommandResult(standardOutput: briefOutput, standardError: "", exitStatus: 0)
      }
      // A read: the file named in the command is the one that answers, so a pick that
      // resolved the wrong file would show the wrong conversation here.
      let said = command.contains("theirs.jsonl") ? "theirs" : "mine"
      let body = Records.assistant(said) + "\n"
      return CommandResult(
        standardOutput: "\(body.utf8.count)\tcomplete\n" + body,
        standardError: "",
        exitStatus: 0
      )
    }
  }

  /// A pick resolves that file, and the header credits the choice rather than calling it a
  /// match.
  @Test("picking a file reads it and credits the pick")
  func pickingAFileCreditsIt() async {
    let model = PaneTranscriptModel(pane: pane(), reader: TranscriptReader(run: ambiguousHost()))
    model.loadIfNeeded()
    await settled(model)
    guard case .unavailable(.ambiguous(let directory, let candidates)) = model.state else {
      Issue.record("Expected ambiguity, got \(model.state)")
      return
    }

    model.choose(candidates[1], in: directory)
    await settled(model)

    #expect(model.source?.file.name == "theirs.jsonl")
    #expect(model.source?.provenance == .chosenByHand)
    #expect(model.transcript?.lastAssistantMessage == "theirs")
  }

  /// A pick is re-applied against a fresh listing on every read, so it survives re-reading.
  /// It is held on this model, which the connection caches per pane id, so a poll, a surface
  /// switch or navigating away and back does not reach it.
  @Test("a pick survives re-reading the directory")
  func aPickSurvivesAReRead() async {
    let model = PaneTranscriptModel(pane: pane(), reader: TranscriptReader(run: ambiguousHost()))
    model.loadIfNeeded()
    await settled(model)
    guard case .unavailable(.ambiguous(let directory, let candidates)) = model.state else {
      Issue.record("Expected ambiguity, got \(model.state)")
      return
    }
    model.choose(candidates[1], in: directory)
    await settled(model)

    model.reload()
    await settled(model)

    #expect(model.source?.file.name == "theirs.jsonl")
    #expect(model.source?.provenance == .chosenByHand)
  }

  /// A pick stops the moment its file leaves the directory. It falls back to the refusal,
  /// not to the newest file.
  @Test("a pick whose file went away is dropped, and the refusal comes back")
  func aPickDoesNotOutliveItsFile() async {
    let model = PaneTranscriptModel(pane: pane(), reader: TranscriptReader(run: ambiguousHost()))
    model.loadIfNeeded()
    await settled(model)
    guard case .unavailable(.ambiguous(let directory, let candidates)) = model.state else {
      Issue.record("Expected ambiguity, got \(model.state)")
      return
    }
    model.choose(candidates[1], in: directory)
    await settled(model)
    #expect(model.pick != nil)

    // The same pane, a directory that no longer holds the file somebody chose.
    let after = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(
        run: ambiguousHost(files: [("mine.jsonl", 4), ("later.jsonl", 6)]))
    )
    after.choose(candidates[1], in: directory)
    await settled(after)

    #expect(after.pick == nil)
    #expect(after.source == nil)
    guard case .unavailable(.ambiguous) = after.state else {
      Issue.record("Expected the refusal back, got \(after.state)")
      return
    }
  }

  /// The refusal lists filenames and mtimes the listing already carried, so the opening lines
  /// cost a round trip only when somebody opens the picker.
  @Test("the opening lines are read when the picker is opened, and only once")
  func briefsAreReadLazilyAndOnce() async {
    let asked = Counter()
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(
        run: ambiguousHost(onCommand: { if $0.contains("FNR>") { asked.bump() } }))
    )
    model.loadIfNeeded()
    await settled(model)

    #expect(asked.value == 0)
    #expect(model.briefs.isEmpty)

    model.loadBriefsIfNeeded()
    model.loadBriefsIfNeeded()
    await model.briefLoad?.value

    #expect(asked.value == 1)
    #expect(model.briefs["mine.jsonl"] == "review the diff on the focus branch")
    #expect(model.briefs["theirs.jsonl"] == "start on the pane-focus bug")
  }

  /// A host refusing the opening lines must not stop anybody picking. The rows fall back to
  /// the filename and the mtime.
  @Test("a host that cannot answer the opening lines does not block the picker")
  func briefsThatFailDoNotBlockThePick() async {
    // The same host, with the one command that reads opening lines refused outright.
    let answering = ambiguousHost()
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(run: { command in
        if command.contains("FNR>") {
          return CommandResult(standardOutput: "", standardError: "no awk", exitStatus: 127)
        }
        return try await answering(command)
      })
    )
    model.loadIfNeeded()
    await settled(model)
    model.loadBriefsIfNeeded()
    await model.briefLoad?.value

    #expect(model.briefs.isEmpty)
    guard case .unavailable(.ambiguous(let directory, let candidates)) = model.state else {
      Issue.record("Expected ambiguity, got \(model.state)")
      return
    }
    // Every candidate still has a row, drawn from what the listing already carried.
    let picker = TranscriptPicker(directory: directory, candidates: candidates, briefs: model.briefs)
    #expect(picker.candidates.count == 2)
    #expect(picker.candidates.allSatisfy { $0.title == TranscriptCandidate.noOpeningLine })

    model.choose(candidates[0], in: directory)
    await settled(model)
    #expect(model.source?.provenance == .chosenByHand)
  }

  /// A file that parses to nothing is a loaded transcript with an outcome, not a failure,
  /// which would put an SSH error on a file that read perfectly.
  @Test("a file with no readable turns is loaded, not failed")
  func noReadableTurnsIsLoaded() async {
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(run: host(records: []))
    )

    model.loadIfNeeded()
    await settled(model)

    #expect(model.transcript?.outcome == .noReadableTurns)
  }

  @Test("a host that refuses the read is a failure the screen can retry")
  func aRefusedReadIsAFailure() async {
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(run: { _ in
        CommandResult(standardOutput: "", standardError: "denied\n", exitStatus: 1)
      })
    )

    model.loadIfNeeded()
    await settled(model)

    guard case .failed = model.state else {
      Issue.record("Expected a failure, got \(model.state)")
      return
    }
  }

  // MARK: - The cache

  /// One fetch per pane for the life of the link, shared by every screen that asks, which is
  /// why the cache is on the connection.
  @Test("two consumers asking for the same pane get the same model")
  func theCacheIsSharedPerPane() {
    let cache = PaneTranscriptCache(reader: TranscriptReader(run: host()))

    let first = cache.model(for: pane())
    let second = cache.model(for: pane())

    #expect(first === second)
  }

  @Test("a different pane gets a different model")
  func differentPanesAreNotShared() {
    let cache = PaneTranscriptCache(reader: TranscriptReader(run: host()))
    let other = Pane(id: "w1:p1", tabID: "w1:t1", workspaceID: "w1", title: "other")

    #expect(cache.model(for: pane()) !== cache.model(for: other))
  }

  /// A poll hands out a new `Pane` value every three seconds, with the same id and possibly a
  /// different status. Rebuilding on that would throw the fetch away twenty times a minute.
  @Test("a re-polled pane with the same id reuses its model")
  func aRepolledPaneReusesItsModel() {
    let cache = PaneTranscriptCache(reader: TranscriptReader(run: host()))
    let working = Pane(
      id: "w1:p2",
      tabID: "w1:t1",
      workspaceID: "w1",
      title: "needs a decision",
      agent: Agent(name: "Claude", kind: "claude", status: .working)
    )

    #expect(cache.model(for: pane()) === cache.model(for: working))
  }

  /// A view holding an old `Pane` value, such as the Needs you row under a pushed pane
  /// screen, must not write it back over the model's pane, or the next re-read resolves the
  /// old session's file. The poll's diff is the one writer that reads the live tree.
  @Test("asking for a model with an older pane value does not rewind the model's pane")
  func aStalePaneValueDoesNotRewindTheModel() {
    let cache = PaneTranscriptCache(reader: TranscriptReader(run: host()))
    let model = cache.model(for: paneReporting(session: "new"))

    _ = cache.model(for: paneReporting(session: "old"))

    #expect(
      model.pane.agent?.session?.identifier == "new",
      "a view holding an old pane value rewound the model to session \(String(describing: model.pane.agent?.session?.identifier))"
    )
  }

  @Test("a model nobody made yet is not invented by asking whether one exists")
  func existingModelDoesNotCreate() {
    let cache = PaneTranscriptCache(reader: TranscriptReader(run: host()))

    #expect(cache.existingModel(for: "w1:p2") == nil)
    _ = cache.model(for: pane())
    #expect(cache.existingModel(for: "w1:p2") != nil)
  }

  // MARK: - Paging back through the file

  /// Paging preserves the scroll position, so a page in flight does not go through
  /// `.loading`, which takes the chat and the reader's place off screen. A separate flag
  /// carries the in-flight state.
  @Test("a page in flight leaves the conversation on screen")
  func pagingKeepsTheTranscriptUp() async throws {
    let model = PaneTranscriptModel(
      pane: pane(), reader: TranscriptReader(run: host(fileSize: 40_000_000)))
    model.loadIfNeeded()
    await settled(model)
    let before = try #require(model.transcript)

    model.loadMore()
    #expect(model.isPagingBack)
    #expect(model.transcript == before, "the page on screen must survive its own replacement")
    #expect(!model.isLoading, "paging must never route through .loading")

    await settled(model)
    #expect(!model.isPagingBack)
  }

  @Test("a page in flight cannot be re-entered")
  func pagingIsNotReentrant() async throws {
    let commands = Counter()
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(run: host(fileSize: 40_000_000, onCommand: { _ in commands.bump() })))
    model.loadIfNeeded()
    await settled(model)
    let afterFirstRead = commands.value

    model.loadMore()
    model.loadMore()
    model.loadMore()
    await settled(model)

    #expect(model.turnsWanted == TranscriptReader.defaultTurns + TranscriptPaging.defaultIncrement)
    #expect(
      commands.value < afterFirstRead * 3,
      "three taps while one page is in flight must not be three fetches")
  }

  @Test("paging asks the reader for more turns than the page it already holds")
  func pagingGrowsTheRequest() async throws {
    let model = PaneTranscriptModel(
      pane: pane(), reader: TranscriptReader(run: host(fileSize: 40_000_000)))
    model.loadIfNeeded()
    await settled(model)
    #expect(model.turnsWanted == TranscriptReader.defaultTurns)

    model.loadMore()
    await settled(model)
    #expect(model.turnsWanted == TranscriptReader.defaultTurns + TranscriptPaging.defaultIncrement)
  }

  /// A page that reaches the first record has nothing behind it, and calling anyway must not
  /// spend a round trip.
  @Test("paging is a no-op once the page reaches the start of the file")
  func pagingStopsAtTheStartOfTheFile() async throws {
    let commands = Counter()
    let model = PaneTranscriptModel(
      pane: pane(), reader: TranscriptReader(run: host(onCommand: { _ in commands.bump() })))
    model.loadIfNeeded()
    await settled(model)
    let paging = try #require(model.paging)
    #expect(paging.window.reachesStartOfFile, "the fixture is a whole small file")
    let afterFirstRead = commands.value

    model.loadMore()
    #expect(!model.isPagingBack)
    #expect(commands.value == afterFirstRead, "nothing behind the page, nothing to fetch")
  }

  @Test("the pager's figures are absent until there is a page to price")
  func noPagingValueBeforeAPage() {
    let model = PaneTranscriptModel(pane: pane(), reader: TranscriptReader(run: host()))
    #expect(model.paging == nil)
  }

  /// Throwing the page away throws its size away too, so the next read starts at a first page.
  @Test("invalidating resets the page size")
  func invalidateResetsTheRequest() async throws {
    let model = PaneTranscriptModel(
      pane: pane(), reader: TranscriptReader(run: host(fileSize: 40_000_000)))
    model.loadIfNeeded()
    await settled(model)
    model.loadMore()
    await settled(model)
    #expect(model.turnsWanted > TranscriptReader.defaultTurns)

    model.invalidate()
    #expect(model.turnsWanted == TranscriptReader.defaultTurns)
  }

  // MARK: - The parsed markdown that rides with the page

  /// `settle` parses, so a settled page carries one render per agent turn and none for turns
  /// drawn verbatim.
  @Test("a settled page carries a render for the agent's turns and nothing else")
  func settleWritesTheRender() async throws {
    let model = PaneTranscriptModel(
      pane: pane(), reader: TranscriptReader(run: host()))
    model.loadIfNeeded()
    await settled(model)

    let turns = try #require(model.transcript?.turns)
    let agentTurns = turns.filter(\.isAssistant)
    #expect(!agentTurns.isEmpty, "the fixture must contain something the agent said")
    for turn in agentTurns {
      #expect(model.render[turn.id]?.text == turn.text)
    }
    for turn in turns where turn.isHuman {
      #expect(model.render[turn.id] == nil, "what a person typed is drawn verbatim")
    }
  }

  /// The render is part of the page. A map left behind would hand the next conversation this
  /// one's parsed turns under any record ids they share.
  @Test("invalidate throws the render away with the page")
  func invalidateResetsTheRender() async throws {
    let model = PaneTranscriptModel(
      pane: pane(), reader: TranscriptReader(run: host()))
    model.loadIfNeeded()
    await settled(model)
    #expect(!model.render.isEmpty)

    model.invalidate()
    #expect(model.render.isEmpty, "the render belongs to the page it was built from")
  }

  /// `pageBack` writes `state` itself rather than through `settle`, so it has to rebuild the
  /// render too. Otherwise paged-in turns parse in the view body, and a newest turn that grew
  /// meanwhile, the ordinary case, draws stale text under the same record id.
  @Test("paging back rebuilds the render for the page it puts on screen")
  func pagingBackRefreshesTheRender() async throws {
    let pages = MutablePages(records: [
      Records.human("ship it", uuid: "u1"), Records.assistant("shipping.", uuid: "a1"),
    ])
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(
        run: growingHost(pages, behavior: GrowingHostBehavior(declaredPageSize: 40_000_000))))
    model.loadIfNeeded()
    await settled(model)
    let newest = try #require(model.transcript?.turns.last?.id)
    #expect(model.render[newest]?.text == "shipping.")

    // The agent wrote more while the reader was scrolling back. Same record, same id.
    pages.setRecords(
      for: "a1b2.jsonl",
      [
        Records.human("ship it", uuid: "u1"),
        Records.assistant("shipping. And here is the rest of it.", uuid: "a1"),
      ])
    model.loadMore()
    await settled(model)

    #expect(model.transcript?.turns.last?.id == newest, "the record id is what makes it stale")
    #expect(model.transcript?.turns.last?.text == "shipping. And here is the rest of it.")
    #expect(model.render[newest]?.text == "shipping. And here is the rest of it.")
  }

  // MARK: - Keeping the conversation current

  /// A host whose file grows between reads, and whose directory a test can add to. The fixed
  /// fixture above cannot show a re-read having done anything.
  ///
  /// `behavior` says what the fake answers for each command class: the probe (`stat -c %Y`),
  /// the listing (`date +%s`), and the page read (in practice `tail -c`).
  ///
  /// `failPageReads()` refuses only the page read. `refuseEverything()` fails the probe too,
  /// and a probe that answers `nil` leaves the baseline alone, so it cannot show a lost growth.
  ///
  /// `returnEmptyListings()` yields an `.unavailable` without failing the host: the listing
  /// exits 0 with no file rows, as a truncated stdout on a healthy link does.
  /// `refuseEverything()` would arrive as `.failed` instead.
  private func growingHost(
    _ pages: MutablePages,
    behavior: GrowingHostBehavior = GrowingHostBehavior()
  ) -> @Sendable (String) async throws -> CommandResult {
    let directory = "/Users/x/.claude/projects/-Users-x-Dev-driverr"
    return { command in
      let answers = behavior.current
      if command.contains("date +%s") {
        switch answers.listing {
        case .refused:
          return CommandResult(standardOutput: "", standardError: "boom", exitStatus: 1)
        case .empty:
          let listing = [String(1_000_000_000), directory].joined(separator: "\n") + "\n"
          return CommandResult(standardOutput: listing, standardError: "", exitStatus: 0)
        case .normal:
          // The size here has to match the probe's, or the baseline seeded from this listing
          // differs from the first tick and every tick re-reads the page.
          // `anUnchangedFileIsNotReRead` fails when they drift apart.
          let rows = pages.files.map { name in
            let size = (pages.records(for: name).joined(separator: "\n") + "\n").utf8.count
            return "999999988\t\(size)\t\(name)"
          }
          let listing =
            ([String(1_000_000_000), directory] + rows).joined(separator: "\n") + "\n"
          return CommandResult(standardOutput: listing, standardError: "", exitStatus: 0)
        }
      }
      let name = pages.files.first { command.contains($0) } ?? pages.files.first ?? ""
      let body = pages.records(for: name).joined(separator: "\n") + "\n"
      // The growth check, off the same records the page is built from, so an appended record
      // moves the probe as it moves the page.
      if command.contains("stat -c %Y") {
        if answers.probe == .refused {
          return CommandResult(standardOutput: "", standardError: "boom", exitStatus: 1)
        }
        // A probe for a missing file, as the host's `stat` answers it, rather than falling
        // back to the first file.
        if !pages.files.contains(where: { command.contains($0) }) {
          return CommandResult(standardOutput: "?\t?\n", standardError: "", exitStatus: 0)
        }
        return CommandResult(
          standardOutput: "999999988\t\(body.utf8.count)\n", standardError: "", exitStatus: 0)
      }
      if answers.pageRead == .refused {
        return CommandResult(standardOutput: "", standardError: "boom", exitStatus: 1)
      }
      // A declared size larger than what was fetched is what leaves something behind the
      // page, so `loadMore` is offered — the same trick `host(fileSize:)` uses.
      let page = "\(answers.declaredPageSize ?? body.utf8.count)\tcomplete\n" + body
      return CommandResult(standardOutput: page, standardError: "", exitStatus: 0)
    }
  }

  /// Between herdr taking a reply and the agent writing the turn, the conversation would look
  /// as it did before the person answered, and invite a second answer.
  @Test("a sent reply shows as a pending turn until the re-read finds it in the file")
  func aSentReplyIsEchoedUntilItLands() async {
    let pages = MutablePages(records: [Records.assistant("Proceed?", uuid: "a1")])
    let model = PaneTranscriptModel(
      pane: pane(), reader: TranscriptReader(run: growingHost(pages)))
    model.loadIfNeeded()
    await settled(model)
    #expect(model.transcript?.turns.count == 1)

    model.recordSend("yes, go ahead")
    #expect(model.pendingTurn?.text == "yes, go ahead")
    #expect(model.pendingTurn?.note == "Sent — not yet in the session file")
    await settled(model)

    // The file has not caught up, so the echo stands.
    #expect(model.pendingTurn?.text == "yes, go ahead")

    // Now it has.
    pages.append(Records.human("yes, go ahead", uuid: "u9"))
    model.refresh()
    await settled(model)

    #expect(model.pendingTurn == nil)
    #expect(model.transcript?.lastHumanMessage == "yes, go ahead")
  }

  /// The re-read must not blank the surface. `.loading` takes the conversation and the
  /// reader's place off screen, which is right only for a first fetch.
  @Test("a refresh keeps the page on screen while it runs")
  func aRefreshDoesNotBlankTheChat() async {
    let pages = MutablePages(records: [Records.assistant("Proceed?", uuid: "a1")])
    let model = PaneTranscriptModel(
      pane: pane(), reader: TranscriptReader(run: growingHost(pages)))
    model.loadIfNeeded()
    await settled(model)
    #expect(model.transcript != nil)

    model.refresh()

    #expect(model.transcript != nil, "the conversation stays up while the re-read runs")
    #expect(model.isRefreshing)
    #expect(!model.isLoading, "a re-read is not a spinner over an empty screen")
    await settled(model)
    #expect(!model.isRefreshing)
  }

  /// Same pane id, a new `agent_session` after a `/clear` or a restart. Resolving the old
  /// uuid would show the old conversation under a "reported by herdr" check.
  @Test("a pane whose session changed resolves the new file, not the old one")
  func aNewSessionResolvesTheNewFile() async {
    let pages = MutablePages(
      files: ["old.jsonl", "new.jsonl"],
      records: [Records.assistant("from the old session", uuid: "a1")]
    )
    pages.setRecords(for: "new.jsonl", [Records.assistant("from the new session", uuid: "a2")])
    let model = PaneTranscriptModel(
      pane: paneReporting(session: "old"),
      reader: TranscriptReader(run: growingHost(pages))
    )
    model.loadIfNeeded()
    await settled(model)
    #expect(model.transcript?.lastAssistantMessage == "from the old session")
    #expect(!model.hasMovedOn)

    model.update(to: paneReporting(session: "new"))

    #expect(model.hasMovedOn, "the page on screen is another conversation now")
    model.refresh()
    await settled(model)
    #expect(model.transcript?.lastAssistantMessage == "from the new session")
  }

  /// The same move, with nobody calling `refresh()`: the poll's diff can miss it, because its
  /// `refresh()` does nothing while a load is in flight. The watcher's next tick has to see
  /// the page is another conversation, rather than probe the old file and leave it up until
  /// `watchedStaleness`.
  @Test("a watcher tick re-resolves a page that was resolved for an older pane")
  func aTickReResolvesAMovedPane() async {
    let pages = MutablePages(
      files: ["old.jsonl", "new.jsonl"],
      records: [Records.assistant("from the old session", uuid: "a1")]
    )
    pages.setRecords(for: "new.jsonl", [Records.assistant("from the new session", uuid: "a2")])
    let model = PaneTranscriptModel(
      pane: paneReporting(session: "old"),
      reader: TranscriptReader(run: growingHost(pages))
    )
    model.loadIfNeeded()
    await settled(model)
    #expect(model.transcript?.lastAssistantMessage == "from the old session")

    model.update(to: paneReporting(session: "new"))
    await model.checkForGrowth()
    await settled(model)

    #expect(
      model.transcript?.lastAssistantMessage == "from the new session",
      "one tick after the pane moved, the chat still shows the old session")
  }

  /// A status change is not a reason to throw a page away. Only what decides which file
  /// counts.
  @Test("a poll that only changed the status leaves the page alone")
  func aStatusChangeIsNotAMove() async {
    let pages = MutablePages(records: [Records.assistant("Proceed?", uuid: "a1")])
    let model = PaneTranscriptModel(
      pane: pane(), reader: TranscriptReader(run: growingHost(pages)))
    model.loadIfNeeded()
    await settled(model)

    model.update(to: pane(agent: Agent(name: "Claude", kind: "claude", status: .working)))

    #expect(!model.hasMovedOn)
  }

  /// Appearing is a refresh trigger, and the bound is what stops a redrawing view paying
  /// for one every frame.
  @Test("appearing re-reads a stale page and leaves a fresh one alone")
  func appearanceRefreshesOnlyWhenStale() async {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let counter = Counter()
    let pages = MutablePages(records: [Records.assistant("Proceed?", uuid: "a1")])
    let inner = growingHost(pages)
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(run: { command in
        if !command.contains("date +%s") { counter.bump() }
        return try await inner(command)
      }),
      now: { clock.now }
    )
    model.loadIfNeeded()
    await settled(model)
    #expect(counter.value == 1)

    // Still fresh: appearing again costs nothing.
    clock.advance(by: 5)
    model.loadIfNeeded()
    await settled(model)
    #expect(counter.value == 1)

    clock.advance(by: PaneTranscriptModel.appearanceStaleness)
    model.loadIfNeeded()
    await settled(model)
    #expect(counter.value == 2)
  }

  /// An absence is not a permanent verdict. A pane whose agent just launched would otherwise
  /// say "the agent may not have written one yet" for the life of the connection.
  @Test("an absence is re-resolved rather than being the answer for the connection")
  func anAbsenceIsRetried() async {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let pages = MutablePages(files: [], records: [])
    let model = PaneTranscriptModel(
      pane: pane(), reader: TranscriptReader(run: growingHost(pages)), now: { clock.now })
    model.loadIfNeeded()
    await settled(model)
    #expect(
      model.state
        == .unavailable(.absent(.noSessionFiles(directory: "/Users/x/Dev/driverr"))))

    pages.addFile("a1b2.jsonl", records: [Records.assistant("here now", uuid: "a1")])
    clock.advance(by: PaneTranscriptModel.appearanceStaleness)
    model.loadIfNeeded()
    await settled(model)

    #expect(model.transcript?.lastAssistantMessage == "here now")
  }

  /// A restarted Claude Code reports its new session id at once but writes no file until its
  /// first prompt, 3 to 11 s later. The status flip the poll could catch lasts about a second,
  /// under the three-second poll, so one watcher tick after the file appears has to be enough.
  @Test("a reported session whose file arrives later is read on the next watcher tick")
  func aMissingReportedFileIsPickedUpOnTheNextTick() async {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let pages = MutablePages(
      files: ["old.jsonl"],
      records: [Records.assistant("from the old session", uuid: "a1")]
    )
    let model = PaneTranscriptModel(
      pane: paneReporting(session: "new"),
      reader: TranscriptReader(run: growingHost(pages)),
      now: { clock.now }
    )
    model.loadIfNeeded()
    await settled(model)
    #expect(
      model.state
        == .unavailable(
          .absent(.reportedSessionMissing(sessionID: "new", directory: "/Users/x/Dev/driverr"))))

    pages.addFile("new.jsonl", records: [Records.assistant("from the new session", uuid: "b1")])
    clock.advance(by: 3)
    await model.checkForGrowth()
    await settled(model)

    #expect(
      model.transcript?.lastAssistantMessage == "from the new session",
      """
      The new session's file exists and one watcher tick has passed, but the chat still \
      shows no page for it. State \(model.state)
      """)
  }

  /// The same start in a directory with no session file yet, which resolves to the neutral
  /// `noSessionFiles` rather than the missing-file warning.
  @Test("a reported session in an empty directory is read on the next watcher tick")
  func aReportedFileInAnEmptyDirectoryIsPickedUpOnTheNextTick() async {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let pages = MutablePages(files: [], records: [])
    let model = PaneTranscriptModel(
      pane: paneReporting(session: "new"),
      reader: TranscriptReader(run: growingHost(pages)),
      now: { clock.now }
    )
    model.loadIfNeeded()
    await settled(model)
    #expect(model.state == .unavailable(.absent(.noSessionFiles(directory: "/Users/x/Dev/driverr"))))

    pages.addFile("new.jsonl", records: [Records.assistant("from the new session", uuid: "b1")])
    clock.advance(by: 3)
    await model.checkForGrowth()
    await settled(model)

    #expect(
      model.transcript?.lastAssistantMessage == "from the new session",
      """
      The new session's file exists and one watcher tick has passed, but the chat still \
      shows no page for it. State \(model.state)
      """)
  }

  /// The price of the tests above. Until the agent writes its file, a tick asks about that
  /// file by name and does not re-list the directory.
  @Test("a reported session with no file yet costs the probe and no listing")
  func aMissingReportedFileCostsOnlyTheProbe() async {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let pages = MutablePages(
      files: ["old.jsonl"],
      records: [Records.assistant("from the old session", uuid: "a1")]
    )
    let probes = Counter()
    let listings = Counter()
    let inner = growingHost(pages)
    let model = PaneTranscriptModel(
      pane: paneReporting(session: "new"),
      reader: TranscriptReader(run: { command in
        if isProbe(command) { probes.bump() }
        if command.contains("date +%s") { listings.bump() }
        return try await inner(command)
      }),
      now: { clock.now }
    )
    model.loadIfNeeded()
    await settled(model)
    #expect(listings.value == 1, "the first listing is the load, not a tick")

    for _ in 0..<3 {
      clock.advance(by: 3)
      await model.checkForGrowth()
      await settled(model)
    }

    #expect(probes.value == 3, "each tick asks about the named file once")
    #expect(listings.value == 1, "a tick re-listed the directory for a file that is not there")
    #expect(
      model.state
        == .unavailable(
          .absent(.reportedSessionMissing(sessionID: "new", directory: "/Users/x/Dev/driverr"))))
  }

  /// A quiet re-read must not take a working page off the screen. Every refresh trigger is
  /// unsolicited, so a blip would replace the conversation with an unexplained error.
  @Test("a refresh that fails leaves the conversation that is already on screen")
  func aFailedRefreshKeepsThePage() async {
    let pages = MutablePages(records: [Records.assistant("Proceed?", uuid: "a1")])
    let behavior = GrowingHostBehavior()
    let model = PaneTranscriptModel(
      pane: pane(), reader: TranscriptReader(run: growingHost(pages, behavior: behavior)))
    model.loadIfNeeded()
    await settled(model)
    #expect(model.transcript != nil)

    behavior.refuseEverything()
    model.refresh()
    await settled(model)

    #expect(model.transcript?.lastAssistantMessage == "Proceed?")
    if case .failed = model.state { Issue.record("the page was replaced by a failure") }
  }

  /// The quiet-verdict guard covers `.unavailable` too. A listing with no file rows, from a
  /// truncated stdout on a healthy link, is not permanent, and must not put the refusal notice
  /// over a conversation somebody is reading.
  @Test("a quiet re-resolve that finds no file leaves the conversation on screen")
  func aQuietUnavailableKeepsThePage() async {
    let pages = MutablePages(records: [Records.assistant("Proceed?", uuid: "a1")])
    let behavior = GrowingHostBehavior()
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(run: growingHost(pages, behavior: behavior))
    )
    model.loadIfNeeded()
    await settled(model)
    #expect(model.transcript != nil)

    behavior.returnEmptyListings()
    model.refresh()
    await settled(model)

    #expect(model.transcript?.lastAssistantMessage == "Proceed?")
    if case .unavailable = model.state {
      Issue.record("a short listing replaced the page with \(model.state)")
    }
  }

  /// An `.unavailable` settles with `keepingPick: false`, so a guard placed below that line
  /// would keep the page but throw away the reader's pick, and re-offer the picker next time.
  @Test("a dropped unavailable keeps the file the reader picked by hand")
  func aQuietUnavailableKeepsThePick() async {
    let pages = MutablePages(
      files: ["mine.jsonl"], records: [Records.assistant("mine", uuid: "a1")])
    pages.addFile("theirs.jsonl", records: [Records.assistant("theirs", uuid: "a2")])
    let behavior = GrowingHostBehavior()
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(run: growingHost(pages, behavior: behavior))
    )
    model.loadIfNeeded()
    await settled(model)
    guard case .unavailable(.ambiguous(let directory, let candidates)) = model.state else {
      Issue.record("Expected ambiguity, got \(model.state)")
      return
    }
    model.choose(candidates[1], in: directory)
    await settled(model)
    #expect(model.source?.provenance == .chosenByHand)

    behavior.returnEmptyListings()
    model.refresh()
    await settled(model)

    #expect(model.source?.provenance == .chosenByHand, "the page they had is still on screen")
    #expect(model.pick != nil, "and the answer they gave is still the answer")
  }

  /// The refusal notice is right when somebody asked. `reload()` is `invalidate()` plus
  /// `start()`, so it is never quiet.
  @Test("a user-initiated re-read that finds no file still shows the notice")
  func anAskedForUnavailableStillReports() async {
    let pages = MutablePages(records: [Records.assistant("Proceed?", uuid: "a1")])
    let behavior = GrowingHostBehavior()
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(run: growingHost(pages, behavior: behavior))
    )
    model.loadIfNeeded()
    await settled(model)
    #expect(model.transcript != nil)

    behavior.returnEmptyListings()
    model.reload()
    await settled(model)

    #expect(
      model.state
        == .unavailable(.absent(.noSessionFiles(directory: "/Users/x/Dev/driverr"))))
  }

  /// A verdict resolved from different pane inputs is about a different conversation, so it
  /// replaces the page even quietly. A pane whose agent changed kind can never resolve the old
  /// file again.
  @Test("a quiet unavailable still replaces the page when the pane moved under it")
  func aMovedOnUnavailableStillReplaces() async {
    let pages = MutablePages(records: [Records.assistant("Proceed?", uuid: "a1")])
    let model = PaneTranscriptModel(
      pane: pane(), reader: TranscriptReader(run: growingHost(pages)))
    model.loadIfNeeded()
    await settled(model)
    #expect(model.transcript != nil)

    // See `unsupportedAgentIsNotFetched`.
    model.update(to: pane(agent: Agent(name: "Gemini", kind: "gemini", status: .blocked)))
    model.refresh()
    await settled(model)

    #expect(model.state == .unavailable(.absent(.agentNotSupported(agent: "Gemini"))))
  }

  /// A failure with nothing behind it still has to be reported, or the retry has no screen
  /// to live on.
  @Test("a refresh that fails with nothing on screen still reports the failure")
  func aFailedFetchOverNothingReports() async {
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(run: { _ in
        CommandResult(standardOutput: "", standardError: "boom", exitStatus: 1)
      })
    )
    model.loadIfNeeded()
    await settled(model)

    #expect(model.state == .failed(.transcriptUnreadable(reason: "boom")))
  }

  /// A failed page has to say so, or on a slow link the tap reads as doing nothing.
  @Test("a failed Load more keeps an error the control can show")
  func aFailedPageSaysSo() async {
    let refusals = Switch()
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(run: host(fileSize: 40_000_000, refusals: refusals))
    )
    model.loadIfNeeded()
    await settled(model)
    #expect(model.paging?.loadMore != nil)

    refusals.turnOn()
    model.loadMore()
    await settled(model)

    #expect(model.lastPagingError != nil)
    #expect(model.transcript != nil, "the page they had is still the page they have")

    refusals.turnOff()
    model.loadMore()
    #expect(model.lastPagingError == nil, "asking again clears the last complaint")
    await settled(model)
  }

  /// A reply that lands tells the composer, so its `Sent` notice can stop waiting.
  @Test("a re-read that gains a turn says so, and a re-read of the same tail does not")
  func advancingIsANewTurnNotTheSameTail() async {
    let pages = MutablePages(records: [Records.assistant("Proceed?", uuid: "a1")])
    let model = PaneTranscriptModel(
      pane: pane(), reader: TranscriptReader(run: growingHost(pages)))
    let advanced = Counter()
    model.onAdvanced = { _ in advanced.bump() }
    model.loadIfNeeded()
    await settled(model)
    let afterFirstRead = advanced.value

    model.refresh()
    await settled(model)
    #expect(advanced.value == afterFirstRead, "the same tail is not the conversation moving")

    pages.append(Records.assistant("Done.", uuid: "a2"))
    model.refresh()
    await settled(model)
    #expect(advanced.value == afterFirstRead + 1)
  }

  private func paneReporting(session: String) -> Pane {
    Pane(
      id: "w1:p2",
      tabID: "w1:t1",
      workspaceID: "w1",
      title: "needs a decision",
      agent: Agent(
        name: "Claude",
        kind: "claude",
        status: .blocked,
        session: AgentSession(agent: "claude", kind: "id", value: session)
      ),
      terminalID: "term_w1p2",
      directory: "/Users/x/Dev/driverr"
    )
  }

  // MARK: - What a refresh does to the turns already held

  /// The page is replaced wholesale, but its turns are keyed on the file's record uuids, so a
  /// page fetched twice keeps the ids of the turns already on screen, and the view diffs rather
  /// than rebuilding.
  @Test("a refresh that finds a new turn keeps the earlier turns' identities")
  func aRefreshKeepsEarlierTurnIdentities() async {
    let pages = MutablePages(records: [
      Records.human("ship it", uuid: "h1"), Records.assistant("Proceed?", uuid: "a1"),
    ])
    let model = PaneTranscriptModel(
      pane: pane(), reader: TranscriptReader(run: growingHost(pages)))
    model.loadIfNeeded()
    await settled(model)
    let held = model.transcript?.turns.map(\.id) ?? []

    pages.append(Records.assistant("Shipped.", uuid: "a2"))
    model.refresh()
    await settled(model)

    let after = model.transcript?.turns.map(\.id) ?? []
    #expect(after.count == held.count + 1)
    #expect(Array(after.prefix(held.count)) == held, "the earlier rows were rebuilt")
  }

  /// `aRefreshDoesNotBlankTheChat` samples `isLoading` once. This records every value `state`
  /// took, so a `.loading` gone before the fetch settled cannot hide between samples.
  /// `start()` is the only writer of `.loading`, and `refresh()` reaches it only from `.idle`.
  @Test("a refresh with turns already held never passes through .loading")
  func aRefreshNeverPassesThroughLoading() async {
    let pages = MutablePages(records: [Records.assistant("Proceed?", uuid: "a1")])
    let model = PaneTranscriptModel(
      pane: pane(), reader: TranscriptReader(run: growingHost(pages)))
    model.loadIfNeeded()
    await settled(model)
    #expect(model.transcript != nil)

    let log = StateLog(watching: model)
    pages.append(Records.assistant("Shipped.", uuid: "a2"))
    model.refresh()
    await settled(model)

    let seen = log.finish()
    #expect(
      !seen.contains(.loading),
      "the refresh blanked the surface; states written were \(seen)"
    )
    #expect(model.transcript?.turns.count == 2, "and it did pick the new turn up")

    // The instrument, proven on `reload()`, which blanks on purpose. Otherwise the assertion
    // above could be vacuous.
    let blanking = StateLog(watching: model)
    model.reload()
    await settled(model)
    #expect(
      blanking.finish().contains(.loading),
      "the recorder cannot see a .loading at all, so the assertion above proves nothing"
    )
  }

  /// Most re-reads answer with the page already on screen. Observation notifies on every
  /// write, not every change, so writing an identical page back would redraw the whole chat.
  /// Both properties the chat reads are tracked, because guarding only one leaves the redraw.
  @Test("a re-read that changed nothing writes neither state nor render")
  func anUnchangedRereadNotifiesNobody() async {
    let pages = MutablePages(records: [
      Records.human("ship it", uuid: "h1"), Records.assistant("Proceed?", uuid: "a1"),
    ])
    let model = PaneTranscriptModel(
      pane: pane(), reader: TranscriptReader(run: growingHost(pages)))
    model.loadIfNeeded()
    await settled(model)
    let before = model.state
    let renderBefore = model.render

    // Nothing is appended: a poll over a conversation nobody is writing.
    let log = StateLog(watching: model)
    model.refresh()
    await settled(model)

    #expect(log.changes == 0, "an unchanged re-read notified the chat \(log.changes) time(s)")
    #expect(model.state == before)
    #expect(model.render == renderBefore)
    // The re-read is still recorded. The guard is on what the chat draws.
    #expect(model.lastFetchedAt != nil)
    #expect(!model.isRefreshing)
  }

  /// The guard must not swallow a page that did move. It ignores the two clock readings on
  /// `TranscriptSource` and nothing else. A record that draws no turn still grows the file,
  /// and the header's `written … ago` is measured from the file.
  @Test("a file that grew without gaining a turn still settles")
  func aGrownFileWithNoNewTurnStillSettles() async {
    let pages = MutablePages(records: [
      Records.human("ship it", uuid: "h1"), Records.assistant("Proceed?", uuid: "a1"),
    ])
    let model = PaneTranscriptModel(
      pane: pane(), reader: TranscriptReader(run: growingHost(pages)))
    model.loadIfNeeded()
    await settled(model)
    let turnsBefore = model.transcript?.turns.map(\.id) ?? []

    // No `message`, so the parser counts it and makes no turn of it.
    let log = StateLog(watching: model)
    pages.append(#"{"type":"file-history-snapshot","uuid":"s1"}"#)
    model.refresh()
    await settled(model)

    #expect(model.transcript?.turns.map(\.id) == turnsBefore, "no turn was added")
    #expect(log.changes > 0, "the page grew and the surface was not told")
  }

  /// Every turn is parsed once, in `settle`, and reuse is keyed on id and text, so an earlier
  /// turn comes back with exactly the render it had.
  @Test("a refresh that gains a turn keeps every earlier render entry")
  func aRefreshKeepsEarlierRenders() async {
    let pages = MutablePages(records: [
      Records.human("ship it", uuid: "h1"),
      Records.assistant("Proceed? **Yes** or no.", uuid: "a1"),
      Records.assistant("Some `context` first.", uuid: "a2"),
    ])
    let model = PaneTranscriptModel(
      pane: pane(), reader: TranscriptReader(run: growingHost(pages)))
    model.loadIfNeeded()
    await settled(model)
    let heldIDs = model.transcript?.turns.map(\.id) ?? []
    let heldRenders = heldIDs.map { model.render[$0] }
    #expect(heldRenders.compactMap { $0 }.count == 2, "the two assistant turns were parsed")

    pages.append(Records.assistant("Shipped.", uuid: "a3"))
    model.refresh()
    await settled(model)

    for (id, render) in zip(heldIDs, heldRenders) {
      #expect(model.render[id] == render, "the render for \(id) was rebuilt")
    }
    #expect(model.render["a3"]?.text == "Shipped.", "and the new turn was parsed")
  }

  // MARK: - The run-spanning id caveat

  /// Why reads are whole pages, not appends.
  ///
  /// A run of tool calls takes the id of the record that opened it, so a run the page boundary
  /// cut carries the id of its first record inside the window. An append-only path would draw
  /// the cut half and the whole run under two ids. A whole-page read replaces both.
  ///
  /// The host honours the record bound in the read command, so a boundary can be placed.
  @Test("a run cut by the page boundary resolves to one turn after the wider read")
  func aBoundaryCutRunResolvesToOneTurn() async {
    // The tail is `TranscriptReader`'s 60-record floor and begins at the run's second record,
    // so the first page opens the run at `t2` and sees two of its three calls.
    let padding = (0..<57).map { Records.assistant("step \($0).", uuid: "p\($0)") }
    let file =
      [
        Records.tools([("Read", "pool.rs")], uuid: "t1"),
        Records.tools([("Edit", "pool.rs")], uuid: "t2"),
        Records.tools([("Bash", "cargo test")], uuid: "t3"),
        Records.assistant("Done.", uuid: "d1"),
      ] + padding
    let model = PaneTranscriptModel(
      pane: pane(), reader: TranscriptReader(run: recordBoundedHost(file)))

    model.loadIfNeeded()
    await settled(model)
    guard let cut = model.transcript?.turns.first(where: { $0.toolRun != nil }) else {
      Issue.record("Expected a run of tool calls in the first page, got \(model.state)")
      return
    }
    #expect(cut.id == "t2", "the boundary cut the run, so it opens at the record inside it")
    #expect(cut.toolRun?.count == 2)
    #expect(model.paging?.loadMore != nil, "there is more file behind this page")

    model.loadMore()
    await settled(model)

    let runs = model.transcript?.turns.filter { $0.toolRun != nil } ?? []
    #expect(runs.count == 1, "the wider read drew the run twice")
    #expect(runs.first?.id == "t1", "and it is now the whole run, opened at its first record")
    #expect(runs.first?.toolRun?.count == 3)
  }

  // MARK: - Watching the file grow

  /// `ConnectionModel.apply` refreshes only panes whose status, session id, agent kind or
  /// directory moved, so an agent that stays `working` while it appends turns triggers
  /// nothing. The watcher is what re-reads for a reader sitting still.
  ///
  /// Nothing here touches the model but the watcher, so a tick is the only thing that can
  /// produce the new turn.
  @Test("a file that grows while the chat is open is re-read with no user action")
  func growthIsPickedUpWithoutTheReader() async {
    let pages = MutablePages(records: [Records.assistant("Proceed?", uuid: "a1")])
    let model = PaneTranscriptModel(
      pane: pane(), reader: TranscriptReader(run: growingHost(pages)))
    model.loadIfNeeded()
    await settled(model)
    #expect(model.transcript?.turns.count == 1)

    // Ten milliseconds rather than the phone's three seconds: the claim is that ticks re-read
    // a grown file, not the cadence.
    let watcher = Task { await model.watch(every: .milliseconds(10)) }
    defer { watcher.cancel() }

    pages.append(Records.assistant("The pool is async now.", uuid: "a2"))

    await waitUntil("the watcher never put the agent's new turn on the page") {
      model.transcript?.turns.last?.text == "The pool is async now."
    }
    #expect(
      model.transcript?.turns.last?.text == "The pool is async now.",
      """
      The agent wrote a turn while the chat was open and it never reached the page. \
      State \(model.state)
      """)
  }

  /// A file nobody has written to costs the probe and nothing else. The probe count stops a
  /// loop that never ran from passing.
  @Test("an unchanged file costs the probe and no page read at all")
  func anUnchangedFileIsNotReRead() async {
    let pages = MutablePages(records: [Records.assistant("Proceed?", uuid: "a1")])
    let probes = Counter()
    let pageReads = Counter()
    let inner = growingHost(pages)
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(run: { command in
        if isProbe(command) { probes.bump() }
        if command.contains("tail -c") { pageReads.bump() }
        return try await inner(command)
      })
    )
    model.loadIfNeeded()
    await settled(model)
    #expect(pageReads.value == 1, "the first read is the load, not a tick")
    let fetchedAt = model.lastFetchedAt

    let watcher = Task { await model.watch(every: .milliseconds(10)) }
    defer { watcher.cancel() }
    // Waited for by the probe count, which `Counter.bump()` signals, not by a clock.
    await waitUntil("the watcher never reached four probes") { probes.value >= 4 }
    watcher.cancel()
    await watcher.value

    #expect(probes.value >= 4, "the watcher never ticked, so nothing below means anything")
    #expect(
      pageReads.value == 1,
      "an unchanged file cost \(pageReads.value - 1) page reads over \(probes.value) ticks")
    #expect(model.lastFetchedAt == fetchedAt, "the page was settled again for nothing")
  }

  /// The growth baseline belongs to the page that landed: `settle` seeds it from the `.ready`
  /// it wrote. If the tick moved the baseline before a fire-and-forget `refresh()`, a failed
  /// read would be dropped quietly and the next tick would see no growth, leaving the chat a
  /// turn behind until the file grew again. A failing read is re-attempted once per tick.
  ///
  /// The refusal is aimed at the page read alone; see `growingHost`.
  @Test("a page read that fails does not swallow the growth that asked for it")
  func aFailedPageReadStillRetries() async {
    let pages = MutablePages(records: [Records.assistant("Proceed?", uuid: "a1")])
    let behavior = GrowingHostBehavior()
    let probes = Counter()
    let inner = growingHost(pages, behavior: behavior)
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(run: { command in
        if isProbe(command) { probes.bump() }
        return try await inner(command)
      })
    )
    model.loadIfNeeded()
    await settled(model)
    #expect(model.transcript?.turns.count == 1)

    let watcher = Task { await model.watch(every: .milliseconds(10)) }
    defer { watcher.cancel() }

    // The link goes bad before the file grows: every probe from here answers with the grown
    // size and every page read is refused.
    behavior.failPageReads()
    pages.append(Records.assistant("The pool is async now.", uuid: "a2"))

    let atGrowth = probes.value
    await waitUntil("the watcher never ticked over the failing read") {
      probes.value >= atGrowth + 3
    }
    #expect(
      probes.value >= atGrowth + 3,
      "the watcher never ticked over the failing read, so nothing below means anything")
    #expect(
      model.transcript?.turns.count == 1,
      "the refused read put a turn on screen it could not have fetched")

    // The link comes back and nothing further is written, so recovery has to come from the
    // watcher re-attempting the read.
    behavior.allowPageReads()

    await waitUntil("the re-attempted read never landed the turn it lost") {
      model.transcript?.turns.last?.text == "The pool is async now."
    }
    #expect(
      model.transcript?.turns.last?.text == "The pool is async now.",
      """
      A page read failed and took the growth with it: the baseline had already moved to the \
      size the failed read was fetching, so no later tick saw the file as changed and the \
      chat stayed a turn behind. State \(model.state)
      """)
  }

  /// `PaneChatView` runs the loop from a `.task` keyed on the pane and the scene being active,
  /// so cancellation is the only way out. A loop that outlived its `.task` would leave one poll
  /// per chat ever opened running against the link.
  @Test("cancelling the task stops the watcher")
  func theLoopStopsOnCancel() async {
    let pages = MutablePages(records: [Records.assistant("Proceed?", uuid: "a1")])
    let probes = Counter()
    let inner = growingHost(pages)
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(run: { command in
        if isProbe(command) { probes.bump() }
        return try await inner(command)
      })
    )
    model.loadIfNeeded()
    await settled(model)

    let watcher = Task { await model.watch(every: .milliseconds(10)) }
    await waitUntil("the watcher never ticked twice") { probes.value >= 2 }
    watcher.cancel()
    await watcher.value
    let atCancel = probes.value
    #expect(atCancel >= 2, "the watcher never ticked, so cancelling it proves nothing")

    // A file that grows after the cancel: a running loop would probe and re-read.
    pages.append(Records.assistant("and again", uuid: "a2"))
    let kept = await settles(within: 0.5) { probes.value > atCancel }

    #expect(!kept, "the watcher went on probing after its task was cancelled")
    #expect(model.transcript?.turns.count == 1, "a cancelled watcher re-read the file")
  }

  /// Gives something that must not happen its chance to, and expires on purpose.
  ///
  /// The one wait a wall clock is right for. Expiry is the passing outcome, so a slow machine
  /// makes it hold rather than fail, and no signal means "nothing further arrived". Never use
  /// it to wait for something that should happen; use `waitUntil`.
  private func settles(within seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
  }

  /// A host that honours the read command's own record bound, so a page boundary can be put
  /// where a test wants one.
  ///
  /// `readCommand` ends its selector with `tail -n <records>`, which the other fakes ignore.
  /// The count is read out of the command, so paging moves the boundary as it does on a host.
  private func recordBoundedHost(
    _ records: [String]
  ) -> @Sendable (String) async throws -> CommandResult {
    let directory = "/Users/x/.claude/projects/-Users-x-Dev-driverr"
    let size = (records.joined(separator: "\n") + "\n").utf8.count
    return { command in
      if command.contains("date +%s") {
        let listing = [String(1_000_000_000), directory, "999999988\t\(size)\ta1b2.jsonl"]
          .joined(separator: "\n") + "\n"
        return CommandResult(standardOutput: listing, standardError: "", exitStatus: 0)
      }
      let bound = recordBound(in: command) ?? records.count
      let body = records.suffix(bound).joined(separator: "\n") + "\n"
      // The declared size is the whole file, so a bounded page leaves something for
      // `loadMore`.
      let page = "\(size)\tcomplete\n" + body
      return CommandResult(standardOutput: page, standardError: "", exitStatus: 0)
    }
  }

}

/// Whether this is the growth check rather than another command that carries a `stat` or a
/// `wc`.
///
/// The listing runs `stat -c %Y` too, so matching that counts the load's own resolve as a
/// probe. The read opens `f=` as well. The growth check is the one command that opens `f=`
/// and reads no byte tail.
///
/// File scope for `recordBound`'s reason.
private func isProbe(_ command: String) -> Bool {
  command.hasPrefix("f=") && !command.contains("tail -c")
}

/// The `N` in the read command's `tail -n N`.
///
/// File scope rather than a member: the suite is `@MainActor`, and the host closure it is
/// called from is `@Sendable` and runs wherever `TranscriptReader` runs it.
private func recordBound(in command: String) -> Int? {
  guard let range = command.range(of: "tail -n ") else { return nil }
  let digits = command[range.upperBound...].prefix { $0.isNumber }
  return Int(digits)
}

/// Every value `PaneTranscriptModel.state` took while this was watching.
///
/// `onChange` runs before the write lands, so it reads the value being replaced, and a
/// `.loading` the model passed through shows up. `finish()` adds the final value.
///
/// Re-armed inside `onChange` because `withObservationTracking` fires once. Both properties
/// `PaneChatView` reads are tracked, so `changes` counts every redraw the chat would get.
@MainActor
private final class StateLog {
  private let model: PaneTranscriptModel
  private(set) var values: [PaneTranscriptModel.State] = []
  /// How many times the chat was notified. Zero for a re-read that changed nothing.
  private(set) var changes = 0

  init(watching model: PaneTranscriptModel) {
    self.model = model
    arm()
  }

  func finish() -> [PaneTranscriptModel.State] { values + [model.state] }

  private func arm() {
    withObservationTracking {
      _ = model.state
      _ = model.render
    } onChange: { [weak self] in
      // The writes are all `settle`'s and `start()`'s, and both are `@MainActor`.
      MainActor.assumeIsolated {
        guard let self else { return }
        self.changes += 1
        self.values.append(self.model.state)
        self.arm()
      }
    }
  }
}

/// A session directory a test can add to between reads.
///
/// `@unchecked Sendable` behind a lock, because the host closure is
/// `@Sendable` and the test mutates the same object from outside it.
private final class MutablePages: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String: [String]]
  private var order: [String]

  init(files: [String] = ["a1b2.jsonl"], records: [String]) {
    order = files
    storage = Dictionary(uniqueKeysWithValues: files.map { ($0, records) })
  }

  var files: [String] {
    lock.lock()
    defer { lock.unlock() }
    return order
  }

  func records(for name: String) -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return storage[name] ?? []
  }

  func setRecords(for name: String, _ records: [String]) {
    lock.lock()
    defer { lock.unlock() }
    storage[name] = records
  }

  func addFile(_ name: String, records: [String]) {
    lock.lock()
    defer { lock.unlock() }
    if !order.contains(name) { order.append(name) }
    storage[name] = records
  }

  func append(_ record: String) {
    lock.lock()
    defer { lock.unlock() }
    guard let first = order.first else { return }
    storage[first, default: []].append(record)
  }
}

/// A host's willingness to answer, flipped by the test from outside the `@Sendable`
/// closure that reads it.
private final class Switch: @unchecked Sendable {
  private let lock = NSLock()
  private var on = false

  var isOn: Bool {
    lock.lock()
    defer { lock.unlock() }
    return on
  }

  func turnOn() {
    lock.lock()
    on = true
    lock.unlock()
  }

  func turnOff() {
    lock.lock()
    on = false
    lock.unlock()
  }
}

/// What `growingHost` answers for each command class: the probe (`stat -c %Y`), the listing
/// (`date +%s`), and the page read. Locked like `Switch`, so a test can flip it mid-run.
private final class GrowingHostBehavior: @unchecked Sendable {
  enum CommandAnswer: Sendable { case normal, refused }
  enum ListingAnswer: Sendable { case normal, empty, refused }

  struct Answers: Sendable {
    var probe: CommandAnswer = .normal
    var listing: ListingAnswer = .normal
    var pageRead: CommandAnswer = .normal
    var declaredPageSize: Int?
  }

  private let lock = NSLock()
  private var answers: Answers

  init(declaredPageSize: Int? = nil) {
    answers = Answers(declaredPageSize: declaredPageSize)
  }

  var current: Answers {
    lock.lock()
    defer { lock.unlock() }
    return answers
  }

  /// Every command class fails.
  func refuseEverything() {
    lock.lock()
    answers.probe = .refused
    answers.listing = .refused
    answers.pageRead = .refused
    lock.unlock()
  }

  /// Only the page read fails.
  func failPageReads() {
    lock.lock()
    answers.pageRead = .refused
    lock.unlock()
  }

  func allowPageReads() {
    lock.lock()
    answers.pageRead = .normal
    lock.unlock()
  }

  /// The listing exits 0 with no file rows.
  func returnEmptyListings() {
    lock.lock()
    answers.listing = .empty
    lock.unlock()
  }
}

/// A host that answers only once the test lets it, so a load can be caught mid-flight.
///
/// An actor rather than a semaphore; see `CLAUDE.md` on blocking a cooperative thread.
private actor Gate {
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var isOpen = false

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }
}

/// Counts commands from inside a `@Sendable` closure the test also reads.
private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func bump() {
    lock.lock()
    count += 1
    lock.unlock()
    // The wake-up for every `waitUntil` on `value`. The signal hops to the main actor itself.
    Waker.signalShared()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

/// The two record shapes this suite needs, written out rather than borrowed.
///
/// The kit's fixture set is not visible from the app's test target. These are minimal: what
/// is proven here is when a fetch happens, not what a record means.
private enum Records {
  static func human(_ text: String, uuid: String = "u1") -> String {
    #"{"type":"user","uuid":"\#(uuid)","isSidechain":false,"#
      + #""message":{"role":"user","content":"\#(text)"}}"#
  }

  static func assistant(_ text: String, uuid: String = "a1") -> String {
    #"{"type":"assistant","uuid":"\#(uuid)","isSidechain":false,"#
      + #""message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
  }

  /// An `Agent` call: this session spawning a sub-agent.
  static func spawn(description: String, id: String, uuid: String) -> String {
    #"{"type":"assistant","uuid":"\#(uuid)","isSidechain":false,"#
      + #""message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","#
      + #""name":"Agent","input":{"subagent_type":"Explore","description":"\#(description)"}}]}}"#
  }

  /// A run of tool calls, as one record carrying every call — one of the two shapes a real
  /// session file has, and the one `FakeTranscriptHost` writes.
  static func tools(_ calls: [(name: String, target: String)], uuid: String = "t1") -> String {
    let blocks = calls.map { call in
      #"{"type":"tool_use","name":"\#(call.name)","input":{"file_path":"\#(call.target)"}}"#
    }
    return #"{"type":"assistant","uuid":"\#(uuid)","isSidechain":false,"#
      + #""message":{"role":"assistant","content":[\#(blocks.joined(separator: ","))]}}"#
  }

}

// MARK: - A sub-agent's own conversation

/// Every command a host was sent, in order.
private final class SubagentCommandLog: @unchecked Sendable {
  private let lock = NSLock()
  private var sent: [String] = []

  func record(_ command: String) {
    lock.lock()
    sent.append(command)
    lock.unlock()
  }

  var commands: [String] {
    lock.lock()
    defer { lock.unlock() }
    return sent
  }

  func clear() {
    lock.lock()
    sent = []
    lock.unlock()
  }
}

/// Opening a spawn line's sub-agent in the pane's chat, against `FakeTranscriptHost`, so a
/// tap goes through the real link command, read and parse mode.
@MainActor
@Suite("A sub-agent's conversation on the pane's model", .timeLimit(.minutes(1)))
struct PaneSubagentModelTests {
  private static let sessionID = "3f8c1d20-0000-4000-8000-000000000002"
  private static let directory = "/home/carson/.claude/projects/-home-carson-dev-driverr"

  private static func analyst(extraTurns: Int = 0) -> FakeTranscriptHost.SubagentFixture {
    FakeTranscriptHost.SubagentFixture(
      agentID: "aanalyst7",
      toolUseID: "toolu_1_0",
      name: "analyst-7",
      secondsAgo: 30,
      prompt: "Plan the config loader.",
      turns: [.init(speaker: .assistant, text: "Reading the chat view first.", secondsAgo: 40)]
        + (0..<extraTurns).map {
          .init(speaker: .assistant, text: "Step \($0) of the plan.", secondsAgo: 20)
        }
    )
  }

  private static let verifier = FakeTranscriptHost.SubagentFixture(
    agentID: "averifier7",
    name: "verifier-7",
    isTeammate: true,
    secondsAgo: 10,
    prompt: "Review the diff.",
    turns: [.init(speaker: .assistant, text: "Checking out the latest commit.", secondsAgo: 9)]
  )

  private static func host(analystTurns: Int = 0) -> FakeTranscriptHost {
    FakeTranscriptHost(
      sessionID: sessionID,
      directory: directory,
      turns: [
        .init(speaker: .human, text: "plan it", secondsAgo: 100),
        .init(
          speaker: .toolBlocks([
            .spawn(
              subagentType: "analyst", name: "analyst-7", description: "Plan it",
              launch: .async(agentID: "aanalyst7"))
          ]),
          secondsAgo: 90
        ),
        .init(speaker: .assistant, text: "The pane's own last words.", secondsAgo: 80),
      ]
    ).serving([analyst(extraTurns: analystTurns), verifier])
  }

  private func pane() -> Pane {
    Pane(
      id: "w1:p2",
      tabID: "w1:t1",
      workspaceID: "w1",
      title: "planning",
      agent: Agent(
        name: "Claude", kind: "claude", status: .working,
        session: AgentSession(agent: "claude", kind: "id", value: Self.sessionID)),
      terminalID: "term_w1p2",
      directory: "/home/carson/dev/driverr"
    )
  }

  /// A pane model over the fake host, with every command logged. Once `grown` is on, the
  /// analyst's file answers with two more turns.
  private func model(
    _ grown: Switch = Switch(), log: SubagentCommandLog = SubagentCommandLog()
  ) async -> PaneTranscriptModel {
    let before = Self.host()
    let after = Self.host(analystTurns: 2)
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(run: { command in
        log.record(command)
        return try await (grown.isOn ? after : before).run(command)
      })
    )
    model.loadIfNeeded()
    await model.currentLoad?.value
    return model
  }

  private func open(
    _ link: SubagentLink, on model: PaneTranscriptModel
  ) async -> PaneTranscriptModel {
    model.openSubagent(link: link, title: "analyst-7")
    await model.shown.currentLoad?.value
    return model.shown
  }

  @Test("a spawn line's link opens the sub-agent's own file on top of the pane's chat")
  func opensTheSubagentsFile() async throws {
    let model = await model()
    let spawn = try #require(model.transcript?.turns.compactMap(\.agentEvent).first)
    #expect(spawn.link == .toolUse(id: "toolu_1_0"))

    let shown = await open(try #require(spawn.link), on: model)
    #expect(model.isShowingSubagent)
    #expect(shown !== model)
    #expect(shown.source?.provenance == .subagent)
    #expect(shown.source?.file.name == "agent-aanalyst7.jsonl")
    let first = try #require(shown.transcript?.turns.first)
    #expect(first.isParentPrompt)
    #expect(first.text == "Plan the config loader.")
  }

  /// The Needs you row reads the pane's model through `PaneTranscriptCache`, so a sub-agent
  /// must never become that model's page.
  @Test("the pane's last assistant message does not change while a sub-agent is shown")
  func theNeedsYouQuoteStaysThePanes() async {
    let model = await model()
    #expect(model.lastAssistantMessage == "The pane's own last words.")
    let shown = await open(.toolUse(id: "toolu_1_0"), on: model)
    #expect(shown.lastAssistantMessage == "Reading the chat view first.")
    #expect(model.lastAssistantMessage == "The pane's own last words.")
    #expect(model.source?.provenance != .subagent)
  }

  /// The fake ignores which session a link command names, so the command itself is asserted.
  /// A teammate is searched for under the session whose file holds the spawn; a tool-use id
  /// across the whole project.
  @Test("a teammate is searched for under the pane file's session, a tool-use id project-wide")
  func theLinkCommandsNameTheirScope() async {
    let log = SubagentCommandLog()
    let model = await model(log: log)
    log.clear()
    _ = await open(.teammate(name: "verifier-7"), on: model)
    let teammate = log.commands.first { $0.contains("grep -lF") }
    #expect(teammate?.contains("\(Self.directory)/\(Self.sessionID)/subagents") == true)
    #expect(teammate?.contains(#""name":"verifier-7""#) == true)
    #expect(model.shown.source?.file.name == "agent-averifier7.jsonl")

    model.closeSubagent()
    log.clear()
    _ = await open(.toolUse(id: "toolu_1_0"), on: model)
    let byID = log.commands.first { $0.contains("grep -rlF") }
    #expect(byID != nil)
    #expect(byID?.contains("\(Self.sessionID)/subagents") == false)
  }

  @Test("a link no file carries says so, in its own notice")
  func anUnresolvedLinkIsItsOwnNotice() async {
    let model = await model()
    let shown = await open(.toolUse(id: "toolu_nobody"), on: model)
    #expect(shown.state == .unavailable(.absent(.subagentFileNotFound)))
    #expect(model.isShowingSubagent)
  }

  @Test("closing returns to the pane's own conversation")
  func closingReturnsToThePane() async {
    let model = await model()
    _ = await open(.toolUse(id: "toolu_1_0"), on: model)
    model.closeSubagent()
    #expect(!model.isShowingSubagent)
    #expect(model.shown === model)
    #expect(model.lastAssistantMessage == "The pane's own last words.")
  }

  @Test("invalidating the pane's page closes every sub-agent opened from it")
  func invalidateReachesTheStack() async {
    let model = await model()
    _ = await open(.toolUse(id: "toolu_1_0"), on: model)
    model.invalidate()
    #expect(!model.isShowingSubagent)
  }

  /// A reconnect builds a new transport; a sub-agent on screen has to read through it too.
  @Test("relinking moves a shown sub-agent onto the new link")
  func relinkReachesTheStack() async {
    let model = await model()
    let shown = await open(.toolUse(id: "toolu_1_0"), on: model)
    let fresh = SubagentCommandLog()
    let host = Self.host()
    model.relink(to: TranscriptReader(run: { command in
      fresh.record(command)
      return try await host.run(command)
    }))
    await shown.currentLoad?.value
    await model.currentLoad?.value
    #expect(fresh.commands.contains { $0.contains("agent-aanalyst7.jsonl") })
    #expect(model.isShowingSubagent)
  }

  /// The watcher follows what is on screen. A tick while a sub-agent is shown probes the
  /// sub-agent's file and re-reads it when it grew, and never probes the pane's own.
  @Test("a growing sub-agent file is re-read by the watcher, and the pane's file is not probed")
  func theWatcherFollowsTheShownFile() async throws {
    let grown = Switch()
    let log = SubagentCommandLog()
    let model = await model(grown, log: log)
    let shown = await open(.toolUse(id: "toolu_1_0"), on: model)
    #expect(shown.transcript?.turns.count == 2)

    grown.turnOn()
    log.clear()
    await model.checkShownForGrowth()
    await shown.currentLoad?.value
    #expect(shown.transcript?.turns.count == 4)
    let paneFile = "\(Self.sessionID).jsonl"
    #expect(!log.commands.contains { $0.contains(paneFile) })
    #expect(log.commands.contains { $0.contains("agent-aanalyst7.jsonl") })
    #expect(model.lastAssistantMessage == "The pane's own last words.")
  }
}
