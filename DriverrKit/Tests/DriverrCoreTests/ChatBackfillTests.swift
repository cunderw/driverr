import Foundation
import Testing

@testable import DriverrCore

/// Whether scrolling back fetches the page behind the conversation. A load fired by
/// scrolling causes a scroll, so the rising edge and the disarm are what bound it; they are
/// tested as guarantees.
@Suite("Fetching earlier turns on scrolling back")
struct ChatBackfillTests {
  // MARK: - How far from the start

  @Test("The distance from the start is the offset itself")
  func theDistanceIsTheOffset() {
    #expect(ChatBackfill.distanceFromStart(contentOffsetY: 1900) == 1900)
  }

  /// Rubber-band overscroll reports a negative offset. `ChatEndProximity` clamps the same way.
  @Test("Overscrolling past the front is no distance at all")
  func overscrollIsClamped() {
    #expect(ChatBackfill.distanceFromStart(contentOffsetY: -84) == 0)
  }

  // MARK: - The zone

  /// The chat's container ran 505 points, and 211 with the keyboard up, so the zone is a
  /// screen rather than a constant.
  @Test("A screen above the front is near enough to fetch")
  func aScreenAboveTheFrontIsNearEnough() {
    #expect(ChatBackfill.isNearStart(distanceFromStart: 480, containerHeight: 505.3))
    #expect(ChatBackfill.isNearStart(distanceFromStart: 0, containerHeight: 505.3))
  }

  @Test("More than a screen above the front is not")
  func deeperInIsNotNearEnough() {
    #expect(!ChatBackfill.isNearStart(distanceFromStart: 1900, containerHeight: 505.3))
  }

  /// With the keyboard up, 400 points is nearly two screens away, which is not a prefetch.
  @Test("The zone follows the viewport rather than a fixed number of points")
  func theZoneFollowsTheViewport() {
    #expect(ChatBackfill.isNearStart(distanceFromStart: 400, containerHeight: 505.3))
    #expect(!ChatBackfill.isNearStart(distanceFromStart: 400, containerHeight: 211.3))
  }

  // MARK: - The edge

  @Test("Arriving in the zone fetches the page behind it")
  func arrivingInTheZoneFetches() {
    #expect(
      ChatBackfill.loadsMore(
        isNearStart: true,
        wasNearStart: false,
        isPagingBack: false,
        hasPageBehind: true,
        lastAutoLoadFailed: false))
  }

  /// Crossing into the zone produces many callbacks and a bounce produces more. Only the
  /// first is a fetch.
  @Test("Staying in the zone fetches nothing more")
  func stayingInTheZoneFetchesNothingMore() {
    #expect(
      !ChatBackfill.loadsMore(
        isNearStart: true,
        wasNearStart: true,
        isPagingBack: false,
        hasPageBehind: true,
        lastAutoLoadFailed: false))
  }

  @Test("A reader deeper in the conversation is not fetching")
  func awayFromTheZoneFetchesNothing() {
    #expect(
      !ChatBackfill.loadsMore(
        isNearStart: false,
        wasNearStart: true,
        isPagingBack: false,
        hasPageBehind: true,
        lastAutoLoadFailed: false))
  }

  /// A landed page puts a screenful above the reader, so returning is a second request.
  @Test("Leaving the zone and returning is a fresh fetch")
  func returningToTheZoneFetchesAgain() {
    #expect(
      !ChatBackfill.loadsMore(
        isNearStart: false, wasNearStart: true, isPagingBack: false, hasPageBehind: true,
        lastAutoLoadFailed: false))
    #expect(
      ChatBackfill.loadsMore(
        isNearStart: true, wasNearStart: false, isPagingBack: false, hasPageBehind: true,
        lastAutoLoadFailed: false))
  }

  // MARK: - What refuses it

  /// `TranscriptPaging` removes the button at the start of the file; the fetch obeys the same
  /// fact.
  @Test("Nothing behind the page is nothing to fetch")
  func theStartOfTheFileFetchesNothing() {
    #expect(
      !ChatBackfill.loadsMore(
        isNearStart: true,
        wasNearStart: false,
        isPagingBack: false,
        hasPageBehind: false,
        lastAutoLoadFailed: false))
  }

  @Test("A fetch already in flight is not re-entered")
  func aFetchInFlightIsNotReEntered() {
    #expect(
      !ChatBackfill.loadsMore(
        isNearStart: true,
        wasNearStart: false,
        isPagingBack: true,
        hasPageBehind: true,
        lastAutoLoadFailed: false))
  }

  /// Scrolling does not re-arm a failed fetch, or a reader parked near the front retries on
  /// every movement. Only a tap clears it.
  @Test("A failed automatic fetch stays disarmed at a fresh edge")
  func aFailedFetchStaysDisarmed() {
    #expect(
      !ChatBackfill.loadsMore(
        isNearStart: true,
        wasNearStart: false,
        isPagingBack: false,
        hasPageBehind: true,
        lastAutoLoadFailed: true))
  }

  @Test("A tap re-arms the next edge")
  func aTapReArmsTheNextEdge() {
    #expect(
      ChatBackfill.loadsMore(
        isNearStart: true,
        wasNearStart: false,
        isPagingBack: false,
        hasPageBehind: true,
        lastAutoLoadFailed: false))
  }

  /// A conversation shorter than its viewport sits at offset zero, and `wasNearStart` begins
  /// `false`, so the first frame is an edge.
  @Test("A conversation shorter than the screen is in the zone from the first frame")
  func aShortConversationIsInTheZoneImmediately() {
    #expect(ChatBackfill.isNearStart(distanceFromStart: 0, containerHeight: 505.3))
    #expect(
      ChatBackfill.loadsMore(
        isNearStart: true,
        wasNearStart: false,
        isPagingBack: false,
        hasPageBehind: true,
        lastAutoLoadFailed: false))
  }
}
