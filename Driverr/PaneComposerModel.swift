import DriverrCore
import DriverrHerdr
import Foundation
import Observation

/// Answering one pane without opening a terminal on it.
///
/// A blocked agent usually waits on a word or a keystroke, which a phone can send in two
/// taps as a request and response rather than through a PTY.
///
/// The send states are transitions on `PaneComposerState`, asserted in `swift test`. This
/// model only puts the attempt on the wire and runs the clock for the `Sent` notice.
@MainActor
@Observable
final class PaneComposerModel: Identifiable {
  /// The pane's id, held apart from `pane` because `pane` is main-actor state and
  /// `Identifiable` is `nonisolated`. The id never changes.
  nonisolated let id: String

  /// The pane this answers, as the latest snapshot reported it. `Sent` retires on the
  /// pane's status, so the poll has to keep this current. The header above the bar reads
  /// the live pane, not this copy.
  ///
  /// `@ObservationIgnored` because `PaneComposerCache.model(for:)` is called from a view
  /// body.
  @ObservationIgnored private(set) var pane: Pane

  private(set) var state = PaneComposerState()

  /// The one image this composer holds. It lives here, not in the bar's `@State`, so a
  /// staged photograph survives a switch to the Terminal surface and back.
  ///
  /// The hand-off that types the uploaded path into the pane is wired in `init` and nowhere
  /// else.
  let attachment: PaneAttachmentModel

  /// The moment the status line is rendered against. It ticks while a `Sent` notice waits,
  /// so the notice's age advances on screen. Observed because its only job is to schedule
  /// redraws.
  private(set) var asOf = Date.distantPast

  /// The staged reply. Writing to it is typing; see `PaneComposerState.text`.
  var text: String {
    get { state.text }
    set { state.text = newValue }
  }

  var isSending: Bool { state.isSending }
  var canSend: Bool { state.canSend }
  var failure: AppError? { state.failure }
  /// What the bar says about the last attempt, read against the ticking clock so a reply
  /// nothing has confirmed ages on screen rather than sitting at `Sent` for ever.
  var status: PaneComposerStatus? { state.status(asOf: max(asOf, now())) }

  /// Resolved per send, because the link can go while the composer is on screen.
  @ObservationIgnored private let control: @MainActor () -> (any HerdrControl)?
  @ObservationIgnored private let now: @MainActor () -> Date
  /// How long a send waits for herdr before it is called a failure.
  @ObservationIgnored private let sendDeadline: Duration
  /// How often the `Sent` notice's age is redrawn while it waits.
  @ObservationIgnored private let ageTick: Duration
  /// Told after every reply herdr took, so the connection re-reads the conversation and the
  /// screen. See `PaneComposerCache.onSent`.
  @ObservationIgnored private let onSent: @MainActor (String, PaneComposerState.Attempt) -> Void
  /// The task advancing `asOf` while a `Sent` notice waits. See `startAgeing()`.
  @ObservationIgnored private(set) var sentNotice: Task<Void, Never>?

  init(
    pane: Pane,
    control: @escaping @MainActor () -> (any HerdrControl)?,
    makeUpload: @escaping @MainActor (Data, String) -> (any ImageUploading)? = { _, _ in nil },
    onSent: @escaping @MainActor (String, PaneComposerState.Attempt) -> Void = { _, _ in },
    sendDeadline: Duration = PaneComposerCopy.sendDeadline,
    ageTick: Duration = .seconds(1),
    now: @escaping @MainActor () -> Date = Date.init
  ) {
    let paneID = pane.id
    id = paneID
    self.pane = pane
    self.control = control
    attachment = PaneAttachmentModel(
      makeUpload: makeUpload,
      // `sendText`, never `submitText`: a CR would submit the bare path as the whole
      // question. The path waits in the agent's input box for the reader's reply.
      //
      // `paneID`, never the presenter's current pane: an upload takes seconds and a pane
      // switch can happen meanwhile, and the path belongs to the pane the image was staged
      // for. A local because `self` is not initialised yet.
      //
      // `control()` per hand-off, because the link can go before the upload finishes.
      handOff: { path in
        guard let herdr = control() else { throw AppError.notConnected(host: "this host") }
        try await herdr.sendText(paneID: paneID, text: path)
      }
    )
    self.onSent = onSent
    self.sendDeadline = sendDeadline
    self.ageTick = ageTick
    self.now = now
  }

  /// Records the latest snapshot of the pane, and retires `Sent` once it says the agent has
  /// moved. Call it from the session poll's diff, never from a view body.
  func paneChanged(to pane: Pane) {
    guard pane.id == self.pane.id else { return }
    self.pane = pane
    state.paneChanged(to: pane)
    stopAgeingIfSettled()
  }

  /// The conversation gained a turn, which also retires `Sent`.
  func transcriptAdvanced() {
    state.transcriptAdvanced()
    stopAgeingIfSettled()
  }

  /// Sends the typed text and submits it.
  ///
  /// Text and submit go in one command. Split in two, a failure between them leaves a
  /// half-typed answer in the agent that nobody knows about.
  func send() async {
    await perform { $0.beginSending() }
  }

  /// Sends one key press. A phone keyboard has no Escape and no Control.
  func send(_ key: PaneKey) async {
    await perform { $0.beginSending(key) }
  }

  /// Sends a reply chip. `.keys` sends a whole `AskUserQuestion` answer as one attempt.
  func send(_ chip: ReplyChip) async {
    switch chip.action {
    case .key(let key):
      await send(key)
    case .keys(let keys):
      await perform { $0.beginSending(keys) }
    }
  }

  /// Sends the failed attempt again, unchanged, rather than rebuilding it from the field.
  func retry() async {
    await perform { $0.beginRetry() }
  }

  /// Puts whichever attempt the state agreed to on the wire.
  ///
  /// The re-entry guard is the first line's `else return`, not a disabled button, because a
  /// tap can land in the frame before the button redraws.
  private func perform(
    _ begin: (inout PaneComposerState) -> PaneComposerState.Attempt?
  ) async {
    guard let attempt = begin(&state) else { return }
    sentNotice?.cancel()
    sentNotice = nil
    guard let control = control() else {
      state.failed(.notConnected(host: "this host"))
      return
    }
    let paneID = pane.id
    do {
      try await bounded {
        switch attempt {
        case .text(let text):
          // `submitText`, not `sendText(text + "\n")`: a bare LF is a line break to Claude
          // Code and submits nothing. `HerdrControl.submitText` carries the byte table.
          try await control.submitText(paneID: paneID, text: text)
        case .key(let key):
          try await control.sendKeys(paneID: paneID, keys: [key])
        case .keys(let keys):
          try await control.sendKeys(paneID: paneID, keys: keys)
        }
      }
      state.succeeded(at: now(), pane: pane)
      startAgeing()
      // A text reply retires a settled attachment row, since the question it was staged for
      // has now gone. Keep the `isSettled` guard: `remove()` cancels an upload in flight,
      // and a reply sent mid-upload must not silently discard the photograph. A key press
      // is not the reply the image was for, so it leaves the row.
      if case .text = attempt, attachment.phase?.isSettled == true { attachment.remove() }
      onSent(paneID, attempt)
    } catch {
      state.failed(Self.appError(from: error))
    }
  }

  /// Runs a send, and gives up on it after `sendDeadline`.
  ///
  /// Nothing under `CLIControl` checks cancellation, so a send already on the wire may still
  /// land. That is why the failure says herdr did not answer, not that the reply was not sent.
  ///
  /// **Not a task group.** A group waits for every child, so racing a hung send against a
  /// sleep in `withThrowingTaskGroup` waits out the hang. Instead the send runs as an
  /// unstructured task that may be abandoned. Whichever finishes first, the send or the
  /// deadline, settles the result. Everything is `@MainActor`, so "exactly once" is a `nil`
  /// check, not a lock.
  private func bounded(_ send: @escaping @Sendable () async throws -> Void) async throws {
    let work = Task<Void, any Error> { try await send() }
    let verdict: Result<Void, any Error> = await withCheckedContinuation { continuation in
      let race = SendRace(continuation)
      Task { @MainActor in
        do {
          try await work.value
          race.settle(.success(()))
        } catch {
          race.settle(.failure(error))
        }
      }
      race.deadline = Task { @MainActor [sendDeadline] in
        try? await Task.sleep(for: sendDeadline)
        guard !Task.isCancelled else { return }
        race.settle(.failure(AppError.herdrCommandFailed(reason: PaneComposerCopy.noAnswer)))
      }
    }
    try verdict.get()
  }

  /// Whichever of a send and its deadline finishes first, resolved exactly once.
  ///
  /// The second caller finds the continuation spent and returns, which stops a double
  /// resume (a crash). Settling also cancels the deadline, so a fast send leaves no sleep
  /// parked behind it.
  @MainActor
  private final class SendRace {
    private var continuation: CheckedContinuation<Result<Void, any Error>, Never>?
    var deadline: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Result<Void, any Error>, Never>) {
      self.continuation = continuation
    }

    func settle(_ result: Result<Void, any Error>) {
      guard let continuation else { return }
      self.continuation = nil
      deadline?.cancel()
      deadline = nil
      continuation.resume(returning: result)
    }
  }

  /// Keeps the `Sent` notice's age moving while it waits.
  ///
  /// It decides nothing. `paneChanged(to:)` and `transcriptAdvanced()` retire the notice,
  /// because a clock is not evidence that the agent read the reply. It stops when the phase
  /// leaves `sent`, so a settled composer holds no wake-up open.
  private func startAgeing() {
    asOf = now()
    sentNotice = Task { [weak self, ageTick] in
      while !Task.isCancelled {
        try? await Task.sleep(for: ageTick)
        guard !Task.isCancelled, let self, self.state.phase == .sent else { return }
        self.asOf = self.now()
      }
    }
  }

  private func stopAgeingIfSettled() {
    guard state.phase != .sent else { return }
    sentNotice?.cancel()
    sentNotice = nil
  }

  private static func appError(from error: any Error) -> AppError {
    (error as? AppError) ?? .herdrCommandFailed(reason: "herdr could not be reached.")
  }

  #if DEBUG
    /// A composer already in a given state, for `#Preview`s. Build the state through
    /// `PaneComposerState`'s transitions, so a preview cannot show an impossible state.
    convenience init(
      pane: Pane,
      control: @escaping @MainActor () -> (any HerdrControl)?,
      showing state: PaneComposerState
    ) {
      self.init(pane: pane, control: control)
      self.state = state
    }
  #endif
}
