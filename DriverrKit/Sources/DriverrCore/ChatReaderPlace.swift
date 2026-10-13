import Foundation

/// Where the reader is in the conversation, as one value with one writer.
///
/// Neither SwiftUI scroll API can say "this item, this far into it", so a `UICollectionView`
/// coordinator owns this value, is the only writer of `contentOffset`, and applies it after
/// every layout pass. See the app's `ChatCollectionView`.
///
/// Two states: following the end, or reading with a named item held in place.
public enum ChatReaderPlace: Equatable, Sendable {
  /// The reader is at the end, and anything arriving there should stay in view.
  ///
  /// Applied as a resting offset, `contentSize - bounds + adjustedContentInset.bottom`, not as
  /// a scroll to a target. SwiftUI's `scrollTo(id:anchor: .bottom)` lands a composer's height
  /// low and `scrollTo(edge: .bottom)` overshoots by the same amount.
  case followingLatest

  /// The reader is holding a place: `anchorItemID` is the topmost item in the viewport and
  /// `offsetWithinItem` is how far the viewport's top edge sits inside it, in points.
  ///
  /// Without the offset, every reconcile would snap a reader partway down a long answer to
  /// its first line.
  case reading(anchorItemID: TranscriptTurn.ID, offsetWithinItem: Double)

  /// A snapshot of which item the viewport's top edge is in, and how far into it.
  ///
  /// `nil` when the owner cannot take one (an empty conversation, or nothing measured yet).
  /// Every transition treats `nil` as "leave the place alone".
  public struct Anchor: Equatable, Sendable {
    public var itemID: TranscriptTurn.ID
    /// Points from the item's top edge to the top of the visible region. Not negative in
    /// practice, because the anchor is the first item whose bottom edge is past that line.
    public var offsetWithinItem: Double

    public init(itemID: TranscriptTurn.ID, offsetWithinItem: Double) {
      self.itemID = itemID
      self.offsetWithinItem = offsetWithinItem
    }
  }

  /// Everything that can happen to the chat, so the transition table is exhaustive. Most
  /// events leave the place unchanged, and that is intended.
  public enum Event: Equatable, Sendable {
    /// The chat appeared, or a pane switch gave it another conversation. The reader came for
    /// the last thing said.
    case opened
    /// The reader tapped jump-to-latest, or focused the composer, which answers the newest
    /// thing.
    case jumpedToLatest
    /// A finger went down. The anchor is taken before the drag moves anything.
    case dragBegan(Anchor?)
    /// The reader scrolled without a pan gesture: VoiceOver's `accessibilityScroll`, or the
    /// `scrollRectToVisible` UIKit performs for a newly focused element. Same rule as
    /// `dragBegan`, but the anchor is taken after the scroll.
    case scrolledWithoutADrag(Anchor?)
    /// A drag ended without deceleration, or deceleration finished. `distanceFromEnd` is
    /// `ChatEndProximity.distanceFromEnd`, and `anchor` is where the reader came to rest.
    case settled(distanceFromEnd: Double, at: Anchor?)
    /// A turn arrived at the end of the conversation.
    case appended
    /// The final turn grew while keeping its record id, which a diffable data source cannot
    /// see.
    case finalTurnGrew
    /// The working row appeared or left.
    case activityChanged
    /// A tool run was opened or a bounded turn expanded. The anchor is taken before the growth
    /// lands, so it records what the reader was looking at.
    case rowExpansionChanged(Anchor?)
    /// Older turns arrived at the front. The anchor is taken before they are applied, so it
    /// records where the reader is now, not where the drag began.
    case prepended(Anchor?)
    /// The composer grew a line, or the keyboard came or went.
    case insetChanged
    /// A rotation, a column resize, or a surface switch.
    case widthChanged
  }

  /// The whole transition table, and the only way this value changes.
  ///
  /// | event | rule |
  /// |---|---|
  /// | `opened` | `followingLatest` |
  /// | `jumpedToLatest` | `followingLatest` |
  /// | `dragBegan` | `reading` at the snapshotted anchor |
  /// | `scrolledWithoutADrag` | `reading` at the snapshotted anchor |
  /// | `settled` within `tolerance` of the end | `followingLatest` |
  /// | `settled` beyond it | `reading` re-anchored; a follower unchanged |
  /// | `appended` | unchanged |
  /// | `finalTurnGrew` | unchanged |
  /// | `activityChanged` | unchanged |
  /// | `rowExpansionChanged` | `reading` at the snapshotted anchor |
  /// | `prepended` | `reading` re-anchored; a follower unchanged |
  /// | `insetChanged` | unchanged |
  /// | `widthChanged` | unchanged |
  ///
  /// The unchanged rows are the design. A reader keeps their item wherever content moves, and
  /// a follower is carried by the resting offset, which the owner re-applies after every
  /// layout pass.
  ///
  /// Only the reader hands the position over: a drag, or a scroll they made without one. A
  /// settle or a prepend can re-anchor a reader but never turns a follower into one, because
  /// a scroll view settles for reasons the reader had no part in.
  ///
  /// `prepended` re-anchors because older turns are fetched during the swipe that asks for
  /// them. Without it the reconcile would return the reader to the drag-start anchor and undo
  /// the swipe.
  ///
  /// `rowExpansionChanged` makes even a follower a reader. Resting at the end after a run
  /// opens would scroll every row above it up by the run's height, and opening a run must not
  /// cost the reader their place. The cost: a following reader who opens a run stops
  /// following until they scroll back to the end.
  ///
  /// `scrolledWithoutADrag` exists because VoiceOver scrolls raise no
  /// `scrollViewWillBeginDragging`, so without it the next layout pass put a screen-reader
  /// user back at the end. Its anchor is taken after the scroll, because the scroll is over
  /// when the owner hears of it and an earlier anchor would undo it. The owner enforces that
  /// order in `ChatCollectionView.Coordinator.scrolledWithoutADrag`.
  ///
  /// A missing anchor never moves the reader, except a settle inside the tolerance, which
  /// needs no anchor to mean "at the end".
  public func applying(
    _ event: Event,
    tolerance: Double = ChatEndProximity.jumpTolerance
  ) -> ChatReaderPlace {
    switch event {
    case .opened, .jumpedToLatest:
      return .followingLatest
    case .dragBegan(let anchor), .scrolledWithoutADrag(let anchor):
      guard let anchor else { return self }
      return .reading(anchorItemID: anchor.itemID, offsetWithinItem: anchor.offsetWithinItem)
    case .settled(let distanceFromEnd, let anchor):
      if distanceFromEnd <= tolerance { return .followingLatest }
      // A settle cannot take the position from a follower. On iPad, returning from the
      // terminal, a settle fired against a half-measured layout and anchored a follower 1613 pt
      // into a turn they never scrolled to.
      // `PaneChatUITests.testComingBackFromTheTerminalLandsOnTheNewestTurn` catches it.
      guard case .reading = self, let anchor else { return self }
      return .reading(anchorItemID: anchor.itemID, offsetWithinItem: anchor.offsetWithinItem)
    case .rowExpansionChanged(let anchor):
      guard let anchor else { return self }
      return .reading(anchorItemID: anchor.itemID, offsetWithinItem: anchor.offsetWithinItem)
    case .prepended(let anchor):
      // A follower is carried by the resting offset and keeps following.
      guard case .reading = self, let anchor else { return self }
      return .reading(anchorItemID: anchor.itemID, offsetWithinItem: anchor.offsetWithinItem)
    case .appended, .finalTurnGrew, .activityChanged, .insetChanged, .widthChanged:
      return self
    }
  }

  /// Whether the reader has taken the position over. `debug.keyboardMetrics` reports it as
  /// `isPositionedByUser`.
  public var isPositionedByReader: Bool {
    if case .reading = self { return true }
    return false
  }

  /// The item the reader is holding, or `nil` while they are following the end.
  public var anchorItemID: TranscriptTurn.ID? {
    if case .reading(let id, _) = self { return id }
    return nil
  }
}
