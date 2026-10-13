import DriverrCore
import DriverrHerdr
import Foundation
import Testing

@testable import Driverr

/// The app-level plumbing behind the captured-screen surface, with no host and no
/// simulator behind it.
///
/// `DriverrHerdr` owns what a pane's screen is. This owns when to read, and what the surface
/// sees while a read is in flight.
///
/// **A refusal is a fault and a blank screen is an answer.** Collapsing them gives a spinner
/// that never resolves or a false calm, and a screenshot cannot tell them apart.
@MainActor
@Suite("PaneScreenModel", .timeLimit(.minutes(1)))
struct PaneScreenModelTests {

  private func pane(
    agent: Agent? = Agent(name: "Claude", kind: "claude", status: .blocked),
    viewportRows: Int? = 24
  ) -> Pane {
    Pane(
      id: "w1:p2",
      tabID: "w1:t1",
      workspaceID: "w1",
      title: "needs a decision",
      agent: agent,
      terminalID: "term_w1p2",
      directory: "/Users/x/Dev/driverr",
      viewportRows: viewportRows
    )
  }

  private func settled(_ model: PaneScreenModel) async {
    await model.currentLoad?.value
  }

  // MARK: - Reading for a question

  /// The cache keeps a screen for the whole connection. One read on an earlier visit can show
  /// a question since answered, so neither the chips nor the focus gate may use it.
  @Test("a screen read before the watch for a question started is not used for one")
  func questionScreenIsReadAfterTheWatch() async {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let control = FakeControl(screen: FakeControl.askUserQuestionScreen)
    let model = PaneScreenModel(pane: pane(), control: { control }, now: { clock.now })

    model.loadIfNeeded()
    await settled(model)
    #expect(model.screen != nil)

    clock.advance(by: 60)
    model.startWatchingForQuestion()
    #expect(model.screenForQuestion == nil)
    #expect(!model.hasReadForQuestion)

    model.refresh()
    await settled(model)
    #expect(model.hasReadForQuestion)
    #expect(model.screenForQuestion == FakeControl.askUserQuestionScreen)
  }

  // MARK: - Reading

  @Test("a pane's screen is read once and kept")
  func readsOnceAndKeeps() async {
    let control = FakeControl()
    let model = PaneScreenModel(pane: pane(), control: { control })

    model.loadIfNeeded()
    await settled(model)

    #expect(model.screen?.isEmpty == false)
    var reads = await control.screenReads.map(\.paneID)
    #expect(reads == ["w1:p2"])

    // A second ask is a no-op, so calling this from a `.task` that re-runs is free.
    model.loadIfNeeded()
    await settled(model)
    reads = await control.screenReads.map(\.paneID)
    #expect(reads == ["w1:p2"])
  }

  @Test("the read is asked for this pane, and for as much of the screen as there is")
  func readsThisPaneBoundedToItsScreen() async {
    let control = FakeControl()
    let model = PaneScreenModel(pane: pane(), control: { control })

    model.loadIfNeeded()
    await settled(model)

    let read = await control.screenReads.first
    #expect(read?.paneID == "w1:p2")
    // The near side asks for its own ceiling. `CLIControl.boundedLines` clamps it to the
    // pane's `viewport_rows`, so a read never pays about 420 ms for rows past the viewport.
    #expect(read?.lines == PaneScreen.maximumLines)
  }

  @Test("a screen Driverr was given is the screen it shows")
  func showsTheScreenItWasGiven() async {
    let given = PaneScreen.sanitised("\u{1B}[38;5;15m⏺ \u{1B}[0mready when you are", lines: 24)
    let control = FakeControl(screen: given)
    let model = PaneScreenModel(pane: pane(), control: { control })

    model.loadIfNeeded()
    await settled(model)

    #expect(model.state == .ready(given))
    #expect(model.screen?.text == "⏺ ready when you are")
  }

  // MARK: - A refusal is not a blank screen

  /// `agent_not_idle` comes back for working panes, the state a pane is in when somebody wants
  /// to read what it just said, so this is the common failure.
  @Test("herdr refusing the read is a failure, and a failure is retryable")
  func aRefusalIsAFailure() async {
    let control = FakeControl(failure: .herdrCommandFailed(reason: "agent_not_idle"))
    let model = PaneScreenModel(pane: pane(), control: { control })

    model.loadIfNeeded()
    await settled(model)

    #expect(model.state == .failed(.herdrCommandFailed(reason: "agent_not_idle")))
    #expect(model.screen == nil)
  }

  /// A pane showing nothing is an answer, and the surface must not offer to ask again for the
  /// same nothing.
  @Test("a genuinely blank screen is an answer rather than a failure")
  func aBlankScreenIsAnAnswer() async {
    let control = FakeControl(screen: .blank)
    let model = PaneScreenModel(pane: pane(), control: { control })

    model.loadIfNeeded()
    await settled(model)

    #expect(model.state == .ready(.blank))
    #expect(model.screen?.isEmpty == true)
    if case .failed = model.state {
      Issue.record("a blank screen must never be reported as a failure")
    }
  }

  /// A retry that quietly does nothing is the worst outcome, so the asking again is asserted,
  /// by the state and by the count. Unlike `refresh()`, a retry goes back to a spinner: there
  /// is nothing behind a failure worth keeping on screen. `FakeControl` records a refused read
  /// before it throws.
  @Test("a retry on a refusal reads again rather than sitting there")
  func retryOnARefusalReadsAgain() async {
    let refusal = AppError.herdrCommandFailed(reason: "agent_not_idle")
    let control = FakeControl(failure: refusal)
    let model = PaneScreenModel(pane: pane(), control: { control })

    model.loadIfNeeded()
    await settled(model)
    #expect(model.state == .failed(refusal))

    model.reload()
    #expect(model.state == .loading)

    await settled(model)
    // The same fake still refuses, so "it retried" cannot pass as "it never failed".
    #expect(model.state == .failed(refusal))
    #expect(await control.screenReads.count == 2, "the load, then the retry")
  }

  @Test("a retry on a screen that did read asks the host again")
  func retryReadsAgain() async {
    let control = FakeControl()
    let model = PaneScreenModel(pane: pane(), control: { control })

    model.loadIfNeeded()
    await settled(model)

    model.reload()
    await settled(model)

    let reads = await control.screenReads.count
    #expect(reads == 2)
  }

  // MARK: - Reading again

  /// A screen is live, so this surface re-reads whenever it appears, without withdrawing what
  /// is drawn: a screen two seconds old says more than a spinner.
  @Test("a re-read keeps the screen that is already drawn")
  func rereadKeepsWhatIsDrawn() async {
    let control = FakeControl()
    let model = PaneScreenModel(pane: pane(), control: { control })

    model.loadIfNeeded()
    await settled(model)
    let first = model.screen
    #expect(first != nil)

    model.refresh()
    #expect(model.screen == first, "the surface must not blank while a re-read is in flight")
    #expect(model.isRereading)

    await settled(model)
    #expect(!model.isRereading)
    let reads = await control.screenReads.count
    #expect(reads == 2)
  }

  @Test("a re-read while one is already in flight does not start a second")
  func rereadDoesNotStack() async {
    let control = FakeControl()
    let model = PaneScreenModel(pane: pane(), control: { control })

    model.loadIfNeeded()
    model.refresh()
    model.refresh()
    await settled(model)

    let reads = await control.screenReads.count
    #expect(reads == 1)
  }

  @Test("a first read shows a spinner, because there is nothing behind it to keep")
  func aFirstReadShowsASpinner() async {
    let control = FakeControl()
    let model = PaneScreenModel(pane: pane(), control: { control })

    model.refresh()

    #expect(model.state == .loading)
    #expect(!model.isRereading)
    await settled(model)
  }

  // MARK: - The link that came back

  @Test("a read cancelled by a relink does not clear the re-read that replaced it")
  func aCancelledReadDoesNotClearTheReread() async {
    // `relink()` cancels the read in flight and starts one on the new link, but nothing under
    // `HerdrControl` checks cancellation, so the cancelled read still lands in `settle`. It
    // must not clear `isRereading`, which belongs to the read that replaced it.
    let control = GatedScreenControl()
    let model = PaneScreenModel(pane: pane(), control: { control })

    // A capture on screen, so the re-read below keeps what is drawn rather than blanking.
    model.loadIfNeeded()
    await control.waitForParkedReads(1)
    await control.releaseFirst()
    await settled(model)
    #expect(model.screen != nil, "the first read never landed")

    // A re-read confirmed parked before the relink starts a second, so `releaseFirst()` is
    // unambiguously the cancelled read.
    model.refresh()
    let cancelled = model.currentLoad
    await control.waitForParkedReads(1)
    #expect(model.isRereading)

    model.relink()
    let replacement = model.currentLoad
    await control.waitForParkedReads(2)

    // The cancelled read lands late, with the new one still parked.
    await control.releaseFirst()
    await cancelled?.value

    #expect(
      model.isRereading,
      "the cancelled read cleared the indicator belonging to the read that replaced it"
    )
    #expect(model.screen != nil, "the surface blanked while the new read was in flight")

    await control.releaseFirst()
    await replacement?.value
    #expect(!model.isRereading, "the re-read that actually landed never cleared it")
    #expect(model.screen != nil)
  }

  // MARK: - A link that has gone

  /// A read attempted on a connection that is not there would spend the outage opening exec
  /// channels, and must not leave the surface spinning for ever.
  @Test("no herdr means a failure rather than a spinner that never resolves")
  func noControlSettlesRatherThanSpinning() async {
    let model = PaneScreenModel(pane: pane(), control: { nil })

    model.loadIfNeeded()
    await settled(model)

    if case .failed = model.state {} else {
      Issue.record("expected a settled failure, got \(model.state)")
    }
  }

  // MARK: - Throwing the screen away

  @Test("invalidating takes it back to never having asked")
  func invalidateResetsToIdle() async {
    let control = FakeControl()
    let model = PaneScreenModel(pane: pane(), control: { control })

    model.loadIfNeeded()
    await settled(model)
    model.invalidate()

    #expect(model.state == .idle)

    model.loadIfNeeded()
    await settled(model)
    let reads = await control.screenReads.count
    #expect(reads == 2)
  }

  // MARK: - Saying how old the capture is

  /// The caption is present-tense ("the last 9 lines of the pane"), so a capture needs its
  /// time, or an answered permission prompt stays on screen with nothing saying how old it is.
  @Test("a capture records when it was taken")
  func aCaptureIsStamped() async {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let model = PaneScreenModel(pane: pane(), control: { FakeControl() }, now: { clock.now })
    #expect(model.capturedAt == nil)

    model.loadIfNeeded()
    await settled(model)

    #expect(model.capturedAt == clock.now)
  }

  /// A refusal is stamped too. That is a fact about freshness, and it stops `refreshIfStale`
  /// re-asking a refusing pane on every redraw.
  @Test("a refusal is stamped as well, so it is not re-asked on every redraw")
  func aRefusalIsStamped() async {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let control = FakeControl.failing(.herdrCommandFailed(reason: "agent_not_idle"))
    let model = PaneScreenModel(pane: pane(), control: { control }, now: { clock.now })

    model.loadIfNeeded()
    await settled(model)

    #expect(model.capturedAt == clock.now)

    model.refreshIfStale()
    await settled(model)
    let reads = await control.screenReads.count
    // One: the `loadIfNeeded()` above was refused, and its stamp stops `refreshIfStale()`
    // asking again. `FakeControl` records refused reads, so a re-ask would make two.
    #expect(reads == 1, "asked once; the stamp is what stops it being re-asked")
  }

  @Test("appearing re-reads a stale capture and leaves a fresh one alone")
  func appearanceRefreshesOnlyWhenStale() async {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let control = FakeControl()
    let model = PaneScreenModel(pane: pane(), control: { control }, now: { clock.now })
    model.loadIfNeeded()
    await settled(model)
    #expect(await control.screenReads.count == 1)

    clock.advance(by: 5)
    model.refreshIfStale()
    await settled(model)
    #expect(await control.screenReads.count == 1)

    clock.advance(by: PaneScreenModel.appearanceStaleness)
    model.refreshIfStale()
    await settled(model)
    #expect(await control.screenReads.count == 2)
  }

  /// A re-read must not blank the surface: a stale screen says more than a spinner.
  @Test("a stale capture is replaced without the surface going back to a spinner")
  func aRefreshKeepsTheScreen() async {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let model = PaneScreenModel(pane: pane(), control: { FakeControl() }, now: { clock.now })
    model.loadIfNeeded()
    await settled(model)

    clock.advance(by: PaneScreenModel.appearanceStaleness)
    model.refreshIfStale()

    #expect(model.screen != nil)
    #expect(model.isRereading)
    await settled(model)
    #expect(model.capturedAt == clock.now)
  }

  /// The cached model records the fresh `Pane` value. Deciding what it means is the session
  /// poll's job.
  @Test("a polled pane value is recorded rather than discarded")
  func recordsTheFreshPane() {
    let model = PaneScreenModel(pane: pane(), control: { nil })

    model.update(to: pane(agent: Agent(name: "Claude", kind: "claude", status: .idle)))

    #expect(model.pane.agent?.status == .idle)
  }

  @Test("a value for a different pane is refused rather than silently adopted")
  func refusesAnotherPanesValue() {
    let model = PaneScreenModel(pane: pane(), control: { nil })
    let other = Pane(id: "w9:p9", tabID: "w9:t1", workspaceID: "w9", title: "elsewhere")

    model.update(to: other)

    #expect(model.pane.id == "w1:p2")
  }
}

/// The cache the connection holds, which is what makes switching to the terminal and back
/// free.
@MainActor
@Suite("PaneScreenCache")
struct PaneScreenCacheTests {

  private func pane(_ id: String) -> Pane {
    Pane(
      id: id,
      tabID: "w1:t1",
      workspaceID: "w1",
      title: id,
      agent: Agent(name: "Claude", kind: "claude", status: .blocked)
    )
  }

  @Test("one model per pane, made on first ask and kept")
  func oneModelPerPane() {
    let control = FakeControl()
    let cache = PaneScreenCache(control: { control })

    let first = cache.model(for: pane("w1:p1"))
    let again = cache.model(for: pane("w1:p1"))
    let other = cache.model(for: pane("w1:p2"))

    #expect(first === again)
    #expect(first !== other)
  }

  /// Keyed by pane id, because a poll hands out a new `Pane` value every three seconds, and
  /// rebuilding on that would throw the screen away twenty times a minute.
  @Test("a pane whose status changed is still the same pane")
  func keyedByIdRatherThanValue() {
    let control = FakeControl()
    let cache = PaneScreenCache(control: { control })
    let blocked = pane("w1:p1")
    let working = Pane(
      id: "w1:p1",
      tabID: "w1:t1",
      workspaceID: "w1",
      title: "w1:p1",
      agent: Agent(name: "Claude", kind: "claude", status: .working)
    )

    #expect(blocked != working)
    #expect(cache.model(for: blocked) === cache.model(for: working))
  }

  @Test("nothing is made for a pane nobody has asked about")
  func existingModelNeverCreates() {
    let cache = PaneScreenCache(control: { nil })

    #expect(cache.existingModel(for: "w1:p1") == nil)
    _ = cache.model(for: pane("w1:p1"))
    #expect(cache.existingModel(for: "w1:p1") != nil)
  }

  @Test("forgetting a pane drops its screen")
  func forgetDropsTheScreen() {
    let control = FakeControl()
    let cache = PaneScreenCache(control: { control })
    let first = cache.model(for: pane("w1:p1"))

    cache.forget("w1:p1")

    #expect(cache.existingModel(for: "w1:p1") == nil)
    #expect(cache.model(for: pane("w1:p1")) !== first)
  }

  /// The cache records the fresh `Pane` on the model it hands back, and only records it,
  /// because this is called from a view body.
  @Test("asking again with a newer pane value records it on the model it hands back")
  func recordsThePolledPane() {
    let cache = PaneScreenCache(control: { nil })
    _ = cache.model(for: pane("w1:p1"))

    let polled = Pane(
      id: "w1:p1",
      tabID: "w1:t1",
      workspaceID: "w1",
      title: "wiring",
      agent: Agent(name: "Claude", kind: "claude", status: .idle)
    )

    #expect(cache.model(for: polled).pane.agent?.status == .idle)
  }

  @Test("panes that have left the session are forgotten in one pass")
  func forgetsPanesThatLeft() {
    let cache = PaneScreenCache(control: { nil })
    _ = cache.model(for: pane("w1:p1"))
    _ = cache.model(for: pane("w1:p2"))

    cache.forgetEverythingExcept(["w1:p2"])

    #expect(cache.existingModel(for: "w1:p1") == nil)
    #expect(cache.existingModel(for: "w1:p2") != nil)
  }
}


/// A control whose screen reads park on a continuation until a test lets them go.
///
/// Suspends rather than sleeps; see `CLAUDE.md` on the cooperative pool.
///
/// For two reads in flight at once in a known order, which `FakeControl`'s instant answers
/// cannot produce.
private actor GatedScreenControl: HerdrControl {
  private var waiting: [@Sendable () -> Void] = []

  /// Parked until `waiting.count` has reached `threshold`.
  private struct ParkedReadWaiter {
    let id: Int
    let threshold: Int
    let continuation: CheckedContinuation<Void, Never>
  }

  private var parkedReadWaiters: [ParkedReadWaiter] = []
  private var nextParkedReadWaiterID = 0

  nonisolated var binaryPath: String { "herdr" }
  func snapshot() async throws -> SessionTree { .empty }
  nonisolated func attachCommand(for pane: Pane) -> String { "herdr terminal attach t" }
  func availability() async -> HerdrAvailability {
    .ready(version: "0.8.2", protocolVersion: HerdrProtocol.lastVerified)
  }
  func readPanes(ids: [String], lines: Int) async throws -> [String: [String]] { [:] }
  func perform(_ action: PaneAction, on paneID: String) async throws {}
  func rename(_ target: RenameTarget, to label: String) async throws {}
  func sendText(paneID: String, text: String) async throws {}
  func submitText(paneID: String, text: String) async throws {}
  func sendKeys(paneID: String, keys: [PaneKey]) async throws {}

  func readScreen(of pane: Pane, lines: Int) async throws -> PaneScreen {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      waiting.append { continuation.resume() }
      resumeParkedReadWaiters()
    }
    return PaneScreen.sanitised("$ herdr pane \(pane.id)", lines: lines)
  }

  /// Lets the longest-parked read finish. Order is arrival order, which is why a test
  /// confirms a read has reached the gate before starting the next one.
  func releaseFirst() {
    guard !waiting.isEmpty else { return }
    waiting.removeFirst()()
  }

  /// Suspends until this control has at least `count` reads parked at the gate.
  ///
  /// A count is a fact about the fake; a deadline would be a fact about the machine. A read
  /// that never parks fails on the suite's `.timeLimit`.
  func waitForParkedReads(_ count: Int) async {
    guard waiting.count < count else { return }
    let id = nextParkedReadWaiterID
    nextParkedReadWaiterID += 1
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        // Cancelled before the waiter was parked: resume now, or nothing ever will.
        if Task.isCancelled {
          continuation.resume()
        } else {
          parkedReadWaiters.append(
            ParkedReadWaiter(id: id, threshold: count, continuation: continuation)
          )
        }
      }
    } onCancel: {
      Task { await self.cancelParkedReadWaiter(id) }
    }
  }

  private func resumeParkedReadWaiters() {
    let reached = waiting.count
    var parked: [ParkedReadWaiter] = []
    for waiter in parkedReadWaiters {
      if reached >= waiter.threshold {
        waiter.continuation.resume()
      } else {
        parked.append(waiter)
      }
    }
    parkedReadWaiters = parked
  }

  private func cancelParkedReadWaiter(_ id: Int) {
    guard let index = parkedReadWaiters.firstIndex(where: { $0.id == id }) else { return }
    parkedReadWaiters.remove(at: index).continuation.resume()
  }
}
