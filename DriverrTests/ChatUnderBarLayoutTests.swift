import DriverrCore
import SwiftUI
import Testing
import UIKit

@testable import Driverr

/// The conversation scrolls under the pane screen's floating glass bar, as a chat app's does.
///
/// The real `PaneChatView` on the seeded transcript, inside a real `NavigationStack` whose bar
/// carries one glass button, with a stand-in composer as the `safeAreaBar` `TerminalScreen`
/// attaches. Three claims, all in one window (see `ChatCollectionViewTests.pump(until:)` for why
/// windows are scarce):
///
/// - the collection view reaches the window's top, so rows pass under the bar;
/// - at the top of the conversation its first row starts just below the bar, not under it;
/// - the bottom inset is still the composer's strip, with the top extension taken out of it.
///
/// It reads the `UICollectionView` and the `UINavigationBar` directly, because a SwiftUI frame
/// read after `.ignoresSafeArea` reports the unexpanded slot (CLAUDE.md, `GeometryReader`
/// probes). Whether the system's soft top edge paints is a look, and needs a capture.
@MainActor
@Suite("Chat under the bar", .serialized)
struct ChatUnderBarLayoutTests {
  /// A stand-in for the resting composer pill. A fixture value, not a measurement.
  private static let composer: CGFloat = 62

  /// The seed's one pane with a reported session, `needs a decision`, set to working, so no
  /// capsule floats over the conversation.
  private static var workingPane: DriverrCore.Pane {
    let pane = PreviewSupport.agentPane
    return DriverrCore.Pane(
      id: pane.id, tabID: pane.tabID, workspaceID: pane.workspaceID, title: pane.title,
      agent: pane.agent.map {
        Agent(
          name: $0.name, kind: $0.kind, status: .working, session: $0.session,
          machine: $0.machine)
      },
      terminalID: pane.terminalID, directory: pane.directory, isFocused: pane.isFocused,
      viewportRows: pane.viewportRows)
  }

  private struct Fixture: View {
    let model: PaneTranscriptModel
    let screen: PaneScreenModel
    var onComposer: @MainActor (CGRect) -> Void

    var body: some View {
      NavigationStack {
        PaneChatView(model: model, agentName: "Claude", screen: screen)
          // As `TerminalScreen.paneSurfaces` attaches the composer.
          .safeAreaBar(edge: .bottom, spacing: 0) {
            Color.green
              .frame(height: ChatUnderBarLayoutTests.composer)
              // Not `measuredFrame`, whose `onAppear` reads the first frame only, which in a
              // `NavigationStack` is laid out before the stack has its size.
              .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { onComposer($0) }
          }
          .navigationTitle("pane")
          .navigationBarTitleDisplayMode(.inline)
          .toolbar(removing: .title)
          .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Panes") {} }
          }
      }
    }
  }

  private func pump(until condition: () -> Bool, budget: Int = 200) {
    for _ in 0..<budget {
      if condition() { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
  }

  private func first<View: UIView>(_ type: View.Type, in view: UIView) -> View? {
    if let found = view as? View { return found }
    for child in view.subviews {
      if let found = first(type, in: child) { return found }
    }
    return nil
  }

  private func scrollViews(in view: UIView) -> [String] {
    (view is UIScrollView ? [String(describing: Swift.type(of: view))] : [])
      + view.subviews.flatMap { scrollViews(in: $0) }
  }

  @Test("the conversation reaches under the bar and rests its first row just below it")
  func theConversationScrollsUnderTheBar() async {
    // Loaded before the window, so the conversation is ready on the first frame.
    let model = PreviewSupport.transcript(for: Self.workingPane)
    await model.currentLoad?.value
    await model.subagentListLoad?.value
    expectTheConversation(model: model, pane: Self.workingPane, underTheBar: true)
  }

  /// A blocked pane offers Show the Screen as a capsule floating over the conversation, not as
  /// a row pinned above it, so the conversation still reaches under the bar and its first row
  /// still rests just below the bar.
  @Test("Show the Screen floats over the conversation, which still reaches under the bar")
  func showTheScreenFloatsOverTheConversation() async {
    let model = PreviewSupport.transcript(for: PreviewSupport.agentPane)
    await model.currentLoad?.value
    await model.subagentListLoad?.value
    expectTheConversation(model: model, pane: PreviewSupport.agentPane, underTheBar: true)
  }

  /// The synchronous half: `RunLoop` cannot be pumped from an `async` context.
  private func expectTheConversation(
    model: PaneTranscriptModel, pane: DriverrCore.Pane, underTheBar: Bool
  ) {
    var composer = CGRect.zero
    let window = HostedProbe.window(
      Fixture(
        model: model,
        screen: PreviewSupport.paneScreen(for: pane),
        onComposer: { composer = $0 }),
      size: HostedProbe.phone)
    pump(until: { first(UICollectionView.self, in: window) != nil && composer.width > 100 })
    guard let collection = first(UICollectionView.self, in: window),
      let bar = first(UINavigationBar.self, in: window)
    else {
      Issue.record(
        """
        No UICollectionView or no UINavigationBar under the fixture. Scroll views: \
        \(scrollViews(in: window)); navigation bar: \(first(UINavigationBar.self, in: window) != nil); \
        composer: \(composer); transcript: \(model.shown.state)
        """)
      withExtendedLifetime(window) {}
      return
    }
    let barBottom = bar.convert(bar.bounds, to: window).maxY
    // Let the self-sizing list converge before reading the rest at the top.
    for _ in 0..<10 {
      collection.layoutIfNeeded()
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }

    let frame = collection.convert(collection.bounds, to: window)
    let under = """
      The conversation's scroll view starts at y \(frame.minY) in the window, against the bar's \
      bottom at \(barBottom). Rows can pass under the glass only if it reaches the window's top, \
      and must not while a row is pinned above them.
      """
    if underTheBar {
      #expect(frame.minY < 0.5, "\(under)")
    } else {
      #expect(frame.minY > barBottom, "\(under)")
    }

    // The top of the conversation, where a reader who scrolled all the way back rests.
    collection.contentOffset = CGPoint(x: 0, y: -collection.adjustedContentInset.top)
    collection.layoutIfNeeded()
    guard let first = collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
    else {
      Issue.record("No first item in the conversation.")
      withExtendedLifetime(window) {}
      return
    }
    let firstTop = collection.convert(first.frame, to: window).minY
    let items = (collection.dataSource as? UICollectionViewDiffableDataSource<ChatSection, ChatItem>)?
      .snapshot().itemIdentifiers ?? []
    let provenance = """
      The conversation's items are \(items.prefix(3))…, and its first is \(first.frame.height) pt \
      tall. The provenance row must be the first row, drawn.
      """
    #expect(items.first == .provenance, "\(provenance)")
    #expect(first.frame.height > 10, "\(provenance)")
    // The rest of the claims are about the conversation under the bar.
    guard underTheBar else {
      withExtendedLifetime(window) {}
      return
    }
    let below = """
      At the top of the conversation the first row starts at y \(firstTop), against the bar's \
      bottom at \(barBottom). Above the bar it is drawn under the glass at rest; more than \
      \(ChatTopFade.height) below, the provenance row is still standing above the conversation.
      """
    #expect(firstTop >= barBottom - 0.5, "\(below)")
    #expect(firstTop <= barBottom + ChatTopFade.height, "\(below)")

    let indicatorTop = frame.minY + collection.verticalScrollIndicatorInsets.top
    let indicator = """
      The scroll indicator starts at y \(indicatorTop), against the bar's bottom at \
      \(barBottom). It must stay out from under the glass, as the bottom one stays out of the \
      composer.
      """
    #expect(indicatorTop >= barBottom - 0.5, "\(indicator)")

    let strip = frame.maxY - composer.minY
    let bottom = """
      adjustedContentInset.bottom is \(collection.adjustedContentInset.bottom), against the \
      \(strip) pt of the scroll view behind the composer (scroll view \(frame.minY)..\
      \(frame.maxY), composer from \(composer.minY)). The top extension must not leak into it.
      """
    #expect(abs(collection.adjustedContentInset.bottom - strip) < 0.5, "\(bottom)")

    withExtendedLifetime(window) {}
  }
}
