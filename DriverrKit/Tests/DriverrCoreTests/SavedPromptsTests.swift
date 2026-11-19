import DriverrCore
import Foundation
import Testing

@Suite("Saved prompts")
struct SavedPromptsTests {
  private let first = UUID(uuidString: "00000000-0000-0000-0000-0000000095A1")!
  private let second = UUID(uuidString: "00000000-0000-0000-0000-0000000095A2")!

  @Test("a save puts the prompt at the top, named after its first line")
  func aSaveGoesFirst() {
    var list = SavedPromptList()
    list.save("run the tests", id: first)
    list.save("review the diff\nthen summarise it", id: second)

    #expect(list.prompts.map(\.id) == [second, first])
    #expect(list.prompts.map(\.name) == ["review the diff", "run the tests"])
    #expect(list.prompts[0].text == "review the diff\nthen summarise it")
  }

  @Test("an empty or whitespace-only text is not saved")
  func emptyTextIsRejected() {
    var list = SavedPromptList()

    let empty = list.save("")
    let blank = list.save("  \n\t ")
    #expect(empty == nil)
    #expect(blank == nil)
    #expect(!list.canSave(" \n"))
    #expect(list.prompts.isEmpty)
  }

  @Test("a save trims the ends and keeps the inside")
  func aSaveTrimsTheEnds() {
    var list = SavedPromptList()
    let saved = list.save("\n  fix  the build \n")

    #expect(saved?.text == "fix  the build")
    #expect(saved?.name == "fix  the build")
  }

  @Test("a text already saved is not saved twice, even with other ends")
  func aDuplicateIsDropped() {
    var list = SavedPromptList()
    list.save("run the tests", id: first)

    #expect(!list.canSave("run the tests "))
    let again = list.save("  run the tests")
    #expect(again == nil)
    #expect(list.prompts.map(\.id) == [first])
  }

  @Test("a long first line is cut to the limit with an ellipsis")
  func aLongNameIsCut() {
    let text = String(repeating: "abcde ", count: 12)
    let name = SavedPromptList.defaultName(for: text)

    #expect(name.hasSuffix("…"))
    #expect(name.count <= SavedPromptList.defaultNameLimit + 1)
    #expect(name.hasPrefix("abcde abcde"))
    // A short line is left alone.
    #expect(SavedPromptList.defaultName(for: "short") == "short")
  }

  @Test("the name skips blank leading lines")
  func theNameSkipsBlankLines() {
    #expect(SavedPromptList.defaultName(for: "\n   \nsecond line\nthird") == "second line")
  }

  @Test("a rename changes the name, keeps the text and keeps the order")
  func aRenameKeepsThePlace() {
    var list = SavedPromptList()
    list.save("run the tests", id: first)
    list.save("review the diff", id: second)

    let renamed = list.rename(first, to: "  Tests  ")
    #expect(renamed)

    #expect(list.prompts.map(\.id) == [second, first])
    #expect(list.prompts[1].name == "Tests")
    #expect(list.prompts[1].text == "run the tests")
  }

  @Test("an empty name or an unknown id renames nothing")
  func anEmptyRenameChangesNothing() {
    var list = SavedPromptList()
    list.save("run the tests", id: first)
    let before = list

    let blank = list.rename(first, to: "   ")
    let unknown = list.rename(second, to: "Other")
    #expect(!blank)
    #expect(!unknown)
    #expect(list == before)
  }

  @Test("a delete removes only that prompt and keeps the order")
  func aDeleteRemovesOne() {
    var list = SavedPromptList()
    let third = UUID()
    list.save("one", id: first)
    list.save("two", id: second)
    list.save("three", id: third)

    list.delete(second)
    #expect(list.prompts.map(\.id) == [third, first])

    list.delete(UUID())
    #expect(list.prompts.map(\.id) == [third, first])
  }

  @Test("a deleted text can be saved again")
  func aDeletedTextCanReturn() {
    var list = SavedPromptList()
    list.save("one", id: first)
    list.delete(first)

    let again = list.save("one")
    #expect(again != nil)
  }

  @Test("an empty field takes the prompt as it is")
  func insertIntoEmpty() {
    #expect(SavedPromptInsertion.inserting("run the tests", into: "") == "run the tests")
  }

  @Test("text in the field gets the prompt after one space")
  func insertAppendsAfterASpace() {
    #expect(
      SavedPromptInsertion.inserting("run the tests", into: "then")
        == "then run the tests")
  }

  @Test("text that already ends in whitespace gets no second space")
  func insertAfterWhitespace() {
    #expect(SavedPromptInsertion.inserting("b", into: "a ") == "a b")
    #expect(SavedPromptInsertion.inserting("b", into: "a\n") == "a\nb")
  }

  @Test("the list round-trips through JSON")
  func theListRoundTrips() throws {
    var list = SavedPromptList()
    list.save("one", id: first)
    list.save("two", id: second)
    list.rename(first, to: "First")

    let data = try JSONEncoder().encode(list.prompts)
    let decoded = try JSONDecoder().decode([SavedPrompt].self, from: data)
    #expect(SavedPromptList(decoded) == list)
  }

  @Test("the in-memory store keeps what it was given")
  func theInMemoryStoreKeepsAList() async {
    let store = InMemorySavedPromptStore([SavedPrompt(id: first, name: "a", text: "a")])
    #expect(await store.prompts().map(\.id) == [first])

    await store.save([])
    #expect(await store.prompts().isEmpty)
  }
}
