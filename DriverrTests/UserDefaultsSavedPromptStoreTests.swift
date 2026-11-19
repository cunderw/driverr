@testable import Driverr
import DriverrCore
import Foundation
import Testing

/// A throwaway suite name per test, so one test can never see another's prompts and nothing
/// leaks into the app's real defaults.
private func makeSuiteName() -> String {
  "driverr.tests.savedprompts.\(UUID().uuidString)"
}

private func cleanUp(_ suiteName: String) {
  UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
}

/// The persisted saved-prompt store. `SavedPromptsTests` pins the list's rules; this adds
/// surviving the process, which is what makes a saved prompt worth saving.
@Suite("UserDefaultsSavedPromptStore", .serialized)
struct UserDefaultsSavedPromptStoreTests {
  private let first = SavedPrompt(
    id: UUID(uuidString: "00000000-0000-0000-0000-0000000095B1")!,
    name: "Tests", text: "Run the tests.")
  private let second = SavedPrompt(
    id: UUID(uuidString: "00000000-0000-0000-0000-0000000095B2")!,
    name: "Diff", text: "Review the diff.\nThen summarise it.")

  @Test("a store with nothing saved answers an empty list")
  func nothingSavedIsEmpty() async {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    #expect(await UserDefaultsSavedPromptStore(suiteName: suite).prompts().isEmpty)
  }

  /// A second store over the same defaults is the next launch, and it has to find the list in
  /// the same order, with renamed names and multi-line texts intact.
  @Test("the list survives into another store over the same defaults")
  func theListSurvivesTheProcess() async {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }

    await UserDefaultsSavedPromptStore(suiteName: suite).save([second, first])

    let reopened = UserDefaultsSavedPromptStore(suiteName: suite)
    #expect(await reopened.prompts() == [second, first])
  }

  /// Through the model, as the app uses it: a save, a rename and a delete reach the defaults.
  @MainActor
  @Test("the model's changes reach the next launch")
  func theModelWritesThrough() async throws {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    let model = SavedPromptsModel(store: UserDefaultsSavedPromptStore(suiteName: suite))
    await model.load()

    model.save("Run the tests.")
    model.save("Review the diff.")
    let renamed = try #require(model.prompts.last)
    model.rename(renamed.id, to: "Tests")
    model.delete(try #require(model.prompts.first).id)

    // The write is a background task, so wait for the next launch to see it rather than
    // assume it has landed.
    let next = SavedPromptsModel(store: UserDefaultsSavedPromptStore(suiteName: suite))
    let deadline = ContinuousClock.now + .seconds(5)
    repeat {
      await next.load()
      if next.prompts.map(\.name) == ["Tests"] { break }
      try await Task.sleep(for: .milliseconds(20))
    } while ContinuousClock.now < deadline
    #expect(next.prompts.map(\.name) == ["Tests"])
    #expect(next.prompts.map(\.text) == ["Run the tests."])
  }

  @Test("an undecodable value reads as no prompts")
  func anUndecodableValueIsEmpty() async {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    UserDefaults(suiteName: suite)?.set(
      Data([0x7b, 0x21]), forKey: UserDefaultsSavedPromptStore.key)

    #expect(await UserDefaultsSavedPromptStore(suiteName: suite).prompts().isEmpty)
  }
}
