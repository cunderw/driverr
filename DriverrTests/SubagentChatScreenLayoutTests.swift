import DriverrCore
import DriverrTranscript
import SwiftUI
import Testing
import UIKit

@testable import Driverr

/// The sub-agent's chat the phone pushes over the pane scene, under its own navigation bar.
///
/// The real `SubagentChatScreen` over a sub-agent opened through the real model, on the UI
/// suite's `subagentTranscript`, inside a real `NavigationStack`. With nothing pinned above the
/// conversation any more (the back bar it replaced stood there), the claims are those
/// `ChatUnderBarLayoutTests` makes for the pane's own chat: the conversation reaches under the
/// bar, and at its top the first row rests just below the bar, not under its glass. A
/// sub-agent's chat holds no provenance row, so its first row is the paging foot or the
/// parent's prompt.
@MainActor
@Suite("Sub-agent chat screen", .serialized)
struct SubagentChatScreenLayoutTests {
  private static let pane = DriverrCore.Pane(
    id: "w1:p2",
    tabID: "w1:t1",
    workspaceID: "w1",
    title: "needs a decision",
    agent: Agent(
      name: "Claude", kind: "claude", status: .working,
      session: AgentSession(
        agent: "claude", kind: "id", value: "3f8c1d20-0000-4000-8000-000000000002")),
    terminalID: "term_w1p2",
    directory: "/home/carson/dev/driverr"
  )

  private func first<View: UIView>(_ type: View.Type, in view: UIView) -> View? {
    if let found = view as? View { return found }
    for child in view.subviews {
      if let found = first(type, in: child) { return found }
    }
    return nil
  }

  private func pump(until condition: () -> Bool, budget: Int = 200) {
    for _ in 0..<budget {
      if condition() { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
  }

  @Test("the pushed sub-agent's first row rests just below the bar, and nothing is pinned above")
  func theFirstRowClearsTheBar() async throws {
    let host = AppEnvironment.subagentTranscript
    let model = PaneTranscriptModel(pane: Self.pane, reader: TranscriptReader(run: host.run))
    model.loadIfNeeded()
    await model.currentLoad?.value
    model.openSubagent(link: .toolUse(id: "toolu_1_0"), title: "analyst-7")
    let child = try #require(model.subagents.top)
    await child.currentLoad?.value
    #expect(child.transcript != nil, "The sub-agent's page never loaded: \(child.state)")
    expectTheFirstRowClearsTheBar(child: child)
  }

  /// The synchronous half: `RunLoop` cannot be pumped from an `async` context.
  private func expectTheFirstRowClearsTheBar(child: PaneTranscriptModel) {
    let window = HostedProbe.window(
      NavigationStack {
        SubagentChatScreen(
          opened: child, agentName: "Claude", screen: PreviewSupport.paneScreen(for: Self.pane))
      },
      size: HostedProbe.phone)
    pump(until: { first(UICollectionView.self, in: window) != nil })
    guard let collection = first(UICollectionView.self, in: window),
      let bar = first(UINavigationBar.self, in: window)
    else {
      Issue.record("No UICollectionView or no UINavigationBar under the pushed screen.")
      withExtendedLifetime(window) {}
      return
    }
    for _ in 0..<10 {
      collection.layoutIfNeeded()
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    #expect(
      collection.accessibilityIdentifier == "subagent.chat",
      "XCUITest sees through the push, so the sub-agent's chat needs its own identifier.")

    let barBottom = bar.convert(bar.bounds, to: window).maxY
    let frame = collection.convert(collection.bounds, to: window)
    #expect(
      frame.minY < 0.5,
      "The conversation starts at y \(frame.minY), not the window's top: something is pinned above it.")

    guard let firstItem = collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
    else {
      Issue.record("No first item in the sub-agent's conversation.")
      withExtendedLifetime(window) {}
      return
    }
    let firstTop = frame.minY + collection.adjustedContentInset.top + firstItem.frame.minY
    let below = """
      At the top of the conversation the first row starts at y \(firstTop), against the bar's \
      bottom at \(barBottom). Above it, the row is under the glass at rest; more than \
      \(ChatColumn.topGap) below, something is still pinned above the conversation.
      """
    #expect(firstTop >= barBottom - 0.5, "\(below)")
    #expect(firstTop <= barBottom + ChatColumn.topGap, "\(below)")

    let items =
      (collection.dataSource as? UICollectionViewDiffableDataSource<ChatSection, ChatItem>)?
      .snapshot().itemIdentifiers ?? []
    #expect(!items.isEmpty, "No items in the sub-agent's conversation.")
    #expect(!items.contains(.provenance), "A sub-agent's chat holds no provenance row.")
    withExtendedLifetime(window) {}
  }
}
