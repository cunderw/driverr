import Foundation
import Testing

@testable import DriverrCore

@Suite("Live Activity preferences")
struct LiveActivityPreferencesTests {
  private let workbox = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
  private let buildbox = UUID(uuidString: "22222222-0000-0000-0000-000000000002")!

  @Test("a host nobody has touched follows the global switch")
  func anUntouchedHostFollowsTheSwitch() {
    #expect(LiveActivityPreferences().isOn(for: workbox))
    #expect(LiveActivityPreferences(isEnabled: false).isOn(for: workbox) == false)
  }

  @Test("a stopped host stays off while the switch is on")
  func aStoppedHostStaysOff() {
    var preferences = LiveActivityPreferences()
    preferences.set(false, for: workbox)
    #expect(preferences.isOn(for: workbox) == false)
    #expect(preferences.isOn(for: buildbox))
  }

  /// Stop is about one machine and the switch about the feature.
  @Test("the switch coming back on does not restart a host that was stopped")
  func theSwitchDoesNotUndoAStop() {
    var preferences = LiveActivityPreferences()
    preferences.set(false, for: workbox)
    preferences.isEnabled = false
    preferences.isEnabled = true
    #expect(preferences.isOn(for: workbox) == false)
    #expect(preferences.isStarted(for: workbox) == false)
  }

  /// The buttons are hidden while the switch is off, so this ignores it.
  @Test("a host's own Start/Stop reads the same whatever the switch says")
  func isStartedIgnoresTheSwitch() {
    var preferences = LiveActivityPreferences(isEnabled: false)
    #expect(preferences.isStarted(for: workbox))
    preferences.set(false, for: workbox)
    #expect(preferences.isStarted(for: workbox) == false)
    preferences.set(true, for: workbox)
    #expect(preferences.isStarted(for: workbox))
  }

  @Test("forgetting a deleted host drops its entry")
  func forgettingAHost() {
    var preferences = LiveActivityPreferences()
    preferences.set(false, for: workbox)
    preferences.forget(workbox)
    #expect(preferences.hostOverrides.isEmpty)
    #expect(preferences.isOn(for: workbox))
  }

  /// Synthesised `Codable` writes a dictionary keyed by `UUID` as an alternating array, which
  /// round-trips but makes the blob unreadable.
  @Test("the persisted overrides are a JSON object keyed by uuid string")
  func theOverridesAreAJSONObject() throws {
    var preferences = LiveActivityPreferences()
    preferences.set(false, for: workbox)
    let encoded = try JSONEncoder().encode(preferences)
    let payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let overrides = try #require(payload["hostOverrides"] as? [String: Bool])
    #expect(overrides == [workbox.uuidString: false])
  }

  @Test("the preferences round trip")
  func coding() throws {
    var preferences = LiveActivityPreferences(isEnabled: false)
    preferences.set(false, for: workbox)
    preferences.set(true, for: buildbox)
    #expect(
      try JSONDecoder().decode(
        LiveActivityPreferences.self, from: JSONEncoder().encode(preferences)) == preferences)
  }

  @Test("the in-memory store hands back what it was given")
  func theInMemoryStore() async {
    let store = InMemoryLiveActivityPreferenceStore()
    #expect(await store.hostOverrides().isEmpty)
    await store.save([workbox.uuidString: false])
    #expect(await store.hostOverrides() == [workbox.uuidString: false])
  }
}

@Suite("Live Activity counts sentence")
struct AgentStatusCountsActivitySummaryTests {
  /// The card's first line already names the hosts.
  @Test("the clauses match the calm sentence without its prefix")
  func theClausesMatchTheCalmSentence() {
    let counts = AgentStatusCounts(done: 1, working: 2, idle: 1, shells: 2)
    #expect(counts.activitySummary == "2 working · 1 finished · 1 idle · 2 shells")
    #expect(counts.calmSummary == "Nothing needs you · " + counts.activitySummary)
  }

  /// Unlike `calmSummary`: an escalated card still words its calm panes when expanded.
  @Test("a blocked pane does not silence the sentence")
  func aBlockedPaneDoesNotSilenceIt() {
    let counts = AgentStatusCounts(blocked: 1, working: 2)
    #expect(counts.activitySummary == "2 working")
    #expect(counts.calmSummary == nil)
  }

  @Test("nothing running reads as connected rather than as an empty line")
  func nothingRunning() {
    #expect(AgentStatusCounts().activitySummary == "Connected")
    #expect(AgentStatusCounts(blocked: 2).activitySummary == "Connected")
  }

  @Test("one shell is singular and two are plural")
  func shellsArePluralised() {
    #expect(AgentStatusCounts(shells: 1).activitySummary == "1 shell")
    #expect(AgentStatusCounts(shells: 2).activitySummary == "2 shells")
  }

  @Test("two hosts' counts add up field by field")
  func countsAdd() {
    let sum = AgentStatusCounts(blocked: 1, done: 2, working: 3, idle: 4, unknown: 5, shells: 6)
      + AgentStatusCounts(blocked: 6, done: 5, working: 4, idle: 3, unknown: 2, shells: 1)
    #expect(sum == AgentStatusCounts(
      blocked: 7, done: 7, working: 7, idle: 7, unknown: 7, shells: 7))
  }

  @Test("the counts round trip so a card can carry them")
  func coding() throws {
    let counts = AgentStatusCounts(blocked: 1, done: 2, working: 3, idle: 4, shells: 5)
    #expect(
      try JSONDecoder().decode(
        AgentStatusCounts.self, from: JSONEncoder().encode(counts)) == counts)
  }
}
