import Foundation

/// What VoiceOver is told when the foot of the conversation changes, or `nil` for nothing.
///
/// The transcript is a `UICollectionView`, which creates only visible cells, so a reader
/// scrolled back has no working-row element to find. The news is posted instead (one line in
/// `PaneChatView`, as `PaneComposerBar` does for send verdicts). Three rules, each a thing
/// not to announce:
///
/// 1. Nothing to a reader at the end, who already has the row on screen.
/// 2. Only arrivals. A row leaving is not news, and a row changing its wording is not an
///    arrival, which keeps the ticking "Sent 40s ago" from re-announcing every second.
/// 3. Never a send verdict, which `PaneComposerBar` already announces to everyone.
public enum ChatActivityAnnouncement {
  /// The sentence to announce, or `nil` when there is nothing to say.
  ///
  /// - Parameters:
  ///   - previous: the foot of the conversation before this change, `nil` for no row.
  ///   - current: the foot of the conversation now, `nil` for no row.
  ///   - isScrolledBack: whether the reader is away from the end.
  ///     `ChatReaderState.showsJumpToLatest` is the value to pass: true exactly for a reader
  ///     whose cells do not reach the end.
  public static func onArrival(
    previous: ChatActivity?,
    current: ChatActivity?,
    isScrolledBack: Bool
  ) -> String? {
    guard isScrolledBack else { return nil }
    guard previous == nil, let current else { return nil }
    guard !current.isVerdict else { return nil }
    // The row's own reading, so the announcement and the cell use the same words.
    return current.accessibilityLabel
  }
}
