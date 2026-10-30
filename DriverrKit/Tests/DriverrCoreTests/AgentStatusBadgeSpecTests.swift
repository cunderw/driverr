import Foundation
import Testing

@testable import DriverrCore

/// What a status looks like, defined once because `Driverr/AgentStatusBadge.swift` and
/// `DriverrWatch/DriverrWatch.swift` both draw it.
@Suite("AgentStatus badge spec")
struct AgentStatusBadgeSpecTests {
  @Test("blocked is a filled exclamation in the red role, in one place")
  func blockedSpec() {
    #expect(AgentStatus.blocked.symbolName == "exclamationmark.circle.fill")
    #expect(AgentStatus.blocked.hue == .red)
    #expect(AgentStatus.blocked.accessibleName == "Waiting for you")
  }

  @Test("each state carries the glyph the design named for it")
  func symbolsMatchTheDesign() {
    #expect(AgentStatus.done.symbolName == "checkmark.circle")
    // A dotted ring was indistinguishable from `idle`'s at row size.
    #expect(AgentStatus.working.symbolName == "circle.lefthalf.filled")
    #expect(AgentStatus.idle.symbolName == "circle")
    #expect(AgentStatus.unknown.symbolName == "questionmark.circle")
  }

  @Test("no two statuses share a symbol, so colour is never the only difference")
  func symbolsAreDistinct() {
    // A shared symbol leaves colour to carry the whole meaning, which fails colour-blind
    // readers and greyscale screenshots.
    let symbols = AgentStatus.allCases.map(\.symbolName)
    #expect(Set(symbols).count == AgentStatus.allCases.count)
  }

  @Test("blocked owns the only whole-shape fill, because it is the one you must find")
  func blockedStandsOut() {
    // `.fill` is the reserved whole-shape variant. A `.filled` suffix, as on `working`'s half
    // circle, is a partial fill and allowed.
    #expect(AgentStatus.blocked.symbolName.hasSuffix(".fill"))
    for status in AgentStatus.allCases where status != .blocked {
      #expect(!status.symbolName.hasSuffix(".fill"))
    }
  }

  @Test("each state carries herdr's hue role")
  func huesMatchHerdrsRoles() {
    // herdr's palette cannot be matched literally, so the role each hue plays is.
    #expect(AgentStatus.error.hue == .orange)
    #expect(AgentStatus.done.hue == .teal)
    #expect(AgentStatus.working.hue == .yellow)
    #expect(AgentStatus.idle.hue == .green)
    // herdr cannot say what this agent is doing, so no colour claims it.
    #expect(AgentStatus.unknown.hue == .neutral)
  }

  /// Red says "wants you", and `error` asks for nothing.
  @Test("a failure is drawn apart from a request, in shape and in hue")
  func errorIsNotBlocked() {
    #expect(AgentStatus.error.symbolName == "exclamationmark.triangle")
    #expect(AgentStatus.error.symbolName != AgentStatus.blocked.symbolName)
    #expect(AgentStatus.error.hue != AgentStatus.blocked.hue)
    #expect(AgentStatus.error.accessibleName == "Failed")
  }

  @Test("only unknown is neutral, so every other state is findable by colour as well")
  func neutralIsReservedForUnknown() {
    for status in AgentStatus.allCases where status != .unknown {
      #expect(status.hue != .neutral, "\(status) has lost its hue role")
    }
  }

  @Test("every status is spoken as a phrase, not as its wire value")
  func namesAreSpeakable() {
    // "blocked" is a protocol token; "Waiting for you" is what a person needs to hear.
    for status in AgentStatus.allCases {
      let spoken = status.accessibleName
      #expect(!spoken.isEmpty)
      #expect(spoken != status.rawValue, "\(status) is read out as its raw wire value")
      #expect(spoken.first?.isUppercase == true, "\(status) is not capitalised for speech")
    }
  }

  @Test("the expanded island's glyph and its card say the same thing, which is why it is hidden")
  func theGlyphAndTheCardRestateOneFact() {
    // Why `DriverrWatch`'s expanded leading region is `accessibilityHidden(true)`: the card's
    // headline beside it states the same fact. No test target compiles the widget, so this
    // pins the overlap, not the modifier.
    let hostID = UUID()
    let state = BlockedPaneActivityAttributes.ContentState(
      hosts: [
        BlockedPaneActivityAttributes.HostSummary(
          hostID: hostID, hostName: "workbox", counts: AgentStatusCounts(blocked: 1))
      ],
      blocked: BlockedPaneActivityAttributes.BlockedPaneSummary(
        hostID: hostID, hostName: "workbox", paneID: "%1", paneTitle: "build",
        agentName: "Claude"),
      lastConfirmedAt: .now
    )
    #expect(state.headline(isStale: false) == "Needs you")
    #expect(AgentStatus.blocked.accessibleName == "Waiting for you")
    #expect(state.headline(isStale: false) != AgentStatus.blocked.accessibleName)
  }
}
