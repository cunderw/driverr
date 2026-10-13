import DriverrCore
import SwiftUI
import Testing
import UIKit

@testable import Driverr

/// `PaneComposerBar`'s measured height with an empty field, the same 115 the other chat layout
/// suites use, so their numbers compare.
private let composerHeight: CGFloat = 115

/// Long enough that both windows have a scroll to rest at the end of, and no longer.
///
/// **Keep the count low and buy height with text, not rows.** Each row is a separate hosting
/// hierarchy laid out on the main actor, and suites run in parallel, so rows here take
/// main-actor time from every other test in the bundle. Adding rows has failed tests in other
/// suites, in their names. See `pump(until:)`.
private let turnCount = 4

/// An accent no bundled theme ships, so a cell drawing the system accent or a default-valued
/// environment key cannot be mistaken for one that received this.
private let handedAccent = Color(red: 0.13, green: 0.77, blue: 0.41)
private let changedAccent = Color(red: 0.91, green: 0.29, blue: 0.13)

/// Constant inputs, so no reconfigure fires and the cells are built once.
@MainActor
private let spikeRowInputs = ChatRowInputs(
  agentStatus: nil,
  openRuns: OpenToolRuns(),
  expanded: [],
  selection: ReplyChipSelection(),
  isSending: false,
  contentWidth: 0,
  render: TranscriptRender(),
  paging: nil,
  isPagingBack: false,
  pagingError: nil,
  activity: nil
)

private func spikeTranscript() -> [TranscriptTurn] {
  (0..<turnCount).map { index in
    let body = """
      Turn \(index) of the spike fixture. This is deliberately several sentences rather than a \
      word, because a row one line tall would let the whole transcript fit inside the pad \
      window and there would be no resting position to measure. The composer is \
      \(Int(composerHeight)) points tall and the question the suite asks is whether the \
      collection view is ever told so, through its safe area or through its adjusted content \
      inset. The pad window is 1376 points tall and the rows are wider there, so each one \
      renders shorter than it does on the phone and the fixture has to be tall enough for the \
      pad rather than for the phone. Height is bought here, in one row, rather than by adding \
      rows: every row is a real TranscriptTurnView laid out in a real window, and the tests \
      running in parallel with this one have wall-clock deadlines that a starved main thread \
      breaks. Four turns of this length clear the 1376 pt pad window with room to spare, which \
      is the only thing the count has to do, and each row removed is a whole hosting hierarchy \
      that is not laid out nine times per run. Text is the cheap half: this paragraph is long \
      deliberately, and lengthening it further is the right way to buy height if a future case \
      ever needs more. A paragraph wraps at the width of the window it is laid out in, so the same \
      text is taller on the phone than on the pad, and the pad is the case that sets the minimum. \
      If the font or the padding of a row ever changes, measure the rows again before trimming \
      anything here. A shorter paragraph can leave the pad cases with no scroll to rest at, and \
      each of them would then compare one resting position with itself, which passes and proves \
      nothing. When a sentence here is reworded, count the characters before and after, so the \
      paragraph does not get shorter. Adding rows here is the one change to this file that breaks \
      tests somewhere else, so buy height with sentences and not with turns.
      """
    // Every turn is `.human`, for the same reason as the count: an `.assistant` turn runs the
    // markdown renderer on the main actor, and this suite measures only geometry.
    return TranscriptTurn(id: "turn-\(index)", speech: .human(body))
  }
}

/// What the cells resolved for `\.themeAccent`, reported out of the hosting configuration.
///
/// A class because the reporting happens inside a SwiftUI body, and the theme-change case reads
/// it on both sides of a state change.
@MainActor
private final class AccentSink {
  var seen: [Color] = []
  var latest: Color? { seen.last }
}

/// Reads `\.themeAccent` from wherever it is placed and reports it.
///
/// A zero-size overlay inside the same row closure, so it resolves the environment
/// `TranscriptTurnView` resolves. This tier cannot read the rendered colour back, so this asks
/// whether the value crossed the hosting boundary into the cell.
private struct AccentProbe: View {
  @Environment(\.themeAccent) private var accent
  let sink: AccentSink

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onAppear { sink.seen.append(accent) }
      .onChange(of: accent) { _, new in sink.seen.append(new) }
  }
}

// The fixture's transcript is there on the first frame. A delayed-arrival variant caught
// nothing more and cost a second layout convergence; `PaneChatUITests` covers arrival with
// `-uiTestingSlowTranscript`.

/// The slot's measured height, read back into the representable with the same one-frame
/// delay production has. File scope for `SpikeTheme`'s reason.
@MainActor
@Observable
private final class SpikeSlot {
  var height: CGFloat = 0
}

/// Where the composer's bar is, in window coordinates, reported on every layout pass.
/// `measuredFrame` reports once, so a case that resizes its window would read a stale edge.
///
/// Not `@Observable`: no view body reads it.
@MainActor
private final class SpikeBar {
  var frame: CGRect = .zero
}

/// The accent the fixture hands in, changeable after the window exists.
///
/// File scope on purpose: `@Observable` on a `private` type nested in the suite does not
/// compile, and because both test targets build under one scheme, that compile error would
/// take `scripts/look.sh` down too.
@MainActor
@Observable
private final class SpikeTheme {
  var accent: Color
  var foreground: Color

  init(accent: Color, foreground: Color) {
    self.accent = accent
    self.foreground = foreground
  }
}

/// Three places a `GeometryProxy`'s `safeAreaInsets.bottom` can be read on the SwiftUI side.
/// The coordinator sets `contentInset.bottom` from a SwiftUI-side number, because the `UIView`'s
/// own `safeAreaInsets` is 0 in every arrangement, and where it is read decides whether it is
/// 115 or 0.
///
/// - `atTheChatRoot`: on the container the `safeAreaBar` is attached to, `PaneChatView`'s root.
/// - `onTheRepresentable`: on the representable, before `.ignoresSafeArea(.container, edges:
///   .bottom)`.
/// - `outsideTheIgnore`: on the result of that modifier.
@MainActor
final class SwiftUIInsetReadings {
  var atTheChatRoot: CGFloat?
  var onTheRepresentable: CGFloat?
  var outsideTheIgnore: CGFloat?
  /// The height of the safe-area-respecting slot the conversation is placed in: the SwiftUI
  /// half of the inset arithmetic.
  var slotHeight: CGFloat?
  /// The frame read after `.ignoresSafeArea(.container, edges: .bottom)`. It reports the
  /// un-expanded number, so it cannot be used for the inset.
  var surfaceBottom: CGFloat?
}

/// One row of either fixture, built the way `PaneChatView.chatRow` builds a production one.
///
/// Only `.turn` draws anything. The tail is the 1 pt marker with the same 9 pt padding, so the
/// content's bottom edge is where a production one would be.
@MainActor
@ViewBuilder
private func spikeRow(
  _ item: ChatItem,
  in turns: [TranscriptTurn],
  sink: AccentSink
) -> some View {
  switch item {
  case .turn(let id):
    if let turn = turns.first(where: { $0.id == id }) {
      TranscriptTurnView(
        turn: turn,
        agentName: "spike",
        isNewest: turn.id == turns.last?.id,
        previousTurn: nil,
        isFinalBlockedAnswer: false,
        agentStatus: nil,
        isOpen: false,
        isExpanded: false,
        onToggleOpen: {},
        onToggleExpand: {}
      )
      .frame(maxWidth: ChatColumn.width, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, ChatColumn.inset)
      .padding(.vertical, 9)
      .overlay(alignment: .topLeading) { AccentProbe(sink: sink) }
    }
  case .tail:
    Color.clear
      .frame(height: 1)
      .padding(.vertical, 9)
      .frame(maxWidth: .infinity, alignment: .leading)
  case .paging, .activity, .reply:
    EmptyView()
  }
}

/// `spikeRow` as a **nameable** type, so a test can ask the collection view for its coordinator.
///
/// A `@ViewBuilder` function's return type is opaque, so
/// `collection.delegate as? ChatCollectionView<…>.Coordinator` would have no type to cast to.
private struct SpikeRow: View {
  let item: ChatItem
  let turns: [TranscriptTurn]
  let sink: AccentSink

  var body: some View {
    spikeRow(item, in: turns, sink: sink)
  }
}

/// The same collection view, hosted through a `UIViewControllerRepresentable`, to ask whether
/// view-controller containment's safe-area chain carries a `safeAreaBar` where a bare `UIView`
/// gets nothing.
///
/// Nothing here sets `additionalSafeAreaInsets` or `contentInset`: the question is whether the
/// number arrives on its own. It shares `ChatCollectionView.makeCollection(wiredTo:)` with
/// production, so this compares two hostings rather than two collection views.
private struct ControllerHostedChatCollection<Row: View>: UIViewControllerRepresentable {
  var turns: [TranscriptTurn]
  var accent: Color
  var accentForeground: Color
  @ViewBuilder var row: (ChatItem) -> Row

  func makeCoordinator() -> ChatCollectionView<Row>.Coordinator {
    ChatCollectionView<Row>.Coordinator(
      row: row,
      accent: accent,
      accentForeground: accentForeground
    )
  }

  func makeUIViewController(context: Context) -> UIViewController {
    let controller = UIViewController()
    let collection = ChatCollectionView<Row>.makeCollection(wiredTo: context.coordinator)
    // The collection view is the controller's view, so the controller adds no frame, margin or
    // inset of its own. Anything the scroll view reports is the containment chain's doing.
    controller.view = collection
    context.coordinator.apply(
      turns: turns, showsPaging: false, showsActivity: false, inputs: spikeRowInputs)
    return controller
  }

  func updateUIViewController(_ controller: UIViewController, context: Context) {
    context.coordinator.row = row
    context.coordinator.accent = accent
    context.coordinator.accentForeground = accentForeground
    context.coordinator.apply(
      turns: turns, showsPaging: false, showsActivity: false, inputs: spikeRowInputs)
  }
}

/// The controller-hosted collection view under the same 115 pt bar as `SpikeFixture`.
///
/// The plain arrangement, with no `.ignoresSafeArea`, because that is the one the containment
/// chain would act through.
private struct ControllerFixture: View {
  var turns: [TranscriptTurn]
  var theme: SpikeTheme
  var sink: AccentSink
  var onComposer: @MainActor (CGRect) -> Void

  var body: some View {
    ControllerHostedChatCollection(
      turns: turns,
      accent: theme.accent,
      accentForeground: theme.foreground
    ) { item in
      spikeRow(item, in: turns, sink: sink)
    }
    .safeAreaBar(edge: .bottom, spacing: 0) {
      Color.green
        .frame(height: composerHeight)
        .measuredFrame(into: onComposer)
    }
  }
}

/// The chat under the composer: `ChatCollectionView` with real rows, inset by a bar of the
/// composer's height.
///
/// Under `HostedProbe.window(_:size:)` the bar is the only bottom inset. Under
/// `HostedProbe.window(_:size:safeAreaBottom:)` a declared home indicator is in play too, and
/// the strip behind the card is the bar plus that number; only
/// `theOwnerRestsTheConversationUnderAHomeIndicator` uses it.
private struct SpikeFixture: View {
  var turns: [TranscriptTurn]
  var theme: SpikeTheme
  var sink: AccentSink
  /// Whether the representable declares that it draws into the bottom safe area. A
  /// `UIViewRepresentable` gets a shrunk frame by default; this asks for the whole frame.
  var ignoresBottomSafeArea: Bool
  /// The bar's height handed across the boundary. 0 for the cases that hand in no inset, which
  /// pin what the platform does on its own.
  var bottomInset: CGFloat = 0
  /// Whether the representable is wrapped as production wraps it, in `Color.clear.overlay { … }`,
  /// so the jump-to-latest control aligns to the safe slot while the conversation draws out of
  /// it. The bare arrangement once passed while the shipped one opened blank.
  var wrapsInClearSlot: Bool = false
  /// Where the slot's measured height lands, so the representable can be handed it.
  var slot = SpikeSlot()
  var jumpToken: Int = 0
  var onReaderState: (ChatReaderState) -> Void = { _ in }
  var onComposer: @MainActor (CGRect) -> Void
  var readings = SwiftUIInsetReadings()
  /// Only the case that resizes its window reads it.
  var bar = SpikeBar()

  var body: some View {
    // Stands in for `PaneChatView`'s root `VStack`, which is what `TerminalScreen` attaches the
    // `safeAreaBar` to.
    VStack(spacing: 0) {
      collection
    }
    .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.bottom }) {
      readings.atTheChatRoot = $0
    }
    .safeAreaBar(edge: .bottom, spacing: 0) {
      Color.green
        .frame(height: composerHeight)
        .measuredFrame(into: onComposer)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { bar.frame = $0 }
    }
  }

  @ViewBuilder
  private var collection: some View {
    if ignoresBottomSafeArea {
      if wrapsInClearSlot {
        Color.clear
          .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
            readings.slotHeight = $0
            slot.height = $0
          }
          .overlay {
            drawnIntoTheBottomSafeArea
              .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).maxY }) {
                readings.surfaceBottom = $0
              }
          }
      } else {
        drawnIntoTheBottomSafeArea
      }
    } else {
      chat
    }
  }

  private var drawnIntoTheBottomSafeArea: some View {
    chat
      .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.bottom }) {
        readings.onTheRepresentable = $0
      }
      .ignoresSafeArea(.container, edges: .bottom)
      .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.bottom }) {
        readings.outsideTheIgnore = $0
      }
  }

  private var chat: some View {
    ChatCollectionView(
      turns: turns,
      showsPaging: false,
      showsActivity: false,
      visibleHeight: wrapsInClearSlot ? slot.height : bottomInset,
      accent: theme.accent,
      accentForeground: theme.foreground,
      rowInputs: spikeRowInputs,
      jumpToken: jumpToken,
      expansionToken: 0,
      dismissesKeyboardImmediately: false,
      onReaderState: onReaderState
    ) { item in
      SpikeRow(item: item, turns: turns, sink: sink)
    }
  }
}

/// `ChatCollectionView`, the `UICollectionView` that owns the chat's scroll position, across the
/// SwiftUI boundary it is hosted through. Real `TranscriptTurnView` rows, so these tests say
/// something about the shipped owner, which the plain-colour replicas cannot.
///
/// - The inset. A SwiftUI `ScrollView` under a `safeAreaBar` gets the bar's height as
///   `adjustedContentInset.bottom`. A `UIViewRepresentable` does not, so the owner is handed the
///   height from the SwiftUI side.
/// - The environment. `\.themeAccent` does not cross a `UIHostingConfiguration`, whose content
///   is a separate hosting hierarchy, so `ChatCollectionView` hands it in per cell. Identifiers
///   surviving cell reuse cannot be asked in-process; see `HostedProbe`.
/// - The glass. Whether the soft bottom edge looks right is a look, not a geometry, and needs a
///   capture.
///
/// `.serialized`: see `ChatGlassLayoutTests`.
@MainActor
@Suite("Chat collection view bridges", .serialized)
struct ChatCollectionViewTests {
  private typealias Measured = (
    scrollBounds: CGRect,
    insetBottom: CGFloat,
    safeAreaBottom: CGFloat,
    lastCell: CGRect,
    /// Where the content's own bottom edge rests, in window coordinates. The resting rule,
    /// `contentSize - bounds + adjustedContentInset.bottom`, is about the content, and the last
    /// item is the tail marker, not a turn.
    contentBottom: CGFloat,
    composer: CGRect,
    contentHeight: CGFloat
  )

  /// Turns the run loop until `condition` holds, or until the budget runs out.
  ///
  /// **This suite's main-actor cost fails other suites.** Suites run in parallel, and
  /// `.serialized` only orders tests inside one suite. Pumping and row layout both hold the main
  /// thread, so tests elsewhere that wait on main-actor work time out in their own names. Wait
  /// for the condition, never for a fixed duration, keep rows few and `.human`, and fold new
  /// claims into an existing window rather than adding one. Nothing enforces this.
  private func pump(until condition: () -> Bool, budget: Int = 40) {
    for _ in 0..<budget {
      if condition() { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
  }

  /// What the owner derives `contentInset.bottom` from: the scroll view's real bounds minus the
  /// SwiftUI slot it was placed in.
  private func collectionInset(in window: UIWindow) -> CGFloat? {
    (ScrollViewProbe.first(in: window) as? UICollectionView)?.adjustedContentInset.bottom
  }

  /// Runs layout passes until `contentOffset` stops moving, or until the budget runs out.
  ///
  /// A self-sizing list converges over several passes, because `contentSize` is estimates until
  /// the cells are measured. A position read mid-convergence is one the reader never sees.
  private func settle(_ collection: UICollectionView, budget: Int = 10) {
    var previous = CGFloat.infinity
    for _ in 0..<budget {
      collection.layoutIfNeeded()
      let now = collection.contentOffset.y
      if abs(now - previous) < 0.5 { return }
      previous = now
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
  }

  /// Lays the fixture out, rests it at the end, and reads the numbers off the `UICollectionView`.
  ///
  /// The cell frame comes from `layoutAttributesForItem`, not `measuredFrame`. A cell is
  /// created when it scrolls in, so its `onAppear` would race the resting scroll. The composer
  /// uses `measuredFrame` because it is a SwiftUI view that does not move.
  private func measure(
    size: CGSize,
    theme: SpikeTheme,
    sink: AccentSink,
    ignoringBottomSafeArea: Bool = true,
    bottomInset: CGFloat = 0,
    wrappingInAClearSlot: Bool = false,
    readings: SwiftUIInsetReadings = SwiftUIInsetReadings()
  ) -> (Measured, UIWindow) {
    let turns = spikeTranscript()
    var composer = CGRect.zero
    let window = HostedProbe.window(
      SpikeFixture(
        turns: turns,
        theme: theme,
        sink: sink,
        ignoresBottomSafeArea: ignoringBottomSafeArea,
        bottomInset: bottomInset,
        wrapsInClearSlot: wrappingInAClearSlot,
        onComposer: { composer = $0 },
        readings: readings
      ),
      size: size
    )
    guard let collection = ScrollViewProbe.first(in: window) as? UICollectionView else {
      return ((.zero, 0, 0, .zero, 0, composer, 0), window)
    }
    // A snapshot apply and several self-sizing passes still have to run after `HostedProbe`'s
    // pump. Wait for the condition; see `pump(until:)`.
    let last = IndexPath(item: turns.count - 1, section: 0)
    pump(until: { collection.layoutAttributesForItem(at: last) != nil })
    collection.layoutIfNeeded()

    let attributes = collection.layoutAttributesForItem(at: last)
    let lastCell = attributes.map { collection.convert($0.frame, to: window) } ?? .zero
    let measured: Measured = (
      scrollBounds: collection.convert(collection.bounds, to: window),
      insetBottom: collection.adjustedContentInset.bottom,
      safeAreaBottom: collection.safeAreaInsets.bottom,
      lastCell: lastCell,
      contentBottom: collection.convert(
        CGPoint(x: 0, y: collection.contentSize.height), to: window
      ).y,
      composer: composer,
      contentHeight: collection.contentSize.height
    )
    return (measured, window)
  }

  /// The bar's height reaches a `UIViewRepresentable` as geometry and never as an inset, in
  /// either arrangement. Under a 115 pt `safeAreaBar(edge: .bottom)`:
  ///
  /// | arrangement | bounds | `safeAreaInsets.bottom` | `adjustedContentInset.bottom` |
  /// |---|---|---|---|
  /// | phone, SwiftUI `ScrollView` (`ChatGlassLayoutTests`) | 0..874 | — | **115** |
  /// | phone, representable, default | **0..759** | 0 | **0** |
  /// | phone, representable, ignoring the bottom safe area | 0..874 | 0 | **0** |
  /// | pad, SwiftUI `ScrollView` (`ChatGlassLayoutTests`) | 0..1376 | — | **115** |
  /// | pad, representable, default | **0..1261** | 0 | **0** |
  /// | pad, representable, ignoring the bottom safe area | 0..1376 | 0 | **0** |
  ///
  /// By default SwiftUI shrinks the representable's frame to the bar's top edge (759, 1261) and
  /// tells the `UIView` nothing. Drawing into the safe area gives the frame back whole and still
  /// tells it nothing. So by default nothing passes behind the glass, and when ignoring the safe
  /// area the newest row rests under the card. That is why the owner is handed the bar's height
  /// from the SwiftUI side.
  ///
  /// These fail the day the safe area reaches a representable, which would let the owner drop
  /// the hand-over.
  @Test("the bar's height reaches the representable as geometry, never as an inset")
  func theSafeAreaDoesNotReachTheRepresentableOnThePhone() {
    expectTheBarIsGeometryOnly(size: HostedProbe.phone, shrunkTo: 759, on: "phone")
  }

  @Test("the bar's height reaches the representable as geometry on the pad too, at 1261")
  func theSafeAreaDoesNotReachTheRepresentableOnThePad() {
    expectTheBarIsGeometryOnly(size: HostedProbe.pad, shrunkTo: 1261, on: "pad")
  }

  /// Measures both arrangements at one window size and pins every number in the table above.
  private func expectTheBarIsGeometryOnly(size: CGSize, shrunkTo: CGFloat, on device: String) {
    let theme = SpikeTheme(accent: handedAccent, foreground: .white)
    let (ignoring, ignoringWindow) = measure(
      size: size,
      theme: theme,
      sink: AccentSink(),
      ignoringBottomSafeArea: true
    )
    let (byDefault, defaultWindow) = measure(
      size: size,
      theme: theme,
      sink: AccentSink(),
      ignoringBottomSafeArea: false
    )

    // Built as `String`s first: `#expect` takes a `Comment`, which a string literal converts
    // to and a `+` concatenation does not.
    let noScroll = """
      The fixture's \(turnCount) turns came to \(ignoring.contentHeight) pt on the \(device), \
      which is not taller than the \(size.height) pt window — so there is no resting position \
      to measure and nothing below this line means anything.
      """
    #expect(ignoring.contentHeight > size.height, "\(noScroll)")

    let shrunk = """
      By default the collection view's bounds are \(byDefault.scrollBounds.minY)..\
      \(byDefault.scrollBounds.maxY) on the \(device); expected 0..\(shrunkTo), the bar's top \
      edge. SwiftUI delivering the bar by shrinking the representable's frame is half of what \
      this test pins — read the table on this test before treating a change here as a pass.
      """
    #expect(abs(byDefault.scrollBounds.minY) < 0.5, "\(shrunk)")
    #expect(abs(byDefault.scrollBounds.maxY - shrunkTo) < 0.5, "\(shrunk)")

    let given = """
      Ignoring the bottom safe area, the collection view's bounds are \
      \(ignoring.scrollBounds.minY)..\(ignoring.scrollBounds.maxY) on the \(device) rather than \
      the window's 0..\(size.height). That line is supposed to give the frame back whole, and \
      every number below assumes it did.
      """
    #expect(abs(ignoring.scrollBounds.minY) < 0.5, "\(given)")
    #expect(abs(ignoring.scrollBounds.maxY - size.height) < 0.5, "\(given)")

    let backdrop = """
      With the frame given back, the collection view ends at y \(ignoring.scrollBounds.maxY) on \
      the \(device) and the composer's card starts at \(ignoring.composer.minY), so the \
      conversation does pass behind the card. If this fails, the ignoring arrangement has \
      stopped being the better of the two and the whole table needs re-reading.
      """
    #expect(ignoring.scrollBounds.maxY > ignoring.composer.minY + 0.5, "\(backdrop)")

    let arrived = """
      The bar's height has started reaching the collection view on the \(device): \
      safeAreaInsets.bottom \(ignoring.safeAreaBottom) and adjustedContentInset.bottom \
      \(ignoring.insetBottom) with the frame given back, \(byDefault.safeAreaBottom) and \
      \(byDefault.insetBottom) by default. All four are expected to be 0. If they are now \
      \(composerHeight), the safe area reaches a representable and `ChatCollectionView` no \
      longer needs the bar's height handed over from the SwiftUI side. Remove that hand-over \
      before you change this test.
      """
    #expect(abs(ignoring.safeAreaBottom) < 0.5, "\(arrived)")
    #expect(abs(ignoring.insetBottom) < 0.5, "\(arrived)")
    #expect(abs(byDefault.safeAreaBottom) < 0.5, "\(arrived)")
    #expect(abs(byDefault.insetBottom) < 0.5, "\(arrived)")

    // Pinned to the window's bottom edge, not "below the composer's top", which an unconverged
    // reconcile could also satisfy. With a 0 inset, resting at the end puts the content's bottom
    // on the window's bottom, so the overlap with the bar is exactly the bar's height.
    let parked = """
      Resting at the end on the \(device) with the frame given back and nothing handed in as a \
      bottom inset, the conversation's content ends at y \(ignoring.contentBottom) where the \
      window itself ends at \(size.height), and the composer starts at \
      \(ignoring.composer.minY) — so \(ignoring.contentBottom - ignoring.composer.minY) pt of \
      it is under the bar, against the bar's own \(composerHeight). That follows from the inset \
      being 0: the owner rests content at contentSize - bounds + adjustedContentInset.bottom, \
      and with a 0 inset that is the window's own bottom. It is the reader's newest turn parked \
      under the composer, and it is the second half of why the bar's height has to be handed in \
      by hand. A miss is either the reconcile not having converged or the inset having started \
      to arrive on its own — read this test's other assertions before deciding which.
      """
    #expect(abs(ignoring.contentBottom - size.height) < 1, "\(parked)")
    #expect(
      abs((ignoring.contentBottom - ignoring.composer.minY) - composerHeight) < 1,
      "\(parked)"
    )

    withExtendedLifetime(ignoringWindow) {}
    withExtendedLifetime(defaultWindow) {}
  }

  /// Hosting through a view controller gives the same answer as a bare view: the frame shrinks
  /// to the bar's top edge (0..759, 0..1261) and both insets are 0. View-controller containment
  /// does not carry a `safeAreaBar`, and there is no third hosting to try.
  @Test("hosting through a view controller does not deliver the inset either")
  func theSafeAreaDoesNotReachAControllerHostedCollectionEither() {
    for (size, shrunkTo, device) in [
      (HostedProbe.phone, CGFloat(759), "phone"),
      (HostedProbe.pad, CGFloat(1261), "pad"),
    ] {
      let turns = spikeTranscript()
      var composer = CGRect.zero
      let theme = SpikeTheme(accent: handedAccent, foreground: .white)
      let window = HostedProbe.window(
        ControllerFixture(
          turns: turns,
          theme: theme,
          sink: AccentSink(),
          onComposer: { composer = $0 }
        ),
        size: size
      )
      guard let collection = ScrollViewProbe.first(in: window) as? UICollectionView else {
        Issue.record("No UICollectionView under the controller-hosted fixture on the \(device).")
        withExtendedLifetime(window) {}
        continue
      }
      let last = IndexPath(item: turns.count - 1, section: 0)
      pump(until: { collection.layoutAttributesForItem(at: last) != nil })
      collection.layoutIfNeeded()

      let bounds = collection.convert(collection.bounds, to: window)
      let safeArea = collection.safeAreaInsets.bottom
      let inset = collection.adjustedContentInset.bottom

      let arrived = """
        Hosted through a UIViewControllerRepresentable on the \(device), the collection view \
        reports bounds \(bounds.minY)..\(bounds.maxY), safeAreaInsets.bottom \(safeArea) and \
        adjustedContentInset.bottom \(inset), under a \(composerHeight) pt safeAreaBar whose \
        card starts at \(composer.minY). Expected 0..\(shrunkTo), 0 and 0, the same as the \
        bare-view hosting. If the frame is now whole or either inset is now \(composerHeight), \
        view-controller containment has started carrying the bar, and `ChatCollectionView` \
        could be hosted that way instead of being handed the bar's height.
        """
      #expect(abs(bounds.minY) < 0.5, "\(arrived)")
      #expect(abs(bounds.maxY - shrunkTo) < 0.5, "\(arrived)")
      #expect(abs(safeArea) < 0.5, "\(arrived)")
      #expect(abs(inset) < 0.5, "\(arrived)")
      withExtendedLifetime(window) {}
    }
  }

  /// The owner with the bar's height handed in. Several claims share one settled window per
  /// device because of the main-actor budget; see `pump(until:)`.
  ///
  /// 1. `adjustedContentInset.bottom` is the number handed in.
  /// 2. At rest the content's bottom is on the composer's top edge.
  /// 3. `contentOffset.x` stays 0. A list layout has no horizontal extent to drift along.
  /// 4. A `reading` place restores the item and the depth inside it (`offsetWithinItem`), so a
  ///    reader two thirds down a tall answer is not snapped to its first line.
  /// 5. A prepend re-anchors the reader where they are, not where the drag began. The kit suite
  ///    asserts the rule; only a real layout shows when the owner takes the anchor.
  /// 6. A scroll that did not come through the pan gesture holds the reader too. XCUITest
  ///    cannot send one, so this tier is the only one that can drive it.
  @Test("the owner rests the conversation on the composer's top edge and holds a place")
  func theOwnerRestsTheConversationOnTheComposersTopEdge() {
    for (size, device) in [(HostedProbe.phone, "phone"), (HostedProbe.pad, "pad")] {
      let theme = SpikeTheme(accent: handedAccent, foreground: .white)
      let readings = SwiftUIInsetReadings()
      let (measured, window) = measure(
        size: size,
        theme: theme,
        sink: AccentSink(),
        ignoringBottomSafeArea: true,
        bottomInset: composerHeight,
        // The production wrapper. The bare arrangement is a shape that does not ship.
        wrappingInAClearSlot: true,
        readings: readings
      )
      guard let collection = ScrollViewProbe.first(in: window) as? UICollectionView else {
        Issue.record("No UICollectionView under the fixture on the \(device).")
        withExtendedLifetime(window) {}
        continue
      }
      settle(collection)
      pump(until: { readings.slotHeight != nil })


      let inset = """
        With \(composerHeight) handed in as the bar's height on the \(device), the collection \
        view's adjustedContentInset.bottom is \(measured.insetBottom). The cases that hand in \
        no inset pin that the platform delivers 0 on its own; this is the number the owner sets \
        from the SwiftUI-side reading, and every position below rests on it.
        """
      #expect(abs(measured.insetBottom - composerHeight) < 0.5, "\(inset)")

      let resting = """
        Resting at the end on the \(device), the conversation's content ends at y \
        \(measured.contentBottom) and the composer's card starts at \
        \(measured.composer.minY). Those are supposed to be the same line: the owner rests \
        content at contentSize - bounds + adjustedContentInset.bottom, so with the bar's height \
        as that inset the newest turn sits ON the card's top edge rather than \
        \(composerHeight) pt under it. Under it is the parked-reader defect; above it by more \
        than a point is an empty band the reader reads as the conversation having ended early.
        """
      #expect(abs(measured.contentBottom - measured.composer.minY) < 1, "\(resting)")

      let straight = """
        contentOffset.x is \(collection.contentOffset.x) on the \(device), against 0, so the \
        conversation is drawn left of its column. The mechanism measured for that drift was a \
        standing scroll target's leading anchor being re-applied against a changed viewport. \
        A list layout gives the content no horizontal extent and the owner writes x 0 \
        explicitly, so this can only move if one of those two stops being true.
        """
      #expect(abs(collection.contentOffset.x) < 0.5, "\(straight)")

      // A place inside an item, restored after a layout pass the reader did not cause: a third
      // of the way into the middle turn, then the inset changes underneath, as when the
      // composer grows a line or the keyboard arrives.
      let middle = IndexPath(item: turnCount / 2, section: 0)
      guard
        let source = collection.dataSource as? UICollectionViewDiffableDataSource<
          ChatSection, ChatItem
        >,
        let item = source.itemIdentifier(for: middle),
        let attributes = collection.layoutAttributesForItem(at: middle)
      else {
        Issue.record("The fixture's middle item is not in the layout on the \(device).")
        withExtendedLifetime(window) {}
        continue
      }
      let depth = Double(attributes.frame.height / 3)
      collection.contentOffset = CGPoint(
        x: 0, y: attributes.frame.minY + CGFloat(depth) - collection.adjustedContentInset.top)
      // Settle before the anchor is taken. `indexPathsForVisibleItems` is the previous layout's
      // answer until a pass runs, so an unsettled snapshot names what was on screen before the
      // write and looks like `offsetWithinItem` being dropped.
      settle(collection)
      // The production path: a drag beginning takes the place to `reading`. Calling the
      // delegate method is what a finger does, without a gesture this tier cannot synthesise.
      collection.delegate?.scrollViewWillBeginDragging?(collection)
      settle(collection)

      let before = collection.contentOffset.y
      collection.contentInset.bottom = composerHeight + 120
      collection.setNeedsLayout()
      settle(collection)

      let held = """
        On the \(device), a reader holding turn \(item.anchorKey) at \(depth) pt into it was \
        at contentOffset.y \(before); after the bottom inset grew by 120 pt — which is the \
        composer growing a line, or the keyboard arriving — they are at \
        \(collection.contentOffset.y). A reading place names an item AND a depth inside it, so \
        an inset change must move them by nothing at all. Landing at the item's top edge \
        instead means offsetWithinItem is being dropped, which is a reader parked two thirds \
        down a screen-tall answer jerked to its first line.
        """
      #expect(abs(collection.contentOffset.y - before) < 1, "\(held)")

      // MARK: - 5. A prepend holds them where they are, not where the drag began

      // A prepend reconciles past a live gesture, because the page fetch happens during the
      // swipe that asks for it. If the owner's anchor were still the drag start, older turns
      // landing mid-swipe would write it back and undo the swipe.
      //
      // The offset write and the apply are adjacent on purpose. `didLayOut()` reconciles after
      // every pass, so a pass in between would pull the content back onto the old anchor and
      // hide the defect. A `contentOffset` write only marks the view as needing layout.
      //
      // The reader moves down, because `currentAnchor()` scans the stale visible set: a top
      // line moved up would stay inside the same topmost item.
      guard
        let coordinator = collection.delegate as? ChatCollectionView<SpikeRow>.Coordinator,
        case .reading(let dragStartItem, _) = coordinator.place
      else {
        Issue.record(
          """
          On the \(device) the collection view's delegate is not the coordinator, or the drag \
          above did not leave the place reading — it is \
          \(String(describing: (collection.delegate as? ChatCollectionView<SpikeRow>.Coordinator)?.place)).
          """)
        withExtendedLifetime(window) {}
        continue
      }

      let framed = collection.indexPathsForVisibleItems.sorted().compactMap {
        path -> (frame: CGRect, item: ChatItem)? in
        guard
          let attributes = collection.layoutAttributesForItem(at: path),
          let visible = source.itemIdentifier(for: path)
        else { return nil }
        return (attributes.frame, visible)
      }
      guard
        let startIndex = framed.firstIndex(where: { $0.item.anchorKey == dragStartItem }),
        startIndex + 1 < framed.count
      else {
        Issue.record(
          """
          On the \(device) the drag anchored on \(dragStartItem) and the visible set is \
          \(framed.map(\.item.anchorKey)), which has nothing below it to move the reader onto.
          """)
        withExtendedLifetime(window) {}
        continue
      }
      let moved = framed[startIndex + 1]
      let depthIntoMoved: CGFloat = 5
      let offsetBeforePrepend = collection.contentOffset.y

      collection.contentOffset = CGPoint(
        x: 0, y: moved.frame.minY + depthIntoMoved - collection.adjustedContentInset.top)
      // `spikeTranscript()` is deterministic, so the update is a prepend and nothing else.
      let older = [
        TranscriptTurn(id: "older-0", speech: .human("An older turn, arriving at the front."))
      ]
      coordinator.apply(
        turns: older + spikeTranscript(), showsPaging: false, showsActivity: false,
        inputs: spikeRowInputs)

      let prepended = """
        On the \(device) the drag began with the reader on \(dragStartItem); they then moved onto \
        \(moved.item.anchorKey), \(depthIntoMoved) pt into it — contentOffset.y \
        \(offsetBeforePrepend) to \(collection.contentOffset.y) — and an older turn arrived at \
        the front. The place is now \(coordinator.place), and it is supposed to name \
        \(moved.item.anchorKey) at \(depthIntoMoved) pt. Naming \(dragStartItem) is the defect: \
        a prepend reconciles past a live gesture, so a stale anchor is not merely stale, it is \
        written back to the scroll view and the reader's own swipe is undone. The visible set at \
        the moment of the prepend was \(framed.map(\.item.anchorKey)).
        """
      if case .reading(let heldItem, let heldDepth) = coordinator.place {
        #expect(heldItem == moved.item.anchorKey, "\(prepended)")
        #expect(abs(heldDepth - Double(depthIntoMoved)) < 1, "\(prepended)")
      } else {
        Issue.record("\(prepended)")
      }

      // MARK: - 6. A scroll that did not come through the pan gesture holds the reader

      // The claim is about a follower, and the prepend above left them reading.
      coordinator.followLatest()
      settle(collection)
      let rested = collection.contentOffset.y

      let following = """
        On the \(device), putting the reader back on the end left the place \
        \(coordinator.place) rather than followingLatest, so nothing below is a result about a \
        follower. contentOffset.y is \(rested).
        """
      #expect(!coordinator.place.isPositionedByReader, "\(following)")

      // `scrollRectToVisible` is driven here; `accessibilityScroll` cannot be. With no
      // assistive technology running, UIKit's accessibility bundle is not loaded, so
      // `accessibilityScroll` falls through to `NSObject`'s default, returns `false` and moves
      // nothing. `ChatReaderPlaceTests` carries the rule its override feeds. `scrollToItem`
      // reaches neither override.
      //
      // `scrollRectToVisible` moves on the next layout pass, not at once. `settle` alone can
      // return before it lands, because two unmoved passes agree, so this waits for the
      // movement, bounded.
      let restingOffset = collection.contentOffset.y
      collection.scrollRectToVisible(
        CGRect(x: 0, y: restingOffset - 100, width: 10, height: 40), animated: false)
      for _ in 0..<40 {
        collection.layoutIfNeeded()
        if abs(collection.contentOffset.y - restingOffset) > 0.5 { break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
      }
      // And then let the owner converge, which is where the defect wrote the reader back.
      settle(collection)
      let offsetAfterFocusScroll = collection.contentOffset.y

      let focusScrollWasUndone = """
        On the \(device) a follower resting at \(restingOffset) was moved by a focus-driven \
        scrollRectToVisible, the scroll UIKit performs to bring a newly focused element on \
        screen. After the layout passes it provokes they are at \(offsetAfterFocusScroll), \
        the end of the conversation is \(restingOffset), and the place is \
        \(coordinator.place). That scroll raises no scrollViewWillBeginDragging, so without \
        ChatReaderPlace.Event.scrolledWithoutADrag the owner never hears the reader has moved, \
        stays followingLatest, and the same layout pass writes the resting offset straight back \
        over them. A VoiceOver reader then cannot hold a place in the history at all.
        """
      #expect(abs(offsetAfterFocusScroll - restingOffset) > 1, "\(focusScrollWasUndone)")
      #expect(coordinator.place.isPositionedByReader, "\(focusScrollWasUndone)")

      withExtendedLifetime(window) {}
    }
  }

  /// A home indicator under the bar, and the keyboard as a viewport change.
  ///
  /// The strip behind the card is the bar's height plus the home indicator whenever the keyboard
  /// is not covering it; on the device, 186 for a 152 pt bar. This is the one hosted case with a
  /// declared home indicator.
  ///
  /// The keyboard is modelled as 328 pt of window taken away and given back. The real keyboard
  /// also covers the home indicator, so production's inset drops by the indicator while it is up.
  /// That cannot be modelled: an overridden window property raises no
  /// `safeAreaInsetsDidChange`.
  ///
  /// The last claims reproduce a reader left 36 pt short of the end, inside
  /// `ChatEndProximity.jumpTolerance`, so no control offers the way back. Only a drag still in
  /// progress or a non-pan scroll can leave that state, and a settle inside the tolerance ends
  /// it.
  ///
  /// One window, phone only: see `pump(until:)`, and the home indicator is a phone fact.
  @Test("a home indicator under the bar, through a slot that shrinks and grows back")
  func theOwnerRestsTheConversationUnderAHomeIndicator() {
    // 27 is no device's home indicator (the phone's is 34, the iPad's 20), so it separates the
    // declared inset reaching the layout from an inherited one.
    let homeIndicator: CGFloat = 27
    let keyboard: CGFloat = 328
    let barRegion = composerHeight + homeIndicator
    let turns = spikeTranscript()
    let readings = SwiftUIInsetReadings()
    let bar = SpikeBar()
    var composer = CGRect.zero
    let window = HostedProbe.window(
      SpikeFixture(
        turns: turns,
        theme: SpikeTheme(accent: handedAccent, foreground: .white),
        sink: AccentSink(),
        ignoresBottomSafeArea: true,
        bottomInset: composerHeight,
        wrapsInClearSlot: true,
        onComposer: { composer = $0 },
        readings: readings,
        bar: bar
      ),
      size: HostedProbe.phone,
      safeAreaBottom: homeIndicator
    )
    guard let collection = ScrollViewProbe.first(in: window) as? UICollectionView else {
      Issue.record("No UICollectionView under the fixture.")
      withExtendedLifetime(window) {}
      return
    }
    let last = IndexPath(item: turns.count - 1, section: 0)

    /// Resizes the window, then waits until the collection view has taken the new height and its
    /// content has stopped moving. It waits on the height, not the inset, so an inset arriving
    /// late is not hidden.
    func layOut(windowHeight: CGFloat) {
      let before = collection.bounds.height
      let resizing = abs(window.frame.height - windowHeight) > 0.5
      window.frame = CGRect(x: 0, y: 0, width: HostedProbe.phone.width, height: windowHeight)
      window.layoutIfNeeded()
      // Waits for the bounds to change, not for a computed height: the scene's 62 pt top inset
      // survives, so no absolute height here is computable.
      if resizing { pump(until: { abs(collection.bounds.height - before) > 0.5 }) }
      pump(until: { collection.layoutAttributesForItem(at: last) != nil })
      settle(collection)
      settle(collection)
    }
    /// The content's own bottom edge in window coordinates, which at rest is the card's top.
    func contentBottom() -> CGFloat {
      collection.convert(CGPoint(x: 0, y: collection.contentSize.height), to: window).y
    }
    func restingOffset() -> CGFloat {
      collection.contentSize.height - collection.bounds.height
        + collection.adjustedContentInset.bottom
    }

    layOut(windowHeight: HostedProbe.phone.height)

    let declared = """
      The chat root reports a bottom safe area of \
      \(readings.atTheChatRoot.map { "\($0)" } ?? "nothing") under a \(composerHeight) pt bar \
      and a \(homeIndicator) pt home indicator, where \(barRegion) is the bar drawn into the \
      indicator's strip. \(composerHeight) means the window's declared inset never reached the \
      layout and every number below is the no-safe-area case this file already covers; see \
      HostedProbe.window(_:size:safeAreaBottom:).
      """
    #expect(abs((readings.atTheChatRoot ?? 0) - barRegion) < 0.5, "\(declared)")

    let strip = """
      With a \(composerHeight) pt bar over a \(homeIndicator) pt home indicator, the \
      conversation's adjustedContentInset.bottom is \(collection.adjustedContentInset.bottom) \
      against \(barRegion). The strip behind the card is the bar PLUS the indicator — measured \
      on Driverr iPhone 17 as 186 for a 152 pt bar — and it is derived as the collection's own \
      bounds minus the SwiftUI slot, \(collection.bounds.height) - \
      \(readings.slotHeight.map { "\($0)" } ?? "nothing").
      """
    #expect(abs(collection.adjustedContentInset.bottom - barRegion) < 0.5, "\(strip)")

    let rested = """
      At rest under the home indicator the conversation's content ends at y \(contentBottom()) \
      and the bar starts at \(bar.frame.minY) (the card's own frame is \(composer)). Those are \
      the same line when the owner rests content at contentSize - bounds + \
      adjustedContentInset.bottom. Below it is the parked-reader defect, which under an \
      indicator is what a conversation reading one point under the composer looks like.
      """
    #expect(abs(contentBottom() - bar.frame.minY) < 1, "\(rested)")

    // The keyboard arrives and leaves: 328 pt of window, the device's difference between a chat
    // of 655 and one of 327.
    layOut(windowHeight: HostedProbe.phone.height - keyboard)

    let shrunk = """
      With the viewport \(keyboard) pt shorter — the keyboard's arrival — the conversation's \
      content ends at \(contentBottom()) against a bar starting at \(bar.frame.minY), and the \
      inset is \(collection.adjustedContentInset.bottom) against \(barRegion). A slot that \
      shrinks under a follower has to re-rest them on the card's edge, not leave them behind \
      the keyboard.
      """
    #expect(abs(contentBottom() - bar.frame.minY) < 1, "\(shrunk)")
    #expect(abs(collection.adjustedContentInset.bottom - barRegion) < 0.5, "\(shrunk)")

    layOut(windowHeight: HostedProbe.phone.height)

    let grownBack = """
      With the viewport back to \(HostedProbe.phone.height) — the keyboard leaving, which is \
      the posture testTheComposerGrowingKeepsTheEndOfTheAnswerOnScreen reads in — the \
      conversation's content ends at \(contentBottom()) against a bar starting at \
      \(bar.frame.minY), with an inset of \(collection.adjustedContentInset.bottom) against \
      \(barRegion). 36 pt of daylight here is the defect: the end of the answer one point under \
      the card rather than 35 above it.
      """
    #expect(abs(contentBottom() - bar.frame.minY) < 1, "\(grownBack)")
    #expect(abs(collection.adjustedContentInset.bottom - barRegion) < 0.5, "\(grownBack)")

    guard
      let coordinator = collection.delegate as? ChatCollectionView<SpikeRow>.Coordinator
    else {
      Issue.record("The collection view's delegate is not the coordinator.")
      withExtendedLifetime(window) {}
      return
    }

    let following = """
      After the viewport shrank and grew back, the reader's place is \(coordinator.place). \
      Nobody touched the conversation, so a follower has to still be following: a place that \
      becomes reading across a keyboard leaving is a follower silently parked wherever the \
      transition left them, with no control offered because the distance is inside \
      ChatEndProximity.jumpTolerance.
      """
    #expect(!coordinator.place.isPositionedByReader, "\(following)")

    // MARK: - A reader 36 pt short of the end, inside the jump tolerance

    // A non-pan scroll, because a synthetic drag cannot produce this state: it raises no
    // `isDragging`, so the reconcile runs at once and puts the follower back on the end. A
    // non-pan scroll snapshots the anchor after the move with no settle to follow. The call
    // below is what `ChatCollection.scrollRectToVisible` makes, in its order.
    let shortfall: CGFloat = 36
    let beforeTheScroll = collection.contentOffset.y
    collection.contentOffset = CGPoint(x: 0, y: restingOffset() - shortfall)
    coordinator.scrolledWithoutADrag(from: beforeTheScroll)
    settle(collection)
    let parked = collection.contentOffset.y
    let distance = restingOffset() - parked

    let inside = """
      The reader was put \(shortfall) pt short of the end and the owner settled them \
      \(distance) pt short, which has to stay inside ChatEndProximity.jumpTolerance \
      (\(ChatEndProximity.jumpTolerance)) for this claim to be about a reader with no control \
      offered. Outside it, the jump-to-latest control appears and the state is one a reader can \
      see and leave.
      """
    #expect(distance > 1 && distance <= CGFloat(ChatEndProximity.jumpTolerance), "\(inside)")
    #expect(coordinator.place.isPositionedByReader, "\(inside)")

    layOut(windowHeight: HostedProbe.phone.height - keyboard)
    layOut(windowHeight: HostedProbe.phone.height)

    let held = """
      A reader holding a place \(distance) pt from the end was at contentOffset.y \(parked) and \
      is at \(collection.contentOffset.y) after the viewport shrank and grew back. A reading \
      place names an item and a depth inside it, so a viewport change must move them by \
      nothing — and this is the state that reads as a follower left short of the end, because \
      the distance is inside the tolerance so no control offers the way back.
      """
    #expect(abs(collection.contentOffset.y - parked) < 1, "\(held)")

    // What ends it: the reader's next drag. A settle inside the tolerance returns them to the
    // end, however they came to be parked.
    collection.delegate?.scrollViewDidEndDragging?(collection, willDecelerate: false)
    settle(collection)
    settle(collection)

    let released = """
      After the drag ended \(distance) pt from the end — inside the tolerance — the place is \
      \(coordinator.place) and the content ends at \(contentBottom()) against a bar at \
      \(bar.frame.minY). ChatReaderPlace.applying(.settled(…)) returns a reader inside the \
      tolerance to followingLatest, which is why the parked state above needs a drag still in \
      progress or a non-pan scroll rather than an ordinary swipe.
      """
    #expect(!coordinator.place.isPositionedByReader, "\(released)")
    #expect(abs(contentBottom() - bar.frame.minY) < 1, "\(released)")

    withExtendedLifetime(window) {}
  }

  /// `ChatCollectionView` hands `\.themeAccent` in per cell, and a theme change has to reach
  /// cells that already exist. One case for both claims; see `pump(until:)`.
  @Test("the theme accent crosses into a cell, and a change reaches it")
  func theAccentCrossesTheHostingBoundary() {
    let sink = AccentSink()
    let theme = SpikeTheme(accent: handedAccent, foreground: .white)
    let (_, window) = measure(size: HostedProbe.phone, theme: theme, sink: sink)

    let missing = """
      No cell reported a resolved themeAccent at all, so the probe never ran and this test \
      proves nothing either way. Either the collection view built no cells or the hosting \
      configuration's content was never laid out.
      """
    #expect(!sink.seen.isEmpty, "\(missing)")

    let wrong = """
      A cell resolved themeAccent as \(String(describing: sink.latest)) rather than the \
      handed-in \(handedAccent). A UIHostingConfiguration's content is a separate hosting \
      hierarchy, so a value PaneChatView has resolved does not reach it — ChatCollectionView \
      re-injects it per cell, and this failing means that injection is not working.
      """
    #expect(sink.seen.allSatisfy { $0 == handedAccent }, "\(wrong)")

    // A theme change from Settings. `updateUIView` hands the new accent to the coordinator and
    // reconfigures every item.
    theme.accent = changedAccent
    pump(until: { sink.latest == changedAccent })

    let stuck = """
      After the theme's accent changed, the newest value a cell reported is \
      \(String(describing: sink.latest)) rather than \(changedAccent). Cells that already \
      exist are not being reconfigured, so a reader who changes theme with the chat open keeps \
      the old accent until the rows happen to be recycled.
      """
    #expect(sink.latest == changedAccent, "\(stuck)")
    withExtendedLifetime(window) {}
  }
}
