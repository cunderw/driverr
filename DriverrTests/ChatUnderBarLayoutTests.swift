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
              .measuredFrame(into: onComposer)
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

  private func navigationBar(in view: UIView) -> UINavigationBar? {
    if let bar = view as? UINavigationBar { return bar }
    for child in view.subviews {
      if let found = navigationBar(in: child) { return found }
    }
    return nil
  }

  @Test("the conversation reaches under the bar and rests its first row just below it")
  func theConversationScrollsUnderTheBar() {
    var composer = CGRect.zero
    let window = HostedProbe.window(
      Fixture(
        model: PreviewSupport.transcript(),
        screen: PreviewSupport.paneScreen(),
        onComposer: { composer = $0 }),
      size: HostedProbe.phone)
    // The transcript loads on a task, so the collection view arrives a few turns later.
    pump(until: { ScrollViewProbe.first(in: window) is UICollectionView && composer != .zero })
    guard let collection = ScrollViewProbe.first(in: window) as? UICollectionView,
      let bar = navigationBar(in: window)
    else {
      Issue.record("No UICollectionView or no UINavigationBar under the fixture.")
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
      bottom at \(barBottom). Rows can pass under the glass only if it reaches the window's top.
      """
    #expect(frame.minY < 0.5, "\(under)")

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
