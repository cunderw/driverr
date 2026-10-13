import DriverrCore
import DriverrTranscript
import Foundation
import Testing

@testable import Driverr

/// When the composer's `/` list asks a host what it has installed, and when it does not.
///
/// The command and the parse are `DriverrTranscript`'s. This is how often it is asked: the
/// answer is about 34 KB, the largest single fetch in the app, and the chat's triggers fire
/// every few seconds, so re-asking on each would be a cost nothing on screen shows.
@MainActor
@Suite("Installed skills, per pane")
struct PaneSkillCatalogTests {
  /// Counts the skills command specifically, and answers it with two entries.
  ///
  /// Keyed on `installed_plugins.json`, which no other command this module runs carries. The
  /// listing and the page fall through to the same fixture every other test here uses.
  private func host(
    skills: [String] = ["!u\tformat", "+description: Format the files."],
    exitStatus: Int = 0,
    asked: Counter? = nil
  ) -> @Sendable (String) async throws -> CommandResult {
    let directory = "/Users/x/.claude/projects/-Users-x-Dev-driverr"
    let body = [
      #"{"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":"ship it"}}"#,
      #"{"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant","#
        + #""content":[{"type":"text","text":"shipping."}]}}"#,
    ].joined(separator: "\n") + "\n"
    let listing = [
      "1000000000", directory, "999999988\t\(body.utf8.count)\ta1b2.jsonl",
    ].joined(separator: "\n") + "\n"
    let page = "\(body.utf8.count)\tcomplete\n" + body
    return { command in
      if command.contains("installed_plugins.json") {
        asked?.bump()
        return CommandResult(
          standardOutput: exitStatus == 0 ? skills.joined(separator: "\n") + "\n" : "",
          standardError: exitStatus == 0 ? "" : "sh: not found\n",
          exitStatus: exitStatus
        )
      }
      if command.contains("date +%s") {
        return CommandResult(standardOutput: listing, standardError: "", exitStatus: 0)
      }
      if command.contains("stat -c %Y") {
        return CommandResult(
          standardOutput: "999999988\t\(body.utf8.count)\n", standardError: "", exitStatus: 0)
      }
      return CommandResult(standardOutput: page, standardError: "", exitStatus: 0)
    }
  }

  private func pane(directory: String? = "/Users/x/Dev/driverr") -> Pane {
    Pane(
      id: "w1:p2",
      tabID: "w1:t1",
      workspaceID: "w1",
      title: "needs a decision",
      agent: Agent(name: "Claude", kind: "claude", status: .blocked),
      terminalID: "term_w1p2",
      directory: directory
    )
  }

  private func settled(_ model: PaneTranscriptModel) async {
    await model.currentLoad?.value
    await model.skillCatalogLoad?.value
  }

  @Test("the first appearance fetches the catalogue and the next twenty do not")
  func fetchedOncePerPane() async {
    let asked = Counter()
    let model = PaneTranscriptModel(pane: pane(), reader: TranscriptReader(run: host(asked: asked)))

    model.loadSkillsIfNeeded()
    await settled(model)

    #expect(asked.value == 1)
    #expect(model.skillCatalog.commands.contains { $0.name == "/format" })

    // The chat's `.task` re-runs whenever the pane's identity changes, which a poll can do.
    for _ in 0..<20 { model.loadSkillsIfNeeded() }
    await settled(model)
    #expect(asked.value == 1)
  }

  /// The key is the directory, so a pane that moved has a catalogue about the wrong project
  /// scope — `.claude/skills` and `.claude/commands` are read relative to it.
  @Test("a pane whose working directory moved fetches again")
  func aMovedDirectoryRefetches() async {
    let asked = Counter()
    let model = PaneTranscriptModel(pane: pane(), reader: TranscriptReader(run: host(asked: asked)))

    model.loadSkillsIfNeeded()
    await settled(model)
    #expect(asked.value == 1)

    model.update(to: pane(directory: "/Users/x/Dev/other"))
    model.loadSkillsIfNeeded()
    await settled(model)
    #expect(asked.value == 2)
  }

  /// Appearance is a refresh trigger, and the staleness bound stops it becoming a poller.
  @Test("an appearance inside the staleness bound asks nothing, and one past it asks again")
  func appearanceRespectsTheStalenessBound() async {
    let asked = Counter()
    let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
    let model = PaneTranscriptModel(
      pane: pane(),
      reader: TranscriptReader(run: host(asked: asked)),
      now: { clock.now }
    )

    model.loadIfNeeded()
    await settled(model)
    model.loadSkillsIfNeeded()
    await settled(model)
    #expect(asked.value == 1)

    clock.advance(by: PaneTranscriptModel.skillCatalogStaleness - 1)
    model.loadSkillsIfNeeded()
    await settled(model)
    #expect(asked.value == 1, "an appearance a moment later must not re-ask")

    clock.advance(by: 2)
    model.loadSkillsIfNeeded()
    await settled(model)
    #expect(asked.value == 2, "past the bound, an appearance picks up a newly installed skill")
  }

  /// A reconnect can be to a different machine, and the key here is the directory alone. The
  /// answer in hand is dropped rather than carried onto a host that was never asked.
  ///
  /// `relink` clears it and the next appearance fetches, as for the page itself.
  @Test("a reconnect drops the catalogue and asks the new link")
  func relinkRefetches() async {
    let first = Counter()
    let second = Counter()
    let model = PaneTranscriptModel(pane: pane(), reader: TranscriptReader(run: host(asked: first)))

    model.loadIfNeeded()
    await settled(model)
    model.loadSkillsIfNeeded()
    await settled(model)
    #expect(first.value == 1)

    model.relink(
      to: TranscriptReader(
        run: host(skills: ["!u\tmemo", "+description: Jot it down."], asked: second)))
    await settled(model)
    #expect(model.skillCatalog == .empty, "the old link's answer is dropped, not carried over")

    model.loadSkillsIfNeeded()
    await settled(model)

    #expect(second.value == 1, "the new link is asked")
    #expect(model.skillCatalog.commands.contains { $0.name == "/memo" })
    #expect(!model.skillCatalog.commands.contains { $0.name == "/format" })
  }

  /// A host without the skills command answers with a shell's 127, and that must not take the
  /// chat down for a fact it does not need.
  @Test("a host that refuses leaves the chat alone and keeps the built-ins")
  func aRefusalDoesNotBreakTheChat() async {
    let model = PaneTranscriptModel(
      pane: pane(), reader: TranscriptReader(run: host(exitStatus: 127)))

    model.loadIfNeeded()
    await settled(model)
    model.loadSkillsIfNeeded()
    await settled(model)

    #expect(model.transcript?.turns.count == 2, "the conversation is unaffected")
    #expect(model.skillCatalog == .builtInsOnly)
  }

  @Test("nothing is offered before the host has been asked")
  func emptyBeforeTheFirstAsk() {
    let model = PaneTranscriptModel(pane: pane(), reader: TranscriptReader(run: host()))
    #expect(model.skillCatalog == .empty)
  }
}

/// A counter a `@Sendable` runner can bump from anywhere.
private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
  func bump() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}

/// A clock the test moves by hand, so a five-minute staleness bound costs no real seconds.
@MainActor
private final class Clock {
  private(set) var now: Date
  init(_ start: Date) { now = start }
  func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}
