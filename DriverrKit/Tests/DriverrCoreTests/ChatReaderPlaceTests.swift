import Foundation
import Testing

@testable import DriverrCore

/// Every row of `ChatReaderPlace`'s transition table. The value is the chat's whole scroll
/// state, so the suite covers every `ChatReaderPlace.Event`; most events must leave the
/// place alone.
@Suite("Where the chat's reader is")
struct ChatReaderPlaceTests {
  private let anchor = ChatReaderPlace.Anchor(itemID: "turn-7", offsetWithinItem: 120)
  private let laterAnchor = ChatReaderPlace.Anchor(itemID: "turn-9", offsetWithinItem: 8)

  private var reading: ChatReaderPlace {
    .reading(anchorItemID: anchor.itemID, offsetWithinItem: anchor.offsetWithinItem)
  }

  // MARK: - The two events that take the reader to the end

  @Test("Opening the chat follows the end, whatever the place was before")
  func openingFollows() {
    #expect(ChatReaderPlace.followingLatest.applying(.opened) == .followingLatest)
    #expect(reading.applying(.opened) == .followingLatest)
  }

  /// Composer focus sends the same event: the composer answers the newest thing.
  @Test("An explicit jump follows the end from anywhere")
  func jumpingFollows() {
    #expect(ChatReaderPlace.followingLatest.applying(.jumpedToLatest) == .followingLatest)
    #expect(reading.applying(.jumpedToLatest) == .followingLatest)
  }

  // MARK: - Taking the position back

  /// The snapshot is taken before the drag moves anything, so the anchor is what the reader
  /// was looking at.
  @Test("A drag beginning holds the item under the top of the viewport")
  func draggingReads() {
    #expect(
      ChatReaderPlace.followingLatest.applying(.dragBegan(anchor))
        == .reading(anchorItemID: "turn-7", offsetWithinItem: 120)
    )
  }

  @Test("A second drag re-anchors rather than keeping the first anchor")
  func draggingAgainReanchors() {
    #expect(
      reading.applying(.dragBegan(laterAnchor))
        == .reading(anchorItemID: "turn-9", offsetWithinItem: 8)
    )
  }

  /// The owner returns `nil` for an empty conversation or an unmeasured layout. That is not
  /// evidence about the reader.
  @Test("A drag the owner could not snapshot leaves the place alone")
  func draggingWithNoAnchorChangesNothing() {
    #expect(ChatReaderPlace.followingLatest.applying(.dragBegan(nil)) == .followingLatest)
    #expect(reading.applying(.dragBegan(nil)) == reading)
  }

  // MARK: - Taking it back without a pan gesture

  /// A VoiceOver three-finger swipe arrives as `UIScrollView.accessibilityScroll(_:)` and
  /// raises no `scrollViewWillBeginDragging`. Without this row the next layout pass returned
  /// the reader to the end.
  @Test("A scroll that did not come through the pan gesture holds the reader's place")
  func scrollingWithoutADragReads() {
    #expect(
      ChatReaderPlace.followingLatest.applying(.scrolledWithoutADrag(anchor))
        == .reading(anchorItemID: "turn-7", offsetWithinItem: 120)
    )
  }

  @Test("A second non-pan scroll re-anchors rather than keeping the first anchor")
  func scrollingWithoutADragAgainReanchors() {
    #expect(
      reading.applying(.scrolledWithoutADrag(laterAnchor))
        == .reading(anchorItemID: "turn-9", offsetWithinItem: 8)
    )
  }

  @Test("A non-pan scroll the owner could not snapshot leaves the place alone")
  func scrollingWithoutADragWithNoAnchorChangesNothing() {
    #expect(
      ChatReaderPlace.followingLatest.applying(.scrolledWithoutADrag(nil)) == .followingLatest)
    #expect(reading.applying(.scrolledWithoutADrag(nil)) == reading)
  }

  /// A settle says where a scroll came to rest, not who asked for it, so it cannot unfollow.
  /// A non-pan scroll can. Folding one row into the other anchored a follower deep in a turn
  /// on a half-measured iPad layout.
  @Test("A settle still cannot hand a follower the position, where a non-pan scroll can")
  func aSettleStillCannotUnfollowWhereThisCan() {
    let far = ChatReaderPlace.followingLatest.applying(
      .settled(distanceFromEnd: 1613, at: anchor))
    #expect(far == .followingLatest)
    #expect(
      ChatReaderPlace.followingLatest.applying(.scrolledWithoutADrag(anchor))
        == .reading(anchorItemID: "turn-7", offsetWithinItem: 120)
    )
  }

  // MARK: - Coming to rest

  /// The residual at the end is the transcript's bottom padding, about 14 pt.
  @Test("Settling within the tolerance of the end goes back to following")
  func settlingAtTheEndFollows() {
    #expect(reading.applying(.settled(distanceFromEnd: 14.7, at: laterAnchor)) == .followingLatest)
    #expect(reading.applying(.settled(distanceFromEnd: 0, at: laterAnchor)) == .followingLatest)
  }

  /// Inclusive: a reader exactly at the tolerance is parked at the end.
  @Test("The tolerance is inclusive, and a point past it is not")
  func theToleranceIsInclusive() {
    #expect(
      reading.applying(.settled(distanceFromEnd: ChatEndProximity.jumpTolerance, at: laterAnchor))
        == .followingLatest
    )
    #expect(
      reading.applying(
        .settled(distanceFromEnd: ChatEndProximity.jumpTolerance + 1, at: laterAnchor))
        == .reading(anchorItemID: "turn-9", offsetWithinItem: 8)
    )
  }

  @Test("Settling beyond the tolerance stays reading, at the new anchor")
  func settlingAwayFromTheEndReads() {
    #expect(
      reading.applying(.settled(distanceFromEnd: 900, at: laterAnchor))
        == .reading(anchorItemID: "turn-9", offsetWithinItem: 8)
    )
  }

  /// Only a drag hands the position over. A scroll view settles for reasons the reader had no
  /// part in: a bounce, a clamp when content shrinks, a re-attach. On an iPad layout that had
  /// self-sized a third of the page, a settle reported about 1600 pt from the end and
  /// unfollowed the reader. `PaneChatUITests.testComingBackFromTheTerminalLandsOnTheNewestTurn`
  /// covers the device side.
  @Test("Settling beyond the tolerance leaves a follower following")
  func settlingAwayFromTheEndDoesNotUnfollow() {
    #expect(
      ChatReaderPlace.followingLatest.applying(.settled(distanceFromEnd: 900, at: laterAnchor))
        == .followingLatest
    )
  }

  /// A reader with no anchor available keeps the one they had.
  @Test("Settling away from the end with no anchor leaves the place alone")
  func settlingWithNoAnchorChangesNothing() {
    #expect(
      ChatReaderPlace.followingLatest.applying(.settled(distanceFromEnd: 900, at: nil))
        == .followingLatest
    )
    #expect(reading.applying(.settled(distanceFromEnd: 900, at: nil)) == reading)
  }

  /// The one asymmetry in the table.
  @Test("Settling at the end follows even with no anchor")
  func settlingAtTheEndNeedsNoAnchor() {
    #expect(reading.applying(.settled(distanceFromEnd: 3, at: nil)) == .followingLatest)
  }

  @Test("The tolerance is a parameter, not a constant this type owns")
  func theToleranceIsAParameter() {
    #expect(reading.applying(.settled(distanceFromEnd: 30, at: laterAnchor), tolerance: 10)
      == .reading(anchorItemID: "turn-9", offsetWithinItem: 8))
    #expect(reading.applying(.settled(distanceFromEnd: 30, at: laterAnchor), tolerance: 100)
      == .followingLatest)
  }

  // MARK: - The events that must change nothing

  /// A turn arriving while the reader is in the history must not move them. The
  /// jump-to-latest control offers the way to it.
  @Test("An appended turn does not move a reader who is reading")
  func appendingDoesNotMoveAReader() {
    #expect(reading.applying(.appended) == reading)
  }

  /// The resting offset carries the new turn into view.
  @Test("An appended turn does not stop a reader following")
  func appendingDoesNotStopFollowing() {
    #expect(ChatReaderPlace.followingLatest.applying(.appended) == .followingLatest)
  }

  /// The final turn growing under the same record id. A diffable data source cannot see it,
  /// so the owner reconfigures the item.
  @Test("The final turn growing in place changes nothing")
  func growthChangesNothing() {
    #expect(reading.applying(.finalTurnGrew) == reading)
    #expect(ChatReaderPlace.followingLatest.applying(.finalTurnGrew) == .followingLatest)
  }

  @Test("The activity row appearing or leaving changes nothing")
  func activityChangesNothing() {
    #expect(reading.applying(.activityChanged) == reading)
    #expect(ChatReaderPlace.followingLatest.applying(.activityChanged) == .followingLatest)
  }

  /// Opening a tool run changes content above and below the reader; the tapped row must not
  /// move. A follower would be carried down by the growth, so the expansion anchors them. See
  /// `applying(_:tolerance:)`.
  @Test("Opening or collapsing a row holds the reader where they are")
  func expansionHoldsTheReader() {
    #expect(
      ChatReaderPlace.followingLatest.applying(.rowExpansionChanged(anchor))
        == .reading(anchorItemID: "turn-7", offsetWithinItem: 120)
    )
    #expect(
      reading.applying(.rowExpansionChanged(laterAnchor))
        == .reading(anchorItemID: "turn-9", offsetWithinItem: 8)
    )
  }

  @Test("An expansion the owner could not snapshot leaves the place alone")
  func expansionWithNoAnchorChangesNothing() {
    #expect(ChatReaderPlace.followingLatest.applying(.rowExpansionChanged(nil)) == .followingLatest)
    #expect(reading.applying(.rowExpansionChanged(nil)) == reading)
  }

  /// The fetch fires during the swipe that asks for it, so the anchor from `dragBegan` is
  /// stale. The owner reads a fresh anchor at the top of `apply(…)` and hands it here. See
  /// `applying(_:tolerance:)`, and `ChatCollectionViewTests` for the timing half.
  @Test("A prepend re-anchors a reader at where they are now")
  func prependingReAnchorsAReader() {
    #expect(
      reading.applying(.prepended(laterAnchor))
        == .reading(anchorItemID: "turn-9", offsetWithinItem: 8)
    )
  }

  /// The resting offset already carries a follower.
  @Test("A prepend leaves a follower following")
  func prependingLeavesAFollowerAlone() {
    #expect(ChatReaderPlace.followingLatest.applying(.prepended(anchor)) == .followingLatest)
    #expect(ChatReaderPlace.followingLatest.applying(.prepended(nil)) == .followingLatest)
  }

  @Test("A prepend the owner could not snapshot leaves the place alone")
  func prependingWithNoAnchorChangesNothing() {
    #expect(reading.applying(.prepended(nil)) == reading)
  }

  /// The inset is the owner's arithmetic, not the reader's place.
  @Test("An inset or keyboard change changes nothing")
  func insetChangesNothing() {
    #expect(reading.applying(.insetChanged) == reading)
    #expect(ChatReaderPlace.followingLatest.applying(.insetChanged) == .followingLatest)
  }

  /// Re-applying a standing target against a changed viewport caused horizontal drift; there
  /// is no standing target now.
  @Test("A width change changes nothing")
  func widthChangesNothing() {
    #expect(reading.applying(.widthChanged) == reading)
    #expect(ChatReaderPlace.followingLatest.applying(.widthChanged) == .followingLatest)
  }

  // MARK: - What the value says about itself

  /// What `debug.keyboardMetrics` reports as `isPositionedByUser`.
  @Test("Reading is the reader having taken the position over")
  func positionedByReader() {
    #expect(ChatReaderPlace.followingLatest.isPositionedByReader == false)
    #expect(reading.isPositionedByReader)
  }

  @Test("Only a reading place names an item")
  func anchorItemID() {
    #expect(ChatReaderPlace.followingLatest.anchorItemID == nil)
    #expect(reading.anchorItemID == "turn-7")
  }

  @Test("Two places in the same item at different depths are not equal")
  func theOffsetIsPartOfTheIdentity() {
    #expect(
      ChatReaderPlace.reading(anchorItemID: "turn-7", offsetWithinItem: 0)
        != ChatReaderPlace.reading(anchorItemID: "turn-7", offsetWithinItem: 120)
    )
  }
}
