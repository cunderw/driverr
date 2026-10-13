import Foundation

/// Where the chat rests while a question is waiting for an answer.
///
/// A pending `AskUserQuestion` with described options can be taller than the chat, and
/// resting at the end would show only its last option. So while chips are offered, the rest
/// is the top of the chip band, never below the end. The jump-to-latest control and the
/// follow/read settle measure from this rest, so a reader at the band's top is following
/// and one who scrolled on toward Send is reading.
public enum ChatReplyAnchor {
  /// The air above the chip band's first line at rest, in points.
  public static let lead: Double = 8

  /// The offset the chat rests at. `endOffset` is the content's end against the composer's
  /// top edge, already clamped at the top. `replyTop` is the band's top in content
  /// coordinates, or `nil` when no band is drawn. `insetTop` is the scroll view's top inset.
  /// `headroom` is extra room left above the band; see `headroom(screenBandTop:bandTop:)`.
  public static func restingOffset(
    endOffset: Double, replyTop: Double?, insetTop: Double, headroom: Double = 0
  ) -> Double {
    guard let replyTop else { return endOffset }
    return max(-insetTop, min(endOffset, replyTop - insetTop - lead - headroom))
  }

  /// The room to leave above a band once the transcript takes a question over from the
  /// screen.
  ///
  /// A screen-read band draws the agent's name and waiting line inside it, so its chips sit
  /// `screenBandTop` below the item's top. The transcript's band puts them `bandTop` below.
  /// Resting higher by the difference keeps the chips where the reader saw them. `nil` for a
  /// band never read off the screen.
  public static func headroom(screenBandTop: Double?, bandTop: Double) -> Double {
    guard let screenBandTop else { return 0 }
    return max(0, screenBandTop - bandTop)
  }

  /// How far the reader is from the rest, in points. It stands in for
  /// `ChatEndProximity.distanceFromEnd` while a band sets the rest.
  ///
  /// More than half a point below the rest counts as infinitely far, because a reader there
  /// has moved on to Send. The space below the rest can be shorter than
  /// `ChatEndProximity.jumpTolerance`, and otherwise a settle there would make the reader a
  /// follower and snap them back to the band. Half a point is the reconcile's no-op guard.
  public static func distanceFromRest(restingOffset: Double, contentOffsetY: Double) -> Double {
    contentOffsetY > restingOffset + 0.5 ? .infinity : max(0, restingOffset - contentOffsetY)
  }
}

extension ChatReplyAnchor {
  /// The place once the chip band the reader may be anchored on leaves the conversation.
  ///
  /// A reader anchored on the band (having scrolled to Send) would otherwise stay put and
  /// not follow the agent's reply. They answered, so they follow it.
  ///
  /// `replyKey` is the band's anchor key, `ChatItem.reply`'s. A reader anchored anywhere else
  /// keeps their place.
  public static func place(_ place: ChatReaderPlace, whenReplyLeaves replyKey: String)
    -> ChatReaderPlace
  {
    guard case .reading(let anchor, _) = place, anchor == replyKey else { return place }
    return .followingLatest
  }
}

/// What the composer does with a request for the keyboard.
///
/// Reply from a Needs-you row asks for the keyboard. While the pane's own question is
/// waiting, the keyboard would cover its chips, so the request is used up without focus. The
/// request waits until the chat has read the session, because the transcript arrives after
/// the screen.
public enum ComposerFocusGate: Equatable, Sendable {
  /// The chat has not read the session yet. Keep the request.
  case wait
  /// The pane is asking its own question. Use up the request and leave the keyboard down.
  case decline
  /// Nothing is asking. Take the keyboard as asked.
  case allow

  /// `isSettled` is whether the chat's read has finished, with a page or without one.
  /// `pendingCall` is the call the page says the agent is waiting on.
  public init(isSettled: Bool, pendingCall: ToolCall?) {
    guard isSettled else {
      self = .wait
      return
    }
    // A question with no chips (an option past the ninth) is answered in the terminal, so
    // the keyboard is not in the way.
    let offersChips = pendingCall.map { $0.asksItsOwnQuestions && !$0.replyChips.isEmpty }
    self = offersChips == true ? .decline : .allow
  }
}
