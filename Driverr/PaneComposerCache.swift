import DriverrCore
import DriverrHerdr
import Foundation

/// One composer per pane, owned by the connection so a disconnect takes it with it.
///
/// A failed reply keeps its text and its Retry across a switch to the Terminal surface and
/// back. `TerminalScreen` rebuilds the composer bar on that switch, so a model in the bar's
/// own `@State` would lose both.
///
/// **A reconnect keeps this object.** `control` resolves through `ConnectionModel.liveHerdr`
/// at every send, and `onSent` reads the other caches when it fires, so nothing here dies
/// with the transport. An outage is the likeliest moment for a send to fail, so a rebuild
/// would drop the text exactly when there is text to keep. A deliberate `disconnect()` still
/// clears it.
///
/// Not `@Observable`, for `PaneTranscriptCache`'s reason.
@MainActor
final class PaneComposerCache {
  /// Resolved per send, so a reply is never attempted on a link that has gone.
  private let control: @MainActor () -> (any HerdrControl)?
  /// Runs after herdr takes a reply, so the connection re-reads the conversation and the
  /// screen. Stated once here and handed to every composer, so no composer has to find
  /// its sibling caches.
  private let onSent: @MainActor (String, PaneComposerState.Attempt) -> Void
  /// How a composer's attachment gets on the wire. `nil` means the link is down, which the
  /// attachment row reports.
  private let makeUpload: @MainActor (Data, String) -> (any ImageUploading)?
  private var models: [String: PaneComposerModel] = [:]

  init(
    control: @escaping @MainActor () -> (any HerdrControl)?,
    makeUpload: @escaping @MainActor (Data, String) -> (any ImageUploading)? = { _, _ in nil },
    onSent: @escaping @MainActor (String, PaneComposerState.Attempt) -> Void = { _, _ in }
  ) {
    self.control = control
    self.makeUpload = makeUpload
    self.onSent = onSent
  }

  /// This pane's composer, made on first ask.
  ///
  /// Keyed by pane id, not by the `Pane` value. The poll hands out a new value on every tick,
  /// and rebuilding on each one would throw away a half-typed reply.
  func model(for pane: Pane) -> PaneComposerModel {
    if let existing = models[pane.id] { return existing }
    let model = PaneComposerModel(
      pane: pane, control: control, makeUpload: makeUpload, onSent: onSent)
    models[pane.id] = model
    return model
  }

  /// The composer for a pane, if one has already been made. Never creates one.
  func existingModel(for paneID: String) -> PaneComposerModel? { models[paneID] }

  /// Drops a pane's composer. Call it only for a pane that has left the session, because
  /// forgetting a composer throws away typed text and a pending Retry.
  func forget(_ paneID: String) {
    models.removeValue(forKey: paneID)
  }

  /// Drops every pane that is no longer in the session. The poll's diff calls this.
  func forgetEverythingExcept(_ liveIDs: Set<String>) {
    for id in models.keys where !liveIDs.contains(id) { forget(id) }
  }
}
