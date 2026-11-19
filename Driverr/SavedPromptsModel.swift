import DriverrCore
import Foundation
import Observation
import SwiftUI

/// The saved prompts the composer offers, for the whole app.
///
/// Injected through the environment, like `LiveActivityPreferencesModel`, and owned by
/// `DriverrApp`, so every composer reads the same list. The rules are
/// `DriverrCore.SavedPromptList`; this type holds the list and writes it through.
@MainActor
@Observable
final class SavedPromptsModel {
  private(set) var list = SavedPromptList()

  @ObservationIgnored private let store: any SavedPromptStore

  /// The newest write to the store. Each write waits for the one before it, so the store
  /// always ends on the newest list, and a test awaits this instead of polling the store.
  @ObservationIgnored private(set) var lastWrite: Task<Void, Never>?

  init(store: any SavedPromptStore) {
    self.store = store
  }

  var prompts: [SavedPrompt] { list.prompts }

  func load() async {
    list = SavedPromptList(await store.prompts())
  }

  func canSave(_ text: String) -> Bool { list.canSave(text) }

  func save(_ text: String) {
    update { $0.save(text) }
  }

  func rename(_ id: UUID, to name: String) {
    update { $0.rename(id, to: name) }
  }

  func delete(_ id: UUID) {
    update { $0.delete(id) }
  }

  /// Writes go to memory at once and to the store in the background, so a row appears
  /// without waiting on `UserDefaults`.
  private func update(_ change: (inout SavedPromptList) -> Void) {
    var next = list
    change(&next)
    guard next != list else { return }
    list = next
    let prompts = next.prompts
    let previous = lastWrite
    lastWrite = Task { [store] in
      await previous?.value
      await store.save(prompts)
    }
  }
}

/// Persists the saved prompts in `UserDefaults`, as one JSON array under one key.
///
/// Local to the device and not synced: a prompt is a few lines of text, not a secret, and
/// nothing else in Driverr uses iCloud. Its own key, so an unreadable list loses the prompts
/// and nothing else.
actor UserDefaultsSavedPromptStore: SavedPromptStore {
  private let defaults: UserDefaults
  static let key = "com.cunderw.driverr.savedPrompts"

  /// Takes a suite name, not an instance; see `UserDefaultsHostStore.init(suiteName:)`.
  init(suiteName: String? = nil) {
    defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
  }

  /// An undecodable payload reads as no prompts. The next save writes over it.
  func prompts() async -> [SavedPrompt] {
    guard let data = defaults.data(forKey: Self.key) else { return [] }
    return (try? JSONDecoder().decode([SavedPrompt].self, from: data)) ?? []
  }

  func save(_ prompts: [SavedPrompt]) async {
    guard let data = try? JSONEncoder().encode(prompts) else { return }
    defaults.set(data, forKey: Self.key)
  }
}

private struct SavedPromptsModelKey: EnvironmentKey {
  // Live in Release, for the reason `SettingsModelKey` gives and with the same hazard: a view
  // that misses its injection there would save over the stored prompts.
  #if DEBUG
  @MainActor static let fallback = SavedPromptsModel(store: InMemorySavedPromptStore())
  #else
  @MainActor static let fallback = SavedPromptsModel(store: AppEnvironment.live.savedPrompts)
  #endif
  nonisolated static var defaultValue: SavedPromptsModel {
    MainActor.assumeIsolated { fallback }
  }
}

extension EnvironmentValues {
  var savedPrompts: SavedPromptsModel {
    get { self[SavedPromptsModelKey.self] }
    set { self[SavedPromptsModelKey.self] = newValue }
  }
}
