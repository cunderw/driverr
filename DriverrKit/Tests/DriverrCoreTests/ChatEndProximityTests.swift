import Foundation
import Testing

@testable import DriverrCore

/// How far the reader is from the end of a conversation, and whether the jump-to-latest
/// control belongs on screen. The resting residual is the transcript stack's 14-point bottom
/// padding on both phone and iPad.
@Suite("Distance from the end of a conversation")
struct ChatEndProximityTests {
  // MARK: - The distance itself

  @Test("At rest the reader is a bottom padding away from the end")
  func restingDistanceIsTheBottomPadding() {
    let distance = ChatEndProximity.distanceFromEnd(
      contentHeight: 1437, contentOffsetY: 917, containerHeight: 505.3)
    #expect(abs(distance - 14.7) < 0.1)
  }

  /// The same residual as on the phone, which is why one tolerance serves both devices.
  @Test("The resting residual is the same on a tablet's viewport")
  func restingDistanceIsDeviceIndependent() {
    let distance = ChatEndProximity.distanceFromEnd(
      contentHeight: 1495, contentOffsetY: 433.5, containerHeight: 1047.5)
    #expect(abs(distance - 14.0) < 0.1)
  }

  /// A bottom content inset is empty space, not content. Adding it in reported a reader
  /// resting at the end as several `jumpTolerance`s away from it.
  @Test("An inset below the content is not distance from the end")
  func aBottomInsetIsNotDistanceFromTheEnd() {
    let distance = ChatEndProximity.distanceFromEnd(
      contentHeight: 518, contentOffsetY: 281, containerHeight: 222.3)
    #expect(abs(distance - 14.7) < 0.1)
    #expect(distance < ChatEndProximity.jumpTolerance)
  }

  @Test("A reader at the top of a tall conversation is still far from the end")
  func theTopOfATallConversationIsFarFromTheEnd() {
    let distance = ChatEndProximity.distanceFromEnd(
      contentHeight: 518, contentOffsetY: 1, containerHeight: 222.3)
    #expect(abs(distance - 294.7) < 0.1)
    #expect(distance > ChatEndProximity.jumpTolerance)
  }

  /// Covers rubber-band overscroll and a conversation shorter than its viewport.
  @Test("A negative composition clamps to zero")
  func negativeCompositionClampsToZero() {
    let shortPage = ChatEndProximity.distanceFromEnd(
      contentHeight: 300, contentOffsetY: 0, containerHeight: 500)
    #expect(shortPage == 0)

    let overscrolled = ChatEndProximity.distanceFromEnd(
      contentHeight: 1437, contentOffsetY: 1000, containerHeight: 505.3)
    #expect(overscrolled == 0)
  }

  // MARK: - Whether the control belongs on screen

  @Test("At rest there is nowhere to go, so there is no control")
  func restingHidesTheControl() {
    #expect(
      ChatEndProximity.showsJumpToLatest(
        distanceFromEnd: 0, isEndMarkerVisible: false,
        tolerance: ChatEndProximity.jumpTolerance) == false)
    #expect(
      ChatEndProximity.showsJumpToLatest(
        distanceFromEnd: 14.7, isEndMarkerVisible: false,
        tolerance: ChatEndProximity.jumpTolerance) == false)
  }

  @Test("Just under the tolerance is still at the end")
  func justUnderTheToleranceHidesTheControl() {
    #expect(
      ChatEndProximity.showsJumpToLatest(
        distanceFromEnd: ChatEndProximity.jumpTolerance - 0.1, isEndMarkerVisible: false,
        tolerance: ChatEndProximity.jumpTolerance) == false)
    #expect(
      ChatEndProximity.showsJumpToLatest(
        distanceFromEnd: ChatEndProximity.jumpTolerance, isEndMarkerVisible: false,
        tolerance: ChatEndProximity.jumpTolerance) == false)
  }

  /// A single drag on phone and iPad, with the newest turn still on screen.
  @Test("A drag's worth of distance shows the control")
  func aDragShowsTheControl() {
    #expect(
      ChatEndProximity.showsJumpToLatest(
        distanceFromEnd: 379, isEndMarkerVisible: false,
        tolerance: ChatEndProximity.jumpTolerance))
    #expect(
      ChatEndProximity.showsJumpToLatest(
        distanceFromEnd: 447.5, isEndMarkerVisible: false,
        tolerance: ChatEndProximity.jumpTolerance))
  }

  /// The marker only suppresses the control. A one-point target does not reliably report
  /// itself visible on a device, so pointing the control at it put an arrow on a chat that
  /// was already at its end.
  @Test("A visible end marker hides the control at any distance")
  func aVisibleMarkerHidesTheControl() {
    for distance in [0.0, 379.0, 1260.7, 10_000.0] {
      #expect(
        ChatEndProximity.showsJumpToLatest(
          distanceFromEnd: distance, isEndMarkerVisible: true,
          tolerance: ChatEndProximity.jumpTolerance) == false,
        "The end of the conversation is on screen at \(distance); there is nowhere to go.")
    }
  }

  /// The working row is about 30 points tall, and the tolerance must cover it.
  @Test("The tolerance covers the working row's own height")
  func theToleranceCoversTheActivityRow() {
    #expect(ChatEndProximity.jumpTolerance >= 30)
  }

  /// Twice the resting residual, and well inside the smallest viewport (211 points on a
  /// phone with the keyboard up).
  @Test("The tolerance sits between the resting residual and a viewport")
  func theToleranceIsBetweenTheResidualAndAViewport() {
    #expect(ChatEndProximity.jumpTolerance > 14.7 * 2)
    #expect(ChatEndProximity.jumpTolerance < 211 / 2)
  }
}
