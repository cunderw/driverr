import Foundation

/// Whether scrolling back should fetch the page behind the conversation.
///
/// The manual `Load more` control stays. A fetch while scrolling back is not spending
/// quietly, because the bill and the priced control stay on screen while it runs.
public enum ChatBackfill {
  /// How far above the visible region the start of the fetched page lies, in points. A
  /// distance for `ChatEndProximity`'s reason, clamped for rubber-band overscroll.
  public static func distanceFromStart(contentOffsetY: Double) -> Double {
    max(0, contentOffsetY)
  }

  /// Whether the page behind should already be on its way: within one container height of
  /// the start.
  ///
  /// Firing only when the oldest turn is visible lands the page mid-flick, and the flick
  /// then carries the reader through the new turns to the front of the file. A screen of
  /// warning lets the turns land above content the reader still has to scroll through. One
  /// container height rather than a constant, because this is distance still to travel,
  /// which scales with the screen. `ChatEndProximity.jumpTolerance` is a resting padding,
  /// which does not.
  public static func isNearStart(distanceFromStart: Double, containerHeight: Double) -> Bool {
    distanceFromStart <= containerHeight
  }

  /// Whether this scroll callback should widen the page.
  ///
  /// Fires only on the rising edge into `isNearStart`, which bounds it: a load fired by a
  /// scroll must not cause a scroll that fires another. A landed page puts a screen of turns
  /// above the reader, taking them out of the zone and re-arming the edge.
  ///
  /// - `hasPageBehind`: `TranscriptPaging` removes the button when nothing is behind, and
  ///   this obeys the same fact.
  /// - `isPagingBack`: no re-entry while a fetch is in flight.
  ///   `PaneTranscriptModel.loadMore` also guards this; the check makes the decision complete.
  /// - `lastAutoLoadFailed`: disarms after a failure and is not cleared by scrolling, or a
  ///   reader near the front would retry on every movement. A tap clears it.
  /// - `wasNearStart`: the edge itself. Without it every callback in the zone would fetch.
  public static func loadsMore(
    isNearStart: Bool,
    wasNearStart: Bool,
    isPagingBack: Bool,
    hasPageBehind: Bool,
    lastAutoLoadFailed: Bool
  ) -> Bool {
    guard isNearStart, !wasNearStart else { return false }
    guard hasPageBehind, !isPagingBack, !lastAutoLoadFailed else { return false }
    return true
  }
}
