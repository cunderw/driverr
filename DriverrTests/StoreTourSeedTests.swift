import DriverrCore
import DriverrTranscript
import Foundation
import Testing

@testable import Driverr

/// What `-uiTestingDemoTranscript` adds to the seed, and that no other launch gets it. Every
/// other UI class reads the ordinary seed, so a leak here changes what they assert on.
@Suite("Store tour seed", .timeLimit(.minutes(1)))
struct StoreTourSeedTests {
  private func turns(_ host: FakeTranscriptHost) -> [FakeTranscriptHost.Turn] {
    host.sessions.first?.turns ?? []
  }

  /// The calls a turn writes, or none for a turn of words.
  private func calls(_ turn: FakeTranscriptHost.Turn?) -> [ToolCall] {
    guard case .tools(let calls)? = turn?.speaker else { return [] }
    return calls
  }

  @Test("An ordinary launch seeds workbox alone, or workbox then beta")
  func anOrdinaryLaunchSeedsNoTourHosts() {
    let one = AppEnvironment.seededHosts(
      seedsHost: true, seedsSecondHost: false, isStoreTour: false)
    #expect(one.map(\.id) == [DriverrCore.Host.uiTestSeed.id])

    let two = AppEnvironment.seededHosts(
      seedsHost: true, seedsSecondHost: true, isStoreTour: false)
    #expect(two.map(\.id) == [DriverrCore.Host.uiTestSeed.id, DriverrCore.Host.uiTestSecondSeed.id])
  }

  @Test("The tour's hosts need the seed flag too")
  func theTourFlagAloneSeedsNothing() {
    let hosts = AppEnvironment.seededHosts(
      seedsHost: false, seedsSecondHost: false, isStoreTour: true)
    #expect(hosts.isEmpty)
  }

  @Test("The store tour lists three hosts, workbox first, each at its own address")
  func theStoreTourListsThreeHosts() {
    let hosts = AppEnvironment.seededHosts(
      seedsHost: true, seedsSecondHost: false, isStoreTour: true)
    #expect(hosts.count == 3)
    #expect(hosts.first?.id == DriverrCore.Host.uiTestSeed.id)
    // Known hosts are keyed by hostname, so a shared address would share a trust decision.
    #expect(Set(hosts.map(\.hostname)).count == hosts.count)
    #expect(Set(hosts.map(\.id)).count == hosts.count)
  }

  @Test("An ordinary launch serves the seeded conversation, which ends on words")
  func anOrdinaryLaunchServesTheSeededConversation() {
    let ordinary = turns(AppEnvironment.defaultConversation(isStoreTour: false))
    let seeded = turns(AppEnvironment.seededTranscript)
    #expect(ordinary.map(\.text) == seeded.map(\.text))
    #expect(calls(ordinary.last).isEmpty)
  }

  /// The tour's terminal ends on `Proceed with the migration? (y/n)`. A pending call on a
  /// blocked pane draws Approve and Deny, which send `y` and `n`.
  @Test("The store tour's conversation ends on one call that is waiting for an answer")
  func theStoreTourConversationEndsOnAPendingCall() throws {
    let tour = turns(AppEnvironment.defaultConversation(isStoreTour: true))
    let pending = calls(tour.last)
    #expect(pending.count == 1)
    #expect(pending.first?.outcome == .pending)
    #expect(pending.first?.asksItsOwnQuestions == false)

    // The Needs-you row quotes the last words, and `SessionTreeUITests` matches these two lines
    // on the ordinary seed. The tour says the same thing in its `needs-you` capture.
    let lastWords = tour.last { $0.speaker.isAssistantWords }?.text
    let seededWords = turns(AppEnvironment.seededTranscript).last?.text
    #expect(lastWords == seededWords)
  }

  /// The `chat` capture shows the bar's sub-agents button, which needs at least one active
  /// sub-agent. Read through a real `TranscriptReader`, so the meta and the file's age are
  /// parsed as the pane parses them. No turns are merged, because the tour's page carries no
  /// spawn line; the rows are what the files alone say.
  @Test("The store tour serves two running sub-agents, and an ordinary launch serves none")
  func theStoreTourServesActiveSubagents() async throws {
    let tour = AppEnvironment.defaultConversation(isStoreTour: true)
    let session = try #require(tour.sessions.first)
    let list = try await TranscriptReader(run: tour.run)
      .subagentList(directory: tour.directory, sessionID: session.sessionID)
    let active = list.activeRows(merging: [], asOf: .now)
    #expect(active.count == 2)
    #expect(active.allSatisfy { $0.state == .running })

    #expect(AppEnvironment.defaultConversation(isStoreTour: false).subagents.isEmpty)
  }
}

extension FakeTranscriptHost.Turn.Speaker {
  fileprivate var isAssistantWords: Bool {
    if case .assistant = self { return true }
    return false
  }
}
