import Foundation

/// How far the reader is from the end of a conversation, which the jump-to-latest control
/// is drawn from.
///
/// A distance, not a fraction of the newest turn visible. A turn taller than the screen is
/// visible from its first line, so a fraction-based rule gave a reader deep in a long answer
/// no way back, and a view cannot know a turn's height before measuring it.
public enum ChatEndProximity {
  /// How far below the visible region the end of the content lies, in points, never less
  /// than zero.
  ///
  /// Do not add the bottom content inset. It is empty space below the content, and adding it
  /// over-reports by the composer's height. At rest with the keyboard up, the distance is
  /// 14.7 without the inset and 449.7 with it, far past `jumpTolerance`.
  ///
  /// Clamped, because rubber-band overscroll and a conversation shorter than its viewport
  /// both go negative. The container height varies a lot between runs; the resting residual
  /// does not, which is why the tolerance is a residual.
  public static func distanceFromEnd(
    contentHeight: Double,
    contentOffsetY: Double,
    containerHeight: Double
  ) -> Double {
    max(0, contentHeight - (contentOffsetY + containerHeight))
  }

  /// Whether the jump-to-latest control belongs on screen.
  ///
  /// The distance decides, and a visible end marker can only take the control away. Do not
  /// show the control because the marker is not visible: on a device a one-point scroll
  /// target does not reliably report itself visible, which put the control on a chat opened
  /// at the bottom. That does not reproduce on a simulator.
  public static func showsJumpToLatest(
    distanceFromEnd: Double,
    isEndMarkerVisible: Bool,
    tolerance: Double
  ) -> Bool {
    if isEndMarkerVisible { return false }
    return distanceFromEnd > tolerance
  }

  /// The distance, in points, at which the reader counts as parked at the end.
  ///
  /// At rest the chat sits about 14 pt from its end on phone and iPad, the transcript stack's
  /// bottom padding. 64 clears that residual by four times and stays under a third of the
  /// smallest viewport (211 pt, phone with keyboard up). Not a fraction of the viewport,
  /// because the resting padding does not change when the keyboard halves the screen.
  public static let jumpTolerance: Double = 64

  /// How near the end a reader's settle must be to return them to following the latest:
  /// `jumpTolerance`, capped at half the conversation's scroll range.
  ///
  /// A conversation that overflows its viewport by less than `jumpTolerance` is all "near the
  /// end", so with the plain tolerance every scroll back settled inside it and snapped to the
  /// end. Its first rows could never be read: the provenance row, the conversation's first
  /// cell, was unreachable on a page 47 pt taller than the screen. Capped at half the range, a
  /// reader nearer the start than the end keeps their place, and one at the end still returns.
  ///
  /// It only narrows the return-to-end band. A settle never creates a reading place; only a
  /// drag does (`ChatReaderPlace.applying(_:tolerance:)`), so a settle against a half-measured
  /// layout still cannot demote a follower, whatever this returns.
  ///
  /// `scrollRange` is the distance from the top rest to the end rest, in points.
  public static func settleTolerance(scrollRange: Double) -> Double {
    min(jumpTolerance, max(0, scrollRange) / 2)
  }
}
