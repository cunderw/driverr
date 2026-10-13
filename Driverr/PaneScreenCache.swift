import DriverrCore
import DriverrHerdr

/// One captured screen per pane, owned by the connection so a disconnect takes it with it.
///
/// Switching to Terminal and back rebuilds `PaneChatView`, so a model in the view's own
/// `@State` would send the reader back to a spinner over a screen they had already read.
///
/// Not `@Observable`, for `PaneTranscriptCache`'s reason.
@MainActor
final class PaneScreenCache {
  /// Resolved per read, so a read is never attempted on a link that has gone.
  private let control: @MainActor () -> (any HerdrControl)?
  private var models: [String: PaneScreenModel] = [:]

  init(control: @escaping @MainActor () -> (any HerdrControl)?) {
    self.control = control
  }

  /// This pane's screen model, made on first ask.
  ///
  /// Keyed by pane id, not by the `Pane` value, so a poll tick does not throw the screen
  /// away.
  func model(for pane: Pane) -> PaneScreenModel {
    if let existing = models[pane.id] {
      // Only records the fresh value. This runs inside a view body, where writing observed
      // state is the "Modifying state during view update" trap.
      existing.update(to: pane)
      return existing
    }
    let model = PaneScreenModel(pane: pane, control: control)
    models[pane.id] = model
    return model
  }

  /// The model for a pane, if one has already been made. Never creates one.
  func existingModel(for paneID: String) -> PaneScreenModel? { models[paneID] }

  /// Re-reads every opened screen on the link that just came back.
  ///
  /// This cache is kept across a reconnect, not rebuilt, because `control` resolves per
  /// read. **Do not rebuild it.** `PaneScreenView` starts its read from
  /// `.task(id: model.pane.id)`, and the id does not change across a reconnect, so a fresh
  /// model would sit in `.idle` under a spinner nothing resolves. The re-read is needed
  /// because a capture from before the outage is stale. See `PaneScreenModel.relink()`.
  func rereadOnNewLink() {
    for model in models.values { model.relink() }
  }

  /// Drops the screen of a pane that has been closed.
  func forget(_ paneID: String) {
    models.removeValue(forKey: paneID)?.invalidate()
  }

  /// Drops every pane that is no longer in the session. The poll's diff calls this.
  func forgetEverythingExcept(_ liveIDs: Set<String>) {
    for id in models.keys where !liveIDs.contains(id) { forget(id) }
  }
}
