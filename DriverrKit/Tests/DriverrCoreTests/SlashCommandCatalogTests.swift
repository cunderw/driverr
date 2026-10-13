import Foundation
import Testing

@testable import DriverrCore

/// Merging what a host has installed with what this session has run. Three rows fit above a
/// keyboard, so the ranking decides which three.
@Suite("Slash command catalogue")
struct SlashCommandCatalogTests {
  private func recent(_ name: String) -> SlashCommand {
    SlashCommand(name: name)
  }

  private func installed(_ pairs: [(String, String?)]) -> SlashCommandCatalog {
    SlashCommandCatalog(
      commands: pairs
        .map { SlashCommand(name: $0.0, description: $0.1, source: .userSkill) }
        .sorted { $0.name < $1.name }
    )
  }

  @Test("recents come first in their own order, the rest alphabetically")
  func ranksRecentsFirst() {
    let offered = SlashCommandMatcher.offerings(
      recents: [recent("/push"), recent("/run-tests")],
      catalog: installed([("/lint", nil), ("/memo", nil), ("/run-tests", nil)])
    )
    #expect(offered.map(\.name) == ["/push", "/run-tests", "/lint", "/memo"])
  }

  /// The transcript records that a command ran, never what it does.
  @Test("a recent that is also installed keeps its place and gains its description")
  func aRecentBorrowsItsDescription() {
    let offered = SlashCommandMatcher.offerings(
      recents: [recent("/run-tests")],
      catalog: installed([("/format", "Format the files."), ("/run-tests", "Run the test suite.")])
    )
    #expect(offered.map(\.name) == ["/run-tests", "/format"])
    #expect(offered.first?.description == "Run the test suite.")
    // Still `.recent`, which is why it is at the top.
    #expect(offered.first?.source == .recent)
  }

  @Test("a command is offered once however many places name it")
  func offersEachCommandOnce() {
    let offered = SlashCommandMatcher.offerings(
      recents: [recent("/run-tests"), recent("/run-tests")],
      catalog: installed([("/run-tests", "Run the test suite.")])
    )
    #expect(offered.map(\.name) == ["/run-tests"])
  }

  /// On a host that answers nothing, the recents are still the list.
  @Test("an empty catalogue leaves the recents exactly as they were")
  func anEmptyCatalogueChangesNothing() {
    let recents = [recent("/run-tests"), recent("/commit")]
    let offered = SlashCommandMatcher.offerings(recents: recents, catalog: .empty)
    #expect(offered.map(\.name) == ["/run-tests", "/commit"])
  }

  @Test("a session with no history offers the catalogue alone")
  func aFreshSessionOffersTheCatalogue() {
    let offered = SlashCommandMatcher.offerings(
      recents: [],
      catalog: installed([("/memo", "Jot something down."), ("/format", "Format the files.")])
    )
    #expect(offered.map(\.name) == ["/format", "/memo"])
    #expect(offered.first?.description == "Format the files.")
  }

  /// The cap belongs to `matches(_:typed:limit:)` only.
  @Test("the merge is not capped; the filter is")
  func theFilterStillCaps() {
    let offered = SlashCommandMatcher.offerings(
      recents: [recent("/run-tests")],
      catalog: SlashCommandCatalog.installed([])
    )
    #expect(offered.count > SlashCommandMatcher.maximumSuggestions)
    let shown = SlashCommandMatcher.matches(offered, typed: "/")
    #expect(shown.count == SlashCommandMatcher.maximumSuggestions)
    #expect(shown.first?.name == "/run-tests")
  }

  @Test("typing narrows the merged list the same way it narrowed the recents")
  func filtersTheMergedList() {
    let offered = SlashCommandMatcher.offerings(
      recents: [recent("/code-review")],
      catalog: installed([("/commit", nil), ("/memo", nil)])
    )
    #expect(SlashCommandMatcher.matches(offered, typed: "/co").map(\.name) == ["/code-review", "/commit"])
    #expect(SlashCommandMatcher.matches(offered, typed: "/z").isEmpty)
  }

  // MARK: - What the catalogue itself holds

  @Test("the built-ins are in every answered catalogue and each carries a description")
  func theBuiltInsAreAlwaysThere() {
    let catalog = SlashCommandCatalog.builtInsOnly
    #expect(catalog.commands.contains { $0.name == "/clear" })
    #expect(catalog.commands.allSatisfy { $0.description?.isEmpty == false })
    #expect(catalog.commands.allSatisfy { $0.name.hasPrefix("/") })
  }

  /// `empty` means Driverr does not yet know the host runs Claude Code.
  @Test("nothing is offered before the host has been asked")
  func nothingBeforeTheQuestion() {
    #expect(SlashCommandCatalog.empty.isEmpty)
  }

  /// Claude Code runs a project's `.claude/commands/review.md` instead of the built-in.
  @Test("the host wins a collision with a built-in")
  func theHostWinsACollision() {
    let catalog = SlashCommandCatalog.installed([
      SlashCommand(name: "/review", description: "This project's own review.", source: .projectCommand)
    ])
    let review = catalog.commands.first { $0.name == "/review" }
    #expect(review?.source == .projectCommand)
    #expect(review?.description == "This project's own review.")
  }

  @Test("the catalogue is sorted, so the merge does not have to sort again")
  func theCatalogueIsSorted() {
    let catalog = SlashCommandCatalog.installed([
      SlashCommand(name: "/zebra", source: .userSkill),
      SlashCommand(name: "/aardvark", source: .userSkill),
    ])
    #expect(catalog.commands.map(\.name) == catalog.commands.map(\.name).sorted())
  }

  // MARK: - Frontmatter

  @Test("a value on the key's own line is the whole of it")
  func readsAPlainValue() {
    #expect(
      SkillFrontmatter.description(inFrontmatter: ["name: memo", "description: Jot it down."])
        == "Jot it down."
    )
  }

  @Test("a folded block is joined with single spaces")
  func readsAFoldedBlock() {
    let found = SkillFrontmatter.description(inFrontmatter: [
      "name: format",
      "description: >-",
      "  Format the files this",
      "  branch changed.",
      "metadata:",
      "  kind: tool",
    ])
    #expect(found == "Format the files this branch changed.")
  }

  /// A folded paragraph break is written as a blank line.
  @Test("a blank line inside a folded block does not end it")
  func aBlankLineIsNotTheEnd() {
    let found = SkillFrontmatter.description(inFrontmatter: [
      "description: >-",
      "  First paragraph.",
      "",
      "  Second paragraph.",
    ])
    #expect(found == "First paragraph. Second paragraph.")
  }

  @Test("a literal block reads the same way")
  func readsALiteralBlock() {
    let found = SkillFrontmatter.description(inFrontmatter: [
      "description: |",
      "  One line.",
      "  Another line.",
    ])
    #expect(found == "One line. Another line.")
  }

  @Test("matching quotes are stripped and unmatched ones are not")
  func stripsMatchingQuotes() {
    #expect(SkillFrontmatter.description(inFrontmatter: [#"description: "Quoted.""#]) == "Quoted.")
    #expect(SkillFrontmatter.description(inFrontmatter: ["description: 'Quoted.'"]) == "Quoted.")
    #expect(
      SkillFrontmatter.description(inFrontmatter: [#"description: He said "no"."#])
        == #"He said "no"."#
    )
  }

  @Test("no frontmatter, no description and an empty description are all nothing")
  func nothingIsNothing() {
    #expect(SkillFrontmatter.description(inFrontmatter: []) == nil)
    #expect(SkillFrontmatter.description(inFrontmatter: ["name: memo", "kind: tool"]) == nil)
    #expect(SkillFrontmatter.description(inFrontmatter: ["description:", "name: memo"]) == nil)
    #expect(SkillFrontmatter.description(inFrontmatter: ["description:   "]) == nil)
  }

  /// Descriptions are prose with colons; ending at the first would truncate most real ones.
  @Test("a colon in prose is not a key")
  func aColonInProseIsNotAKey() {
    let found = SkillFrontmatter.description(inFrontmatter: [
      "description: >-",
      "  Use it for this: the thing it is for.",
      "  And note: it keeps going.",
    ])
    #expect(found == "Use it for this: the thing it is for. And note: it keeps going.")
  }

  /// The host's `awk` stops at the closing `---`, so only a duplicate key inside one block
  /// reaches Swift.
  @Test("the first description in a block is the one that counts")
  func theFirstDescriptionWins() {
    let found = SkillFrontmatter.description(inFrontmatter: [
      "description: The real one.",
      "name: memo",
      "description: A second one nobody expects.",
    ])
    #expect(found == "The real one.")
  }
}
