import DriverrCore
import DriverrHerdr
import Observation

/// Rename and close: one pane's controls, above its terminal.
///
/// Its own model, like `PaneComposerModel`, because the view is rebuilt on every rotation
/// and settings change and an action in flight must not be.
@MainActor
@Observable
final class PaneActionsModel {
  let pane: Pane

  /// What the screen is asking the user, if anything. One value, so two prompts cannot be up
  /// at once.
  enum Prompt: Equatable {
    case confirm(PaneAction)
    case rename
    case failed(AppError)
  }

  var prompt: Prompt?

  /// The action waiting on a confirmation, if any. Only `close` ever sets it.
  var pendingConfirmation: PaneAction? {
    if case .confirm(let action) = prompt { return action }
    return nil
  }

  /// Draft label while the rename prompt is open.
  var draftLabel: String

  private(set) var inFlight: PaneAction?
  private(set) var failure: AppError?

  /// True once the pane has been closed. The screen watches this and leaves, rather than
  /// show a terminal wired to nothing.
  private(set) var didClose = false

  @ObservationIgnored private let control: any HerdrControl
  /// Re-reads the session after a change instead of waiting for the next poll. A closed pane
  /// that lingers reads as a failed tap and invites a second one.
  @ObservationIgnored private let onChanged: () async -> Void
  /// Called once the pane is gone.
  ///
  /// A callback, because an `onChange` on an optional model's property fires only if SwiftUI
  /// happens to re-evaluate the body. Without it the terminal stayed up after the close.
  @ObservationIgnored private let onClosed: () -> Void

  init(
    pane: Pane,
    control: any HerdrControl,
    onChanged: @escaping () async -> Void = {},
    onClosed: @escaping () -> Void = {}
  ) {
    self.pane = pane
    self.control = control
    self.onChanged = onChanged
    self.onClosed = onClosed
    draftLabel = pane.title
  }

  var isBusy: Bool { inFlight != nil }

  /// Whether this pane has a name Driverr can change. A core terminal has none.
  var canRename: Bool { control.canPerform(.rename, on: pane.id) }

  /// Runs it, or asks first if it can lose work. `PaneAction.isDestructive` decides, so a
  /// new destructive action gets the prompt without anyone remembering.
  func request(_ action: PaneAction) async {
    if action.isDestructive {
      prompt = .confirm(action)
      return
    }
    await perform(action)
  }

  /// Opens the rename prompt with the pane's current label already in it.
  func startRenaming() {
    draftLabel = pane.title
    prompt = .rename
  }

  func dismissPrompt() {
    prompt = nil
  }

  /// Takes over the prompt the replaced model had open.
  ///
  /// `TerminalSceneModel.rebuildActions` builds a new model on every tree change, which a
  /// poll produces every few seconds. Without this, a rename being typed would vanish mid-word.
  /// The caller offers this only for the same pane, so switching panes still clears the
  /// prompt. `draftLabel` comes along only when a prompt is open.
  func adoptPrompt(from previous: PaneActionsModel) {
    guard let prompt = previous.prompt else { return }
    self.prompt = prompt
    draftLabel = previous.draftLabel
  }

  /// Runs the action the user just confirmed.
  ///
  /// Takes the action as an argument because an alert's `isPresented` setter runs before the
  /// button's action and has already cleared `pendingConfirmation`.
  func confirm(_ action: PaneAction) async {
    prompt = nil
    await perform(action)
  }

  func cancelConfirmation() {
    prompt = nil
  }

  func clearFailure() {
    failure = nil
    if case .failed = prompt { prompt = nil }
  }

  /// Commits the rename. A blank or unchanged label is a cancel, not a request to erase
  /// the name.
  func commitRename() async {
    prompt = nil
    let label = draftLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty, label != pane.title else { return }
    await perform(.rename(label))
  }

  func perform(_ action: PaneAction) async {
    guard !isBusy else { return }
    inFlight = action
    failure = nil
    do {
      try await control.perform(action, on: pane.id)
      await onChanged()
      if action == .close {
        didClose = true
        onClosed()
      }
    } catch let error as AppError {
      failure = error
      prompt = .failed(error)
    } catch {
      let mapped = AppError.herdrCommandFailed(reason: "herdr could not be reached.")
      failure = mapped
      prompt = .failed(mapped)
    }
    inFlight = nil
  }
}
