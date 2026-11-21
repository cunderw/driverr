import DriverrCore
import DriverrHerdr
import Foundation
import Observation

/// One pane's captured screen, read on demand and kept.
///
/// `readScreen` says what is on the screen. This model decides when to ask and what the
/// surface shows meanwhile, in the same shape as `PaneTranscriptModel`.
///
/// **A refusal and a blank screen are different states.** A herdr refusal such as
/// `agent_not_idle` throws and is a fault with a Retry. A pane showing nothing returns an
/// empty `PaneScreen`, which is an answer. Merging them gives a spinner that never resolves
/// or a blank that hides a fault.
@MainActor
@Observable
final class PaneScreenModel {
  enum State: Equatable {
    /// Not asked yet. Distinct from "asked and got nothing", which is `.ready` holding a
    /// blank screen.
    case idle
    /// A first read, with nothing to show behind it. A re-read keeps `.ready`; see
    /// `isRereading`.
    case loading
    /// A screen, which may be blank.
    case ready(PaneScreen)
    /// herdr refused, or the link went away. The only state with a retry behind it.
    case failed(AppError)
  }

  /// How many rows to ask for: the whole visible screen. `CLIControl.boundedLines` caps the
  /// request at the pane's viewport on the far side, where asking for more is much slower
  /// and returns the same bytes.
  static let lineCount = PaneScreen.maximumLines

  /// The pane this reads, as the latest snapshot reported it. `@ObservationIgnored` because
  /// the cache records it from a view body.
  @ObservationIgnored private(set) var pane: Pane
  private(set) var state: State = .idle

  /// When the screen on show was captured, on this device's clock. The caption shows its
  /// age, and the refresh triggers use it to decide whether to ask again.
  private(set) var capturedAt: Date?

  /// A read in flight over a screen that is already drawn. A flag rather than `.loading`,
  /// because a stale screen says more than a spinner.
  private(set) var isRereading = false

  /// Resolved per read, because the link can go while the surface is up.
  @ObservationIgnored private let control: @MainActor () -> (any HerdrControl)?
  /// The in-flight read, owned here rather than by the view that asked, for the reason on
  /// `PaneTranscriptModel.currentLoad`.
  @ObservationIgnored private(set) var currentLoad: Task<Void, Never>?
  /// Injected so tests can assert `capturedAt` and the staleness bound without waiting.
  @ObservationIgnored private let now: @MainActor () -> Date

  /// What Claude Code's mode is, from every read this model makes. See `PaneModeReading`.
  private(set) var modeReading = PaneModeReading()
  /// How long to wait before a re-read that a Shift-Tab asked for. Claude redrew its footer
  /// about 70 ms after the key on tmux and the herdr TUI, so an immediate re-read on a fast
  /// link lands before it. Injected so tests need not wait.
  @ObservationIgnored private let modeRereadDelay: Duration
  /// The waiting re-read, so a second request does not stack a second one.
  @ObservationIgnored private var modeReread: Task<Void, Never>?

  init(
    pane: Pane,
    control: @escaping @MainActor () -> (any HerdrControl)?,
    now: @escaping @MainActor () -> Date = Date.init,
    modeRereadDelay: Duration = .milliseconds(300)
  ) {
    self.pane = pane
    self.control = control
    self.now = now
    self.modeRereadDelay = modeRereadDelay
  }

  /// Claude Code's mode as the latest believed read shows it. `nil` is unknown.
  var mode: ClaudeMode? { modeReading.mode }

  /// Whether the pane's terminal has been on screen since the chat last read for the mode.
  /// A Shift-Tab typed there, from the key row's held Tab or a hardware keyboard, reaches the
  /// pane without passing `onSent`, so the chat cannot know whether the mode moved.
  @ObservationIgnored private(set) var terminalShownSinceModeRead = false

  /// The pane's terminal is on screen. See `terminalShownSinceModeRead`.
  func terminalShown() {
    terminalShownSinceModeRead = true
  }

  /// The chat with the mode button appeared. Reads at once after the terminal was up, and
  /// otherwise only if the capture is old.
  func refreshForModeOnAppearance() {
    guard terminalShownSinceModeRead else {
      refreshIfStale()
      return
    }
    terminalShownSinceModeRead = false
    refresh()
  }

  /// A Shift-Tab went to the pane: the mode on show is stale until a read answers it. Then
  /// reads, as any send does. A read already in flight started before the key, and
  /// `PaneModeReading` asks for another when it lands.
  func modeToggled() {
    modeReading.toggled()
    refresh()
  }

  /// How old a capture has to be before appearing triggers another read. A read is cheap.
  /// The bound stops a `.task` that re-runs on identity changes from becoming a second
  /// poller.
  static let appearanceStaleness: TimeInterval = 30

  /// The screen on show, if there is one.
  var screen: PaneScreen? {
    guard case .ready(let screen) = state else { return nil }
    return screen
  }

  /// When the chat started reading this screen for a question. See `screenForQuestion`.
  private(set) var questionWatchStartedAt: Date?

  /// Marks the start of a watch for a question. The chat calls it each time it starts one.
  func startWatchingForQuestion() {
    questionWatchStartedAt = now()
  }

  /// The screen, if it was captured after the chat started watching for a question.
  ///
  /// The cache keeps a screen for the whole connection, so an older capture can show a
  /// question that has since been answered. The chat's chips and the composer's focus gate
  /// both read this, so neither acts on that older screen.
  var screenForQuestion: PaneScreen? {
    hasReadForQuestion ? screen : nil
  }

  /// Whether a read, answered or refused, has settled since the chat started watching for a
  /// question. The composer's focus gate waits on this rather than on `screenForQuestion`, so
  /// a refused read does not hold the request for ever.
  var hasReadForQuestion: Bool {
    guard let since = questionWatchStartedAt, let capturedAt else { return false }
    return capturedAt >= since
  }

  /// Reads once. A no-op unless nothing has been asked yet, so a re-running `.task` may
  /// call it.
  func loadIfNeeded() {
    guard case .idle = state else { return }
    start(keepingWhatIsDrawn: false)
  }

  /// Reads again, keeping whatever is on screen until the new answer lands.
  ///
  /// Unlike a transcript, a screen changes while the agent waits, so a capture goes stale.
  /// This reads once and does not poll. Following the pane live is the terminal's job.
  func refresh() {
    guard currentLoad == nil else { return }
    start(keepingWhatIsDrawn: screen != nil)
  }

  /// The Retry on a refusal. Unlike `refresh()`, it returns to a spinner, because nothing
  /// behind a failure is worth keeping.
  func reload() {
    currentLoad?.cancel()
    currentLoad = nil
    start(keepingWhatIsDrawn: false)
  }

  /// Reads again if the capture is older than `maxAge`. Appearance calls this. An event that
  /// certainly changed the screen, such as a sent reply, calls `refresh()` instead.
  func refreshIfStale(maxAge: TimeInterval = PaneScreenModel.appearanceStaleness) {
    guard let capturedAt else {
      refresh()
      return
    }
    guard now().timeIntervalSince(capturedAt) >= maxAge else { return }
    refresh()
  }

  /// Records the latest snapshot of the pane. Writes nothing observed; see `pane`.
  func update(to pane: Pane) {
    guard pane.id == self.pane.id else { return }
    self.pane = pane
  }

  /// Re-reads on the link that came back, because the capture is as old as the outage.
  ///
  /// Nothing is re-pointed, because `control` resolves per read. Every state but `.idle` is
  /// re-read, including a refusal: the new link may answer, and a stale refusal on screen is
  /// worse than one cheap round trip. A model nobody opened stays `.idle`.
  func relink() {
    // Cancelled, not awaited. The read over the dead link still lands, and `settle` drops
    // it. Clearing `currentLoad` lets the `refresh()` below start.
    currentLoad?.cancel()
    currentLoad = nil
    isRereading = false
    if case .idle = state { return }
    refresh()
  }

  /// Throws the screen away so the next `loadIfNeeded()` reads again.
  func invalidate() {
    currentLoad?.cancel()
    currentLoad = nil
    modeReread?.cancel()
    modeReread = nil
    isRereading = false
    capturedAt = nil
    state = .idle
  }

  private func start(keepingWhatIsDrawn: Bool) {
    if keepingWhatIsDrawn {
      isRereading = true
    } else {
      state = .loading
      // Cleared here as well as in `settle`, because a cancelled read does not clear it.
      isRereading = false
    }
    // Taken as the read starts, so a read that began before a Shift-Tab is told apart.
    let ticket = modeReading.ticket
    currentLoad = Task { [weak self] in await self?.fetch(ticket: ticket) }
  }

  private func fetch(ticket: Int) async {
    guard let control = control() else {
      settle(.failed(.notConnected(host: "this host")), ticket: ticket)
      return
    }
    do {
      let screen = try await control.readScreen(of: pane, lines: Self.lineCount)
      settle(.ready(screen), ticket: ticket)
    } catch let error as AppError {
      // herdr's own words, which `CLIControl` has already pulled out of the error envelope.
      settle(.failed(error), ticket: ticket)
    } catch {
      settle(
        .failed(.herdrCommandFailed(reason: "The pane's screen could not be read.")),
        ticket: ticket)
    }
  }

  /// Records a verdict, unless this read was cancelled.
  ///
  /// Nothing below checks cancellation, so a cancelled read still arrives here. Without the
  /// guard, `invalidate()` does not stick and `reload()` races itself.
  private func settle(_ verdict: State, ticket: Int) {
    // `isRereading` is cleared below the guard, not above it. A read cancelled by
    // `relink()` still lands here, and clearing the flag would take the indicator off the
    // read that replaced it. Only the current read may clear it.
    guard !Task.isCancelled else { return }
    isRereading = false
    currentLoad = nil
    state = verdict
    // Stamped for a refusal too, so `refreshIfStale` does not re-ask a refusing pane on
    // every redraw.
    capturedAt = now()
    let readsAgain =
      switch verdict {
      case .ready(let screen): modeReading.read(screen, ticket: ticket)
      case .failed: modeReading.failed(ticket: ticket)
      case .idle, .loading: false
      }
    if readsAgain { scheduleModeReread() }
  }

  /// One re-read after `modeRereadDelay`, for a Shift-Tab whose answer is not on screen yet.
  /// Bounded by `PaneModeReading`, so this is never a poller.
  private func scheduleModeReread() {
    guard modeReread == nil else { return }
    let delay = modeRereadDelay
    modeReread = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard let self, !Task.isCancelled else { return }
      self.modeReread = nil
      self.refresh()
    }
  }
}
