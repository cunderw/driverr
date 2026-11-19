import DriverrCore
import SwiftUI
import Testing
import UIKit

@testable import Driverr

/// The conversation scrolls under the pane screen's floating glass bar, as a chat app's does.
///
/// The real `PaneChatView` on the seeded transcript, inside a real `NavigationStack` whose bar
/// carries one glass button, with a stand-in composer as the `safeAreaBar` `TerminalScreen`
/// attaches. Four claims, all in one window (see `ChatCollectionViewTests.pump(until:)` for why
/// windows are scarce):
///
/// - the collection view reaches the window's top, so rows pass under the bar;
/// - at the top of the conversation its first row starts just below the bar, not under it;
/// - the bottom inset is still the composer's strip, with the top extension taken out of it;
/// - on a blocked pane Show the Screen floats over the conversation just below the bar, read
///   through `PaneChatView.onCapsulesFrame`, pins nothing above it, and at the top of the
///   conversation the first row rests below it rather than under it.
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
    var onCapsules: @MainActor (CGRect) -> Void
    /// The stop notice's Continue opt-in, `nil` for none, as `TerminalScreen` hands it in.
    var continueAtReset: Binding<Bool>? = nil
    var typeSize: DynamicTypeSize = .large
    /// The composer's height. A tall one stands in for the keyboard under it.
    var composerHeight: CGFloat = ChatUnderBarLayoutTests.composer

    var body: some View {
      NavigationStack {
        PaneChatView(
          model: model, agentName: "Claude", screen: screen, onCapsulesFrame: onCapsules,
          continueAtReset: continueAtReset)
          // As `TerminalScreen.paneSurfaces` attaches the composer.
          .safeAreaBar(edge: .bottom, spacing: 0) {
            Color.green
              .frame(height: composerHeight)
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
      .environment(\.dynamicTypeSize, typeSize)
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
    expectTheConversation(model: model, pane: Self.workingPane, floatsCapsules: false)
  }

  /// A blocked pane offers Show the Screen as a capsule floating over the conversation, not as
  /// a row pinned above it, so the conversation still reaches under the bar, and its first row
  /// rests just below the capsule, whose bar adds to the slot's top safe area.
  @Test("Show the Screen floats over the conversation, which still reaches under the bar")
  func showTheScreenFloatsOverTheConversation() async {
    let model = PreviewSupport.transcript(for: PreviewSupport.agentPane)
    await model.currentLoad?.value
    await model.subagentListLoad?.value
    expectTheConversation(model: model, pane: PreviewSupport.agentPane, floatsCapsules: true)
  }

  /// At the largest accessibility size the floating stop stack leaves the chat readable: a
  /// live usage limit with the Continue opt-in, on a blocked pane that also offers Show the
  /// Screen, takes at most a third of the region between the bar and the composer, on the
  /// phone and on the iPad (#107). At AX3 the three blocks once covered most of the phone.
  @Test("at accessibility sizes the stop stack leaves most of the chat visible")
  func theStopStackIsSmallAtAccessibilitySizes() async {
    let model = PreviewSupport.transcript(
      for: PreviewSupport.agentPane, run: AppEnvironment.usageLimitedTranscript.run)
    await model.currentLoad?.value
    await model.subagentListLoad?.value
    #expect(
      model.transcript?.agentStop?.kind == .rateLimit,
      "The fixture must end on a usage-limit stop, got \(String(describing: model.transcript?.agentStop))")
    for size in [HostedProbe.phone, HostedProbe.pad] {
      expectASmallStopStack(model: model, size: size)
    }
  }

  /// When the stack is taller than the room between the bar and the composer, as the open
  /// stack is at AX5 with the keyboard up, it scrolls inside that room rather than riding up
  /// under the status bar and the bar's buttons. A composer tall enough to leave less room than
  /// the folded notice stands in for the keyboard.
  @Test("a stop stack taller than the room scrolls inside it, below the bar")
  func aStopStackTallerThanTheRoomScrolls() async {
    let model = PreviewSupport.transcript(
      for: PreviewSupport.agentPane, run: AppEnvironment.usageLimitedTranscript.run)
    await model.currentLoad?.value
    await model.subagentListLoad?.value
    expectAnOverflowingStackBelowTheBar(model: model)
  }

  private func expectAnOverflowingStackBelowTheBar(model: PaneTranscriptModel) {
    var composer = CGRect.zero
    var capsules: CGRect?
    let window = HostedProbe.window(
      Fixture(
        model: model,
        screen: PreviewSupport.paneScreen(for: PreviewSupport.agentPane),
        onComposer: { composer = $0 },
        onCapsules: { capsules = $0 },
        continueAtReset: .constant(false),
        typeSize: .accessibility5,
        composerHeight: 700),
      size: HostedProbe.phone)
    pump(until: {
      first(UICollectionView.self, in: window) != nil && composer.width > 100
        && capsules != nil
    })
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    guard let bar = first(UINavigationBar.self, in: window), let capsules else {
      Issue.record("No navigation bar, or no capsules (\(String(describing: capsules))).")
      withExtendedLifetime(window) {}
      return
    }
    let barBottom = bar.convert(bar.bounds, to: window).maxY
    let report = """
      With \(composer.minY - barBottom) pt between the bar's bottom at \(barBottom) and the \
      composer at \(composer.minY), the stop stack is at \(capsules.minY)..\(capsules.maxY). It \
      must stay inside that room and scroll; scroll views: \(scrollViews(in: window)).
      """
    print(report)
    #expect(composer.minY - barBottom < 100, "\(report)")
    #expect(capsules.minY >= barBottom - 0.5, "\(report)")
    #expect(capsules.maxY <= composer.minY + 0.5, "\(report)")
    withExtendedLifetime(window) {}
  }

  private func expectASmallStopStack(model: PaneTranscriptModel, size: CGSize) {
    var composer = CGRect.zero
    var capsules: CGRect?
    let window = HostedProbe.window(
      Fixture(
        model: model,
        screen: PreviewSupport.paneScreen(for: PreviewSupport.agentPane),
        onComposer: { composer = $0 },
        onCapsules: { capsules = $0 },
        continueAtReset: .constant(false),
        typeSize: .accessibility5),
      size: size)
    pump(until: {
      first(UICollectionView.self, in: window) != nil && composer.width > 100
        && capsules != nil
    })
    // Let the capsules' text settle at the scaled size.
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    guard let bar = first(UINavigationBar.self, in: window), let capsules else {
      Issue.record(
        "At \(size): no navigation bar, or no capsules (\(String(describing: capsules))).")
      withExtendedLifetime(window) {}
      return
    }
    let barBottom = bar.convert(bar.bounds, to: window).maxY
    let region = composer.minY - barBottom
    let report = """
      At \(size) and AX5 the stop stack is \(capsules.height) pt tall (\(capsules.minY)..\
      \(capsules.maxY)), against the \(region) pt between the bar's bottom at \(barBottom) and \
      the composer at \(composer.minY). It may take at most a third, \(region / 3) pt.
      """
    print(report)
    #expect(region > 200, "\(report)")
    #expect(capsules.height <= region / 3, "\(report)")
    withExtendedLifetime(window) {}
  }

  /// The synchronous half: `RunLoop` cannot be pumped from an `async` context.
  private func expectTheConversation(
    model: PaneTranscriptModel, pane: DriverrCore.Pane, floatsCapsules: Bool
  ) {
    var composer = CGRect.zero
    var capsules: CGRect?
    let window = HostedProbe.window(
      Fixture(
        model: model,
        screen: PreviewSupport.paneScreen(for: pane),
        onComposer: { composer = $0 },
        onCapsules: { capsules = $0 }),
      size: HostedProbe.phone)
    pump(until: {
      first(UICollectionView.self, in: window) != nil && composer.width > 100
        && (!floatsCapsules || capsules != nil)
    })
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
      and nothing may be pinned above them.
      """
    #expect(frame.minY < 0.5, "\(under)")

    // The capsules float over the conversation: inside the scroll view's frame, and below the
    // bar rather than under its glass.
    if floatsCapsules {
      let floating = """
        The floating capsules are at \(String(describing: capsules)), against the bar's bottom \
        at \(barBottom) and the scroll view \(frame.minY)..\(frame.maxY). They must sit over the \
        conversation, just below the bar.
        """
      if let capsules {
        #expect(capsules.minY >= barBottom - 0.5, "\(floating)")
        #expect(capsules.minY <= barBottom + 12, "\(floating)")
        #expect(capsules.maxY < frame.maxY, "\(floating)")
        #expect(capsules.height > 30, "\(floating)")
      } else {
        Issue.record("\(floating)")
      }
    } else {
      #expect(
        capsules == nil,
        "Nothing floats over a working pane's chat, got \(String(describing: capsules)).")
    }

    // The top of the conversation, where a reader who scrolled all the way back rests:
    // `contentOffset.y == -adjustedContentInset.top`. Worked out rather than scrolled to,
    // because the place is `followingLatest` and the owner's reconcile writes the end back over
    // any offset this test sets, which is the top only while the content fits.
    guard let first = collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
    else {
      Issue.record("No first item in the conversation.")
      withExtendedLifetime(window) {}
      return
    }
    let firstTop = frame.minY + collection.adjustedContentInset.top + first.frame.minY
    let items = (collection.dataSource as? UICollectionViewDiffableDataSource<ChatSection, ChatItem>)?
      .snapshot().itemIdentifiers ?? []
    let provenance = """
      The conversation's items are \(items.prefix(3))…, and its first is \(first.frame.height) pt \
      tall. The provenance row must be the first row, drawn.
      """
    #expect(items.first == .provenance, "\(provenance)")
    #expect(first.frame.height > 10, "\(provenance)")
    // Below the bar, or below the capsules where they float: at rest they cover nothing.
    let rest = floatsCapsules ? (capsules?.maxY ?? barBottom) : barBottom
    let below = """
      At the top of the conversation the first row starts at y \(firstTop), against the bar's \
      bottom at \(barBottom) and the capsules' foot at \(String(describing: capsules?.maxY)). \
      Above \(rest) it is drawn under the glass at rest, so the provenance row cannot be read; \
      more than \(ChatColumn.topGap) below, something is still pinned above the conversation.
      """
    #expect(firstTop >= rest - 0.5, "\(below)")
    #expect(firstTop <= rest + ChatColumn.topGap, "\(below)")

    let indicatorTop = frame.minY + collection.verticalScrollIndicatorInsets.top
    let indicator = """
      The scroll indicator starts at y \(indicatorTop), against \(rest), the bar's bottom or \
      the capsules' foot where they float. It must stay out from under the glass, as the \
      bottom one stays out of the composer.
      """
    #expect(indicatorTop >= rest - 0.5, "\(indicator)")

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
