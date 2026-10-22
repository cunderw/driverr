import DriverrCore
import SwiftUI
import UIKit

/// What the conversation holds, in the order a reader meets it.
///
/// The paging control, the working row and the tail marker are items in their own sections,
/// not supplementary views, so they lay out like cells and the anchor arithmetic in
/// `ChatCollectionView.Coordinator.reconcile` does not depend on which are present.
enum ChatItem: Hashable, Sendable {
  /// The paging bill and its priced control, above the oldest turn, where older turns arrive.
  case paging
  case turn(TranscriptTurn.ID)
  /// The chips that answer a pending question. Follows the turn whose call is waiting.
  ///
  /// Its own item because the chat rests at its top while a question waits, and an item's
  /// frame comes straight from the layout. Inside the turn's cell it would have to be measured
  /// in SwiftUI and passed across the hosting boundary. See `ChatReplyAnchor`.
  case reply(TranscriptTurn.ID)
  /// What the conversation is doing, as the last thing in it.
  case activity
  /// The end of the conversation.
  ///
  /// Nothing scrolls to it: the owner rests at the content's true end. It feeds the
  /// suppressor in `ChatEndProximity.showsJumpToLatest`, and its visibility here is exact
  /// (`indexPathsForVisibleItems`).
  case tail

  /// The string `ChatReaderPlace.Anchor` names this item by.
  ///
  /// `ChatReaderPlace` is in `DriverrCore` and cannot know this type, so the anchor is a
  /// `TranscriptTurn.ID`. A turn's id is a record uuid, so the literals below cannot collide.
  var anchorKey: TranscriptTurn.ID {
    switch self {
    case .paging: Self.pagingKey
    case .turn(let id): id
    case .reply(let id): Self.replyPrefix + id
    case .activity: Self.activityKey
    case .tail: Self.tailKey
    }
  }

  static let pagingKey = "pane.chat.paging"
  static let activityKey = "pane.chat.activity"
  static let tailKey = "pane.chat.tail"
  static let replyPrefix = "pane.chat.reply:"

  init(anchorKey: TranscriptTurn.ID) {
    switch anchorKey {
    case Self.pagingKey: self = .paging
    case Self.activityKey: self = .activity
    case Self.tailKey: self = .tail
    case let key where key.hasPrefix(Self.replyPrefix):
      self = .reply(String(key.dropFirst(Self.replyPrefix.count)))
    default: self = .turn(anchorKey)
    }
  }
}

/// One section each, so section insets can give the first and last rows their end margin.
enum ChatSection: Hashable, Sendable {
  case paging
  case turns
  case activity
  case tail
}

/// What the owner tells SwiftUI about the reader, and all it tells it.
///
/// Two booleans rather than a distance: only the jump-to-latest control and the backfill
/// depend on where the reader is. A distance would write SwiftUI state on every scrolled
/// frame and rebuild the representable under the finger.
struct ChatReaderState: Equatable {
  var showsJumpToLatest = false
  var isNearStart = false
}

/// Everything a row draws from that is not part of its own `TranscriptTurn`.
///
/// A `UIHostingConfiguration`'s content is built once, at configuration time. Open tool runs,
/// expanded turns, chosen reply chips, a send in flight, the rendered markdown and the paging
/// state all live in `PaneChatView`, and none of it reaches an existing cell by itself.
///
/// So cells are reconfigured when this value differs, and on no other update. Two
/// alternatives fail:
///
/// - Reconfiguring the visible items on every update. The chat polls, so this runs
///   constantly, and each reconfigure replaces the hosting configuration, so a tap in flight
///   never completes (`testPagingPricesTheNextPageAndSpendsItOnATap`).
/// - An `@Observable` box the cells read, bumped on every update. The app then never
///   reports itself idle and every UI query times out. Do not retry it without a way to
///   watch the update graph.
struct ChatRowInputs: Equatable {
  var agentStatus: AgentStatus?
  var openRuns: OpenToolRuns
  var expanded: Set<String>
  var selection: ReplyChipSelection
  var isSending: Bool
  var contentWidth: CGFloat
  var render: TranscriptRender
  var paging: TranscriptPaging?
  var isPagingBack: Bool
  var pagingError: String?
  var activity: ChatActivity?
}

/// Fades the conversation out as it scrolls under the rows above it, instead of cutting it
/// square.
///
/// Drawn by hand because the system cannot draw it here. `topEdgeEffect.style = .soft` shows
/// nothing, with or without a top inset: a scroll edge effect takes its shape from views that
/// overlay the scroll view's edge, such as a bar or a `UIScrollEdgeElementContainerInteraction`,
/// and the provenance row and sub-agent card stand above the collection view, not over it.
/// An overlay on the slot, not a mask over the conversation; see the bottom edge's comment in
/// `makeCollection`. The collection view's `contentInset.top` is this height, so at the top of
/// the conversation the first row rests below the band.
struct ChatTopFade: View {
  static let height: CGFloat = 16

  var body: some View {
    // To the ground at zero opacity, not to `.clear`, which is black at zero opacity and greys
    // the midpoint.
    LinearGradient(
      colors: [Color(.secondarySystemBackground), Color(.secondarySystemBackground).opacity(0)],
      startPoint: .top, endPoint: .bottom
    )
    .frame(height: Self.height)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// The chat's scroll position, with one writer and one reader.
///
/// Neither SwiftUI scroller can own it. `proxy.scrollTo` resolves only against targets that
/// exist, so it finds nothing on a cold rebuild. `ScrollPosition.scrollTo(id:)` sets a target
/// that stands and is re-applied on every later viewport change. Neither can express
/// `(itemID, offsetWithinItem)`. The coordinator below is the only code that reads or writes
/// `contentOffset`. `DriverrCore.ChatReaderPlace` decides where the reader is, and SwiftUI
/// only asks, through `jumpToken` down and `onReaderState` up.
///
/// SwiftUI never tells a `UIViewRepresentable` the height of a `safeAreaBar`. It shrinks the
/// representable's frame instead (the same for a `UIViewControllerRepresentable`). So the
/// inset is read on the SwiftUI side and the coordinator sets `contentInset.bottom` from it.
/// Which reading to use is not obvious; see `Coordinator.applyBottomInset`.
///
/// Generic over the row, so the caller builds the real rows and `ChatCollectionViewTests`
/// can drive production rows.
struct ChatCollectionView<Row: View>: UIViewRepresentable {
  /// The conversation, oldest first.
  var turns: [TranscriptTurn]
  /// Whether `.paging` leads the list.
  var showsPaging: Bool
  /// Whether `.activity` sits between the turns and the tail.
  var showsActivity: Bool
  /// The turn whose pending call offers chips, or `nil`. The chips follow it as a `.reply`
  /// item, and the chat rests at that item's top. See `ChatReplyAnchor`.
  var replyAfter: TranscriptTurn.ID? = nil
  /// Extra room left above the `.reply` item at rest, in points. See
  /// `ChatReplyAnchor.headroom(screenBandTop:bandTop:)`.
  var replyHeadroom: CGFloat = 0
  /// The height of the SwiftUI slot the conversation is placed in. The coordinator derives
  /// `contentInset.bottom` from it; see `Coordinator.applyBottomInset`.
  var visibleHeight: CGFloat
  /// `\.themeAccent`, handed across the hosting boundary because it cannot cross on its own.
  var accent: Color
  /// `\.themeAccentForeground`, for the same reason. See `Theme.accent(for:)`.
  var accentForeground: Color
  /// What the rows draw from besides their own turns, and the only thing that decides whether
  /// an existing cell is reconfigured. See `ChatRowInputs`.
  var rowInputs: ChatRowInputs
  /// SwiftUI's only request of the scroll position: go to the latest. A counter, so nothing
  /// holds the coordinator across a rebuild. `PaneChatView` bumps it for jump-to-latest,
  /// composer focus and a pane switch. The coordinator acts on the change, not the value, so a
  /// rebuild cannot scroll a reader who has since scrolled back.
  var jumpToken: Int
  /// Bumped when a tool run is opened or a bounded turn expanded. The growth looks like a turn
  /// growing at the end, and only `PaneChatView` knows the reader asked for it. See
  /// `ChatReaderPlace.Event.rowExpansionChanged`.
  var expansionToken: Int
  /// `.immediately` (`.onDrag`) in the collapsed landscape composer, `.interactively`
  /// (`.interactive`) everywhere else.
  var dismissesKeyboardImmediately: Bool
  /// Where the reader is, for the jump-to-latest control and the backfill. See
  /// `ChatReaderState`.
  var onReaderState: (ChatReaderState) -> Void
  /// Debug scroll numbers, `nil` unless the launch asked for them. See `ChatScrollProbe`.
  /// Delivered one run-loop turn later, because the owner stores it in `@State` and the
  /// callbacks can land inside a SwiftUI update.
  var onScrollGeometry: ((ChatScrollProbe) -> Void)?
  /// Debug place numbers, on the same terms. See `ChatPlaceProbe`.
  var onPlaceChange: ((ChatPlaceProbe) -> Void)?
  /// Builds one row. The caller owns the column cap and horizontal inset, because it also
  /// owns them for the composer.
  @ViewBuilder var row: (ChatItem) -> Row

  /// The extra margin the last row gets beyond its own 9 points.
  ///
  /// Rows carry `.padding(.vertical, 9)`, giving 18 between rows, and the end gets 14 in all.
  /// The start gets `ChatTopFade.height` instead, as `contentInset.top`, so the first row rests
  /// below the fade.
  /// It goes on the section, because `contentInset.bottom` belongs to the composer. It shows at
  /// rest with the keyboard down, which is the posture a reader meets first. Do not make it
  /// depend on the keyboard.
  static var endMargin: CGFloat { 5 }


  func makeCoordinator() -> Coordinator {
    Coordinator(row: row, accent: accent, accentForeground: accentForeground)
  }

  func makeUIView(context: Context) -> UICollectionView {
    let coordinator = context.coordinator
    coordinator.jumpToken = jumpToken
    coordinator.expansionToken = expansionToken
    coordinator.onReaderState = onReaderState
    coordinator.onScrollGeometry = onScrollGeometry
    coordinator.onPlaceChange = onPlaceChange
    let view = Self.makeCollection(wiredTo: coordinator)
    view.keyboardDismissMode = dismissesKeyboardImmediately ? .onDrag : .interactive
    coordinator.visibleHeight = visibleHeight
    coordinator.replyHeadroom = replyHeadroom
    coordinator.applyBottomInset()
    coordinator.apply(
      turns: turns, showsPaging: showsPaging, showsActivity: showsActivity,
      replyAfter: replyAfter, inputs: rowInputs)
    return view
  }

  /// Builds the collection view and wires it to `coordinator`.
  ///
  /// Separate from `makeUIView` so tests can host the same object as a
  /// `UIViewControllerRepresentable` and confirm it is told no more than a
  /// `UIViewRepresentable` is.
  @MainActor
  static func makeCollection(wiredTo coordinator: Coordinator) -> ChatCollection {
    // A list section, because its self-sizing is the only one that converges. With an
    // `.estimated` `NSCollectionLayoutGroup`, an owner that rests at the content's end stalls
    // on an under-estimate: cells past the rest are never laid out, so nothing corrects the
    // total.
    //
    // The list's unwanted features are turned off here, and the column inset is `ChatColumn`'s.
    // A section provider, because only the last section carries `endMargin`, and which is last
    // depends on whether the working row is present.
    let layout = UICollectionViewCompositionalLayout { [weak coordinator] index, environment in
      var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
      // The chat draws its own separation, and `PaneChatView` paints one ground behind the
      // surface, so no separators and a clear background.
      configuration.showsSeparators = false
      configuration.backgroundColor = .clear
      let section = NSCollectionLayoutSection.list(
        using: configuration, layoutEnvironment: environment)
      // Nothing but the two insets below may act on the column.
      section.contentInsetsReference = .none
      // The column inset is the section's, not the row's: a cell inset by the layout cannot be
      // overflowed by its content. It is 0 wherever the cap binds. Read from the layout's
      // container, not from SwiftUI, whose width is 0 until measured and would flip one pass
      // later. See `ChatColumn.gutter(forColumnWidth:)`.
      let gutter = ChatColumn.gutter(
        forColumnWidth: environment.container.effectiveContentSize.width)
      let sections = coordinator?.sectionCount ?? 1
      section.contentInsets = NSDirectionalEdgeInsets(
        top: 0,
        leading: gutter,
        bottom: index == sections - 1 ? Self.endMargin : 0,
        trailing: gutter
      )
      return section
    }

    let view = ChatCollection(frame: .zero, collectionViewLayout: layout)
    view.backgroundColor = .clear
    view.alwaysBounceVertical = true
    // A list cell is selectable by default, and its selection gesture wins taps meant for the
    // hosted SwiftUI content, such as the Load-more button.
    view.allowsSelection = false
    // `.automatic` adds the view's own `safeAreaInsets`, which are 0 for a hosted view, so
    // `adjustedContentInset.bottom` is exactly the inset set from SwiftUI.
    view.contentInsetAdjustmentBehavior = .automatic
    // The UIKit form of `.scrollEdgeEffectStyle(.soft, for: .bottom)`, which softens the
    // conversation behind the composer's glass. No availability check: the target is iOS 26.
    // Do not replace it with a mask over the conversation: that renders it offscreen and the
    // composer's material loses its backdrop. A per-row `.scrollTransition` cannot do it
    // either, because its phase is relative to each row's own height.
    view.bottomEdgeEffect.style = .soft
    // The band `ChatTopFade` draws over. `contentInset.bottom` belongs to the composer and is
    // set on every update; this one is fixed.
    view.contentInset.top = ChatTopFade.height
    // UIKit, unlike SwiftUI, does not propagate an identifier to children, so the rows keep
    // their own `pane.chat.turn.*` identifiers.
    view.accessibilityIdentifier = "pane.chat"
    view.preservesSuperviewLayoutMargins = false
    view.insetsLayoutMarginsFromSafeArea = false
    view.directionalLayoutMargins = .zero

    // Both closures hold the coordinator weakly to break a retain cycle: the coordinator owns
    // the data source, which owns the cell provider, which captures the registration. `row`
    // closes over `PaneChatView`'s graph, so a leak would keep a whole pane's models alive.
    let registration = UICollectionView.CellRegistration<UICollectionViewCell, ChatItem> {
      [weak coordinator] cell, _, item in
      guard let coordinator else { return }
      // `.margins(.all, 0)`: `UIHostingConfiguration` adds its own margins (20 pt at regular
      // width, 16 at compact), which pushed the conversation off the composer's column
      // (`testTheComposerStandsInTheSameColumnAsTheConversation`).
      cell.contentConfiguration = UIHostingConfiguration {
        coordinator.row(item)
          // Read from the coordinator, so a theme change reaches a cell reconfigured after it.
          // `\.themeAccent` does not cross a `UIHostingConfiguration` by itself
          // (`theAccentCrossesTheHostingBoundary`).
          .environment(\.themeAccent, coordinator.accent)
          .environment(\.themeAccentForeground, coordinator.accentForeground)
      }
      .margins(.all, 0)
      cell.backgroundConfiguration = .clear()
      // The cell's own layout margins too, which the configuration's do not cover. `ChatColumn`
      // is the one place the column is defined, so nothing may inset beyond it.
      cell.contentView.preservesSuperviewLayoutMargins = false
      cell.contentView.insetsLayoutMarginsFromSafeArea = false
      cell.contentView.directionalLayoutMargins = .zero
    }

    let source = UICollectionViewDiffableDataSource<ChatSection, ChatItem>(
      collectionView: view
    ) { [weak coordinator] view, indexPath, item in
      guard coordinator != nil else { return nil }
      return view.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
    }
    coordinator.data = source
    coordinator.collection = view
    view.delegate = coordinator
    view.onLayout = { [weak coordinator] in coordinator?.didLayOut() }
    view.onScrollWithoutADrag = { [weak coordinator] in
      coordinator?.scrolledWithoutADrag(from: $0)
    }
    return view
  }

  func updateUIView(_ view: UICollectionView, context: Context) {
    let coordinator = context.coordinator
    // The closure captures this SwiftUI view's `self`, so a stale one draws stale rows. Every
    // reconfigure reads it from here.
    coordinator.row = row
    let themeChanged =
      coordinator.accent != accent || coordinator.accentForeground != accentForeground
    coordinator.accent = accent
    coordinator.accentForeground = accentForeground
    coordinator.onReaderState = onReaderState
    coordinator.onScrollGeometry = onScrollGeometry
    coordinator.onPlaceChange = onPlaceChange
    view.keyboardDismissMode = dismissesKeyboardImmediately ? .onDrag : .interactive
    coordinator.visibleHeight = visibleHeight
    coordinator.replyHeadroom = replyHeadroom
    coordinator.applyBottomInset()
    coordinator.apply(
      turns: turns,
      showsPaging: showsPaging,
      showsActivity: showsActivity,
      replyAfter: replyAfter,
      inputs: rowInputs,
      reconfiguringEverything: themeChanged
    )
    // Acted on the change, not the value, so a rebuild carrying the same token does not
    // scroll a reader who has since scrolled back.
    if coordinator.jumpToken != jumpToken {
      coordinator.jumpToken = jumpToken
      coordinator.followLatest()
    }
    // After the snapshot, before the growth is laid out. `apply(…)` has reconfigured the cell,
    // but it is sized on the next pass, so `currentAnchor()` still reads the pre-growth
    // layout and records what the reader was looking at.
    if coordinator.expansionToken != expansionToken {
      coordinator.expansionToken = expansionToken
      coordinator.holdPlaceForExpansion()
    }
  }

  /// Holds what the cells read, applies snapshots, and owns `contentOffset`. A
  /// `UICollectionViewDelegate`, which inherits every scroll-view callback.
  @MainActor
  final class Coordinator: NSObject, UICollectionViewDelegate {
    /// The newest row builder, replaced on every update because a stale one draws stale rows.
    var row: (ChatItem) -> Row
    var accent: Color
    var accentForeground: Color
    /// What the rows draw from besides their own turns. See `ChatRowInputs`.
    var rowInputs: ChatRowInputs?
    var data: UICollectionViewDiffableDataSource<ChatSection, ChatItem>?
    weak var collection: UICollectionView?
    var jumpToken = 0
    var expansionToken = 0
    var onReaderState: (ChatReaderState) -> Void = { _ in }
    var onScrollGeometry: ((ChatScrollProbe) -> Void)?
    var onPlaceChange: ((ChatPlaceProbe) -> Void)?

    /// Where the reader is. Starts at `followingLatest`, because a page is the tail of a
    /// conversation and the reader came for the latest.
    private(set) var place: ChatReaderPlace = .followingLatest

    /// Setting `contentOffset` during layout triggers another pass, so reconcile refuses
    /// reentry.
    private var isReconciling = false

    /// `contentOffset.y` before a scroll the reader made without a pan gesture, while the
    /// owner waits for it to show in a layout pass. See `scrolledWithoutADrag(from:)`.
    private var offsetBeforeNonPanScroll: CGFloat?
    /// Layout passes spent waiting for that scroll, so an animated one is still caught and one
    /// that moved nothing is eventually dropped.
    private var nonPanScrollPasses = 0
    /// Unmeasured: `accessibilityScroll` cannot be driven without VoiceOver, so no test tier
    /// can time an animated one. Too large holds the reader's place off screen for a visible
    /// moment. Too small drops the event and leaves the scroll undone by the next reconcile.
    /// `scrollRectToVisible` needs one pass. Raise it only on evidence from a device.
    private let nonPanScrollPassBudget = 4

    /// The oldest turn of the previous snapshot, so a prepend can be told from an append.
    private var firstTurn: TranscriptTurn.ID?

    /// How many sections the current snapshot holds, so the layout gives the last one
    /// `endMargin`.
    private(set) var sectionCount = 1

    /// Passes `walkTowardTheTail()` may still spend. Re-armed by a prepend and by a replaced
    /// conversation, which both put unmeasured items before the tail.
    private var tailWalkBudget = 0
    private let tailWalkPasses = 40
    /// The turn the `.reply` item follows in the applied snapshot, or `nil`.
    private var replyAfter: TranscriptTurn.ID?
    /// `ChatCollectionView.replyHeadroom`, as last handed across.
    var replyHeadroom: CGFloat = 0
    /// `contentSize.height` at the previous walk pass, to tell a settled layout from one still
    /// measuring. `-1` before the first pass.
    private var heightAtLastWalk: CGFloat = -1

    /// What each id currently holds, so items whose content changed under the same id can be
    /// reconfigured.
    private var turnsByID: [TranscriptTurn.ID: TranscriptTurn] = [:]

    /// The first report sets the baseline and is never sent.
    ///
    /// `ChatBackfill.isNearStart` is true from the first frame for a short conversation, and
    /// that must not fetch a page by itself: fetching costs a priced page, which only the
    /// reader may spend.
    private var hasReported = false

    /// The last value sent to `onReaderState`, so SwiftUI hears only transitions.
    private var reportedReaderState: ChatReaderState?

    /// The SwiftUI slot's height. See `applyBottomInset`.
    var visibleHeight: CGFloat = 0


    init(
      row: @escaping (ChatItem) -> Row,
      accent: Color,
      accentForeground: Color
    ) {
      self.row = row
      self.accent = accent
      self.accentForeground = accentForeground
      super.init()
    }

    // MARK: - What SwiftUI hands in

    /// Sets `contentInset.bottom` to the strip of this scroll view behind the composer.
    ///
    /// The representable ignores the bottom safe area, so its frame includes the composer and
    /// the conversation passes behind the glass. This inset rests the newest row on the
    /// composer's top edge, which a SwiftUI `ScrollView` would get from `safeAreaBar`.
    ///
    /// It is `bounds.height - visibleHeight`. The obvious readings are wrong:
    ///
    /// - `GeometryProxy.safeAreaInsets.bottom` includes the keyboard, so with the keyboard up
    ///   it rests the whole conversation above the visible region.
    /// - A frame read after `.ignoresSafeArea(.container, edges: .bottom)` reports the
    ///   unexpanded height (see CLAUDE.md on `GeometryReader` probes).
    ///
    /// Re-applied after every layout pass, because `bounds.height` changes without SwiftUI
    /// saying so.
    func applyBottomInset() {
      guard let collection, visibleHeight > 0, collection.bounds.height > 0 else { return }
      let inset = max(0, collection.bounds.height - visibleHeight)
      guard abs(collection.contentInset.bottom - inset) > 0.5 else { return }
      collection.contentInset.bottom = inset
      // Otherwise the indicator stops short of the composer, as if the conversation did.
      collection.verticalScrollIndicatorInsets.bottom = inset
    }

    /// Jump-to-latest, composer focus and a pane switch: go to the end and follow it.
    ///
    /// Unanimated. `setContentOffset(_:animated: true)` returns before the animation runs, so
    /// the reconcile on the next layout pass writes the resting offset straight anyway.
    /// Animating needs the reconcile held off until the animation ends or a drag interrupts it.
    func followLatest() {
      // An explicit request outranks a pending non-pan scroll, whose anchor would otherwise
      // land a pass later.
      offsetBeforeNonPanScroll = nil
      place = place.applying(.jumpedToLatest)
      reconcile()
    }

    /// Keeps a following reader in place when a run opens, instead of being carried down by the
    /// growth. `ChatReaderPlace` holds the rule.
    func holdPlaceForExpansion() {
      place = place.applying(.rowExpansionChanged(currentAnchor()))
    }

    // MARK: - The snapshot

    func apply(
      turns: [TranscriptTurn],
      showsPaging: Bool,
      showsActivity: Bool,
      replyAfter: TranscriptTurn.ID? = nil,
      inputs: ChatRowInputs,
      reconfiguringEverything reconfigureAll: Bool = false
    ) {
      guard let data else { return }

      // A turn whose content changed under the same record id. A diffable data source cannot
      // see that, because the ids match.
      let changed = turns.filter { turn in
        guard let previous = turnsByID[turn.id] else { return false }
        return previous != turn
      }
      turnsByID = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0) })
      let inputsChanged = rowInputs != inputs
      rowInputs = inputs

      var snapshot = NSDiffableDataSourceSnapshot<ChatSection, ChatItem>()
      if showsPaging {
        snapshot.appendSections([.paging])
        snapshot.appendItems([.paging], toSection: .paging)
      }
      snapshot.appendSections([.turns])
      snapshot.appendItems(
        turns.flatMap { turn -> [ChatItem] in
          turn.id == replyAfter ? [.turn(turn.id), .reply(turn.id)] : [.turn(turn.id)]
        },
        toSection: .turns
      )
      let appliedReply = turns.contains { $0.id == replyAfter } ? replyAfter : nil
      // The band leaving takes its anchor with it. See
      // `ChatReplyAnchor.place(_:whenReplyLeaves:)`.
      if let leaving = self.replyAfter, leaving != appliedReply {
        place = ChatReplyAnchor.place(
          place, whenReplyLeaves: ChatItem.reply(leaving).anchorKey)
      }
      self.replyAfter = appliedReply
      if showsActivity {
        snapshot.appendSections([.activity])
        snapshot.appendItems([.activity], toSection: .activity)
      }
      snapshot.appendSections([.tail])
      snapshot.appendItems([.tail], toSection: .tail)
      sectionCount = snapshot.numberOfSections

      // Reconfigured only when something a row draws from changed. See `ChatRowInputs`.
      let present = Set(snapshot.itemIdentifiers)
      let reconfigure: [ChatItem]
      if reconfigureAll || inputsChanged {
        reconfigure = snapshot.itemIdentifiers
      } else {
        reconfigure = changed.map { ChatItem.turn($0.id) }.filter { present.contains($0) }
      }
      if !reconfigure.isEmpty {
        snapshot.reconfigureItems(reconfigure)
      }

      // A prepend cannot wait for the finger to lift. Older turns are inserted above the
      // visible region and `contentOffset` is kept, so the reader would be carried back by
      // everything that arrived.
      //
      // Keyed on the first turn, not the first item, because the paging control leads the
      // list before and after a page lands. Only a prepend changes the front turn.
      let front = turns.first?.id
      let isPrepend = firstTurn != nil && front != nil && front != firstTurn
      if isPrepend || front != firstTurn {
        tailWalkBudget = tailWalkPasses
        heightAtLastWalk = -1
      }
      firstTurn = front

      // Take the anchor before applying the snapshot. `currentAnchor()` then reads the settled
      // pre-prepend layout, and the item it names survives because a prepend only inserts in
      // front. After `data.apply` it would read a layout the new turns had already moved.
      // A drag-start anchor would return the reader to where the swipe began.
      // `ChatCollectionViewTests` covers the timing, which no value test can.
      if isPrepend { place = place.applying(.prepended(currentAnchor())) }

      // Never animated: the resting offset brings a followed turn into view, and the
      // conversation must not reflow under the reader.
      data.apply(snapshot, animatingDifferences: false) { [weak self] in
        self?.reconcile(evenWhileInteracting: isPrepend)
      }
    }

    // MARK: - The reader taking the position back

    /// A drag is the reader taking their place back. The anchor is taken before the drag
    /// moves anything, so it records what the reader was looking at.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
      place = place.applying(.dragBegan(currentAnchor()))
      report()
    }

    /// The reader moved the conversation without a pan gesture: VoiceOver's
    /// `accessibilityScroll` or UIKit's focus-driven `scrollRectToVisible`.
    ///
    /// These arrive after the scroll, so an anchor taken now would name the place the reader
    /// left, and `reconcile` would undo the scroll. `currentAnchor()` also still sees the
    /// previous pass's visible items. So this only records that an anchor is owed, and
    /// `didLayOut` takes it once the layout shows the new offset.
    ///
    /// The origin offset is kept because `scrollRectToVisible` is also called for a rect
    /// already on screen, which moves nothing. Refused while `isReconciling`, so the owner's own
    /// `scrollToItem` in `walkTowardTheTail` never counts as the reader's.
    func scrolledWithoutADrag(from offset: CGFloat) {
      guard !isReconciling, offsetBeforeNonPanScroll == nil else { return }
      offsetBeforeNonPanScroll = offset
      nonPanScrollPasses = 0
    }

    /// Applies a pending non-pan scroll once the layout shows it, and says whether this pass
    /// must leave the offset alone until then.
    ///
    /// Nothing may write `contentOffset` while one is owed, or the reader's scroll is undone.
    /// The wait is bounded by `nonPanScrollPassBudget`.
    private func isWaitingForANonPanScroll() -> Bool {
      guard let before = offsetBeforeNonPanScroll, let collection else { return false }
      if abs(collection.contentOffset.y - before) > 0.5 {
        offsetBeforeNonPanScroll = nil
        place = place.applying(.scrolledWithoutADrag(currentAnchor()))
        return false
      }
      nonPanScrollPasses += 1
      if nonPanScrollPasses >= nonPanScrollPassBudget {
        offsetBeforeNonPanScroll = nil
        return false
      }
      return true
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
      guard !decelerate else { return }
      settle()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settle() }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { report() }

    /// A scroll that has come to rest either returns the reader to the end, within
    /// `ChatEndProximity.jumpTolerance`, or re-anchors them to what they see now.
    private func settle() {
      guard let collection else { return }
      place = place.applying(
        .settled(distanceFromEnd: distanceFromEnd(in: collection), at: currentAnchor()))
      reconcile()
      report()
    }

    /// The item under the top of the visible region, and how far into it that line falls.
    ///
    /// Read from the layout, not from the visible set's order, which UIKit does not define.
    /// `nil` for an empty list or an unmeasured layout, which every `ChatReaderPlace`
    /// transition treats as "leave the place alone".
    private func currentAnchor() -> ChatReaderPlace.Anchor? {
      guard let collection, let data else { return nil }
      let top = collection.contentOffset.y + collection.adjustedContentInset.top
      let candidates = collection.indexPathsForVisibleItems.sorted()
      for indexPath in candidates {
        guard let attributes = collection.layoutAttributesForItem(at: indexPath) else { continue }
        guard attributes.frame.maxY > top else { continue }
        guard let item = data.itemIdentifier(for: indexPath) else { continue }
        return ChatReaderPlace.Anchor(
          itemID: item.anchorKey,
          offsetWithinItem: Double(top - attributes.frame.minY)
        )
      }
      return nil
    }

    // MARK: - Applying the place

    /// Called after every layout pass, not once after a snapshot.
    ///
    /// A compositional list self-sizes, so when a snapshot finishes, `contentSize` is built from
    /// estimates far smaller than real turns. One reconcile then clamps to the top and opens
    /// the chat on the oldest turn. `layoutIfNeeded()` measures only the visible cells, the
    /// wrong end. Each pass measures more, so reapplying the place every pass converges. It also
    /// keeps the reader in place when the keyboard or composer changes the inset.
    func didLayOut() {
      applyBottomInset()
      // First, a scroll the reader made without a pan gesture. Until it shows, neither the walk
      // nor the reconcile may write an offset.
      if isWaitingForANonPanScroll() {
        report()
        return
      }
      // A pass that walked has already placed a following reader, and a reconcile from the old
      // arithmetic would undo it.
      if !walkTowardTheTail() { reconcile() }
      report()
    }

    /// Makes the layout measure as far as the end before the resting offset is trusted.
    ///
    /// A list self-sizes, so an owner resting at the content's end can stall on an
    /// under-estimate: cells past the rest are never laid out, so nothing corrects the total.
    /// `scrollToItem` makes the layout work toward a named item. One scroll is not enough on a
    /// tall viewport after a full rebuild, so it walks: each pass that finds the tail unrealised
    /// scrolls to it again, and the pass that finds it realised stops. `budget` only guards
    /// against a loop with `reconcile`.
    ///
    /// Only while following: a reader who is `reading` has an anchor to hold.
    ///
    /// Returns whether it moved the content, in which case the caller skips the reconcile.
    private func walkTowardTheTail() -> Bool {
      guard case .followingLatest = place, tailWalkBudget > 0 else { return false }
      guard let collection, let data, collection.bounds.height > 0 else { return false }
      guard !collection.isTracking, !collection.isDragging, !collection.isDecelerating else {
        return false
      }
      // Toward the chips while a question waits, because the rest is their top.
      let target = replyAfter.map { ChatItem.reply($0) } ?? .tail
      guard let tail = data.indexPath(for: target) else { return false }
      let height = collection.contentSize.height
      let settled = abs(height - heightAtLastWalk) <= 0.5
      heightAtLastWalk = height
      if collection.indexPathsForVisibleItems.contains(tail) {
        // Visible is not enough: early passes can show the tail at offset 0 above many
        // unmeasured turns, because the estimates are short. The walk retires only once the
        // tail is visible and the content height has stopped changing.
        if settled { tailWalkBudget = 0 }
        return false
      }
      tailWalkBudget -= 1
      isReconciling = true
      collection.scrollToItem(at: tail, at: replyAfter == nil ? .bottom : .top, animated: false)
      isReconciling = false
      return true
    }

    /// Puts the content back where `place` says it belongs.
    ///
    /// Deferred while the finger is down or a flick is travelling, so an update does not fight
    /// the gesture. The settle at the end applies it.
    ///
    /// A prepend is the exception. The reader is dragging while the page lands, and waiting
    /// would let the settle re-anchor them wherever the new turns carried them. Writing
    /// `contentOffset` stops the deceleration. Only for a reader who is `reading`; a follower
    /// has nothing to be carried off.
    func reconcile(evenWhileInteracting: Bool = false) {
      guard !isReconciling, let collection, collection.bounds.height > 0 else { return }
      // A reader's scroll not yet anchored. Writing now would undo it, because the place is
      // still `followingLatest`. `didLayOut` bounds the wait.
      guard offsetBeforeNonPanScroll == nil else { return }
      let insists = evenWhileInteracting && place.isPositionedByReader
      guard
        insists || (!collection.isTracking && !collection.isDragging && !collection.isDecelerating)
      else {
        return
      }
      guard let target = targetOffset(in: collection) else { return }
      guard abs(collection.contentOffset.y - target) > 0.5 else { return }
      isReconciling = true
      // `x` is pinned at 0 so the conversation can never gain a horizontal scroll.
      collection.contentOffset = CGPoint(x: 0, y: target)
      isReconciling = false
    }

    private func targetOffset(in collection: UICollectionView) -> CGFloat? {
      switch place {
      case .followingLatest:
        return restingOffset(in: collection)
      case .reading(let anchorItemID, let offsetWithinItem):
        guard
          let indexPath = data?.indexPath(for: ChatItem(anchorKey: anchorItemID)),
          let attributes = collection.layoutAttributesForItem(at: indexPath)
        else {
          // The anchored item has gone. Leave the offset alone; the next drag re-anchors.
          return nil
        }
        let inset = collection.adjustedContentInset
        let wanted = attributes.frame.minY + CGFloat(offsetWithinItem) - inset.top
        return min(max(-inset.top, wanted), endOffset(in: collection))
      }
    }

    /// The content's bottom edge against the bottom of the safe area.
    ///
    /// `adjustedContentInset.bottom` is the composer's height, so resting here puts the newest
    /// row on the composer's top edge. Neither `scrollTo(id:anchor: .bottom)` nor
    /// `scrollTo(edge: .bottom)` can express this. The first rests a composer's height low and
    /// the second overshoots by the same amount.
    private func endOffset(in collection: UICollectionView) -> CGFloat {
      let inset = collection.adjustedContentInset
      let bottom = collection.contentSize.height - collection.bounds.height + inset.bottom
      return max(-inset.top, bottom)
    }

    /// Where a following reader rests: the end, or the chips' top while a question waits. A
    /// reader who is `reading` is clamped to `endOffset` instead, so one who scrolls on to
    /// Send stays there.
    private func restingOffset(in collection: UICollectionView) -> CGFloat {
      CGFloat(
        ChatReplyAnchor.restingOffset(
          endOffset: Double(endOffset(in: collection)),
          replyTop: replyTop(in: collection).map(Double.init),
          insetTop: Double(collection.adjustedContentInset.top),
          headroom: Double(replyHeadroom)
        ))
    }

    /// The `.reply` item's top in content coordinates, or `nil` when there is none or the
    /// layout has no frame for it yet.
    private func replyTop(in collection: UICollectionView) -> CGFloat? {
      guard let replyAfter, let indexPath = data?.indexPath(for: .reply(replyAfter)),
        let attributes = collection.layoutAttributesForItem(at: indexPath)
      else { return nil }
      return attributes.frame.minY
    }

    // MARK: - What SwiftUI is told

    private func distanceFromEnd(in collection: UICollectionView) -> Double {
      // While chips decide the rest, the rest is "the end". See `ChatReplyAnchor`.
      if replyTop(in: collection) != nil {
        return ChatReplyAnchor.distanceFromRest(
          restingOffset: Double(restingOffset(in: collection)),
          contentOffsetY: Double(collection.contentOffset.y))
      }
      return ChatEndProximity.distanceFromEnd(
        contentHeight: Double(collection.contentSize.height),
        contentOffsetY: Double(collection.contentOffset.y),
        containerHeight: Double(collection.bounds.height - collection.adjustedContentInset.bottom)
      )
    }

    /// Reports the reader's state up and the debug probes out, writing SwiftUI state only for
    /// a changed value.
    private func report() {
      guard let collection else { return }
      let distance = distanceFromEnd(in: collection)
      // Exact: the layout's own answer. A tiny marker view with a visibility threshold was not
      // reliable on a device.
      let isTailVisible = data.map { data in
        collection.indexPathsForVisibleItems.contains { data.itemIdentifier(for: $0) == .tail }
      } ?? false
      let state = ChatReaderState(
        showsJumpToLatest: ChatEndProximity.showsJumpToLatest(
          distanceFromEnd: distance,
          isEndMarkerVisible: isTailVisible,
          tolerance: ChatEndProximity.jumpTolerance
        ),
        isNearStart: ChatBackfill.isNearStart(
          distanceFromStart: ChatBackfill.distanceFromStart(
            contentOffsetY: Double(collection.contentOffset.y)),
          containerHeight: Double(collection.bounds.height)
        )
      )
      if !hasReported {
        hasReported = true
        reportedReaderState = state
      } else if state != reportedReaderState {
        reportedReaderState = state
        // Deferred a run-loop turn. This runs from `layoutSubviews` and snapshot completion,
        // which can land inside a SwiftUI update, where writing `@State` is an error.
        let report = onReaderState
        Task { @MainActor in report(state) }
      }
      // A shipping build sets neither probe, so it creates no task per scroll tick.
      let onScrollGeometry = onScrollGeometry
      let onPlaceChange = onPlaceChange
      guard onScrollGeometry != nil || onPlaceChange != nil else { return }
      let scroll = ChatScrollProbe(
        contentOffsetX: Double(collection.contentOffset.x),
        contentWidth: Double(collection.contentSize.width),
        containerWidth: Double(collection.bounds.width),
        contentHeight: Double(collection.contentSize.height),
        insetBottom: Double(collection.adjustedContentInset.bottom),
        boundsHeight: Double(collection.bounds.height),
        slotHeight: Double(visibleHeight)
      )
      let placeProbe = ChatPlaceProbe(
        distanceFromEnd: distance,
        isPositionedByUser: place.isPositionedByReader,
        // Always false: nothing here keeps a standing scroll target. `debug.keyboardMetrics`
        // readers check this field.
        hasStandingTarget: false
      )
      // Deferred a run-loop turn like `onReaderState`. A rotation's new `contentInset` scrolls
      // the view before `updateUIView` returns. Both in one task, because deferring only the
      // scroll probe still logged the warning.
      Task { @MainActor in
        onScrollGeometry?(scroll)
        onPlaceChange?(placeProbe)
      }
    }
  }
}

/// A `UICollectionView` that reports each layout pass.
///
/// The post-layout reconcile needs the layout pass itself as its signal. See
/// `ChatCollectionView.Coordinator.didLayOut`. A scroll delegate hears scrolling, not layout,
/// and KVO on `contentSize` reports estimate changes too. A subclass is the only way to hear it.
final class ChatCollection: UICollectionView {
  var onLayout: (() -> Void)?

  /// Called when the reader moved it without a pan gesture, with `contentOffset.y` from before
  /// the scroll, so the owner decides whether anything moved. See
  /// `ChatCollectionView.Coordinator.scrolledWithoutADrag(from:)`.
  var onScrollWithoutADrag: ((CGFloat) -> Void)?

  override func layoutSubviews() {
    super.layoutSubviews()
    onLayout?()
  }

  /// VoiceOver's three-finger page scroll, which is not a pan gesture.
  ///
  /// It raises no `scrollViewWillBeginDragging`, so without this the next layout pass would
  /// put the reader back at the end. Reported only when `super` performed the scroll.
  ///
  /// Untestable here: `UIScrollView`'s implementation arrives with UIKit's accessibility
  /// bundle, which loads only when an assistive technology starts, so without VoiceOver
  /// `super` returns `false`. XCUITest cannot send the gesture. The rule is tested in
  /// `ChatReaderPlaceTests.scrollingWithoutADragReads`.
  override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
    let before = contentOffset.y
    let performed = super.accessibilityScroll(direction)
    if performed { onScrollWithoutADrag?(before) }
    return performed
  }

  /// The scroll UIKit makes to bring a newly focused element on screen, again with no drag.
  ///
  /// The owner's own writes do not reach it: `reconcile` sets `contentOffset` directly, and
  /// `scrollToItem` in `walkTowardTheTail` does not route through this method. The
  /// `isReconciling` guard in `scrolledWithoutADrag(from:)` is kept in case a future SDK
  /// changes that. In tests without VoiceOver this is called but moves nothing, so
  /// `ChatCollectionViewTests` asserts only that such a call keeps a follower following.
  override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {
    let before = contentOffset.y
    super.scrollRectToVisible(rect, animated: animated)
    onScrollWithoutADrag?(before)
  }
}
