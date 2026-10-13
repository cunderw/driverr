import DriverrCore
import Foundation
import Testing

@testable import Driverr

/// What an incoming `driverr://` URL asks the presenter for.
///
/// Driven through `route(url:to:)`, because a SwiftUI modifier cannot be invoked without a
/// scene, and the modifier only hands the URL over.
///
/// Which URL a card carries is `BlockedPaneActivityRouteTests`'. This is the mapping onto
/// `TerminalPresenter`. `LaunchUITests` covers the destination; the Live Activity tap itself
/// needs a device.
@MainActor
@Suite("ActivityURLRouter")
struct ActivityURLRouterTests {
  private let hostID = UUID(uuidString: "00000000-0000-0000-0000-00000000D701")!

  @Test("a single-pane card's URL asks for that pane")
  func aPaneURLRequestsThePane() {
    let presenter = TerminalPresenter()
    let url = BlockedPaneActivityRoute.url(for: .pane(hostID: hostID, paneID: "w1:p2"))

    #expect(ActivityURLRouter.route(url: url, to: presenter))

    #expect(presenter.pendingOpen == .init(hostID: hostID, paneID: "w1:p2"))
  }

  /// The multi-pane card: the one request that does not end in a presentation, hence
  /// `PendingOpen`'s intent.
  @Test("a multi-pane card's URL asks for the host's tree")
  func aHostURLRequestsTheHost() {
    let presenter = TerminalPresenter()
    let url = BlockedPaneActivityRoute.url(for: .host(hostID: hostID))

    #expect(ActivityURLRouter.route(url: url, to: presenter))

    #expect(presenter.pendingOpen == .init(hostID: hostID, intent: .host))
  }

  /// A card outlives the build that posted it, and the app can be handed any URL, so nothing is
  /// asked for and nothing is said.
  @Test("a URL this build does not understand asks for nothing")
  func anUnrecognisedURLDoesNothing() {
    for string in [
      "https://example.com",
      "driverr://tab?host=00000000-0000-0000-0000-00000000D701",
      "driverr://pane?host=00000000-0000-0000-0000-00000000D701",
      "driverr://host?host=workbox",
    ] {
      let presenter = TerminalPresenter()

      #expect(!ActivityURLRouter.route(url: URL(string: string)!, to: presenter), "\(string)")

      #expect(presenter.pendingOpen == nil, "'\(string)' asked for something")
    }
  }

  /// The whole path a card takes, end to end, with only the system's own delivery left out.
  @Test("a card's own URL round-trips into the request it names")
  func aCardsURLRoundTripsIntoARequest() throws {
    func state(blocked: Int) -> BlockedPaneActivityAttributes.ContentState {
      BlockedPaneActivityAttributes.ContentState(
        hosts: [
          BlockedPaneActivityAttributes.HostSummary(
            hostID: hostID, hostName: "workbox",
            counts: AgentStatusCounts(blocked: blocked))
        ],
        blocked: BlockedPaneActivityAttributes.BlockedPaneSummary(
          hostID: hostID, hostName: "workbox", paneID: "w1:p2",
          paneTitle: "needs a decision", agentName: "Claude"),
        lastConfirmedAt: .now)
    }

    let one = TerminalPresenter()
    ActivityURLRouter.route(
      url: try #require(BlockedPaneActivityRoute.url(for: state(blocked: 1))), to: one)
    #expect(one.pendingOpen == .init(hostID: hostID, paneID: "w1:p2"))

    let many = TerminalPresenter()
    ActivityURLRouter.route(
      url: try #require(BlockedPaneActivityRoute.url(for: state(blocked: 3))), to: many)
    #expect(many.pendingOpen == .init(hostID: hostID, intent: .host))

    // A tap on a calm card opens the host it names.
    let calm = TerminalPresenter()
    let calmState = BlockedPaneActivityAttributes.ContentState(
      hosts: [
        BlockedPaneActivityAttributes.HostSummary(
          hostID: hostID, hostName: "workbox", counts: AgentStatusCounts(working: 2))
      ],
      lastConfirmedAt: .now)
    ActivityURLRouter.route(
      url: try #require(BlockedPaneActivityRoute.url(for: calmState)), to: calm)
    #expect(calm.pendingOpen == .init(hostID: hostID, intent: .host))
  }
}
