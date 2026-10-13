/// What the conversation says about itself, at the foot of the transcript.
///
/// Drawn inside the scroll after the last turn, where the agent's next words will appear,
/// not pinned over the composer, which would chase a reader scrolled up into history. A send
/// verdict outranks the agent's state, and the two never stack, so the row does not grow and
/// shrink under a thumb.
public struct ChatActivity: Equatable, Sendable {
  public enum Tone: Equatable, Sendable {
    /// Something is happening and nobody has to do anything about it.
    case progress
    case success
    case failure
    /// Something is waiting on the reader, such as a part-answered question set. Drawn like
    /// `progress` without a spinner, because the reader is the one mid-answer.
    case prompt
  }

  public let message: String
  /// What the far side said, if anything.
  public let detail: String?
  public let tone: Tone
  /// Only a failure offers Retry. Retrying a send that worked would send it twice.
  public let offersRetry: Bool
  /// Whether this row is news about a sent reply rather than about the pane. Stored, because
  /// `Sending…` and `Claude is working.` share a tone. Read by `foot(reporting:answering:)`.
  public let isVerdict: Bool

  public init(
    message: String,
    detail: String?,
    tone: Tone,
    offersRetry: Bool,
    isVerdict: Bool = false
  ) {
    self.message = message
    self.detail = detail
    self.tone = tone
    self.offersRetry = offersRetry
    self.isVerdict = isVerdict
  }

  /// The foot of the transcript, or `nil` when there is nothing worth a row.
  ///
  /// Silence is the common case. A blocked pane shows itself through the emphasised turn and
  /// its chips, and an idle or finished pane has nothing in flight. The row is for what the
  /// transcript cannot show: something running, or a send that just happened.
  public init?(header: PaneComposerHeader, status: PaneComposerStatus?) {
    // A verdict first, whatever the pane is doing.
    if let status {
      self.init(
        message: status.message,
        detail: status.detail,
        tone: Tone(status.tone),
        offersRetry: status.offersRetry,
        isVerdict: true
      )
      return
    }
    guard header.isWorking else { return nil }
    self.init(
      message: header.state,
      detail: nil,
      tone: .progress,
      offersRetry: false
    )
  }

  /// The foot while a multi-question call is part answered, or `nil` for one question or
  /// none, where a tap answers directly.
  ///
  /// Returned from zero answered, so the row does not appear under a thumb on the way to the
  /// next chip. Priority against a send verdict is `foot(reporting:answering:)`'s.
  public static func answering(chosen: Int, of questions: Int) -> ChatActivity? {
    guard questions > 1 else { return nil }
    return ChatActivity(
      message: PaneComposerCopy.answered(chosen: chosen, of: questions),
      detail: nil,
      tone: .prompt,
      offersRetry: false
    )
  }

  /// Which row the foot shows. In order:
  ///
  /// 1. A send verdict, which is the news while a reply is in flight or just landed.
  /// 2. The answered count. Without this, `Claude is working.` on a question herdr has not
  ///    called blocked would hide `0 of 2 answered` exactly where the count is needed.
  /// 3. Whatever the pane is doing.
  public static func foot(reporting activity: ChatActivity?, answering count: ChatActivity?)
    -> ChatActivity?
  {
    if let activity, activity.isVerdict { return activity }
    return count ?? activity
  }

  /// Whether a spinner belongs beside the message. Only progress is still going; `prompt`
  /// waits on the reader.
  public var showsSpinner: Bool { tone == .progress }

  /// One VoiceOver sentence, because a headline and its cause are one fact.
  public var accessibilityLabel: String {
    guard let detail else { return message }
    return "\(message). \(detail)"
  }
}

extension ChatActivity.Tone {
  init(_ tone: PaneComposerStatus.Tone) {
    switch tone {
    case .progress: self = .progress
    case .success: self = .success
    case .failure: self = .failure
    }
  }
}
