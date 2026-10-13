import Testing

@testable import DriverrCore

@Suite("AgentStatus")
struct AgentStatusTests {
  @Test("the five states rank blocked, done, working, idle, unknown")
  func urgencyOrder() {
    // Shuffled, so the assertion is on the ranking rather than the input order.
    let sorted = [AgentStatus.idle, .unknown, .blocked, .working, .done]
      .sorted { $0.sortPriority < $1.sortPriority }
    #expect(sorted == [.blocked, .done, .working, .idle, .unknown])
  }

  @Test("done outranks working, which is where Driverr parts company with herdr")
  func doneOutranksWorking() {
    // Deliberately differs from herdr's order. A phone is a triage surface: a finished agent is
    // news the user has not seen, a working one is news that has not happened.
    #expect(AgentStatus.done.sortPriority < AgentStatus.working.sortPriority)
    #expect(AgentStatus.blocked.sortPriority < AgentStatus.done.sortPriority)
  }

  @Test("a pane with no agent ranks behind every state an agent can be in")
  func noAgentRanksLast() {
    for status in AgentStatus.allCases {
      #expect(status.sortPriority < AgentStatus.noAgentSortPriority)
    }
  }

  @Test("unknown decodes from an unrecognised wire value")
  func unknownFallback() {
    #expect(AgentStatus(wireValue: "some_future_status") == .unknown)
    #expect(AgentStatus(wireValue: "blocked") == .blocked)
  }

  @Test("done comes off the wire as itself rather than collapsing to unknown")
  func doneDecodes() {
    // herdr's fifth state must not collapse to unknown.
    #expect(AgentStatus(wireValue: "done") == .done)
  }

  // MARK: - One vocabulary, not three

  @Test("every state is spoken as a title-case word, not the wire token")
  func displayNameIsHumanForEveryState() {
    #expect(AgentStatus.blocked.displayName == "Blocked")
    #expect(AgentStatus.done.displayName == "Done")
    #expect(AgentStatus.working.displayName == "Working")
    #expect(AgentStatus.idle.displayName == "Idle")
    #expect(AgentStatus.unknown.displayName == "Unknown")
    for status in AgentStatus.allCases {
      #expect(status.displayName != status.rawValue, "\(status) reads out its wire token")
    }
  }
}
