import DriverrCore
import DriverrTranscript

/// One transcript per pane, owned by the connection so a disconnect takes it with it. A pane
/// is read once however many surfaces show it.
///
/// **Not `@Observable`.** `model(for:)` inserts on first ask, from inside a view body, where
/// mutating observable state is the "Modifying state during view update" trap. The models
/// inside are observable. The other per-pane caches follow the same rule.
@MainActor
final class PaneTranscriptCache {
  private let reader: TranscriptReader
  /// The reader for a pane on a machine a herdr-core added, or `nil` for `reader`'s. The SSH
  /// host's reader refuses such a pane, so with no core to reach it the chat says why.
  private let machineReader: @MainActor (Pane) -> TranscriptReader?
  /// Told a pane id whenever a re-read finds a new turn. See
  /// `PaneTranscriptModel.onAdvanced`.
  private let onAdvanced: @MainActor (String) -> Void
  private var models: [String: PaneTranscriptModel] = [:]

  init(
    reader: TranscriptReader,
    machineReader: @escaping @MainActor (Pane) -> TranscriptReader? = { _ in nil },
    onAdvanced: @escaping @MainActor (String) -> Void = { _ in }
  ) {
    self.reader = reader
    self.machineReader = machineReader
    self.onAdvanced = onAdvanced
  }

  /// The reader that reaches the computer this pane is on.
  private func reader(for pane: Pane) -> TranscriptReader {
    machineReader(pane) ?? reader
  }

  /// This pane's transcript model, made on first ask.
  ///
  /// Keyed by pane id, not by the `Pane` value, so a poll tick does not throw the fetch
  /// away.
  func model(for pane: Pane) -> PaneTranscriptModel {
    // **The `Pane` only makes a model, never updates one.** `ConnectionModel.apply(_:)`
    // records moved panes from the live tree after every poll. A second writer here is
    // wrong because a view can hold an old `Pane`: a Needs-you row under the pushed pane
    // screen wrote a replaced session back, and the next re-read opened the old file.
    if let existing = models[pane.id] { return existing }
    let model = PaneTranscriptModel(pane: pane, reader: reader(for: pane))
    model.onAdvanced = onAdvanced
    models[pane.id] = model
    return model
  }

  /// The model for a pane, if one has already been made. Never creates one, so it starts
  /// no fetch.
  func existingModel(for paneID: String) -> PaneTranscriptModel? { models[paneID] }

  /// Carries the previous link's conversations onto this one.
  ///
  /// A reconnect rebuilds this cache, because the reader closes over the transport. **Do
  /// not drop the models.** `PaneChatView` fetches from `.task(id: model.pane.id)`, and the
  /// id does not change across a reconnect, so a fresh `.idle` model is never asked and
  /// shows a spinner for ever. See `PaneTranscriptModel.relink(to:)`. A deliberate
  /// disconnect clears the cache first, so there is nothing to carry.
  func takeOver(from previous: PaneTranscriptCache?) {
    guard let previous, previous !== self else { return }
    for (id, model) in previous.models where models[id] == nil {
      // Re-hooked, because the hook is built per connection and the old one would notify
      // the previous link's composer.
      model.onAdvanced = onAdvanced
      model.relink(to: reader(for: model.pane))
      models[id] = model
    }
    previous.models.removeAll()
  }

  /// Drops the transcript of a pane that has closed, or whose conversation has moved on.
  func forget(_ paneID: String) {
    models.removeValue(forKey: paneID)?.invalidate()
  }

  /// Drops every pane that is no longer in the session. The poll's diff calls this, so a
  /// pane id herdr reuses does not get the closed pane's conversation.
  func forgetEverythingExcept(_ liveIDs: Set<String>) {
    for id in models.keys where !liveIDs.contains(id) { forget(id) }
  }
}
